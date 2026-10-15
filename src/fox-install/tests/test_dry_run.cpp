// A dry run writes nothing (installer audit 2026-10-15): modules that used to write before checking sh::dry_run().
// vault wrote its user unit and only then looked; a dry run must leave the unit dir untouched and still say what a
// real run would do.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

namespace fox_install { void run_vault(Context& ctx); }

namespace fs = std::filesystem;
using namespace fox_install;

int main() {
    int failed = 0;
    auto expect = [&](const char* what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
    };
    const fs::path home = fs::temp_directory_path() / ("fox_dry_run_test_" + std::to_string(::getpid()));
    fs::remove_all(home);
    fs::create_directories(home / ".local/bin");
    std::ofstream(home / ".local/bin/fox-vault") << "stand-in\n";   // run_vault only checks it exists

    Context ctx;
    ctx.home = home;
    ctx.config_home = home / ".config";
    sh::set_dry_run(true);
    run_vault(ctx);
    sh::set_dry_run(false);
    expect("vault: a dry run writes no unit", !fs::exists(ctx.config_home / "systemd/user/fox-vault.service"));
    expect("vault: a dry run makes no unit dir", !fs::exists(ctx.config_home / "systemd"));
    fs::remove_all(home);

    if (failed) { std::fprintf(stderr, "dry_run tests: %d FAILED\n", failed); return 1; }
    std::printf("dry_run tests: OK\n");
    return 0;
}
