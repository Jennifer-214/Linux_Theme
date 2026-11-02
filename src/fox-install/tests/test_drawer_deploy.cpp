#include "../core/backup.hpp"
#include "../../fox-common/shell.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <cstdlib>
#include <unistd.h>

namespace fs = std::filesystem;
namespace fox_install { void run_drawer(Context&); }

std::string read(const fs::path& path) {
    std::ifstream f(path);
    return {std::istreambuf_iterator<char>(f), {}};
}

int main() {
    char pattern[] = "/tmp/fox-drawer-deploy-XXXXXX";
    const char* temp = ::mkdtemp(pattern);
    if (!temp) return 1;
    const fs::path root(temp);
    fox_install::Context ctx;
    ctx.home = root / "home";
    ctx.config_home = ctx.home / ".config";
    ctx.backup_dir = root / "backup";
    fs::create_directories(ctx.home);
    const auto source = root / "source";
    const auto dest = ctx.home / "program";
    std::ofstream(source) << "new\n";
    std::ofstream(dest) << "original\n";
    fs::permissions(source, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec);
    int failures = 0;
    auto expect = [&](bool ok, const char* why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "deploy succeeds");
    expect(read(dest) == "new\n", "new file is installed");
    expect(read(ctx.backup_dir / "program") == "original\n", "old file is backed up");
    expect((fs::status(dest).permissions() & fs::perms::owner_exec) != fs::perms::none,
           "executable permissions are preserved");
    expect(!fs::exists(dest.string() + ".foxin.tmp"), "temporary file is gone");
    std::ofstream(source) << "newer\n";
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "repeat deployment succeeds");
    expect(read(ctx.backup_dir / "program") == "original\n", "first snapshot survives a second deploy");
    const auto protected_file = root / "protected";
    std::ofstream(protected_file) << "leave this alone\n";
    fs::create_symlink(protected_file, dest.string() + ".foxin.tmp");
    expect(fox_install::deploy_file_atomic(ctx, source, dest), "old predictable temporary path is ignored");
    expect(read(protected_file) == "leave this alone\n", "temporary symlink target is untouched");
    ctx.backup_dir = root / "blocked";
    std::ofstream(ctx.backup_dir) << "not a directory";
    std::ofstream(source) << "must not land\n";
    expect(!fox_install::deploy_file_atomic(ctx, source, dest), "backup failure refuses deployment");
    expect(read(dest) == "newer\n", "backup failure preserves installed file");
    fox_install::sh::set_dry_run(true);
    fox_install::run_drawer(ctx);
    fox_install::sh::set_dry_run(false);
    expect(!fs::exists(ctx.config_home), "drawer dry run creates no configuration");
    fs::remove_all(root);
    if (!failures) std::cout << "drawer deployment: OK\n";
    return failures ? 1 : 0;
}
