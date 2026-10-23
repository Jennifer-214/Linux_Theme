// Unit test for core/git_clone.hpp — a dropped clone can't leave a broken checkout behind for good. Real local git
// repos (file paths as URLs): offline, no waiting (the sleeper only records). Never deletes anything it didn't make.

#include "../core/git_clone.hpp"

#include <cstdio>
#include <fstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace fox_install::git_clone;

static int exec_argv(const std::vector<std::string>& a) {   // fork + execvp: the test's own runner (no shell)
    pid_t pid = fork();
    if (pid == 0) {
        std::vector<char*> v;
        for (auto& s : a) v.push_back(const_cast<char*>(s.c_str()));
        v.push_back(nullptr);
        if (std::freopen("/dev/null", "w", stdout) == nullptr || std::freopen("/dev/null", "w", stderr) == nullptr) _exit(126);
        execvp(v[0], v.data());
        _exit(127);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int failed = 0;
static void expect(bool ok, const char* what) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
}

int main() {
    const fs::path root = fs::path(BUILD_DIR) / ("git_clone_fixture_" + std::to_string(::getpid()));
    fs::remove_all(root);
    fs::create_directories(root);
    const fs::path src = root / "src";                       // the "remote": a repo with one commit
    exec_argv({"git", "init", "--quiet", src.string()});
    std::ofstream(src / "README") << "hello\n";
    exec_argv({"git", "-C", src.string(), "add", "README"});
    exec_argv({"git", "-C", src.string(), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "one"});
    const std::string url = src.string();

    std::vector<int> slept;
    Runner r{exec_argv, exec_argv, [&](int s) { slept.push_back(s); }, 3};

    // absent → cloned
    Result a = ensure(r, url, root / "fresh");
    expect(a.outcome == Outcome::Cloned && valid_checkout(r, root / "fresh") && a.attempts == 1, "absent repo is cloned");
    // present and valid → untouched
    Result b = ensure(r, url, root / "fresh");
    expect(b.outcome == Outcome::Present, "a valid checkout is left as present");

    // a dropped clone (a repo with nothing but .git, no commit) → moved aside, cloned again
    exec_argv({"git", "init", "--quiet", (root / "partial").string()});
    Result c = ensure(r, url, root / "partial");
    expect(c.outcome == Outcome::Repaired, "a partial clone is repaired");
    expect(valid_checkout(r, root / "partial"), "the repaired repo is a valid checkout");
    expect(!c.moved_aside.empty() && fs::exists(c.moved_aside / ".git"), "the broken clone is kept, moved aside — not deleted");

    // someone's own fresh `git init` with files in it → left alone
    exec_argv({"git", "init", "--quiet", (root / "mine").string()});
    std::ofstream(root / "mine" / "notes.txt") << "mine\n";
    Result d = ensure(r, url, root / "mine");
    expect(d.outcome == Outcome::NotARepo && fs::exists(root / "mine" / "notes.txt"), "a git init with files is left alone");
    // a plain folder of files → left alone
    fs::create_directories(root / "plain");
    std::ofstream(root / "plain" / "x") << "x\n";
    Result e = ensure(r, url, root / "plain");
    expect(e.outcome == Outcome::NotARepo && fs::exists(root / "plain" / "x"), "a plain folder is left alone");
    // a repo git refuses to read (dubious ownership, simulated: --git-dir fails) → left alone
    exec_argv({"git", "init", "--quiet", (root / "unreadable").string()});
    Runner deny = r;
    deny.probe = [](const std::vector<std::string>& a2) { return (a2.size() > 3 && a2[3] == "rev-parse") ? 128 : 0; };
    Result f = ensure(deny, url, root / "unreadable");
    expect(f.outcome == Outcome::NotARepo && fs::exists(root / "unreadable" / ".git"), "a repo git can't read is left alone");

    // two dropped attempts, then it goes through → cloned on the third try, backoff 5 then 15
    int calls = 0;
    Runner flaky = r;
    flaky.run = [&](const std::vector<std::string>& a2) {
        if (++calls <= 2) {                                  // a drop that leaves a half-made folder behind
            fs::create_directories(fs::path(a2.back()) / ".git");
            return 128;
        }
        return exec_argv(a2);
    };
    slept.clear();
    Result g = ensure(flaky, url, root / "flaky");
    expect(g.outcome == Outcome::Cloned && g.attempts == 3 && valid_checkout(r, root / "flaky"), "a flaky clone succeeds on retry");
    expect(slept == std::vector<int>({5, 15}), "retries back off 5 s, then 15 s");

    // never reachable → fails after 3 tries, nothing broken left at the target
    slept.clear();
    Result h = ensure(r, (root / "no-such-remote").string(), root / "gone");
    expect(h.outcome == Outcome::Failed && h.attempts == 3, "an unreachable remote fails after 3 tries");
    expect(!fs::exists(root / "gone"), "a failed clone leaves nothing at the target");

    // the clone command never prompts and gives up on a stalled transfer
    const auto argv = clone_argv("u", "d", {"--depth", "1"});
    std::string joined;
    for (auto& s : argv) joined += s + " ";
    expect(joined.find("GIT_TERMINAL_PROMPT=0") != std::string::npos && joined.find("ConnectTimeout") != std::string::npos
           && joined.find("http.lowSpeedTime") != std::string::npos && joined.find("--depth 1 u d") != std::string::npos,
           "the clone command: no prompt, timeouts, extra args before the URL");

    fs::remove_all(root);
    if (failed) return 1;
    std::printf("test_git_clone: all checks passed\n");
    return 0;
}
