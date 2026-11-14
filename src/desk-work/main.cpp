#include "json.hpp"
#include "shell.hpp"
#include "work_updates.hpp"
#include <algorithm>
#include <chrono>
#include <charconv>
#include <cctype>
#include <csignal>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <fcntl.h>
#include <fnmatch.h>
#include <glob.h>
#include <poll.h>
#include <openssl/sha.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/inotify.h>
#include <sys/prctl.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace sh = desk_install::sh;
using J = nlohmann::json;
using A = std::vector<std::string>;
namespace {
std::string env(const char* k, const std::string& fallback = {}) { const auto p = std::getenv(k); return p && *p ? p : fallback; }
std::string str(const J& j, const char* k, const std::string& fallback = {}) {
    const auto it = j.find(k); return it != j.end() && it->is_string() ? it->get<std::string>() : fallback;
}
long long num(const J& j, const char* k, long long fallback = 0) {
    const auto it = j.find(k); return it != j.end() && it->is_number_integer() ? it->get<long long>() : fallback;
}
long long now() { return std::time(nullptr); }
std::string trim(std::string s) { auto a = s.find_first_not_of(" \t\r\n"); return a == s.npos ? "" : s.substr(a, s.find_last_not_of(" \t\r\n") - a + 1); }
bool id_ok(const std::string& s) { return s.size() == 32 && s.find_first_not_of("0123456789abcdef") == s.npos; }
std::string hash(const std::string& s) {
    unsigned char digest[SHA256_DIGEST_LENGTH]; SHA256(reinterpret_cast<const unsigned char*>(s.data()), s.size(), digest);
    static const char hex[] = "0123456789abcdef"; std::string out;
    for (auto b : digest) { out += hex[b >> 4]; out += hex[b & 15]; } return out;
}
std::string read(const fs::path& p, size_t limit = 8 * 1024 * 1024) {
    std::error_code ec;
    if (!fs::is_regular_file(fs::symlink_status(p, ec)) || fs::file_size(p, ec) > limit) return {};
    std::ifstream f(p, std::ios::binary); return f ? std::string(std::istreambuf_iterator<char>(f), {}) : "";
}
J json(const fs::path& p) { auto j = J::parse(read(p), nullptr, false); return j.is_discarded() ? J() : j; }
// A run record without its source snapshot: the snapshot is most of the file (every tracked file's hash), and only
// the freshness checks need it, so a listing of every run skips building it (load_run reads the whole record).
J json_lean(const fs::path& p) {
    const J::parser_callback_t skip = [](int depth, J::parse_event_t event, J& parsed) {
        return !(depth == 1 && event == J::parse_event_t::key && parsed == "snapshot");
    };
    auto j = J::parse(read(p), skip, false);
    return j.is_discarded() ? J() : j;
}
fs::path base() { return fs::path(env("XDG_STATE_HOME", env("HOME") + "/.local/state")) / "foxml/work"; }
bool private_dir(const fs::path& p) {
    std::error_code ec; fs::create_directories(p, ec);
    struct stat s{};
    return !ec && ::lstat(p.c_str(), &s) == 0 && S_ISDIR(s.st_mode) && s.st_uid == ::getuid() && ::chmod(p.c_str(), 0700) == 0;
}
void changed(const fs::path& path, const std::string& data);
J report_client(const std::string& client, const std::string& build, long long pid, const std::string& root, const J& fields);
void record_event(const std::string& root, const std::string& kind, const std::string& identity,
                  const std::string& label, J action, J extra = J::object());
bool atomic(const fs::path& p, const std::string& data) {
    if (!private_dir(p.parent_path())) return false;
    std::string tmp = p.string() + ".XXXXXX"; std::vector<char> name(tmp.begin(), tmp.end()); name.push_back(0);
    const int fd = ::mkstemp(name.data()); if (fd < 0) return false;
    size_t at = 0;
    while (at < data.size()) { const auto n = ::write(fd, data.data() + at, data.size() - at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        at += static_cast<size_t>(n); }
    const bool ok = at == data.size() && ::fsync(fd) == 0; ::close(fd);
    if (ok && ::rename(name.data(), p.c_str()) == 0) { changed(p, data); return true; }
    ::unlink(name.data()); return false;
}
struct Lock {
    int fd = -1;
    explicit Lock(const fs::path& p) {
        if (private_dir(p.parent_path())) fd = ::open(p.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd >= 0 && ::flock(fd, LOCK_EX) < 0) { ::close(fd); fd = -1; }
    }
    ~Lock() { if (fd >= 0) { ::flock(fd, LOCK_UN); ::close(fd); } }
};
std::string query(A a, int seconds = 3) {
    std::string out;
    if (sh::have("timeout")) { a.insert(a.begin(), {"timeout", "-k", "1", std::to_string(seconds)}); }
    return sh::capture(a, out) ? out : "";
}
std::string root_of(const std::string& path) {
    std::error_code ec;
    auto parent = fs::absolute(path, ec);
    bool git = false;
    while (!parent.empty()) {
        if (fs::exists(parent / ".git", ec)) { git = true; break; }
        if (parent == parent.parent_path()) break;
        parent = parent.parent_path();
    }
    // The folder holding .git is the repo's top level (a worktree's .git is a file, which counts the same), so no
    // git call is needed: the drawer asks this for every project on every open.
    return fs::canonical(git ? parent : fs::path(path), ec).string();
}
fs::path project_dir(const std::string& root) { return base() / "projects" / hash(root); }
bool register_root(const std::string& root) { return !root.empty() && atomic(project_dir(root) / "root", root); }
// A refusal always says why; every client shows this text as it is.
J refuse(const std::string& message) { return J{{"ok", false}, {"message", message}}; }
J unwritable() { return refuse("Could not write the work records in " + base().string() + "; the disk may be full or read-only"); }
J written(bool ok, const std::string& what) {
    return ok ? J{{"ok", true}} : refuse("Could not save the " + what + "; the disk may be full or read-only");
}
// Every record a project keeps, with the container its writers expect and the lock they take. A record that cannot be
// read refuses every write (no writer overwrites what it cannot read), so the refusal names it and work health can set
// it aside.
struct RecordSpec { const char* file; const char* label; const char* lock; bool array; };
const std::vector<RecordSpec>& record_specs() {
    static const std::vector<RecordSpec> specs{
        {"tasks.json", "next steps", "tasks.lock", true}, {"reviewed.json", "finished reviews", "reviews.lock", false},
        {"review-marks.json", "review marks", "reviews.lock", false}, {"review-requests.json", "change requests", "reviews.lock", false},
        {"commit-plans.json", "commit plans", "reviews.lock", false}, {"snoozed.json", "snoozes", "snoozed.lock", false},
        {"events.json", "project history", "events.lock", false}, {"seen.json", "read positions", "seen.lock", false}};
    return specs;
}
std::string record_label(const std::string& file) {
    for (const auto& spec : record_specs()) if (file == spec.file) return spec.label;
    return file;
}
J unreadable(const std::string& file) {
    auto out = refuse("The " + record_label(file) + " record (" + file + ") cannot be read, so nothing was changed. "
                      "Work health (:WorkHealth) can set it aside and start a fresh one.");
    out["record"] = file;
    return out;
}
// What a record holds now, read the way its writers read it: missing (nothing yet), ok, or unreadable (every write to
// it would be refused). Cheap enough for each attention read; references are checked only by the full report.
J record_state(const std::string& root, const RecordSpec& spec) {
    const auto path = project_dir(root) / spec.file;
    J state{{"file", spec.file}, {"label", spec.label}};
    struct stat info{};
    if (::lstat(path.c_str(), &info) != 0) { state["state"] = "missing"; return state; }
    state["at"] = static_cast<long long>(info.st_mtime);
    std::string why; J parsed;
    if (!S_ISREG(info.st_mode)) why = "not a regular file";
    else if (info.st_size > 8 * 1024 * 1024) why = "larger than 8 MiB";
    else {
        parsed = J::parse(read(path), nullptr, false);
        if (parsed.is_discarded()) why = "not valid JSON";
        else if (spec.array ? !parsed.is_array() : !parsed.is_object()) why = spec.array ? "not a list" : "not an object";
        else if (std::string(spec.file) == "events.json" && !parsed.value("items", J()).is_array()) why = "no list of events";
    }
    if (!why.empty()) { state["state"] = "unreadable"; state["why"] = why; return state; }
    state["state"] = "ok";
    state["entries"] = std::string(spec.file) == "events.json" ? parsed["items"].size() : parsed.size();
    return state;
}
J records_brief(const std::string& root) {
    J out = J::array();
    for (const auto& spec : record_specs()) {
        auto state = record_state(root, spec);
        if (str(state, "state") == "unreadable") out.push_back(state);
    }
    return out;
}
std::string proc_stamp(long long pid) {
    return desk_install::work_updates::process_stamp(pid);
}
std::string uuid() {
    const auto seed = read("/proc/sys/kernel/random/uuid", 128);
    return hash(seed + std::to_string(::getpid()) + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())).substr(0, 32);
}
bool signal_change(const std::string& root) {
    if (root.empty()) return false;
    const auto event = J{{"version", 1}, {"root", root}, {"revision", uuid()}, {"at", now()}}.dump();
    const bool local = atomic(project_dir(root) / "revision.json", event);
    return atomic(base() / "revision.json", event) && local;
}
void changed(const fs::path& path, const std::string& data) {
    const auto name = path.filename().string();
    // Cache reads and event markers never announce themselves: that would make refreshes feed back forever.
    const bool record = std::any_of(record_specs().begin(), record_specs().end(), [&](const RecordSpec& spec) { return name == spec.file; });
    if (name == "run.json") {
        const auto job = J::parse(data, nullptr, false);
        if (job.is_object()) {
            const auto state = str(job, "state"), root = str(job, "root");
            const auto title = !str(job, "title").empty() ? str(job, "title") : job.value("testRun", false) ? "Tests" : !str(job, "kind").empty() ? str(job, "kind") : "Job";
            record_event(root, "job", str(job, "id") + ':' + state,
                title + " · " + state,
                J{{"kind", job.value("testRun", false) ? "tests" : "log"}, {"id", str(job, "id")}},
                J{{"state", state}, {"run", str(job, "id")}});
            signal_change(root);
        }
    } else if (record) signal_change(trim(read(path.parent_path() / "root")));
    else if (path.parent_path().filename() == "plans" || path.parent_path().filename() == "agents")
        signal_change(trim(read(path.parent_path().parent_path() / "root")));
}
int watch_changes(const std::string& root, bool all, const std::string& client = {}, const std::string& build = {}) {
    if (root.empty() && !all) return 2;
    const auto folder = all ? base() : project_dir(root);
    if (!private_dir(folder)) return 1;
    const auto marker = folder / "revision.json";
    std::string previous;
    long long reported = 0;
    const auto publish = [&](bool resumed = false) {
        auto event = json(marker);
        if (!event.is_object()) event = J{{"version", 1}, {"revision", ""}, {"root", root}};
        const auto text = event.dump();
        if (text != previous || resumed) {
            if (resumed) event["reason"] = "resume";
            std::cout << event.dump() << '\n' << std::flush; previous = text;
            // A burst of edits is many events; the client record needs one write per quiet spell, not one per event.
            if (!client.empty() && now() - reported >= 15) {
                report_client(client, build, ::getppid(), all ? "" : root,
                    J{{"stream", "connected"}, {"eventAt", now()}, {"retryAt", 0}, {"watchPid", ::getpid()}, {"watchProcess", proc_stamp(::getpid())}});
                reported = now();
            }
        }
    };
    // Each subscriber owns its child. Closing an editor or unloading a mod cannot leave a watcher behind.
    const auto owner = ::getppid();
    ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (::getppid() != owner) return 0;
    const int fd = ::inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    const int wd = fd >= 0 ? ::inotify_add_watch(fd, folder.c_str(), IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF) : -1;
    publish();
    auto last_tick = now();
    char events[16384];
    for (;;) {
        if (wd >= 0) {
            pollfd interest{fd, POLLIN, 0};
            const auto ready = ::poll(&interest, 1, 1000);
            if (ready < 0 && errno != EINTR) { ::close(fd); return 1; }
            if (ready > 0) while (::read(fd, events, sizeof(events)) > 0) {}
        } else ::usleep(1000000);
        const auto tick = now();
        publish(tick - last_tick > 10 || tick < last_tick); last_tick = tick;
        if (!std::cout.good()) { if (fd >= 0) ::close(fd); return 0; }
    }
}
std::vector<std::string> split(const std::string& s, char sep = '\n') {
    std::istringstream in(s); std::vector<std::string> out; std::string v;
    while (std::getline(in, v, sep)) if (!v.empty()) out.push_back(v);
    return out;
}
#include "history.hpp"
bool source(const fs::path& p) {
    const auto name = p.filename().string();
    static const std::set<std::string> ext = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".inl", ".ipp", ".py", ".lua", ".sh", ".zsh", ".rs", ".go", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".qml", ".cmake", ".json", ".toml", ".yaml", ".yml", ".conf", ".cfg", ".ini", ".css", ".html", ".proto", ".txt"};
    std::string low = p.string(); std::transform(low.begin(), low.end(), low.begin(), ::tolower);
    if (low.find("secret") != low.npos || low.find("credential") != low.npos || low.find(".env") != low.npos || low.find("private") != low.npos) return false;
    for (const auto& part : p) if (part == ".." || part.string().front() == '.') return false;
    return !p.is_absolute() && (ext.count(p.extension().string()) || name == "Makefile" || name == "Dockerfile");
}
bool private_repo(const std::string& root) {
    for (const auto& p : split(read(fs::path(env("XDG_CONFIG_HOME", env("HOME") + "/.config")) / "foxml/claude-private-repos")))
        if (trim(p) == root) return true;
    return false;
}
J snapshot(const std::string& root, const fs::path& dest = {}) {
    J out{{"files", J::object()}, {"complete", true}, {"head", ""}};
    std::error_code error;
    if (!fs::exists(fs::path(root) / ".git", error)) { out["complete"] = false; return out; }
    out["head"] = trim(query({"git", "-C", root, "rev-parse", "--verify", "--quiet", "HEAD"}));
    std::string files;
    A args{"git", "--no-optional-locks", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"};
    if (private_repo(root) || !sh::capture(args, files)) { out["complete"] = false; return out; }
    size_t bytes = 0, count = 0;
    std::set<std::string> paths;
    for (const auto& p : split(files, '\0')) if (source(p)) paths.insert(p);
    for (const auto& p : paths) {
        std::error_code ec; const auto path = fs::path(root) / p;
        if (!fs::exists(path, ec)) continue;
        const auto canonical = fs::canonical(path, ec);
        if (ec || canonical != path.lexically_normal() || !fs::is_regular_file(fs::symlink_status(path, ec))) { out["complete"] = false; continue; }
        const auto size = fs::file_size(path, ec);
        if (ec || size > 1024 * 1024 || bytes + size > 32 * 1024 * 1024 || ++count > 4000) { out["complete"] = false; continue; }
        auto content = read(path, 1024 * 1024);
        if (content.find('\0') != content.npos) continue;
        bytes += content.size();
        const auto digest = hash(content);
        out["files"][p] = digest;
        if (!dest.empty()) {
            const auto blob = base() / "blobs" / digest;
            // Most builds read identical source: keep one private copy of each version.
            std::error_code error;
            if ((!fs::is_regular_file(fs::symlink_status(blob, error)) || hash(read(blob, 1024 * 1024)) != digest)
                && !atomic(blob, content)) out["complete"] = false;
        }
    }
    out["fingerprint"] = hash(out["files"].dump()); return out;
}
bool same_source(const J& a, const J& b) {
    return a.is_object() && b.is_object() && a.value("complete", false) && b.value("complete", false)
        && str(a, "fingerprint") == str(b, "fingerprint");
}
void freshness(J& job, const J& current) {
    const auto& captured = job["snapshot"];
    job["stale"] = job.value("changedDuringRun", false) || !same_source(captured, current);
    job["changedFiles"] = nullptr;
    if (!captured.is_object() || !captured.value("complete", false) || !current.value("complete", false)
        || !captured.contains("files") || !captured["files"].is_object()) return;
    std::set<std::string> paths;
    for (const auto& version : {captured["files"], current["files"]})
        for (auto it = version.begin(); it != version.end(); ++it) paths.insert(it.key());
    J changed = J::array();
    for (const auto& path : paths)
        if (!captured["files"].contains(path) || !current["files"].contains(path)
            || captured["files"][path] != current["files"][path]) changed.push_back(path);
    job["changedFiles"] = changed;
}
std::string clean(std::string s) {
    s = std::regex_replace(s, std::regex("\x1b\\[[0-?]*[ -/]*[@-~]"), "");
    s = std::regex_replace(s, std::regex("\x1b\\][^\x07]*(\x07|\x1b\\\\)"), "");
    s.erase(std::remove_if(s.begin(), s.end(), [](unsigned char c) { return c < 32 && c != '\n' && c != '\t'; }), s.end());
    return s;
}
int count(const std::string& s) {
    int n = 0; const auto parsed = std::from_chars(s.data(), s.data() + s.size(), n);
    return parsed.ec == std::errc{} && parsed.ptr == s.data() + s.size() && n >= 0 ? n : -1;
}
J parse_tests(const std::string& log, const std::string& root, const std::string& cwd = {}) {
    J out{{"passed", nullptr}, {"failed", nullptr}, {"failures", J::array()}};
    const std::regex counts("([0-9]+) (passed|failed|failures)(?:\\b)");
    const std::regex gtest("\\[\\s*(PASSED|FAILED)\\s*\\]\\s+([0-9]+) tests?");
    const std::regex ctest("([0-9]+)% tests passed, ([0-9]+) tests failed out of ([0-9]+)");
    const std::regex loc("^\\s*(.+?):([0-9]+)(?::([0-9]+))?:\\s*(.*)$");
    const std::regex gloc("^\\s*(.+?)\\(([0-9]+)\\):\\s*(?:error:)?\\s*(.*)$");
    const std::regex unittest("^Ran ([0-9]+) tests? in ");
    int unit_total = -1;
    long long ctest_pass = 0, ctest_fail = 0;
    bool saw_ctest = false;
    const auto add = [&](const char* key, int n) { if (n >= 0) out[key] = num(out, key) + n; };
    fs::path context = cwd.empty() ? root : cwd;
    for (const auto& line : split(clean(log))) {
        if (line.size() > 8192) continue;
        std::smatch m;
        if (std::regex_search(line, m, std::regex("(?:Entering directory|Test project) ['`]?(.+?)['`]?$"))) {
            fs::path p = m[1].str(); if (p.is_absolute()) context = p;
        }
        if (std::regex_search(line, m, ctest)) {
            const int fail = count(m[2]), total = count(m[3]);
            if (fail >= 0 && total >= fail) { saw_ctest = true; ctest_fail += fail; ctest_pass += total - fail; }
        } else if (std::regex_search(line, m, gtest)) add(m[1] == "PASSED" ? "passed" : "failed", count(m[2]));
        else if (std::regex_search(line, m, unittest)) unit_total = count(m[1]);
        else if (unit_total >= 0 && line.rfind("OK", 0) == 0) { add("passed", unit_total); add("failed", 0); unit_total = -1; }
        else if (unit_total >= 0 && line.rfind("FAILED (", 0) == 0) {
            int fail = 0;
            const std::regex fields("(?:failures|errors)=([0-9]+)");
            for (std::sregex_iterator i(line.begin(), line.end(), fields), end; i != end; ++i) fail += std::max(0, count((*i)[1]));
            add("failed", fail); add("passed", std::max(0, unit_total - fail)); unit_total = -1;
        } else if (line.find("passed") != line.npos || line.find("failed") != line.npos) {
            for (std::sregex_iterator i(line.begin(), line.end(), counts), end; i != end; ++i)
                add((*i)[2] == "passed" ? "passed" : "failed", count((*i)[1]));
        }
        fs::path file; int lnum = 0, col = 1; std::string message;
        if (std::regex_match(line, m, loc)) { file = m[1].str(); lnum = count(m[2]); if (m[3].matched) col = std::max(1, count(m[3])); message = m[4]; }
        else if (std::regex_match(line, m, gloc)) { file = m[1].str(); lnum = count(m[2]); message = m[3]; }
        else if (std::regex_search(line, m, std::regex("File \"([^\"]+)\", line ([0-9]+)"))) { file = m[1].str(); lnum = count(m[2]); message = "test traceback"; }
        if (file.empty() || lnum <= 0 || out["failures"].size() >= 200) continue;
        if (file.is_relative()) file = context / file;
        std::error_code ec; const auto resolved = fs::weakly_canonical(file, ec);
        const auto rel = resolved.lexically_relative(root);
        if (ec || rel.empty() || *rel.begin() == ".." || !fs::is_regular_file(resolved, ec)) continue;
        if (message.find("warning:") != message.npos || message.find("note:") != message.npos) continue;
        out["failures"].push_back(J{{"filename", resolved.string()}, {"lnum", lnum}, {"col", col}, {"text", message.substr(0, 500)}, {"type", "E"}});
    }
    // CTest totals already include any child gtest summaries printed on failure.
    if (saw_ctest) { out["passed"] = ctest_pass; out["failed"] = ctest_fail; out["scope"] = "ctest"; }
    else out["scope"] = "reported";
    if (!out["passed"].is_null() && out["failed"].is_null()) out["failed"] = 0;
    return out;
}
fs::path run_dir(const std::string& id) { return id_ok(id) ? base() / "runs" / id : fs::path(); }
// A run is two files: run.json (small, read for every listing) and snapshot.json (the source snapshot, read only by
// the freshness checks). Records written before the split carry their snapshot inline; both read the same way.
J load_run(const std::string& id) {
    if (!id_ok(id)) return J();
    auto j = json(run_dir(id) / "run.json");
    if (j.is_object() && !j.contains("snapshot") && fs::exists(run_dir(id) / "snapshot.json")) j["snapshot"] = json(run_dir(id) / "snapshot.json");
    return j;
}
std::string command_key(const J& job) {
    return J::array({str(job, "root"), str(job, "cwd", str(job, "root")), str(job, "command")}).dump();
}
bool save_run(const fs::path& dir, J j) {
    if (j.contains("snapshot")) {
        if (!atomic(dir / "snapshot.json", j["snapshot"].dump())) return false;
        j.erase("snapshot");
    }
    return atomic(dir / "run.json", j.dump());
}
J runs(const std::string& root = {}) {
    J out = J::array(); std::error_code ec;
    for (const auto& e : fs::directory_iterator(base() / "runs", ec)) {
        if (!id_ok(e.path().filename().string()) || e.is_symlink(ec)) continue;
        auto j = json_lean(e.path() / "run.json"); if (!j.is_object() || (!root.empty() && str(j, "root") != root)) continue;
        if (str(j, "state") == "running" && proc_stamp(num(j, "pid")) != str(j, "process")) j["state"] = "interrupted";
        j["elapsed"] = std::max(0LL, (num(j, "ended") ? num(j, "ended") : now()) - num(j, "started"));
        struct stat st{}; const auto log = e.path() / "output.log";
        j["activity"] = ::stat(log.c_str(), &st) == 0 ? std::max(num(j, "started"), static_cast<long long>(st.st_mtime)) : num(j, "started");
        j["log"] = log.string(); out.push_back(j);
    }
    std::sort(out.begin(), out.end(), [](const J& a, const J& b) { return num(a, "startedNs", num(a, "started") * 1000000000LL) > num(b, "startedNs", num(b, "started") * 1000000000LL); });
    // A running job's estimate: how long the newest pass of the exact same command in the same checkout took.
    std::map<std::string, long long> took;
    for (const auto& r : out) {
        const auto took_s = num(r, "ended") - num(r, "started");
        if (str(r, "state") == "passed" && num(r, "ended") > 0 && took_s >= 1) took.emplace(command_key(r), took_s);
    }
    for (auto& r : out) if (str(r, "state") == "running") {
        const auto it = took.find(command_key(r));
        if (it != took.end()) r["estimate"] = it->second;
    }
    return out;
}
std::string kind_of(const std::string& command) {
    if (std::regex_search(command, std::regex("(^|[ /;&|])(ctest|pytest|test_[^ /;&|]*|[^ /;&|]*_test)([ ;&|]|$)|\\b(cargo|go|npm|pnpm|bun) (run )?test\\b|\\bmake[^;&|]*\\btest\\b|unittest"))) return "tests";
    if (std::regex_search(command, std::regex("\\b(make|ninja|cmake|cargo|meson|gcc|g\\+\\+|clang\\+\\+|rustc)\\b|\\b(npm|pnpm|bun) (run )?build\\b"))) return "build";
    if (std::regex_search(command, std::regex("\\b(curl|wget|aria2c|llm-update)\\b"))) return "download";
    return {};
}
bool observable(const std::string& command) {
    if (command.empty() || command.size() > 4000 || std::isspace(static_cast<unsigned char>(command[0])) || trim(command).back() == '&'
        || command.find("<<") != command.npos || std::regex_search(command, std::regex("desk-work|fox-work|\\bfjob\\b|password|token|secret|authorization|\\bpass\\b|\\bsudo\\b|\\bexport\\b|sk-|ghp_| -u |--user ", std::regex::icase))) return false;
    const std::regex prefix("^(?:(?:[A-Za-z_][A-Za-z0-9_]*=\\S*|command|env|nice)\\s+|timeout\\s+(?:-\\S+\\s+)*\\S+\\s+)+");
    const std::regex runner("^(?:(?:make|ninja|cmake|ctest|pytest|cargo|meson|curl|wget|aria2c|llm-update)\\b|(?:npm|pnpm|bun|go) (?:run )?(?:test|build)\\b|python3? (?:-\\S+ )*-m (?:unittest|pytest)\\b|(?:python3?|node|bun) (?:-\\S+ )*[A-Za-z0-9_.~/\\-]*(?:test_[A-Za-z0-9_]+|[A-Za-z0-9_]+_test|[A-Za-z0-9_]+\\.test)\\.[A-Za-z0-9]+|[A-Za-z0-9_.~/\\-]*/(?:test_[A-Za-z0-9_]+|[A-Za-z0-9_]+_test)\\b)");
    const std::regex separator("[;&|\\n()]");
    for (std::sregex_token_iterator i(command.begin(), command.end(), separator, -1), end; i != end; ++i) {
        auto segment = std::regex_replace(trim(i->str()), prefix, "");
        if (std::regex_search(segment, runner)) return true;
    }
    return false;
}
// Runs older than 30 days go: estimates, failures and the notebook look back a day or a few weeks at most, and every
// listing reads every run. Judged by the record's file date, so it costs a stat per run, not a read.
void prune_old_runs() {
    std::error_code ec;
    const auto limit = fs::file_time_type::clock::now() - std::chrono::hours(24 * 30);
    for (const auto& e : fs::directory_iterator(base() / "runs", ec)) {
        if (!id_ok(e.path().filename().string()) || e.is_symlink(ec)) continue;
        std::error_code tec; const auto when = fs::last_write_time(e.path() / "run.json", tec);
        if (!tec && when < limit) fs::remove_all(e.path(), tec);
    }
}
J begin(const std::string& command, const std::string& root, const std::string& session, long long pid, bool observed, const std::string& title = {}, const std::string& cwd = {}) {
    std::error_code cwd_error;
    const auto current = fs::current_path();
    const bool cwd_known = !cwd.empty() || root_of(current.string()) == root;
    const auto where = fs::canonical(cwd.empty() ? (cwd_known ? current : fs::path(root)) : fs::path(cwd), cwd_error).string();
    if (cwd_error || root_of(where) != root) return J();
    if (!register_root(root)) return J();
    prune_old_runs();
    const auto id = uuid(); const auto dir = run_dir(id);
    auto snap = snapshot(root, dir / "source");
    if (!cwd_known) snap["complete"] = false;
    std::string green;
    const J identity{{"root", root}, {"cwd", where}, {"command", command}};
    for (const auto& r : runs(root)) if (command_key(r) == command_key(identity) && str(r, "state") == "passed" && r.value("baselineEligible", false)) { green = str(r, "id"); break; }
    J j{{"id", id}, {"root", root}, {"command", command.substr(0, 4000)}, {"kind", kind_of(command)}, {"session", session},
        {"pane", env("TMUX_PANE")}, {"pid", pid}, {"process", proc_stamp(pid)}, {"started", now()}, {"state", "running"}, {"cwd", where}, {"cwdKnown", cwd_known},
        {"snapshot", snap}, {"baseline", green}, {"observed", observed},
        // The commit the run started on, and whether the tree was exactly that commit: only then does a test run
        // speak for the commit itself (the review tree's "tests passed here").
        {"head", str(snap, "head")},
        {"clean", trim(query({"git", "--no-optional-locks", "-C", root, "status", "--porcelain", "--untracked-files=no"})).empty()},
        {"startedNs", std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count()}};
    // What the command does in plain words (Claude's description of it), shown in place of the command.
    const auto named = trim(clean(title));
    if (!named.empty() && named.find('\n') == std::string::npos) j["title"] = named.substr(0, 160);
    return save_run(dir, j) ? j : J();
}
// How many runs of the same command in the same checkout failed in a row just before this one; a stop is skipped.
long long failed_before(const J& job) {
    long long n = 0; const auto started = num(job, "startedNs", num(job, "started") * 1000000000LL);
    for (const auto& r : runs(str(job, "root"))) {
        if (str(r, "id") == str(job, "id") || command_key(r) != command_key(job)
            || num(r, "startedNs", num(r, "started") * 1000000000LL) >= started) continue;
        const auto state = str(r, "state");
        if (state == "failed") ++n;
        else if (state == "passed") break;
    }
    return n;
}
bool finish(J& j, int code, bool truncated) {
    if (!j.is_object()) return false;
    j["ended"] = now(); j["exit"] = code; j["truncated"] = truncated;
    j["failedBefore"] = failed_before(j);
    j["state"] = code == 0 ? "passed" : code >= 128 || code < 0 ? "interrupted" : "failed";
    j["tests"] = parse_tests(read(run_dir(str(j, "id")) / "output.log"), str(j, "root"), str(j, "cwd"));
    j["testRun"] = str(j, "kind") == "tests" || !j["tests"]["passed"].is_null() || !j["tests"]["failed"].is_null();
    if (!same_source(j["snapshot"], snapshot(str(j, "root")))) j["changedDuringRun"] = true;
    if (j.value("changedDuringRun", false) || truncated || num(j["tests"], "failed") > 0) j["baselineEligible"] = false;
    else j["baselineEligible"] = j["testRun"].get<bool>() && code == 0 && num(j["tests"], "passed") > 0 && j["snapshot"].value("complete", false);
    if (!save_run(run_dir(str(j, "id")), j)) return false;
    return true;
}
J tasks(const std::string& root) { auto j = json(project_dir(root) / "tasks.json"); return j.is_array() ? j : J::array(); }
J task_change(const std::string& root, const std::string& text, const std::string& id) {
    if (!register_root(root)) return unwritable();
    Lock lock(project_dir(root) / "tasks.lock"); if (lock.fd < 0) return unwritable();
    const auto file = project_dir(root) / "tasks.json";
    auto j = json(file); std::error_code ec;
    if (fs::exists(file, ec) && !j.is_array()) return unreadable("tasks.json");
    if (!j.is_array()) j = J::array();
    if (id.empty()) {
        if (j.size() >= 200) return refuse("A project keeps at most 200 next steps; mark some done first");
        if (trim(text).empty() || text.size() > 2000) return refuse("A next step needs some text, up to 2000 characters");
        j.push_back(J{{"id", uuid()}, {"text", trim(text)}, {"done", false}, {"at", now()}});
    } else { bool found = false; for (auto& t : j) if (str(t, "id") == id) { t["done"] = !t.value("done", false); found = true; }
        if (!found) return J{{"ok", false}, {"message", "That next step is no longer here"}};
    }
    if (!atomic(file, j.dump())) return written(false, "next steps");
    return J{{"ok", true}, {"message", id.empty() ? "Next step pinned" : "Next step updated"}};
}
// The file a commit, checkout or rebase in this checkout touches: .git/logs/HEAD, or its worktree's own.
fs::path head_log(const std::string& root) {
    const auto dot = fs::path(root) / ".git";
    std::error_code ec;
    if (fs::is_directory(dot, ec)) return dot / "logs/HEAD";
    const auto line = trim(read(dot));
    if (line.rfind("gitdir:", 0) != 0) return dot;
    fs::path dir = trim(line.substr(7));
    if (dir.is_relative()) dir = fs::path(root) / dir;
    return dir / "logs/HEAD";
}
long long stamp_of(const fs::path& p) {
    std::error_code ec; const auto t = fs::last_write_time(p, ec);
    return ec ? 0 : static_cast<long long>(t.time_since_epoch().count());
}
J review_progress(const std::string& root, const std::string& only);
// A finished review is also stamped on the commit as a git note (refs/notes/reviews): it lives in the repository, so
// it survives a reinstall and travels with `git push origin refs/notes/reviews`. History is never rewritten.
const char* const REVIEW_NOTES = "reviews";
std::set<std::string> stamped_commits(const std::string& root) {
    std::set<std::string> out;
    for (const auto& line : split(query({"git", "--no-optional-locks", "-C", root, "notes", "--ref", REVIEW_NOTES, "list"}))) {
        std::istringstream fields(line); std::string note, commit;
        if (fields >> note >> commit && commit.size() == 40) out.insert(commit);
    }
    return out;
}
J reviews(const std::string& root, bool today_only = true) {
    std::error_code error;
    if (!fs::exists(fs::path(root) / ".git", error)) return J::array();
    // Kept until the checkout's history or the review marks change (or the day turns): the drawer asks every open.
    const std::time_t clock = std::time(nullptr);
    std::tm day = *std::localtime(&clock);
    const auto signature = std::to_string(stamp_of(head_log(root))) + "|" + std::to_string(stamp_of(project_dir(root) / "reviewed.json"))
                           + "|" + std::to_string(stamp_of(project_dir(root) / "review-marks.json"))
                           + "|" + trim(query({"git", "--no-optional-locks", "-C", root, "rev-parse", "--verify", "--quiet", std::string("refs/notes/") + REVIEW_NOTES}))
                           + "|" + std::to_string(day.tm_year) + "-" + std::to_string(day.tm_yday) + "|" + (today_only ? "today" : "all");
    const auto cached = json(project_dir(root) / "reviews-cache.json");
    if (cached.is_object() && str(cached, "signature") == signature && cached["reviews"].is_array()) return cached["reviews"];
    const auto marks = json(project_dir(root) / "reviewed.json");
    const auto progress = review_progress(root, "");
    const auto stamped = stamped_commits(root);
    A a{"git", "--no-optional-locks", "-C", root, "log", "-80", "--format=%H%x1f%ct%x1f%s%x1f%(trailers:key=Claude-Session,valueonly)%x1f%(trailers:key=Co-Authored-By,valueonly)%x1e"};
    J out = J::array();
    const std::time_t time = std::time(nullptr);
    std::tm midnight = *std::localtime(&time);
    midnight.tm_hour = midnight.tm_min = midnight.tm_sec = 0; midnight.tm_isdst = -1;
    const auto start = std::mktime(&midnight);
    for (const auto& entry : split(query(a), '\x1e')) {
        std::vector<std::string> f; std::istringstream fields(trim(entry)); std::string field;
        while (std::getline(fields, field, '\x1f')) f.push_back(field);
        if (f.size() < 4 || f[0].size() != 40) continue;
        if (f[3].empty() && (f.size() < 5 || (f[4].find("Claude") == std::string::npos && f[4].find("claude") == std::string::npos))) continue;
        long long at = 0; try { at = std::stoll(f[1]); } catch (...) { continue; }
        const bool seen = (marks.is_object() && marks.contains(f[0])) || stamped.count(f[0]) > 0;
        if (today_only && (at < start || seen)) continue;
        J row{{"sha", f[0]}, {"at", at}, {"subject", f[2]}, {"root", root}, {"reviewed", seen}};
        if (progress.contains(f[0])) { row["checked"] = progress[f[0]]["checked"]; row["total"] = progress[f[0]]["total"]; }
        out.push_back(row);
    }
    if (register_root(root)) atomic(project_dir(root) / "reviews-cache.json", J{{"signature", signature}, {"reviews", out}}.dump());
    return out;
}
J reviewed(const std::string& root, const std::string& sha) {
    if (!std::regex_match(sha, std::regex("[a-f0-9]{40}")) || trim(query({"git", "-C", root, "rev-parse", "--verify", sha + "^{commit}"})) != sha)
        return refuse("That commit is not in this repository");
    if (!register_root(root)) return unwritable();
    const auto file = project_dir(root) / "reviewed.json"; Lock lock(project_dir(root) / "reviews.lock");
    auto j = json(file); std::error_code ec;
    if (lock.fd < 0) return unwritable();
    if (fs::exists(file, ec) && !j.is_object()) return unreadable("reviewed.json");
    if (!j.is_object()) j = J::object();
    j[sha] = now();
    const bool ok = atomic(file, j.dump());
    if (ok) record_event(root, "review", "commit:" + sha, sha.substr(0, 8) + " · review finished", J{{"kind", "reviews"}, {"id", sha}});
    // The stamp on the commit itself: who, when, how many files. Best effort; the local record above is the truth here.
    if (ok && env("DESK_REVIEW_NOTES", env("FOXML_REVIEW_NOTES", "1")) != "0") {
        const auto who = trim(query({"git", "-C", root, "config", "user.name"}));
        const auto progress = review_progress(root, sha);
        const int files = progress.contains(sha) ? progress[sha].value("total", 0) : 0;
        char day[32] = {}; const std::time_t t = std::time(nullptr); std::strftime(day, sizeof day, "%Y-%m-%d", std::localtime(&t));
        const std::string note = "Reviewed-by: " + (who.empty() ? std::string("unknown") : who) + "\nReviewed-on: " + day
                                 + (files > 0 ? "\nReviewed-files: " + std::to_string(files) : "");
        query({"git", "-C", root, "notes", "--ref", REVIEW_NOTES, "add", "-f", "-m", note, sha});
    }
    return written(ok, "finished review");
}
// Review progress shared by Neovim, the notebook and the drawer. One review is a key (a commit sha, a session id, or
// "working"); each checked file keeps the signature of the two sides that were read and, for a file on disk, the hash
// of its content then, so "changed since review" is a comparison and never a guess. Checks are never dropped when a
// file changes: the old one stays as history under "before".
bool review_key_ok(const std::string& key) { return std::regex_match(key, std::regex("[A-Za-z0-9_-]{1,64}")); }
bool review_file_ok(const std::string& rel) {
    return !rel.empty() && rel.size() <= 1024 && rel[0] != '/' && rel.find('\0') == std::string::npos
        && rel.find("..") == std::string::npos && rel.find('\n') == std::string::npos;
}
J review_mark(const std::string& root, const std::string& key, const std::string& rel, const std::string& signature,
              const std::string& content, const std::string& total, const std::string& done) {
    if (!review_key_ok(key) || (!rel.empty() && !review_file_ok(rel))) return refuse("That review or file name is not one the review keeps");
    if (!register_root(root)) return unwritable();
    if ((!signature.empty() && !std::regex_match(signature, std::regex("[a-f0-9]{64}")))
        || (!content.empty() && !std::regex_match(content, std::regex("[a-f0-9]{64}")))) return refuse("Review signatures are SHA-256 hashes");
    const auto file = project_dir(root) / "review-marks.json"; Lock lock(project_dir(root) / "reviews.lock");
    auto j = json(file); std::error_code ec;
    if (lock.fd < 0) return unwritable();
    if (fs::exists(file, ec) && !j.is_object()) return unreadable("review-marks.json");
    if (!j.is_object()) j = J::object();
    auto& review = j[key];
    if (!review.is_object()) review = J{{"files", J::object()}};
    if (!review["files"].is_object()) review["files"] = J::object();
    if (!rel.empty()) {
        if (signature.empty()) review["files"].erase(rel);
        else {
            J mark{{"signature", signature}, {"at", now()}};
            if (!content.empty()) mark["content"] = content;
            const auto old = review["files"].find(rel);
            if (old != review["files"].end() && old->is_object() && str(*old, "signature") != signature)
                mark["before"] = J{{"signature", str(*old, "signature")}, {"at", old->value("at", 0LL)}};
            review["files"][rel] = mark;
        }
    }
    if (!total.empty()) { try { review["total"] = std::clamp(std::stoi(total), 0, 100000); } catch (...) { return refuse("The file total must be a number"); } }
    if (!done.empty()) review["completed"] = done == "yes";
    review["at"] = now();
    // Old reviews go after 90 days, so the file stays small.
    for (auto it = j.begin(); it != j.end();) {
        if (it.key() != key && it->is_object() && now() - it->value("at", 0LL) > 90LL * 86400) it = j.erase(it); else ++it;
    }
    const bool saved = atomic(file, j.dump());
    if (saved && !rel.empty()) record_event(root, "review", key + ':' + rel + ':' + signature,
        rel + (signature.empty() ? " · review unchecked" : " · reviewed"),
        std::regex_match(key, std::regex("[a-f0-9]{40}")) ? J{{"kind", "reviews"}, {"id", key}, {"file", rel}} : J{{"kind", "file-diff"}, {"file", rel}}, J{{"file", rel}});
    return written(saved, "review mark");
}
// Every review of this checkout with, per file, whether its check still holds: "checked", or "changed" when the file
// on disk no longer has the content that was read (only where that content was recorded: a commit's never changes).
// Change requests: a note the reader sent to a session about a file. Kept here (not only in the editor) so the
// notebook can show the thread: who was asked, what for, and whether the file has changed since ("ready").
J review_request(const std::string& root, const std::string& rel, const std::string& name, const std::string& sid,
                 const std::string& text, bool clear) {
    if (!review_file_ok(rel) || (!sid.empty() && !review_key_ok(sid))) return refuse("That file or session name is not one the review keeps");
    if (!register_root(root)) return unwritable();
    const auto file = project_dir(root) / "review-requests.json"; Lock lock(project_dir(root) / "reviews.lock");
    auto j = json(file); std::error_code ec;
    if (lock.fd < 0) return unwritable();
    if (fs::exists(file, ec) && !j.is_object()) return unreadable("review-requests.json");
    if (!j.is_object()) j = J::object();
    if (clear) j.erase(rel);
    else {
        const auto path = fs::path(root) / rel;
        const auto line = [](std::string s) { s = clean(s); for (auto& c : s) if (c == '\n' || c == '\r' || c == '\t') c = ' '; return s; };
        j[rel] = J{{"name", line(name).substr(0, 80)}, {"sid", sid}, {"text", line(text).substr(0, 300)}, {"at", now()},
                   {"content", fs::is_regular_file(path, ec) ? hash(read(path)) : hash("")}};
    }
    for (auto it = j.begin(); it != j.end();)
        it = (!it->is_object() || now() - it->value("at", 0LL) > 90LL * 86400) ? j.erase(it) : std::next(it);
    const bool saved = atomic(file, j.dump());
    if (saved) record_event(root, "request", rel + ':' + hash(j.dump()), rel + (clear ? " · request settled" : " · changes requested"),
        J{{"kind", "file-diff"}, {"file", rel}}, J{{"file", rel}, {"state", clear ? "settled" : "waiting"}});
    return written(saved, "change request");
}
J review_requests(const std::string& root) {
    J out = J::array();
    const auto j = json(project_dir(root) / "review-requests.json");
    if (!j.is_object()) return out;
    for (const auto& [rel, request] : j.items()) {
        if (!request.is_object() || !review_file_ok(rel)) continue;
        std::error_code ec; const auto path = fs::path(root) / rel;
        const bool changed = (fs::is_regular_file(path, ec) ? hash(read(path)) : hash("")) != str(request, "content");
        out.push_back(J{{"file", rel}, {"name", str(request, "name")}, {"sid", str(request, "sid")}, {"text", str(request, "text")},
                        {"at", request.value("at", 0LL)}, {"state", changed ? "ready" : "waiting"}});
    }
    std::sort(out.begin(), out.end(), [](const J& a, const J& b) { return a.value("at", 0LL) > b.value("at", 0LL); });
    return out;
}
bool agent_name_ok(const std::string& name) { return std::regex_match(name, std::regex("[a-z][a-z0-9_-]{0,31}")); }
J agent_update(const std::string& root, const std::map<std::string, std::string>& opts) {
    const auto get = [&](const char* key) { const auto it = opts.find(key); return it == opts.end() ? std::string() : it->second; };
    const auto agent = get("--agent"), sid = get("--session"), state = get("--state");
    if (!agent_name_ok(agent) || !std::regex_match(sid, std::regex("[A-Za-z0-9_-]{1,80}")))
        return refuse("Agent updates need a lowercase agent name and a session id");
    if (!std::set<std::string>{"working", "waiting", "needs", "error", "compacting", "done"}.count(state))
        return refuse("An agent state is working, waiting, needs, error, compacting or done");
    if (!register_root(root)) return unwritable();
    const auto path = project_dir(root) / "agents" / (hash(agent + ':' + sid) + ".json");
    Lock lock(project_dir(root) / "agents.lock");
    if (lock.fd < 0) return unwritable();
    if (state == "done") {
        std::error_code ec; fs::remove(path, ec);
        if (!ec) signal_change(root);
        return ec ? refuse("Could not remove the agent record: " + ec.message()) : J{{"ok", true}};
    }
    const auto pid = get("--pid") == "parent" ? static_cast<long long>(::getppid()) : std::stoll(get("--pid"));
    const auto process = proc_stamp(pid);
    if (process.empty()) return refuse("That process is not running");
    auto previous = json(path);
    J files = previous.is_object() && str(previous, "process") == process && previous.value("files", J()).is_array()
        ? previous["files"] : J::array();
    auto times = previous.is_object() && str(previous, "process") == process && previous.value("fileTimes", J()).is_object()
        ? previous["fileTimes"] : J::object();
    const auto file = get("--file");
    std::string edited;
    if (!file.empty()) {
        std::error_code ec; const auto resolved = fs::weakly_canonical(fs::path(root) / file, ec);
        const auto rel = resolved.lexically_relative(root).string();
        if (ec || !review_file_ok(rel) || rel == ".") return refuse("That file is outside the project");
        if (std::find(files.begin(), files.end(), rel) == files.end() && files.size() < 1000) files.push_back(rel);
        times[rel] = now(); edited = rel;
    }
    const auto line = [](std::string s) { s = clean(s); for (auto& c : s) if (c == '\n' || c == '\r' || c == '\t') c = ' '; return s; };
    J record{{"agent", agent}, {"id", sid}, {"key", agent + ':' + sid}, {"root", root}, {"pid", pid}, {"process", process},
             {"state", state}, {"at", now()}, {"seenAt", now()}, {"files", files}, {"fileTimes", times}, {"attribution", "observed tool edits"},
             {"name", line(get("--title")).substr(0, 160)}, {"pane", get("--pane")},
             {"build", get("--build").empty() ? str(previous, "build") : get("--build").substr(0, 80)}};
    if (str(record, "name").empty()) record["name"] = previous.is_object() ? str(previous, "name", agent) : agent;
    if (!std::regex_match(str(record, "pane"), std::regex("%[0-9]+"))) record["pane"] = "";
    const bool saved = atomic(path, record.dump());
    if (saved && !edited.empty()) record_event(root, "edit", agent + ':' + sid + ':' + edited + ':' + hash(read(fs::path(root) / edited)),
        edited + " · " + agent + " edited", J{{"kind", "file-diff"}, {"file", edited}},
        J{{"file", edited}, {"agent", agent}, {"session", sid}});
    return written(saved, "agent record");
}
J agent_heartbeat(const std::string& root, const std::string& agent, const std::string& sid, long long pid) {
    if (!agent_name_ok(agent) || !std::regex_match(sid, std::regex("[A-Za-z0-9_-]{1,80}")))
        return refuse("Heartbeats need a lowercase agent name and a session id");
    Lock lock(project_dir(root) / "agents.lock");
    const auto path = project_dir(root) / "agents" / (hash(agent + ':' + sid) + ".json");
    auto record = json(path);
    if (lock.fd < 0) return unwritable();
    if (!record.is_object() || str(record, "process").empty() || num(record, "pid") != pid || proc_stamp(pid) != str(record, "process"))
        return refuse("No agent record belongs to this process; send an agent update first");
    record["seenAt"] = now();
    return written(atomic(path, record.dump()), "heartbeat");
}
J agents(const std::string& root = {}) {
    std::map<std::string, J> found;
    std::error_code ec;
    for (const auto& project : fs::directory_iterator(base() / "projects", ec)) {
        const auto where = trim(read(project.path() / "root"));
        if (where.empty() || (!root.empty() && where != root)) continue;
        for (const auto& file : fs::directory_iterator(project.path() / "agents", ec)) {
            auto one = json(file.path());
            if (!one.is_object() || !agent_name_ok(str(one, "agent"))
                || str(one, "process").empty() || proc_stamp(num(one, "pid")) != str(one, "process")) continue;
            one["busy"] = str(one, "state") == "working" || str(one, "state") == "compacting";
            one["project"] = fs::path(where).filename().string();
            one["canMessage"] = str(one, "agent") == "claude";
            one["delayed"] = now() - num(one, "seenAt", num(one, "at")) > 180;
            found[str(one, "key")] = one;
        }
    }
    // Running Claude sessions keep their existing runtime records until they naturally end. Read them as an
    // adapter, so installing this never requires restarting a session or claiming somebody else's edits.
    const auto runtime = fs::path(env("XDG_RUNTIME_DIR", "/tmp")) / "foxml-claude";
    std::map<std::string, std::pair<J, J>> legacy;
    for (const auto& file : fs::directory_iterator(runtime, ec)) {
        const auto ext = file.path().extension().string(), sid = file.path().stem().string();
        if ((ext != ".json" && ext != ".state") || !std::regex_match(sid, std::regex("[A-Za-z0-9_-]{1,80}"))) continue;
        auto one = json(file.path()); if (!one.is_object()) continue;
        (ext == ".json" ? legacy[sid].first : legacy[sid].second) = one;
    }
    std::map<std::string, std::string> panes;
    if (!legacy.empty()) for (const auto& line : split(query({"tmux", "list-panes", "-a", "-F", "#{pane_id}\x1f#{pane_current_command}"}))) {
        const auto at = line.find('\x1f'); if (at != line.npos) panes[line.substr(0, at)] = line.substr(at + 1);
    }
    for (const auto& [sid, pair] : legacy) {
        const auto& [look, word] = pair;
        const auto epoch = std::max(num(look, "epoch"), num(word, "epoch"));
        const auto place = str(word, "cwd", str(look, "project", str(look, "cwd")));
        if (place.empty() || epoch <= 0 || now() - epoch > 12 * 3600) continue;
        const auto where = root_of(place);
        if (!root.empty() && where != root) continue;
        const auto key = "claude:" + sid;
        if (!found.count(key)) {
            const auto pane = str(word, "pane", str(look, "pane"));
            if (!pane.empty() && (!panes.count(pane) || std::set<std::string>{"bash", "zsh", "fish", "sh", "dash"}.count(panes[pane]))) continue;
            const auto state = str(word, "state", "waiting");
            found[key] = J{{"key", key}, {"id", sid}, {"agent", "claude"}, {"root", where}, {"project", fs::path(where).filename().string()},
                           {"name", str(word, "title", fs::path(where).filename().string())}, {"pane", pane}, {"at", epoch},
                           {"state", state}, {"busy", state == "working" || state == "compacting"}, {"canMessage", true},
                           {"files", J::array()}, {"attribution", "unknown"}};
        }
        auto& one = found[key];
        const auto ledger = json(runtime / "edits" / (sid + ".json"));
        if (one.value("files", J::array()).empty() && ledger.is_object() && ledger.value("edits", J()).is_array()) {
            one["fileTimes"] = J::object();
            for (const auto& edit : ledger["edits"]) {
                std::error_code file_error;
                const auto rel = fs::weakly_canonical(str(edit, "path"), file_error).lexically_relative(where).string();
                if (!file_error && review_file_ok(rel)) {
                    one["files"].push_back(rel); one["fileTimes"][rel] = num(edit, "at") / 1000;
                }
            }
            one["attribution"] = "legacy session ledger";
        }
        // The legacy hooks still report permission prompts, compaction and engine errors. A newer hook event
        // speaks for that state; registry identity/liveness and observed files remain owned here.
        if (num(word, "epoch") >= num(one, "at") && !str(word, "state").empty()) {
            one["state"] = str(word, "state"); one["at"] = num(word, "epoch");
            one["busy"] = str(word, "state") == "working" || str(word, "state") == "compacting";
        }
        one["model"] = str(look, "model", "Claude"); one["context"] = num(look, "context", -1);
        one["usageAt"] = num(look, "epoch"); one["detail"] = clean(str(word, "detail"));
        one["fresh"] = str(word, "detail") == "fresh" && now() - num(word, "epoch") < 90;
        if (look.is_object()) for (const auto* window : {"five", "week"}) if (look.contains(window)) one[window] = look[window];
    }
    J out = J::array();
    for (auto& [key, one] : found) out.push_back(one);
    std::sort(out.begin(), out.end(), [](const J& a, const J& b) { return num(a, "at") != num(b, "at") ? num(a, "at") > num(b, "at") : str(a, "key") < str(b, "key"); });
    return out;
}
J review_progress(const std::string& root, const std::string& only) {
    const auto marks = json(project_dir(root) / "review-marks.json");
    J out = J::object();
    if (!marks.is_object()) return out;
    for (const auto& [key, review] : marks.items()) {
        if ((!only.empty() && key != only) || !review.is_object() || !review.contains("files") || !review["files"].is_object()) continue;
        J files = J::object(); int checked = 0, changed = 0;
        for (const auto& [rel, mark] : review["files"].items()) {
            if (!mark.is_object() || !review_file_ok(rel)) continue;
            std::string state = "checked";
            const auto content = str(mark, "content");
            if (!content.empty()) {
                std::error_code ec;
                const auto path = fs::path(root) / rel;
                const auto now_hash = fs::is_regular_file(path, ec) ? hash(read(path)) : hash("");
                if (now_hash != content) state = "changed";
            }
            (state == "checked" ? checked : changed)++;
            files[rel] = J{{"state", state}, {"at", mark.value("at", 0LL)}};
        }
        const int total = std::max(review.value("total", 0), static_cast<int>(files.size()));
        out[key] = J{{"files", files}, {"checked", checked}, {"changed", changed}, {"total", total},
                     {"completed", review.value("completed", false) && changed == 0 && checked >= total && total > 0},
                     {"at", review.value("at", 0LL)}};
    }
    return out;
}
// Which plan a commit was made under, recorded by the notebook when the commit lands (the session's pinned or last
// plan). The review tree groups by it; a commit with no record falls back to its branch and day.
J commit_plan(const std::string& root, const std::string& sha, const std::string& file, const std::string& title, const std::string& step) {
    if (!std::regex_match(sha, std::regex("[a-f0-9]{40}")) || title.size() > 300 || step.size() > 300 || file.size() > 4096)
        return refuse("A commit plan needs a full commit id, and a title and step of up to 300 characters");
    if (!register_root(root)) return unwritable();
    const auto path = project_dir(root) / "commit-plans.json"; Lock lock(project_dir(root) / "reviews.lock");
    auto j = json(path); std::error_code ec;
    if (lock.fd < 0) return unwritable();
    if (fs::exists(path, ec) && !j.is_object()) return unreadable("commit-plans.json");
    if (!j.is_object()) j = J::object();
    j[sha] = J{{"file", file}, {"title", title}, {"step", step}, {"at", now()}};
    while (j.size() > 2000) j.erase(j.begin());
    return written(atomic(path, j.dump()), "commit plan");
}
// What the tests said AT a commit: the newest finished test run that started on exactly that commit with a clean tree
// and saw no edits while it ran. Anything less is not evidence about the commit, and is left out.
std::map<std::string, std::string> commit_tests(const std::string& root) {
    std::map<std::string, std::string> out;
    for (const auto& r : runs(root)) {   // newest first
        const auto head = str(r, "head"), state = str(r, "state");
        if (head.size() != 40 || out.count(head) || !r.value("clean", false) || !r.value("testRun", false)
            || r.value("changedDuringRun", false) || (state != "passed" && state != "failed")) continue;
        out[head] = state;
    }
    return out;
}
// The review tree: tasks (a plan, else "branch · day") holding their commits oldest first, each with its progress.
// Only Claude's commits, like the tray; `all` includes the reviewed ones.
J review_tree(const std::string& root, bool all) {
    const auto plans = json(project_dir(root) / "commit-plans.json");
    const auto branch = trim(query({"git", "--no-optional-locks", "-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"}));
    J rows = reviews(root, false);
    const auto tested = commit_tests(root);
    std::vector<J> commits(rows.begin(), rows.end());
    // git log gives newest first: turned round, then ordered by time with ties left in history's order.
    std::reverse(commits.begin(), commits.end());
    std::stable_sort(commits.begin(), commits.end(), [](const J& a, const J& b) { return a.value("at", 0LL) < b.value("at", 0LL); });
    J tasks = J::array(); std::map<std::string, size_t> at;
    for (auto& c : commits) {
        if (!all && c.value("reviewed", false)) continue;
        const auto sha = str(c, "sha");
        std::string key, title, file, step;
        if (plans.is_object() && plans.contains(sha) && plans[sha].is_object() && !str(plans[sha], "title").empty()) {
            file = str(plans[sha], "file"); title = str(plans[sha], "title"); step = str(plans[sha], "step");
            key = "plan:" + (file.empty() ? title : file);
        } else {
            const std::time_t when = static_cast<std::time_t>(c.value("at", 0LL));
            char day[32] = {}; std::strftime(day, sizeof day, "%a %b %e", std::localtime(&when));
            title = (branch.empty() ? std::string("detached") : branch) + " · " + trim(day);
            key = "day:" + title;
        }
        if (!at.count(key)) {
            at[key] = tasks.size();
            tasks.push_back(J{{"key", key}, {"title", title}, {"plan", file}, {"commits", J::array()}, {"checked", 0}, {"total", 0}, {"reviewed", 0}});
        }
        auto& task = tasks[at[key]];
        if (!step.empty()) c["step"] = step;
        if (tested.count(sha)) c["tests"] = tested.at(sha);
        task["checked"] = task.value("checked", 0) + c.value("checked", 0);
        task["total"] = task.value("total", 0) + c.value("total", 0);
        task["reviewed"] = task.value("reviewed", 0) + (c.value("reviewed", false) ? 1 : 0);
        task["commits"].push_back(c);
    }
    return tasks;
}
// The red-zone list (shared/redzone.json, deployed to ~/.config/foxml/): the same file the notebook's band and the
// review's risk marks read. The copy here stands in when it is missing; tests/test_redzone.py keeps them the same.
const std::vector<std::string> RED_DEFAULT_PATHS = {"/etc/pam.d", "/etc/fstab", "/etc/crypttab", "/etc/greetd", "/etc/sudoers", "/etc/mkinitcpio",
    "/etc/default/grub", "/etc/kernel/cmdline", "/etc/sysctl", "/etc/usbguard", "/etc/ufw", "/etc/security", "/boot/"};
const std::vector<std::string> RED_DEFAULT_TOOLS = {"bootctl", "efibootmgr", "mkinitcpio", "grub-mkconfig", "ufw", "usbguard", "sysctl -w", "cryptsetup", "faillock"};
std::pair<std::vector<std::string>, std::vector<std::string>> red_zone() {
    const auto listed = json(fs::path(env("XDG_CONFIG_HOME", env("HOME") + "/.config")) / "foxml/redzone.json");
    const auto strings = [&](const char* key, const std::vector<std::string>& fallback) {
        std::vector<std::string> out;
        if (listed.is_object() && listed.contains(key) && listed[key].is_array())
            for (const auto& s : listed[key]) if (s.is_string() && !s.get<std::string>().empty()) out.push_back(s.get<std::string>());
        return out.empty() ? fallback : out;
    };
    return {strings("paths", RED_DEFAULT_PATHS), strings("tools", RED_DEFAULT_TOOLS)};
}
bool names_word(const std::string& line, const std::string& word) {
    const auto wordy = [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-'; };
    for (auto at = line.find(word); at != std::string::npos; at = line.find(word, at + 1)) {
        const bool before = at > 0 && wordy(line[at - 1]), after = at + word.size() < line.size() && wordy(line[at + word.size()]);
        if (!before && !after) return true;
    }
    return false;
}
// What a commit's ADDED lines name from the red zone, or "".
std::string commit_red_zone(const std::string& root, const std::string& sha) {
    const auto [paths, tools] = red_zone();
    for (const auto& line : split(query({"git", "--no-optional-locks", "-C", root, "show", "--format=", "--unified=0", "--no-color", sha}))) {
        if (line.size() < 2 || line[0] != '+' || line.rfind("+++", 0) == 0) continue;
        for (const auto& p : paths) if (line.find(p) != std::string::npos) return p;
        for (const auto& tool : tools) if (names_word(line, tool)) return tool;
    }
    return "";
}
// Before a push: Claude's commits about to go out that nobody finished reviewing, and whether any touches the red
// zone. It only says so; it never stops a push.
J push_check(const std::string& root) {
    J out{{"unpushed", 0}, {"unreviewed", 0}, {"risky", J::array()}, {"line", ""}};
    const auto ahead = split(query({"git", "--no-optional-locks", "-C", root, "rev-list", "--max-count=200", "@{upstream}..HEAD"}));
    std::set<std::string> going;
    for (const auto& sha : ahead) if (trim(sha).size() == 40) going.insert(trim(sha));
    out["unpushed"] = going.size();
    if (going.empty()) return out;
    int unreviewed = 0; J risky = J::array();
    for (const auto& c : reviews(root, false)) {
        const auto sha = str(c, "sha");
        if (!going.count(sha) || c.value("reviewed", false)) continue;
        ++unreviewed;
        const auto what = commit_red_zone(root, sha);
        if (!what.empty() && risky.size() < 5) risky.push_back(J{{"sha", sha.substr(0, 7)}, {"what", what}});
    }
    out["unreviewed"] = unreviewed; out["risky"] = risky;
    if (unreviewed > 0) {
        std::string line = std::to_string(unreviewed) + (unreviewed == 1 ? " Claude commit" : " Claude commits") + " not reviewed";
        if (!risky.empty()) line += " · " + std::to_string(risky.size()) + (risky.size() == 1 ? " touches " : " touch ") + "the red zone (" + str(risky[0], "what") + ")";
        out["line"] = line;
    }
    return out;
}
// Review stamps travel with the branch only where the repository asks for it: `git config desk.pushReviewNotes true`.
// Off by default, because a push publishes who reviewed what. Never forced: a remote whose notes have moved on is
// reported, not overwritten.
J push_notes(const std::string& root) {
    if (trim(query({"git", "--no-optional-locks", "-C", root, "config", "--get", "--bool", "desk.pushReviewNotes"})) != "true")
        return J{{"pushed", false}, {"reason", "off"}};
    const std::string ref = std::string("refs/notes/") + REVIEW_NOTES;
    if (trim(query({"git", "--no-optional-locks", "-C", root, "rev-parse", "--verify", "--quiet", ref})).empty())
        return J{{"pushed", false}, {"reason", "no stamps yet"}};
    const auto branch = trim(query({"git", "--no-optional-locks", "-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"}));
    const auto remote = branch.empty() ? std::string() : trim(query({"git", "--no-optional-locks", "-C", root, "for-each-ref", "--format=%(upstream:remotename)", "refs/heads/" + branch}));
    if (remote.empty() || remote.front() == '-') return J{{"pushed", false}, {"reason", "this branch has no upstream"}};
    const int code = sh::run({"timeout", "30", "git", "-C", root, "push", "--quiet", remote, ref + ":" + ref});
    return code == 0 ? J{{"pushed", true}, {"remote", remote}}
                     : J{{"pushed", false}, {"reason", "the remote's stamps differ or it refused; fetch " + ref + " and merge first"}};
}
J known_roots() {
    J roots = J::array(); std::error_code ec;
    for (const auto& e : fs::directory_iterator(base() / "projects", ec)) {
        auto r = read(e.path() / "root", 4096); if (!r.empty() && e.path().filename() == hash(r)) roots.push_back(r);
    } return roots;
}
// The tests a command runs — not the files it merely mentions (a script it writes, a heredoc's body): the test file
// after a runner ("python3 -B tests/test_x.py", "node t.mjs", "nvim -l t.lua"), a test binary run by path, the files a
// `for t in tests/test_*.py` loop walks, "make -C D test" (as "make:D") and "claude plugin test DIR" (as "plugin:DIR").
// Globs are expanded in the project, so a command written differently still names the same files. Empty: none.
std::vector<std::string> test_targets(const std::string& command, const std::string& root) {
    static const std::regex test_file(R"(([\w./*~-]*/)?(test_[\w.*-]+|[\w.*-]+[-_]test|[\w.*-]+\.test)\.(py|lua|cpp|cc|mjs|js|ts|tsx|sh))");
    static const std::regex test_binary(R"(^(\./|/)?[\w./*-]*/?(test_[\w.*-]+|[\w.*-]+_test)$)");
    static const std::set<std::string> runners{"python3", "python", "node", "bash", "sh", "nvim", "lua", "luajit", "pytest",
                                               "bun", "deno", "timeout", "env", "npx", "uv"};
    std::vector<std::string> out;
    auto clean = [](std::string s) {
        while (!s.empty() && (s.front() == '"' || s.front() == '\'' || s.front() == '(' || s.front() == '{')) s.erase(0, 1);
        while (!s.empty() && (s.back() == '"' || s.back() == '\'' || s.back() == ')' || s.back() == '}')) s.pop_back();
        if (s.rfind("./", 0) == 0) s.erase(0, 2);
        return s;
    };
    auto add_file = [&](const std::string& token) {
        std::smatch m;
        if (std::regex_search(token, m, test_file)) out.push_back(m[0].str());
        else if (std::regex_match(token, test_binary)) out.push_back(token);
    };
    std::string heredoc;
    std::istringstream lines(command);
    for (std::string line; std::getline(lines, line);) {
        if (!heredoc.empty()) { if (line == heredoc) heredoc.clear(); continue; }
        std::smatch h;
        static const std::regex opens(R"(<<-?\s*['"]?(\w+)['"]?)");
        if (std::regex_search(line, h, opens)) heredoc = h[1].str();
        static const std::regex split(R"(;|&&|\|\||\||&)");
        for (auto it = std::sregex_token_iterator(line.begin(), line.end(), split, -1); it != std::sregex_token_iterator(); ++it) {
            std::istringstream words(it->str());
            std::vector<std::string> w;
            for (std::string x; words >> x;) w.push_back(clean(x));
            size_t i = 0;
            while (i < w.size() && (w[i].empty() || w[i] == "do" || w[i] == "then" || w[i] == "!" || w[i].find('=') != std::string::npos)) ++i;
            if (i >= w.size()) continue;
            const auto& head = w[i];
            if (head == "for") {
                for (size_t k = i + 1; k < w.size(); ++k) if (w[k] == "in") { for (size_t j = k + 1; j < w.size(); ++j) add_file(w[j]); break; }
            } else if (head == "make") {
                std::string dir = ".", goal;
                for (size_t k = i + 1; k < w.size(); ++k) {
                    if (w[k] == "-C" && k + 1 < w.size()) dir = w[++k];
                    else if (w[k] == "test" || w[k] == "check") goal = w[k];
                }
                if (!goal.empty()) out.push_back("make:" + dir);
            } else if (head == "ctest" || head == "pytest"
                       || ((head == "cargo" || head == "go" || head == "npm" || head == "pnpm" || head == "bun") && i + 1 < w.size()
                           && (w[i + 1] == "test" || (w[i + 1] == "run" && i + 2 < w.size() && w[i + 2] == "test")))
                       || (fs::path(head).filename().string().rfind("python", 0) == 0 && std::find(w.begin(), w.end(), "unittest") != w.end())) {
                std::smatch m; bool named = false;
                for (size_t k = i + 1; k < w.size() && !named; ++k)
                    if (std::regex_search(w[k], m, test_file)) { out.push_back(m[0].str()); named = true; }
                if (!named) out.push_back("suite:" + fs::path(head).filename().string());  // a whole suite: tests, none by name
            } else if (head == "claude" && i + 3 < w.size() && w[i + 1] == "plugin" && w[i + 2] == "test") {
                out.push_back("plugin:" + w[i + 3]);
            } else if (runners.count(fs::path(head).filename().string()) && head != "pytest") {
                for (size_t k = i + 1; k < w.size(); ++k) {
                    std::smatch m;
                    if (std::regex_search(w[k], m, test_file)) { out.push_back(m[0].str()); break; }
                }
            } else {
                add_file(head);
            }
        }
    }
    // Globs to the files they name in this project, so a glob and the folder it matches are one target.
    std::vector<std::string> expanded;
    for (const auto& target : out) {
        const auto colon = target.find(':');
        const std::string prefix = colon == std::string::npos ? "" : target.substr(0, colon + 1);
        const std::string path = colon == std::string::npos ? target : target.substr(colon + 1);
        if (path.find_first_of("*?[") == std::string::npos || root.empty()) { expanded.push_back(target); continue; }
        ::glob_t g{};
        const auto pattern = (fs::path(root) / path).string();
        if (::glob(pattern.c_str(), 0, nullptr, &g) == 0 && g.gl_pathc > 0) {
            for (size_t k = 0; k < g.gl_pathc; ++k) expanded.push_back(prefix + fs::path(g.gl_pathv[k]).lexically_relative(root).string());
        } else expanded.push_back(target);
        ::globfree(&g);
    }
    std::sort(expanded.begin(), expanded.end()); expanded.erase(std::unique(expanded.begin(), expanded.end()), expanded.end());
    return expanded;
}
// One target covering another: the same; a glob that matches it; the same file written from another folder; or a
// passing "make -C D test" for a test that lives under D.
bool covers(const std::string& a, const std::string& b) {
    if (a == b || ::fnmatch(a.c_str(), b.c_str(), 0) == 0) return true;
    const auto tail = [](const std::string& x, const std::string& y) { return x.size() > y.size() && x.compare(x.size() - y.size() - 1, y.size() + 1, "/" + y) == 0; };
    if (a.rfind("make:", 0) == 0 && b.find(':') == std::string::npos) {
        const auto dir = a.substr(5);
        return dir == "." || b.rfind(dir + "/", 0) == 0;
    }
    return tail(a, b) || tail(b, a);
}
// Whether a failed run still stands, deciding newest first: it clears once a newer run passed every test it named
// (whatever that run was called or how its command was written), and it counts once among newer failures of the
// same tests. A command that names no test keeps the old rule: only a newer run of the same command settles it.
struct Settled {
    std::set<std::string> commands;
    std::map<std::string, std::vector<std::string>> passed, failed;
    bool standing(const J& r) {
        const auto root = str(r, "root"), state = str(r, "state"), cwd = str(r, "cwd", root);
        const auto scope = J::array({root, cwd}).dump();
        const bool newest = commands.insert(command_key(r)).second;
        const auto targets = test_targets(str(r, "command"), cwd);
        auto all_in = [&](const std::vector<std::string>& seen) {
            return !targets.empty() && std::all_of(targets.begin(), targets.end(), [&](const std::string& t) {
                return std::any_of(seen.begin(), seen.end(), [&](const std::string& s) { return covers(s, t); });
            });
        };
        if (state == "passed") { for (const auto& t : targets) passed[scope].push_back(t); return false; }
        if (state != "failed" && state != "interrupted") return false;
        // A call filed as a test run that ran no test (a grep that only mentions tests/test_x.py) is no failure.
        if (str(r, "kind") == "tests" && targets.empty()) return false;
        const bool open = newest && !all_in(passed[scope]) && !all_in(failed[scope]);
        for (const auto& t : targets) failed[scope].push_back(t);
        return open;
    }
};
bool attention_less(const J& a, const J& b) {
    if (num(a, "priority") != num(b, "priority")) return num(a, "priority") < num(b, "priority");
    if (num(a, "at") != num(b, "at")) return str(a, "kind") == "commit" ? num(a, "at") < num(b, "at") : num(a, "at") > num(b, "at");
    return str(a, "root") + str(a, "id") < str(b, "root") + str(b, "id");
}
J attention_items(const std::string& root, const J& work, const J& commits, const J& sessions,
                  const std::string& own = {}, bool review_only = false, bool include_snoozed = false) {
    J out = J::array(); std::set<std::string> files;
    const auto add = [&](const std::string& kind, const std::string& id, const std::string& label, const std::string& why,
                         long long at, int priority, J action, J extra = J::object()) {
        extra.update(J{{"kind", kind}, {"id", kind + ':' + id}, {"root", root}, {"label", label}, {"why", why},
                       {"at", at}, {"priority", priority}, {"action", action}});
        out.push_back(extra);
    };
    if (!review_only) {
        for (const auto& record : work.value("records", J::array()))
            add("records", str(record, "file"), "The " + str(record, "label") + " record cannot be read",
                "Writes to it are refused until work health sets it aside (" + str(record, "why") + ")", num(record, "at"), 5,
                J{{"kind", "health"}}, J{{"file", str(record, "file")}});
        for (const auto& job : work.value("failures", J::array())) {
            const auto id = str(job, "id");
            add("job", id, str(job, "title", str(job, "command")), "Failed and has not passed since", num(job, "ended"), 10,
                J{{"kind", job.value("testRun", false) ? "tests" : "log"}, {"id", id}}, J{{"run", id}});
        }
        for (const auto& agent : sessions) {
            const auto state = str(agent, "state");
            if ((state != "needs" && state != "error") || (!own.empty() && str(agent, "id") == own && str(agent, "agent") == "claude")) continue;
            add("agent", str(agent, "key"), str(agent, "name", str(agent, "agent")),
                str(agent, "agent") + (state == "needs" ? " needs you" : " stopped on an error"), num(agent, "at"), 10,
                J{{"kind", "agent"}, {"key", str(agent, "key")}}, J{{"session", str(agent, "id")}, {"agent", str(agent, "agent")}});
        }
    }
    for (const auto& request : work.value("requests", J::array())) if (str(request, "state") == "ready") {
        const auto file = str(request, "file"); files.insert(file);
        add("request", file, fs::path(file).filename().string(), "Changed since you asked " + str(request, "name", "a session"),
            num(request, "at"), 20, J{{"kind", "file-diff"}, {"file", file}}, J{{"file", file}});
    }
    // The current working diff decides whether a changed mark still has something to read here. A committed
    // change belongs to its commit's review, rather than an empty working-tree comparison.
    std::set<std::string> dirty;
    for (const auto& name : split(query({"git", "--no-optional-locks", "-C", root, "diff", "--name-only", "-z", "HEAD"}), '\0')) dirty.insert(name);
    for (const auto& name : split(query({"git", "--no-optional-locks", "-C", root, "ls-files", "--others", "--exclude-standard", "-z"}), '\0')) dirty.insert(name);
    const auto progress = work.value("review", J::object());
    for (const auto& [key, review] : progress.items()) {
        if (std::regex_match(key, std::regex("[a-f0-9]{40}"))) continue;
        const auto marks = review.value("files", J::object());
        for (const auto& [file, mark] : marks.items()) if (str(mark, "state") == "changed" && dirty.count(file) && files.insert(file).second)
            add("changed", file, fs::path(file).filename().string(), "Edited since you reviewed it", num(mark, "at"), 30,
                J{{"kind", "file-diff"}, {"file", file}}, J{{"file", file}});
    }
    for (const auto& commit : commits) if (!commit.value("reviewed", false)) {
        const auto sha = str(commit, "sha");
        add("commit", sha, str(commit, "subject"), "Not reviewed yet", num(commit, "at"), 40,
            J{{"kind", "reviews"}, {"id", sha}}, J{{"sha", sha}});
    }
    std::sort(out.begin(), out.end(), attention_less);
    return filter_attention(root, out, include_snoozed);
}
J attention(const std::string& root, const std::string& session = {}, bool review_only = false, bool include_snoozed = false) {
    J failures = J::array(); Settled settled;
    for (const auto& job : runs(root)) if (settled.standing(job) && num(job, "ended") >= now() - 24 * 3600) failures.push_back(job);
    return attention_items(root, J{{"failures", failures}, {"requests", review_requests(root)}, {"review", review_progress(root, "")},
                                   {"records", records_brief(root)}},
                           reviews(root, false), agents(root), session, review_only, include_snoozed);
}
#include "workflow.hpp"
#include "records.hpp"
#include "integrations.hpp"
J overview(const A& requested, bool fresh = false, bool include_history = false) {
    auto all = runs(); J todo = J::array(), review = J::array(); int running = 0, finished = 0, failed = 0;
    std::map<std::string, J> snapshots;
    std::set<std::string> roots;
    for (const auto& r : known_roots()) roots.insert(r.get<std::string>());
    for (const auto& r : requested) { const auto root = root_of(r); if (!root.empty()) roots.insert(root); }
    const auto day = now() - 24 * 3600;
    // A failure counts until a newer run in the same project gets past it (Settled); runs are newest first.
    Settled settled;
    for (auto& r : all) {
        const bool standing = settled.standing(r);
        if (str(r, "state") == "running") ++running;
        else if (num(r, "ended") >= day) {
            ++finished;
            if (standing) ++failed;
        }
        if (fresh && r.value("testRun", false)) {
            const auto root = str(r, "root");
            if (!snapshots.count(root)) snapshots[root] = snapshot(root);
            r["stale"] = r.value("changedDuringRun", false) || !same_source(load_run(str(r, "id")).value("snapshot", J()), snapshots[root]);
        }
        r.erase("snapshot");
    }
    J needs = J::array(), history = J::array(), digests = J::array(), held = J::array();
    for (const auto& root : roots) {
        for (auto t : tasks(root)) if (!t.value("done", false)) { t["root"] = root; todo.push_back(t); }
        for (auto r : reviews(root)) review.push_back(r);
        for (auto item : attention(root)) needs.push_back(item);
        if (include_history) {
            for (auto event : timeline(root, 0, 30)) history.push_back(event);
            auto summary = project_digest(root, "desktop"); summary["root"] = root; digests.push_back(summary);
        }
        for (auto item : attention(root, "", false, true)) if (item.contains("snoozed")) held.push_back(item);
    }
    std::sort(needs.begin(), needs.end(), attention_less);
    std::sort(history.begin(), history.end(), [](const J& a, const J& b) {
        if (num(a, "at") != num(b, "at")) return num(a, "at") > num(b, "at");
        return str(a, "root") != str(b, "root") ? str(a, "root") < str(b, "root") : num(a, "seq") > num(b, "seq");
    });
    return J{{"jobs", all}, {"running", running}, {"finished", finished}, {"failed", failed}, {"tasks", todo}, {"reviews", review},
             {"attention", needs}, {"agents", agents()}, {"timeline", history}, {"digests", digests}, {"snoozed", held}};
}
J notebook(const std::string& root, const std::string& session, const std::string& loaded = {}, bool health = false) {
    J latest; auto all = runs(root); const auto current = snapshot(root);
    J jobs = J::array(), failures = J::array(); Settled settled;
    for (auto j : all) {
        const bool standing = settled.standing(j);
        if (str(j, "state") == "running") { j.erase("snapshot"); jobs.push_back(j); }
        else if (standing && num(j, "ended") >= now() - 24 * 3600) {
            auto failed = j; failed.erase("snapshot"); failures.push_back(failed);
        }
        if (latest.is_null() && j.value("testRun", false)) {
            j["snapshot"] = load_run(str(j, "id")).value("snapshot", J());
            freshness(j, current); j.erase("snapshot"); latest = j;
        }
    }
    // Claude commits nobody has finished reviewing yet (any day), for the notebook's one review line.
    int pending = 0;
    for (const auto& c : reviews(root, false)) if (!c.value("reviewed", false)) ++pending;
    J out{{"tests", latest}, {"jobs", jobs}, {"failures", failures}, {"tasks", tasks(root)}, {"session", session},
          {"review", review_progress(root, "")}, {"pending", pending}, {"requests", review_requests(root)}, {"agents", agents(root)},
          {"records", records_brief(root)}};
    out["attention"] = attention_items(root, out, reviews(root, false), out["agents"], session);
    out["revision"] = str(json(project_dir(root) / "revision.json"), "revision");
    out["digest"] = project_digest(root, "notebook");
    out["timeline"] = timeline(root, 0, 30);
    out["integration"] = integration_status("notebook", loaded, false, session);
    // Commits finished today, so a row can say "reviewed" for the rest of the day.
    J today = J::array();
    const auto finished = json(project_dir(root) / "reviewed.json");
    std::time_t midnight = now(); std::tm local{};
    if (localtime_r(&midnight, &local)) { local.tm_hour = local.tm_min = local.tm_sec = 0; midnight = std::mktime(&local); }
    if (finished.is_object()) for (const auto& [sha, at] : finished.items()) if (at.is_number_integer() && at.get<long long>() >= midnight) today.push_back(sha);
    out["reviewedToday"] = today;
    if (health) out["health"] = integration_health();
    return out;
}
fs::path plan_path(const std::string& root, const std::string& session) {
    return project_dir(root) / "plans" / (hash(session) + ".json");
}
J pin_plan(const std::string& root, const std::string& session, const std::string& file, const std::string& step) {
    if (session.empty() || session.size() > 80) return refuse("A pinned plan needs the session id");
    if (step.size() > 1000) return refuse("A pinned step is limited to 1000 characters");
    J plan;
    if (!file.empty()) {
        std::error_code ec;
        const auto path = fs::canonical(fs::path(file).is_absolute() ? fs::path(file) : fs::path(root) / file, ec);
        if (ec || path.extension() != ".md" || !fs::is_regular_file(path, ec)) return J{{"ok", false}, {"message", "Choose an existing Markdown plan"}};
        plan = J{{"file", path.string()}, {"step", clean(step)}, {"at", now()}};
    }
    return written(atomic(plan_path(root, session), plan.dump()), "pinned plan");
}
// Markdown checkboxes outside code fences: "- [x]" done, "- [ ]" still to do.
J plan_with_progress(J plan) {
    if (!plan.is_object() || str(plan, "file").empty()) return plan;
    const std::regex box("^\\s*(?:[-*+]|[0-9]+[.)])\\s+\\[([ xX])\\]");
    long long done = 0, total = 0; bool fence = false; std::smatch m;
    for (const auto& line : split(read(str(plan, "file"), 1024 * 1024))) {
        const auto t = trim(line);
        if (t.rfind("```", 0) == 0 || t.rfind("~~~", 0) == 0) { fence = !fence; continue; }
        if (!fence && std::regex_search(line, m, box)) { ++total; if (m[1] != " ") ++done; }
    }
    plan["done"] = done; plan["total"] = total; return plan;
}
J worktrees(const std::string& root) {
    J rows = J::array(), row;
    std::error_code error;
    if (!fs::exists(fs::path(root) / ".git", error)) return rows;
    for (const auto& line : split(query({"git", "--no-optional-locks", "-C", root, "worktree", "list", "--porcelain", "-z"}), '\0')) {
        if (line.rfind("worktree ", 0) == 0) {
            if (row.is_object()) rows.push_back(row);
            row = J{{"path", line.substr(9)}, {"branch", "detached"}};
        } else if (line.rfind("branch refs/heads/", 0) == 0) row["branch"] = line.substr(18);
        else if (line == "bare") row["bare"] = true;
    }
    if (row.is_object()) rows.push_back(row);
    J peers = J::parse(query({"desk-drawer", "claude-peers"}), nullptr, false);
    const auto runtime = fs::path(env("XDG_RUNTIME_DIR", "/tmp")) / "foxml-claude";
    for (auto& r : rows) {
        const auto path = str(r, "path"); const auto status = query({"git", "--no-optional-locks", "-C", path, "status", "--porcelain=v1", "--branch", "--untracked-files=normal"});
        r["status"] = status; r["sessions"] = J::array();
        if (peers.is_array()) for (const auto& p : peers) {
            const auto sid = str(p, "id"); if (!std::regex_match(sid, std::regex("[A-Za-z0-9_-]{1,80}"))) continue;
            auto look = json(runtime / (sid + ".json")); const auto where = str(look, "cwd", str(look, "project"));
            if (where == path || where.rfind(path + "/", 0) == 0) r["sessions"].push_back(p);
        }
    } return rows;
}
std::string comparison(const J& job) {
    const auto baseline = load_run(str(job, "baseline"));
    if (!baseline.is_object() || !baseline.value("baselineEligible", false)) return "No comparable successful test run was recorded.\n";
    if (!job["snapshot"].value("complete", false)) return "The source snapshot was incomplete; this comparison is unavailable.\n";
    std::set<std::string> paths;
    for (auto it = baseline["snapshot"]["files"].begin(); it != baseline["snapshot"]["files"].end(); ++it) paths.insert(it.key());
    for (auto it = job["snapshot"]["files"].begin(); it != job["snapshot"]["files"].end(); ++it) paths.insert(it.key());
    std::string out = "Last passed: " + str(baseline, "id") + "\nFailed run: " + str(job, "id") + "\nSource captured at each run's start, including uncommitted edits.\n\n";
    for (const auto& path : paths) {
        const auto& before = baseline["snapshot"]["files"]; const auto& after = job["snapshot"]["files"];
        if (before.contains(path) && after.contains(path) && before[path] == after[path]) continue;
        const auto left = before.contains(path) ? (base() / "blobs" / before[path].get<std::string>()).string() : "/dev/null";
        const auto right = after.contains(path) ? (base() / "blobs" / after[path].get<std::string>()).string() : "/dev/null";
        std::string patch; sh::probe({"diff", "-u", "--label", "a/" + path, "--label", "b/" + path, left, right}, patch); out += patch;
        if (out.size() > 4 * 1024 * 1024) { out += "\nComparison truncated.\n"; break; }
    } return out;
}
std::string quote(const std::string& s) { std::string out = "'"; for (char c : s) out += c == '\'' ? "'\\''" : std::string(1, c); return out + "'"; }
int open_editor(const std::string& root, const std::string& action, const std::string& id = {}, const std::string& index = {}) {
    // Data travels through argv into a fixed Lua call, never through an Ex/Lua interpolation.
    return sh::run({"kitty", "--detach", "--directory", root, "-e", "nvim", "+lua require('foxml.work').open_args()", "--", "foxml-work:" + action, id, index});
}
void notify_failure(const std::string& label, const std::string& id, bool service = false) {
    if (env("FOXML_WORK_NOTIFY") == "0" || !sh::have("notify-send") || !sh::have("setsid")) return;
    const auto own = fs::canonical("/proc/self/exe").string();
    const bool pane = !service && !str(load_run(id), "pane").empty();
    const bool tests = !service && load_run(id).value("testRun", false);
    const std::string script = "exec >/dev/null 2>&1; choice=$(notify-send --wait --expire-time=0 --category=foxml.work --app-name=FoxML --action=default='Open result' --action=log='Open log' "
        + std::string(pane ? "--action=jump='Jump to terminal' " : "")
        + "--action=ask='Ask Claude' \"$4\" \"$2\"); case \"$choice\" in default) exec \"$1\" open --action \"$7\" --id \"$3\";; log) exec \"$1\" open --action \"$5\" --id \"$3\";; jump) exec \"$1\" open --action jump --id \"$3\";; ask) exec \"$1\" open --action \"$6\" --id \"$3\";; esac";
    sh::run({"setsid", "-f", "sh", "-c", script, "sh", own, clean(label).substr(0, 160), id,
             service ? "User service failed" : tests ? "Tests failed" : "Job failed", service ? "service" : "log", service ? "ask-service" : "ask",
             service ? "service" : tests ? "tests" : "log"});
}
int supervise(const A& child, const std::string& root, const std::string& session, const std::string& title, const std::string& label) {
    auto job = begin(label, root, session, ::getpid(), false, title);
    if (!job.is_object()) { std::cerr << "Could not record job; running command directly.\n"; return sh::run(child); }
    bool truncated = false;
    const int code = sh::run_logged(child, run_dir(str(job, "id")) / "output.log", 4 * 1024 * 1024, truncated);
    finish(job, code, truncated);
    if (code != 0) notify_failure(str(job, "title", label), str(job, "id"));
    return code < 0 ? 125 : code;
}
}

std::string invoked;
int dispatch(int argc, char** argv) {
    ::umask(0077);
    try {
        A args; std::map<std::string, std::string> opts; A roots; bool end = false;
        for (int i = 1; i < argc; ++i) {
            std::string a = argv[i];
            if (!end && a == "--") { end = true; continue; }
            if (!end && a.rfind("--", 0) == 0 && i + 1 < argc) {
                const std::string value = argv[++i]; opts[a] = value; if (a == "--root") roots.push_back(value);
            } else args.push_back(a);
        }
        if (args.empty() || args[0] == "help") {
            std::cout << "desk-work run [--root DIR] [--session ID] [--title TEXT] -- COMMAND [ARGS...]\n"
                         "desk-work jobs | overview [--root DIR...] | notebook --root DIR | worktrees --root DIR\n"
                         "desk-work begin --root DIR --pid PID|parent --command TEXT [--session ID --title TEXT] | finish --id RUN --exit N [--output -]\n"
                         "desk-work task-add --root DIR --text TEXT | task-toggle --root DIR --id ID\n"
                         "desk-work tests --root DIR | compare --id RUN | reviewed --root DIR --sha SHA\n"
                         "desk-work plan|plan-pin --root DIR --session ID [--file PLAN.md --step TEXT]\n"
                         "desk-work attention --root DIR [--scope review] | watch [--root DIR | --all yes] | signal --root DIR\n"
                         "desk-work timeline|digest --root DIR [--consumer NAME --through SEQUENCE]\n"
                         "desk-work snooze --root DIR --id ITEM [--seconds 3600 | --until-change yes | --clear yes]\n"
                         "desk-work suggest-tests --root DIR --file PATH | run-suggested --root DIR --id RUN\n"
                         "desk-work integrations plan|apply|rollback|recover|status|backups [--expected PLAN | --transaction ID]\n"
                         "desk-work integrations cleanup-plan|cleanup [--keep 3 --older-than 30 --expected PLAN]\n"
                         "desk-work records --root DIR | records-repair --root DIR [--expected PLAN]\n"
                         "desk-work health | integration-status [--client NAME --loaded BUILD] | workspace --root DIR --client NAME [--input -]\n"
                         "desk-work client-report --client NAME --build BUILD --pid parent [--root DIR --stream connected|retrying --refresh-at SECONDS --error TEXT]\n"
                         "desk-work agents [--root DIR] | agent-update --root DIR --agent NAME --session ID --state working|waiting|needs|error|done --pid PID|parent [--title NAME --pane PANE --file PATH]\n"
                         "desk-work open --root DIR --action attention|tests|reviews|compare|log|tasks|ask|file|file-diff|plan|worktree --id ITEM [--file PATH --session ID]\n"; return 0;
        }
        const auto cmd = args[0];
        invoked = cmd;
        const auto place = opts.count("--root") ? opts["--root"] : fs::current_path().string();
        const auto root = std::set<std::string>{"run", "begin", "notebook", "tests", "tasks", "task-add", "task-toggle", "reviews", "reviewed", "review-mark", "review-progress", "review-request", "review-requests", "commit-plan", "review-tree", "push-check", "push-notes", "records", "records-repair", "worktrees", "activity", "plan", "plan-pin", "watch", "signal", "attention", "agent-update", "agents", "revision", "open", "agent-heartbeat", "overlaps", "timeline", "digest", "snooze", "workspace", "suggest-tests", "run-suggested", "resolve"}.count(cmd)
            ? root_of(place) : place;
        const auto id = opts["--id"];
        J out;
        if (cmd == "watch") {
            if (!opts["--client"].empty()) client_loaded(opts["--client"], opts["--build"], ::getppid());
            return watch_changes(root, opts["--all"] == "yes", opts["--client"], opts["--build"]);
        }
        if (cmd == "signal") out = J{{"ok", signal_change(root)}};
        else if (cmd == "client-loaded") out = client_loaded(opts["--client"], opts["--build"],
            opts["--pid"] == "parent" ? ::getppid() : std::stoll(opts["--pid"]));
        else if (cmd == "client-report") {
            if (opts.count("--root") && root_of(opts["--root"]).empty()) return 2;
            J fields = J::object();
            for (const auto& [flag, key] : std::map<std::string, std::string>{{"--event-at", "eventAt"}, {"--refresh-at", "refreshAt"}, {"--retry-at", "retryAt"}})
                if (opts.count(flag)) fields[key] = std::stoll(opts[flag]);
            if (opts.count("--stream")) fields["stream"] = opts["--stream"];
            if (opts.count("--error")) fields["refreshError"] = opts["--error"];
            out = report_client(opts["--client"], opts["--build"], opts["--pid"] == "parent" ? ::getppid() : std::stoll(opts["--pid"]),
                opts.count("--root") ? root_of(opts["--root"]) : std::string(), fields);
        }
        else if (cmd == "integration-status") out = integration_status(opts["--client"], opts["--loaded"], opts["--quick"] != "yes");
        else if (cmd == "health") out = integration_health();
        else if (cmd == "integrations") {
            if (args.size() < 2 || !std::set<std::string>{"plan", "apply", "rollback", "recover", "status", "backups", "cleanup-plan", "cleanup"}.count(args[1])) {
                std::cerr << "desk-work integrations: choose plan, apply, rollback, recover, status, backups, cleanup-plan or cleanup\n"; return 2;
            }
            if (!opts["--repo"].empty()) ::setenv("FOXML_REPO", opts["--repo"].c_str(), 1);
            A command{"desk-install", "--integrations", args[1]};
            if (args[1] == "apply" || args[1] == "rollback" || args[1] == "recover" || args[1] == "cleanup") command.push_back("--yes");
            if (!opts["--expected"].empty()) { command.push_back("--expected"); command.push_back(opts["--expected"]); }
            if (!opts["--transaction"].empty()) { command.push_back("--transaction"); command.push_back(opts["--transaction"]); }
            for (const char* flag : {"--keep", "--older-than"}) if (!opts[flag].empty()) { command.push_back(flag); command.push_back(opts[flag]); }
            return sh::run(command);
        }
        else if (cmd == "revision") out = J{{"version", 1}, {"path", (project_dir(root) / "revision.json").string()}, {"revision", str(json(project_dir(root) / "revision.json"), "revision")}};
        else if (cmd == "attention") out = attention(root, opts["--session"], opts["--scope"] == "review", opts["--include-snoozed"] == "yes");
        else if (cmd == "agent-update") out = agent_update(root, opts);
        else if (cmd == "agent-heartbeat") out = agent_heartbeat(root, opts["--agent"], opts["--session"],
            opts["--pid"] == "parent" ? static_cast<long long>(::getppid()) : std::stoll(opts["--pid"]));
        else if (cmd == "overlaps") out = overlaps(root, opts["--file"], opts["--agent"], opts["--session"]);
        else if (cmd == "timeline") out = timeline(root, opts["--after"].empty() ? 0 : std::stoll(opts["--after"]));
        else if (cmd == "digest") out = project_digest(root, opts["--consumer"].empty() ? "notebook" : opts["--consumer"],
            opts["--through"].empty() ? -1 : std::stoll(opts["--through"]));
        else if (cmd == "snooze") out = snooze(root, id, opts["--seconds"].empty() ? 3600 : std::stoll(opts["--seconds"]),
            opts["--until-change"] == "yes", opts["--clear"] == "yes");
        else if (cmd == "workspace") {
            std::string input;
            if (opts["--input"] == "-") {
                input.resize(65537); std::cin.read(input.data(), input.size()); input.resize(static_cast<size_t>(std::cin.gcount()));
                if (input.size() > 65536) return 2;
            }
            out = workspace(root, opts["--client"], input);
        }
        else if (cmd == "workspace-list") out = workspace_list(opts["--client"]);
        else if (cmd == "suggest-tests") out = suggested_tests(root, opts["--file"]);
        else if (cmd == "run-suggested") {
            auto previous = load_run(id);
            if (!previous.is_object() || str(previous, "root") != root || !previous.value("testRun", false)) {
                std::cerr << "desk-work run-suggested: that is not a captured test run of this project\n"; return 2;
            }
            const auto command = str(previous, "command");
            const auto cwd = str(previous, "cwd");
            if (cwd.empty() || !previous.value("cwdKnown", false) || root_of(cwd) != root) {
                std::cerr << "desk-work run-suggested: the folder that run started in is not known\n"; return 2;
            }
            std::error_code cwd_error; fs::current_path(cwd, cwd_error);
            if (cwd_error) { std::cerr << "desk-work run-suggested: " << cwd << " is gone\n"; return 2; }
            return supervise({"bash", "-c", command}, root, opts["--session"], str(previous, "title"), command);
        }
        else if (cmd == "agents") out = agents(opts.count("--root") ? root : std::string());
        else if (cmd == "classify") { out = J{{"kind", kind_of(opts["--command"])}, {"observable", observable(opts["--command"])}}; }
        else if (cmd == "run") {
            if (args.size() < 2) return 2;
            if (root.empty()) return 2;
            if (root_of(fs::current_path().string()) != root) {
                std::error_code cwd_error; fs::current_path(root, cwd_error); if (cwd_error) return 2;
            }
            A child(args.begin() + 1, args.end()); std::string label;
            for (const auto& a : child) label += (label.empty() ? "" : " ") + quote(a);
            if (child.size() == 3 && (child[0] == "bash" || child[0] == "zsh") && child[1] == "-c") label = child[2];
            return supervise(child, root, opts["--session"], opts["--title"], label);
        } else if (cmd == "begin") {
            if (opts["--safe"] == "yes" && !observable(opts["--command"])) return 0;
            if (kind_of(opts["--command"]).empty()) return 0;
            // "parent": whoever started this (Claude Code itself, for a mod); the job stays running only while it lives.
            const long long pid = opts["--pid"] == "parent" ? static_cast<long long>(::getppid()) : std::stoll(opts["--pid"]);
            out = begin(opts["--command"], root, opts["--session"], pid, true, opts["--title"], opts["--cwd"]);
            if (!out.is_object()) return 1;
            std::cout << str(out, "id") << '\n'; return 0;
        } else if (cmd == "finish") {
            auto j = load_run(id); const int code = std::stoi(opts["--exit"]);
            // "--output -": the caller saw the output (a Claude Code Bash call) and hands it over, so the run reads like one desk-work ran.
            bool truncated = false;
            if (j.is_object() && opts["--output"] == "-") {
                constexpr size_t cap = 4 * 1024 * 1024;
                std::string output(cap + 1, '\0');
                std::cin.read(&output[0], static_cast<std::streamsize>(output.size()));
                output.resize(static_cast<size_t>(std::cin.gcount()));
                if (output.size() > cap) { output.resize(cap); truncated = true; }
                if (atomic(run_dir(str(j, "id")) / "output.log", output)) j["observed"] = false;
            }
            const bool ok = j.is_object() && finish(j, code, truncated);
            // A stop (Ctrl+C, a denied or interrupted call) is the person's own doing; only real failures notify.
            if (ok && code != 0 && code < 128) notify_failure(str(j, "title", str(j, "command")), id);
            out = J{{"ok", ok}};
            if (ok) { out["state"] = j["state"]; out["testRun"] = j["testRun"]; out["failedBefore"] = j["failedBefore"]; }
        } else if (cmd == "activity") {
            const auto sid = opts["--session"];
            if (!std::regex_match(sid, std::regex("[A-Za-z0-9_-]{1,80}"))) return 2;
            const auto path = base() / "activity" / (sid + ".json");
            auto previous = json(path);
            out = J{{"root", root}, {"text", clean(opts["--text"]).substr(0, 160)}, {"at", now()},
                    {"started", opts["--state"] == "done" ? num(previous, "started", now()) : now()}, {"active", opts["--state"] != "done"}};
            out["ok"] = atomic(path, out.dump());
        } else if (cmd == "activities") {
            out = J::object(); std::error_code ec;
            for (const auto& e : fs::directory_iterator(base() / "activity", ec)) {
                auto j = json(e.path()); if (j.is_object() && now() - num(j, "at") < 12 * 3600) out[e.path().stem().string()] = j;
            }
            std::set<std::string> busy;
            for (const auto& job : runs()) if (str(job, "state") == "running" && !str(job, "session").empty() && busy.insert(str(job, "session")).second)
                out[str(job, "session")] = J{{"root", str(job, "root")}, {"text", str(job, "command").substr(0, 160)},
                    {"started", num(job, "started")}, {"at", num(job, "activity")}, {"active", true}};
        } else if (cmd == "jobs") out = runs(opts.count("--root") ? root : "");
        else if (cmd == "overview") out = overview(roots, opts["--fresh"] == "yes", opts["--history"] == "yes");
        else if (cmd == "notebook") out = notebook(root, opts["--session"], opts["--loaded"], opts["--health"] == "yes");
        else if (cmd == "worktrees") out = worktrees(root);
        else if (cmd == "plan") out = plan_with_progress(json(plan_path(root, opts["--session"])));
        else if (cmd == "plan-pin") out = pin_plan(root, opts["--session"], opts["--file"], opts["--step"]);
        else if (cmd == "tasks") out = tasks(root);
        else if (cmd == "task-add") out = task_change(root, opts["--text"], "");
        else if (cmd == "task-toggle") out = task_change(root, "", id);
        else if (cmd == "reviews") out = reviews(root, opts["--all"] != "yes");
        else if (cmd == "reviewed") out = reviewed(root, opts["--sha"]);
        else if (cmd == "review-mark") out = review_mark(root, opts["--key"], opts["--file"], opts["--signature"], opts["--content"], opts["--total"], opts["--done"]);
        else if (cmd == "review-progress") out = review_progress(root, opts["--key"]);
        else if (cmd == "review-request") out = review_request(root, opts["--file"], opts["--name"], opts["--sid"], opts["--text"], opts["--clear"] == "yes");
        else if (cmd == "review-requests") out = review_requests(root);
        else if (cmd == "commit-plan") out = commit_plan(root, opts["--sha"], opts["--file"], opts["--title"], opts["--step"]);
        else if (cmd == "review-tree") out = review_tree(root, opts["--all"] == "yes");
        else if (cmd == "push-check") out = push_check(root);
        else if (cmd == "records") out = records_report(root);
        else if (cmd == "records-repair") out = records_repair(root, opts["--expected"]);
        else if (cmd == "push-notes") out = push_notes(root);
        else if (cmd == "tests") {
            auto j = id.empty() ? notebook(root, "")["tests"] : load_run(id);
            if (j.is_object() && j.contains("snapshot")) { freshness(j, snapshot(str(j, "root"))); j.erase("snapshot"); }
            out = j.is_object() ? j : J();
        } else if (cmd == "compare") {
            auto j = load_run(id); if (!j.is_object()) return 1;
            std::cout << comparison(j); return 0;
        } else if (cmd == "open" || cmd == "resolve") {
            auto action = opts["--action"], target = id;
            J resolved;
            if (action == "attention") {
                J selected;
                for (const auto& item : attention(root)) if (str(item, "id") == id) { selected = item["action"]; break; }
                if (!selected.is_object()) { std::cout << J{{"ok", false}, {"message", "That item is settled. Refresh the list."}}.dump() << '\n'; return 1; }
                resolved = selected;
                action = str(selected, "kind"); target = str(selected, "id", str(selected, "key"));
                if (selected.contains("file")) opts["--file"] = str(selected, "file");
            }
            if (action == "event") {
                for (const auto& event : timeline(root, 0, 500)) if (str(event, "id") == id) resolved = event["action"];
                if (!resolved.is_object()) return 1;
                action = str(resolved, "kind"); target = str(resolved, "id", str(resolved, "key"));
                if (resolved.contains("file")) opts["--file"] = str(resolved, "file");
            }
            if (cmd == "resolve") {
                if (!resolved.is_object()) return 2;
                std::cout << J{{"root", root}, {"action", resolved}}.dump() << '\n'; return 0;
            }
            if (action == "agent") {
                for (const auto& agent : agents(root)) if (str(agent, "key") == target && !str(agent, "pane").empty())
                    return sh::run({"desk-drawer", "run", "claude-jump", str(agent, "pane")});
                return 1;
            }
            auto j = load_run(target); const auto where = j.is_object() ? str(j, "root") : root;
            if (action == "jump") {
                if (!j.is_object() || str(j, "pane").empty()) return 1;
                return sh::run({"desk-drawer", "run", "work-jump", str(j, "pane")});
            }
            if (action == "file" || action == "file-diff" || action == "suggested-tests") {
                std::error_code ec;
                const auto canonical_root = fs::canonical(where, ec); if (ec) return 2;
                const auto path = fs::weakly_canonical(canonical_root / fs::path(opts["--file"]), ec);
                const auto relative = path.lexically_relative(canonical_root);
                if (ec || opts["--file"].empty() || relative.empty() || *relative.begin() == ".." || relative == ".") return 2;
                return open_editor(canonical_root.string(), action, path.string(), opts["--session"]);
            }
            if (action == "plan") {
                auto plan = json(plan_path(root_of(where), opts["--session"]));
                if (!plan.is_object()) return 1;
                return open_editor(where, "file", str(plan, "file"));
            }
            if (action == "worktree") {
                std::error_code ec; const auto selected = fs::canonical(opts["--file"], ec); if (ec) return 2;
                for (const auto& tree : worktrees(root_of(where)))
                    if (str(tree, "path") == selected.string() && !tree.value("bare", false)) return open_editor(selected.string(), "workspace");
                return 2;
            }
            if (!std::set<std::string>{"tests", "reviews", "compare", "log", "tasks", "ask", "service", "ask-service", "timeline", "digest", "snoozed", "health", "backups"}.count(action)) return 2;
            return open_editor(where.empty() ? fs::current_path().string() : where, action, target, opts["--index"]);
        } else if (cmd == "notify-services") {
            std::string failed;
            if (!sh::capture({"timeout", "3", "systemctl", "--user", "--failed", "--no-legend", "--plain", "--type=service"}, failed)) return 0;
            const auto file = base() / "failed-services.json"; const auto previous = json(file);
            J current = J::array();
            for (const auto& line : split(failed)) {
                std::istringstream fields(line); std::string unit; fields >> unit;
                if (!std::regex_match(unit, std::regex("[A-Za-z0-9_.@:-]{1,200}\\.service")) || unit == "fox-work-notify.service") continue;
                current.push_back(unit);
                if (!previous.is_array() || std::find(previous.begin(), previous.end(), unit) == previous.end()) notify_failure(unit, unit, true);
            }
            out = written(atomic(file, current.dump()), "failed-service list");
        } else if (cmd == "log") {
            const auto j = load_run(id); if (!j.is_object()) return 1;
            std::cout << clean(read(run_dir(id) / "output.log")); return 0;
        } else if (cmd == "service-log") {
            const auto unit = opts["--unit"];
            if (!std::regex_match(unit, std::regex("[A-Za-z0-9_.@:-]{1,200}\\.service"))) return 2;
            std::cout << clean(query({"journalctl", "--user", "-u", unit, "-n", "80", "--no-pager", "-o", "cat"})); return 0;
        } else return 2;
        std::cout << out.dump(-1, ' ', false, J::error_handler_t::replace) << '\n';
        return out.is_object() && out.contains("ok") && out["ok"] == false ? 1 : 0;
    } catch (const std::exception& e) { std::cerr << "desk-work: " << e.what() << '\n'; return 1; }
}
int main(int argc, char** argv) {
    const int code = dispatch(argc, argv);
    // Usage refusals print nothing else, so say which command refused. Commands that hand back a child's own exit
    // status are left alone: a 2 from them is the child's.
    static const std::set<std::string> passthrough{"integrations", "run", "run-suggested"};
    if (code == 2 && !passthrough.count(invoked))
        std::cerr << "desk-work " << (invoked.empty() ? "" : invoked + ": ") << "missing or invalid arguments (desk-work help lists them)\n";
    return code;
}
