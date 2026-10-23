// sh::check_ro (installer audit 2026-10-15, finding 11; batch 3a): a state check runs in a dry run too, so the plan
// says what is really there — and only the read-only argv forms is_read_only() accepts ever run. probe() and capture()
// are untouched (capture() has callers that run other commands).

#include "../../fox-common/shell.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace fox_install;

int main() {
    int failed = 0;
    auto expect = [&](const std::string& what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
    };
    using V = std::vector<std::string>;
    for (const V& ok : {V{"systemctl", "is-active", "--quiet", "x.service"}, V{"systemctl", "--user", "is-enabled", "--quiet", "y.timer"},
                        V{"systemctl", "is-enabled", "z"}, V{"grep", "-q", "^--theme=", "/tmp/conf"}, V{"grep", "-q", "-E", "a|b", "f"}})
        expect("read-only form accepted: " + ok[0] + " " + ok[1], sh::is_read_only(ok));
    for (const V& bad : {V{"systemctl", "enable", "--now", "ufw"}, V{"systemctl", "start", "x"}, V{"systemctl", "is-active", "--now", "x"},
                         V{"systemctl", "--user", "disable", "x"}, V{"systemctl"}, V{"grep", "-r", "x", "/"}, V{"grep", "x", "f"},
                         V{"sed", "-i", "s/a/b/", "f"}, V{"sh", "-c", "systemctl is-active x"}, V{"pacman", "-S", "x"}, V{"tee", "f"}, V{}})
        expect("write or unknown form refused: " + (bad.empty() ? std::string("(empty)") : bad[0] + (bad.size() > 1 ? " " + bad[1] : "")),
               !sh::is_read_only(bad));
    // a refused form never runs: check_ro says -1 (a "no" for every caller's == 0 / != 0 test) without executing
    expect("a refused form returns -1", sh::check_ro({"sh", "-c", "exit 0"}) == -1);
    // the point of it: in a dry run, run() answers 0 ("yes") for anything; check_ro asks the real system
    sh::set_dry_run(true);
    expect("dry run: run() says yes to a grep that would fail", sh::run({"grep", "-q", "x", "/nonexistent/fox-check-ro"}) == 0);
    expect("dry run: check_ro tells the truth", sh::check_ro({"grep", "-q", "x", "/nonexistent/fox-check-ro"}) != 0);
    expect("dry run: pacman_installed says no for a package that can't exist", !sh::pacman_installed("fox-check-ro-no-such-package"));
    sh::set_dry_run(false);
    expect("real run: check_ro agrees with run() on the same read-only form",
           sh::check_ro({"grep", "-q", "x", "/nonexistent/fox-check-ro"}) == sh::run({"grep", "-q", "x", "/nonexistent/fox-check-ro"}));
    if (failed) { std::fprintf(stderr, "check_ro tests: %d FAILED\n", failed); return 1; }
    std::printf("check_ro tests: OK\n");
    return 0;
}
