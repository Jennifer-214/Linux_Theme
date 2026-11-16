// tests/test_browser_hardening.cpp — the module on a machine where Firefox has never run: it hardens the profile that
// Firefox's first start will open, instead of skipping because there is none yet. Fake firefox and curl on PATH (no
// network, no browser, no firejail or sudo reachable), a temporary HOME.
#include "../core/context.hpp"
#include "../modules/arkenfox_userjs.hpp"
#include "../modules/firefox_appearance.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace fs = std::filesystem;
namespace desk_install { void run_browser_hardening(Context&); }
namespace desk_install::state {
bool rendered_is_current(const Context&) { return false; }
}

static std::string read(const fs::path& path) {
    std::ifstream f(path);
    return {std::istreambuf_iterator<char>(f), {}};
}

int main() {
    // The fakes are executed, and /tmp is noexec on these machines.
    std::string pattern = (fs::current_path() / ".fox-browser-hardening-XXXXXX").string();
    const char* made = ::mkdtemp(pattern.data());
    if (!made) return 1;
    const fs::path root(made);
    const auto bin = root / "bin";
    fs::create_directories(bin);
    auto program = [&](const char* name, const std::string& body) {
        std::ofstream(bin / name) << body;
        fs::permissions(bin / name, fs::perms::owner_all);
    };
    program("firefox", "#!/bin/sh\nexit 1\n");  // found, never run
    program("curl", "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do [ \"$1\" = -o ] && out=\"$2\"; shift; done\n"
                    "printf '%s\\n' '// arkenfox user.js (a stand-in)' 'user_pref(\"_user.js.parrot\", \"SUCCESS: done\");' > \"$out\"\n");
    const std::string saved_path = std::getenv("PATH") ? std::getenv("PATH") : "";
    ::setenv("PATH", bin.c_str(), 1);

    int failures = 0;
    auto expect = [&](bool ok, const char* why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };
    desk_install::Context ctx;
    ctx.home = root / "home";
    ctx.config_home = ctx.home / ".config";
    ctx.backup_dir = root / "backup";
    fs::create_directories(ctx.home);
    desk_install::run_browser_hardening(ctx);
    const auto profile = desk_install::firefox_appearance::profile(ctx);
    expect(!profile.empty(), "a profile for Firefox's first start");
    const auto user_js = read(profile / "user.js");
    expect(desk_install::arkenfox::is_arkenfox(user_js), "arkenfox's user.js is in it");
    expect(desk_install::arkenfox::has_overrides(user_js), "with user-overrides.js copied in after it");
    expect(fs::exists(profile / "user-overrides.js"), "and user-overrides.js beside it to edit");

    // Without Firefox nothing is made.
    ::setenv("PATH", (root / "empty").c_str(), 1);
    ctx.home = root / "no-firefox";
    ctx.config_home = ctx.home / ".config";
    desk_install::run_browser_hardening(ctx);
    expect(!fs::exists(ctx.home), "no Firefox, no profile");

    ::setenv("PATH", saved_path.c_str(), 1);
    fs::remove_all(root);
    std::cout << (failures ? "Browser hardening on a fresh install: FAILED\n" : "Browser hardening on a fresh install: OK\n");
    return failures ? 1 : 0;
}
