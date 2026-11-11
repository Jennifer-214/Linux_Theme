#include "../modules/notification_refresh.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace fs = std::filesystem;
int main() {
    std::string pattern = (fs::temp_directory_path() / "fox-notification-refresh-XXXXXX").string();
    if (!::mkdtemp(pattern.data())) return 1;
    const fs::path root(pattern), installed = root / "installed", running = root / "running";
    fs::create_directories(root / "proc/42");
    fs::create_symlink(running, root / "proc/42/exe");
    std::ofstream(installed) << "same executable";
    std::ofstream(running) << "same executable";
    bool ok = !fox_install::notifications::running_binary_changed(installed, "42\n", root / "proc");
    std::ofstream(installed) << "new renderer";
    ok &= fox_install::notifications::running_binary_changed(installed, "42\n", root / "proc");
    ok &= !fox_install::notifications::running_binary_changed(installed, "99\n../../etc\n", root / "proc");
    fs::remove(installed);
    ok &= fox_install::notifications::running_binary_changed(installed, "42\n", root / "proc");
    fs::remove_all(root);
    std::cout << (ok ? "notification binary refresh: OK\n" : "notification binary refresh: FAILED\n");
    return ok ? 0 : 1;
}
