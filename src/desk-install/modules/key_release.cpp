// modules/key_release.cpp — on a ThinkPad, Fn+S (SysRq, the Print key) always sends its release (key_release.hpp).

#include "key_release.hpp"

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

namespace desk_install {

namespace {

std::string read_all(const fs::path& path) {
    std::ifstream in(path);
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

// The force_release attribute of the built-in keyboard's port (i8042 KBD port), or "" without one.
std::string keyboard_force_release() {
    std::error_code ec;
    for (const auto& port : fs::directory_iterator("/sys/bus/serio/devices", ec)) {
        if (read_all(port.path() / "description").rfind("i8042 KBD port", 0) == 0)
            return read_all(port.path() / "force_release");
    }
    return "";
}

}  // namespace

void run_key_release(Context& ctx) {
    ui::section("ThinkPad Fn+S always lets go");
    if (!key_release::is_thinkpad(read_all("/sys/class/dmi/id/sys_vendor"), read_all("/sys/class/dmi/id/product_version"))) {
        ui::skipped("not a ThinkPad — nothing to do");
        return;
    }
    const fs::path src = ctx.shared_dir / "udev" / key_release::RULE;
    const fs::path dest = fs::path(key_release::RULE_DIR) / key_release::RULE;
    const std::string body = read_all(src);
    if (body.empty()) {
        ui::warn("missing " + src.string());
        return;
    }
    std::error_code ec;
    if (!ctx.force_reapply && fs::exists(dest, ec) && read_all(dest) == body &&
        key_release::releases(keyboard_force_release(), key_release::SYSRQ_SCAN)) {
        ui::skipped("Fn+S already lets go");
        return;
    }
    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    if (!sh::write_root_atomic(dest, body)) {
        ui::warn("could not write " + dest.string());
        return;
    }
    if (sh::run({"sudo", "systemd-hwdb", "update", "--strict"}) != 0) {
        // A rule the database refuses goes back out, so the next update is clean.
        sh::run({"sudo", "rm", "-f", dest.string()});
        sh::run({"sudo", "systemd-hwdb", "update"});
        ui::warn("systemd-hwdb refused " + dest.string() + "; removed it again");
        return;
    }
    sh::run({"sudo", "udevadm", "trigger", "--action=change", "--subsystem-match=input"});
    sh::run({"sudo", "udevadm", "settle", "--timeout=10"});
    if (sh::dry_run()) return;
    if (key_release::releases(keyboard_force_release(), key_release::SYSRQ_SCAN))
        ui::ok("Fn+S (SysRq) now sends its release with every press");
    else
        ui::warn(dest.string() + " installed; the keyboard picks it up at the next boot");
}

}  // namespace desk_install
