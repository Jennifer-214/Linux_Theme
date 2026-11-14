// Where the kernel command line lives: loader.conf's default entry (archinstall's <date>_linux.conf), arch.conf,
// then the first entry; never a recovery copy; GRUB only when there is no systemd-boot; and a /boot that cannot be
// read is "unreadable", never "GRUB".
#include "../modules/boot_files.hpp"

#include <cstdio>
#include <fstream>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace desk_install::boot_files;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}
static void write(const fs::path& p, const std::string& text) {
    fs::create_directories(p.parent_path());
    std::ofstream(p) << text;
}

int main() {
    char pattern[] = "/tmp/boot-files-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path root(pattern), boot = root / "boot", grub = root / "etc/default/grub";
    write(grub, "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n");

    expect(cmdline(boot, grub).loader == Loader::Grub, "no systemd-boot: GRUB");
    fs::remove(grub);
    expect(cmdline(boot, grub).loader == Loader::None, "neither: nothing");
    write(grub, "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n");

    const auto entries = boot / "loader/entries";
    fs::create_directories(entries);
    auto empty = cmdline(boot, grub);
    expect(empty.loader == Loader::None, "systemd-boot with no entry is still not GRUB");

    write(entries / "2026-01-02_10-00-00_linux.conf", "options root=/dev/x rw\n");
    write(entries / "2026-01-02_10-00-00_linux-fallback.conf", "options root=/dev/x rw\n");
    write(entries / "2026-01-02_10-00-00_linux-recovery.conf", "options root=/dev/x rw\n");
    auto first = cmdline(boot, grub);
    expect(first.loader == Loader::SystemdBoot && first.file.filename() == "2026-01-02_10-00-00_linux-fallback.conf",
           "no default: the first entry by name, not a recovery copy");
    write(boot / "loader/loader.conf", "timeout 3\ndefault 2026-01-02_10-00-00_linux.conf\n");
    expect(cmdline(boot, grub).file.filename() == "2026-01-02_10-00-00_linux.conf", "loader.conf's default wins");
    write(boot / "loader/loader.conf", "default 2026-01-02_10-00-00_linux\n");
    expect(cmdline(boot, grub).file.filename() == "2026-01-02_10-00-00_linux.conf", "a default without .conf");
    write(boot / "loader/loader.conf", "default @saved\n");
    write(entries / "arch.conf", "options root=/dev/x rw\n");
    expect(cmdline(boot, grub).file.filename() == "arch.conf", "@saved is not followed; arch.conf next");

    if (::geteuid() != 0) {   // root reads anything: the unreadable case needs an ordinary user
        fs::permissions(boot / "loader", fs::perms::none);
        const auto locked = cmdline(boot, grub);
        expect(locked.loader == Loader::Unreadable && !locked.why.empty(), "an unreadable /boot is unreadable, not GRUB");
        std::string why;
        expect(default_entry(boot, why).empty() && !why.empty(), "default_entry says why instead of throwing");
        fs::permissions(boot / "loader", fs::perms::owner_all);
    }
    fs::remove_all(root);

    if (failures == 0) std::printf("test_boot_files: ok\n");
    return failures == 0 ? 0 : 1;
}
