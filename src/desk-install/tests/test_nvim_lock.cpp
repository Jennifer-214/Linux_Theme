// Whether the deployed lazy-lock.json is the repo's (modules/nvim_lock.hpp). In the test VM (2026-11-16) an upgrade that
// added three plugins left lazy.nvim and nvim-scrollbar at the old lock's commits: lazy rewrote the lock as Neovim
// started, before `Lazy! restore` read it, and post_install still said "at the lock file's versions".
#include "../modules/nvim_lock.hpp"

#include <cstdio>

using namespace desk_install::nvim_lock;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

int main() {
    const std::string repo = R"({
  "lazy.nvim": { "branch": "main", "commit": "306a0552" },
  "nvim-scrollbar": { "branch": "v1", "commit": "f8e87b96" },
  "vimtex": { "branch": "master", "commit": "aaaa1111" }
})";
    const std::string same = R"({"lazy.nvim": {"branch": "main", "commit": "306a0552"}, "nvim-scrollbar": {"branch": "v1", "commit": "f8e87b96"}})";
    const std::string old = R"({"lazy.nvim": {"branch": "main", "commit": "85c7ff37"}, "nvim-scrollbar": {"branch": "main", "commit": "00fe857e"}})";

    expect(mismatches(repo, same).empty(), "the repo's commits deployed (and a plugin not installed here left out): none off");
    const auto off = mismatches(repo, old);
    expect(off.size() == 2 && off[0] == "lazy.nvim" && off[1] == "nvim-scrollbar", "the VM's upgrade: both named");
    expect(mismatches(repo, R"({"lazy.nvim": {"branch": "main"}})") == std::vector<std::string>{"lazy.nvim"},
           "a deployed line with no commit is not at the lock");
    expect(mismatches(repo, "{ half a lock") == std::vector<std::string>{"(unreadable)"}, "a lock that does not parse is not the repo's");
    expect(mismatches(repo, "") == std::vector<std::string>{"(unreadable)"}, "no deployed lock is not the repo's");

    if (failures == 0) std::printf("test_nvim_lock: all checks passed\n");
    return failures ? 1 : 0;
}
