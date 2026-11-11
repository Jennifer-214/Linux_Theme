#include "json.hpp"
#include "shell.hpp"
#include <algorithm>
#include <chrono>
#include <charconv>
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
#include <openssl/sha.h>
#include <sys/file.h>
#include <sys/stat.h>
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
    if (ok && ::rename(name.data(), p.c_str()) == 0) return true;
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
std::string proc_stamp(long long pid) {
    if (pid <= 0) return {};
    const auto stat = read(fs::path("/proc") / std::to_string(pid) / "stat", 8192);
    const auto end = stat.rfind(')'); if (end == stat.npos) return {};
    std::istringstream in(stat.substr(end + 2)); std::string v;
    for (int field = 3; field <= 22; ++field) if (!(in >> v) || (field == 3 && (v == "Z" || v == "X"))) return {};
    return trim(read("/proc/sys/kernel/random/boot_id")) + ":" + v;
}
std::string uuid() {
    const auto seed = read("/proc/sys/kernel/random/uuid", 128);
    return hash(seed + std::to_string(::getpid()) + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())).substr(0, 32);
}
std::vector<std::string> split(const std::string& s, char sep = '\n') {
    std::istringstream in(s); std::vector<std::string> out; std::string v;
    while (std::getline(in, v, sep)) if (!v.empty()) out.push_back(v);
    return out;
}
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
J parse_tests(const std::string& log, const std::string& root) {
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
    fs::path context = root;
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
        if (str(r, "state") == "passed" && num(r, "ended") > 0 && took_s >= 1) took.emplace(str(r, "root") + '\n' + str(r, "command"), took_s);
    }
    for (auto& r : out) if (str(r, "state") == "running") {
        const auto it = took.find(str(r, "root") + '\n' + str(r, "command"));
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
J begin(const std::string& command, const std::string& root, const std::string& session, long long pid, bool observed, const std::string& title = {}) {
    if (!register_root(root)) return J();
    prune_old_runs();
    const auto id = uuid(); const auto dir = run_dir(id);
    const auto snap = snapshot(root, dir / "source");
    std::string green;
    for (const auto& r : runs(root)) if (str(r, "command") == command && str(r, "state") == "passed" && r.value("baselineEligible", false)) { green = str(r, "id"); break; }
    J j{{"id", id}, {"root", root}, {"command", command.substr(0, 4000)}, {"kind", kind_of(command)}, {"session", session},
        {"pane", env("TMUX_PANE")}, {"pid", pid}, {"process", proc_stamp(pid)}, {"started", now()}, {"state", "running"},
        {"snapshot", snap}, {"baseline", green}, {"observed", observed},
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
        if (str(r, "id") == str(job, "id") || str(r, "command") != str(job, "command")
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
    j["tests"] = parse_tests(read(run_dir(str(j, "id")) / "output.log"), str(j, "root"));
    j["testRun"] = str(j, "kind") == "tests" || !j["tests"]["passed"].is_null() || !j["tests"]["failed"].is_null();
    if (!same_source(j["snapshot"], snapshot(str(j, "root")))) j["changedDuringRun"] = true;
    if (j.value("changedDuringRun", false) || truncated || num(j["tests"], "failed") > 0) j["baselineEligible"] = false;
    else j["baselineEligible"] = j["testRun"].get<bool>() && code == 0 && num(j["tests"], "passed") > 0 && j["snapshot"].value("complete", false);
    if (!save_run(run_dir(str(j, "id")), j)) return false;
    return true;
}
J tasks(const std::string& root) { auto j = json(project_dir(root) / "tasks.json"); return j.is_array() ? j : J::array(); }
J task_change(const std::string& root, const std::string& text, const std::string& id) {
    if (!register_root(root)) return J{{"ok", false}};
    Lock lock(project_dir(root) / "tasks.lock"); if (lock.fd < 0) return J{{"ok", false}};
    const auto file = project_dir(root) / "tasks.json";
    auto j = json(file); std::error_code ec;
    if (fs::exists(file, ec) && !j.is_array()) return J{{"ok", false}, {"message", "Next steps are unreadable; left untouched"}};
    if (!j.is_array()) j = J::array();
    if (id.empty()) { if (trim(text).empty() || text.size() > 2000 || j.size() >= 200) return J{{"ok", false}};
        j.push_back(J{{"id", uuid()}, {"text", trim(text)}, {"done", false}, {"at", now()}});
    } else { bool found = false; for (auto& t : j) if (str(t, "id") == id) { t["done"] = !t.value("done", false); found = true; }
        if (!found) return J{{"ok", false}, {"message", "That next step is no longer here"}};
    }
    return J{{"ok", atomic(file, j.dump())}, {"message", id.empty() ? "Next step pinned" : "Next step updated"}};
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
J reviews(const std::string& root, bool today_only = true) {
    std::error_code error;
    if (!fs::exists(fs::path(root) / ".git", error)) return J::array();
    // Kept until the checkout's history or the review marks change (or the day turns): the drawer asks every open.
    const std::time_t clock = std::time(nullptr);
    std::tm day = *std::localtime(&clock);
    const auto signature = std::to_string(stamp_of(head_log(root))) + "|" + std::to_string(stamp_of(project_dir(root) / "reviewed.json"))
                           + "|" + std::to_string(day.tm_year) + "-" + std::to_string(day.tm_yday) + "|" + (today_only ? "today" : "all");
    const auto cached = json(project_dir(root) / "reviews-cache.json");
    if (cached.is_object() && str(cached, "signature") == signature && cached["reviews"].is_array()) return cached["reviews"];
    const auto marks = json(project_dir(root) / "reviewed.json");
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
        const bool seen = marks.is_object() && marks.contains(f[0]);
        if (today_only && (at < start || seen)) continue;
        out.push_back(J{{"sha", f[0]}, {"at", at}, {"subject", f[2]}, {"root", root}, {"reviewed", seen}});
    }
    if (register_root(root)) atomic(project_dir(root) / "reviews-cache.json", J{{"signature", signature}, {"reviews", out}}.dump());
    return out;
}
J reviewed(const std::string& root, const std::string& sha) {
    if (!std::regex_match(sha, std::regex("[a-f0-9]{40}")) || trim(query({"git", "-C", root, "rev-parse", "--verify", sha + "^{commit}"})) != sha || !register_root(root)) return J{{"ok", false}};
    const auto file = project_dir(root) / "reviewed.json"; Lock lock(project_dir(root) / "reviews.lock");
    auto j = json(file); std::error_code ec;
    if (lock.fd < 0 || (fs::exists(file, ec) && !j.is_object())) return J{{"ok", false}};
    if (!j.is_object()) j = J::object();
    j[sha] = now();
    return J{{"ok", atomic(file, j.dump())}};
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
        const auto root = str(r, "root"), state = str(r, "state");
        const bool newest = commands.insert(root + '\n' + str(r, "command")).second;
        const auto targets = test_targets(str(r, "command"), root);
        auto all_in = [&](const std::vector<std::string>& seen) {
            return !targets.empty() && std::all_of(targets.begin(), targets.end(), [&](const std::string& t) {
                return std::any_of(seen.begin(), seen.end(), [&](const std::string& s) { return covers(s, t); });
            });
        };
        if (state == "passed") { for (const auto& t : targets) passed[root].push_back(t); return false; }
        if (state != "failed" && state != "interrupted") return false;
        // A call filed as a test run that ran no test (a grep that only mentions tests/test_x.py) is no failure.
        if (str(r, "kind") == "tests" && targets.empty()) return false;
        const bool open = newest && !all_in(passed[root]) && !all_in(failed[root]);
        for (const auto& t : targets) failed[root].push_back(t);
        return open;
    }
};
J overview(const A& requested, bool fresh = false) {
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
    for (const auto& root : roots) {
        for (auto t : tasks(root)) if (!t.value("done", false)) { t["root"] = root; todo.push_back(t); }
        for (auto r : reviews(root)) review.push_back(r);
    }
    return J{{"jobs", all}, {"running", running}, {"finished", finished}, {"failed", failed}, {"tasks", todo}, {"reviews", review}};
}
J notebook(const std::string& root, const std::string& session) {
    J latest; auto all = runs(root); const auto current = snapshot(root);
    J jobs = J::array(), failures = J::array(); Settled settled;
    for (auto j : all) {
        const bool standing = settled.standing(j);
        if (str(j, "state") == "running") { j.erase("snapshot"); jobs.push_back(j); }
        else if (standing && failures.size() < 3 && num(j, "ended") >= now() - 24 * 3600) {
            auto failed = j; failed.erase("snapshot"); failures.push_back(failed);
        }
        if (latest.is_null() && j.value("testRun", false)) {
            j["snapshot"] = load_run(str(j, "id")).value("snapshot", J());
            freshness(j, current); j.erase("snapshot"); latest = j;
        }
    }
    return J{{"tests", latest}, {"jobs", jobs}, {"failures", failures}, {"tasks", tasks(root)}, {"session", session}};
}
fs::path plan_path(const std::string& root, const std::string& session) {
    return project_dir(root) / "plans" / (hash(session) + ".json");
}
J pin_plan(const std::string& root, const std::string& session, const std::string& file, const std::string& step) {
    if (session.empty() || session.size() > 80 || step.size() > 1000) return J{{"ok", false}};
    J plan;
    if (!file.empty()) {
        std::error_code ec;
        const auto path = fs::canonical(fs::path(file).is_absolute() ? fs::path(file) : fs::path(root) / file, ec);
        if (ec || path.extension() != ".md" || !fs::is_regular_file(path, ec)) return J{{"ok", false}, {"message", "Choose an existing Markdown plan"}};
        plan = J{{"file", path.string()}, {"step", clean(step)}, {"at", now()}};
    }
    return J{{"ok", atomic(plan_path(root, session), plan.dump())}};
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
}

int main(int argc, char** argv) {
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
                         "desk-work open --root DIR --action tests|reviews|compare|log|tasks|ask|file|file-diff|plan|worktree --id RUN [--file PATH --session ID]\n"; return 0;
        }
        const auto cmd = args[0];
        const auto place = opts.count("--root") ? opts["--root"] : fs::current_path().string();
        const auto root = std::set<std::string>{"run", "begin", "notebook", "tests", "tasks", "task-add", "task-toggle", "reviews", "reviewed", "worktrees", "activity", "plan", "plan-pin"}.count(cmd)
            ? root_of(place) : place;
        const auto id = opts["--id"];
        J out;
        if (cmd == "classify") { out = J{{"kind", kind_of(opts["--command"])}}; }
        else if (cmd == "run") {
            if (args.size() < 2) return 2;
            A child(args.begin() + 1, args.end()); std::string label;
            for (const auto& a : child) label += (label.empty() ? "" : " ") + quote(a);
            if (child.size() == 3 && (child[0] == "bash" || child[0] == "zsh") && child[1] == "-c") label = child[2];
            auto j = begin(label, root, opts["--session"], ::getpid(), false, opts["--title"]);
            if (!j.is_object()) { std::cerr << "Could not record job; running command directly.\n"; return sh::run(child); }
            bool truncated = false; const int code = sh::run_logged(child, run_dir(str(j, "id")) / "output.log", 4 * 1024 * 1024, truncated);
            finish(j, code, truncated);
            if (code != 0) notify_failure(str(j, "title", label), str(j, "id"));
            return code < 0 ? 125 : code;
        } else if (cmd == "begin") {
            if (kind_of(opts["--command"]).empty()) return 0;
            // "parent": whoever started this (Claude Code itself, for a mod); the job stays running only while it lives.
            const long long pid = opts["--pid"] == "parent" ? static_cast<long long>(::getppid()) : std::stoll(opts["--pid"]);
            out = begin(opts["--command"], root, opts["--session"], pid, true, opts["--title"]);
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
        else if (cmd == "overview") out = overview(roots, opts["--fresh"] == "yes");
        else if (cmd == "notebook") out = notebook(root, opts["--session"]);
        else if (cmd == "worktrees") out = worktrees(root);
        else if (cmd == "plan") out = plan_with_progress(json(plan_path(root, opts["--session"])));
        else if (cmd == "plan-pin") out = pin_plan(root, opts["--session"], opts["--file"], opts["--step"]);
        else if (cmd == "tasks") out = tasks(root);
        else if (cmd == "task-add") out = task_change(root, opts["--text"], "");
        else if (cmd == "task-toggle") out = task_change(root, "", id);
        else if (cmd == "reviews") out = reviews(root, opts["--all"] != "yes");
        else if (cmd == "reviewed") out = reviewed(root, opts["--sha"]);
        else if (cmd == "tests") {
            auto j = id.empty() ? notebook(root, "")["tests"] : load_run(id);
            if (j.is_object() && j.contains("snapshot")) { freshness(j, snapshot(str(j, "root"))); j.erase("snapshot"); }
            out = j.is_object() ? j : J();
        } else if (cmd == "compare") {
            auto j = load_run(id); if (!j.is_object()) return 1;
            std::cout << comparison(j); return 0;
        } else if (cmd == "open") {
            const auto action = opts["--action"];
            auto j = load_run(id); const auto where = j.is_object() ? str(j, "root") : root;
            if (action == "jump") {
                if (!j.is_object() || str(j, "pane").empty()) return 1;
                return sh::run({"desk-drawer", "run", "work-jump", str(j, "pane")});
            }
            if (action == "file" || action == "file-diff") {
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
            if (!std::set<std::string>{"tests", "reviews", "compare", "log", "tasks", "ask", "service", "ask-service"}.count(action)) return 2;
            return open_editor(where, action, id, opts["--index"]);
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
            out = J{{"ok", atomic(file, current.dump())}};
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
