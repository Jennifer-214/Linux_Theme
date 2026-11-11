// core/git_clone.hpp — clone a repo so a dropped connection can't leave a broken checkout behind for good.
//
// Before (2026-10-22): a clone that dropped part-way (network gone, laptop asleep, Ctrl-C on a hang) could leave a
// half-made folder; the next run saw the folder, called it "already present" and skipped it forever, with no retry and
// a summary that never named which repo failed. Now:
//   • a partial clone — a repo git can read, with no commit, holding nothing but .git — is MOVED ASIDE to
//     <name>.broken-<time> (never deleted) and cloned again;
//   • anything else in the way (someone's own files, a repo git refuses to read) is left alone and reported;
//   • a clone gets 3 tries with backoff, with timeouts so a stalled transfer fails instead of hanging
//     (ssh ConnectTimeout + keepalives; http lowSpeedLimit/lowSpeedTime), and never prompts;
//   • the caller gets an outcome per repo, so a summary can name every failure.
// Header-only; the runner is injectable so tests/test_git_clone.cpp can drive it against local repos, offline.
#pragma once

#include <chrono>
#include <ctime>
#include <filesystem>
#include <functional>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

namespace fox_install::git_clone {

namespace fs = std::filesystem;

enum class Outcome { Present, Cloned, Repaired, NotARepo, Failed };

struct Runner {
    std::function<int(const std::vector<std::string>&)> run;     // a command that may change things
    std::function<int(const std::vector<std::string>&)> probe;   // a read-only query; its exit code
    std::function<void(int)> sleep_s = [](int s) { std::this_thread::sleep_for(std::chrono::seconds(s)); };
    int tries = 3;
};

struct Result {
    Outcome outcome;
    fs::path moved_aside;   // where a broken checkout went (Repaired), else empty
    int attempts = 0;
};

// A git checkout with a commit checked out — what a finished clone leaves.
inline bool valid_checkout(const Runner& r, const fs::path& dir) {
    std::error_code ec;
    if (!fs::exists(dir / ".git", ec)) return false;
    return r.probe({"git", "-C", dir.string(), "rev-parse", "--verify", "--quiet", "HEAD"}) == 0;
}

// What a dropped clone leaves: a repo git CAN read, with no commit, holding nothing but .git (checkout comes last).
// Anything else — a repo git refuses to read ("dubious ownership"), someone's fresh `git init` with files in it — is
// not ours to move.
inline bool partial_clone(const Runner& r, const fs::path& dir) {
    std::error_code ec;
    if (!fs::is_directory(dir / ".git", ec) || valid_checkout(r, dir)) return false;
    if (r.probe({"git", "-C", dir.string(), "rev-parse", "--git-dir"}) != 0) return false;
    for (const auto& e : fs::directory_iterator(dir, ec))
        if (e.path().filename() != ".git") return false;
    return !ec;
}

// <dir>.broken-<YYYYmmdd-HHMMSS>[-n]: a free name next to dir.
inline fs::path aside_name(const fs::path& dir) {
    char ts[32]{};
    std::time_t now = std::time(nullptr);
    if (std::tm* tm = std::localtime(&now)) std::strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", tm);
    fs::path p = dir.string() + ".broken-" + ts;
    std::error_code ec;
    for (int n = 2; fs::exists(p, ec); ++n) p = dir.string() + ".broken-" + ts + "-" + std::to_string(n);
    return p;
}

// The clone command: never prompts, gives up on a stalled transfer instead of hanging.
inline std::vector<std::string> clone_argv(const std::string& url, const fs::path& dir,
                                           const std::vector<std::string>& extra) {
    std::vector<std::string> a = {"env", "GIT_TERMINAL_PROMPT=0",
                                  "GIT_SSH_COMMAND=ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
                                  "git", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=60",
                                  "clone", "--quiet"};
    a.insert(a.end(), extra.begin(), extra.end());
    a.push_back(url);
    a.push_back(dir.string());
    return a;
}

// Make dir a valid checkout of url: Present if it already is; NotARepo (left alone) if it's a folder of someone's own
// files; else clone — after moving a partial clone aside — with retries. `extra` goes before the URL (--depth 1 …).
inline Result ensure(const Runner& r, const std::string& url, const fs::path& dir,
                     const std::vector<std::string>& extra = {}) {
    std::error_code ec;
    Result res{Outcome::Cloned, {}, 0};
    if (fs::exists(dir, ec)) {
        if (valid_checkout(r, dir)) return {Outcome::Present, {}, 0};
        if (!partial_clone(r, dir)) return {Outcome::NotARepo, {}, 0};
        res.moved_aside = aside_name(dir);                       // a partial clone: keep it, out of the way
        fs::rename(dir, res.moved_aside, ec);
        if (ec) return {Outcome::Failed, {}, 0};
        res.outcome = Outcome::Repaired;
    }
    fs::create_directories(dir.parent_path(), ec);
    for (int k = 1; k <= r.tries; ++k) {
        res.attempts = k;
        if (r.run(clone_argv(url, dir, extra)) == 0 && valid_checkout(r, dir)) return res;
        if (fs::exists(dir, ec)) {                               // this attempt's own leftovers: out of the way too
            fs::path p = aside_name(dir);
            fs::rename(dir, p, ec);
        }
        if (k < r.tries) r.sleep_s(k == 1 ? 5 : 15);
    }
    res.outcome = Outcome::Failed;
    return res;
}

inline const char* describe(Outcome o) {
    switch (o) {
        case Outcome::Present:  return "already present";
        case Outcome::Cloned:   return "cloned";
        case Outcome::Repaired: return "was a broken partial clone — moved aside and cloned again";
        case Outcome::NotARepo: return "a folder that isn't a clean clone (your files, or a repo git can't read) — left alone";
        case Outcome::Failed:   return "clone failed after retries";
    }
    return "?";
}

}  // namespace fox_install::git_clone
