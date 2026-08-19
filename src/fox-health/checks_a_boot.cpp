// checks_a_boot.cpp — A-category checks (boot path won't reach login).
//
// Each check is a free function returning a CheckResult. They take no
// arguments so they're trivial to register and to invoke from a per-
// transaction context that may not have any other state available.
//
// Reading layer:
//   - /lib/modules/<uname>/modules.dep — running kernel's module tree
//   - pacman -Qkk linux linux-lts — installed-vs-package file integrity
//   - /boot/vmlinuz-* — what the bootloader would load
//   - /boot/efi/vmlinuz-* OR /efi/vmlinuz-* — what the firmware loads
//   - /boot/loader/entries/*.conf — systemd-boot entry kernel args

#include "checks.hpp"

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_health::checks {

namespace {

// Capture a command's stdout into `out`. Returns true on exit code 0.
// Self-contained so the health library doesn't pull in fox-common —
// the per-transaction pacman hook wants a tiny static binary.
bool run_capture(const std::vector<std::string>& argv, std::string& out) {
    out.clear();
    int pipefd[2];
    if (::pipe(pipefd) != 0) return false;
    pid_t pid = ::fork();
    if (pid < 0) {
        ::close(pipefd[0]); ::close(pipefd[1]);
        return false;
    }
    if (pid == 0) {
        ::dup2(pipefd[1], STDOUT_FILENO);
        ::close(pipefd[0]); ::close(pipefd[1]);
        // Send stderr to /dev/null — health checks don't want command
        // chatter polluting their own output.
        int dn = ::open("/dev/null", O_WRONLY);
        if (dn >= 0) { ::dup2(dn, STDERR_FILENO); ::close(dn); }
        std::vector<char*> c_argv;
        c_argv.reserve(argv.size() + 1);
        for (auto& s : argv) c_argv.push_back(const_cast<char*>(s.c_str()));
        c_argv.push_back(nullptr);
        ::execvp(c_argv[0], c_argv.data());
        ::_exit(127);
    }
    ::close(pipefd[1]);
    char buf[4096];
    for (;;) {
        ssize_t n = ::read(pipefd[0], buf, sizeof(buf));
        if (n <= 0) break;
        out.append(buf, buf + n);
    }
    ::close(pipefd[0]);
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

CheckResult pass(const char* id, const char* detail = nullptr) {
    CheckResult r;
    r.id     = id;
    r.status = Status::Pass;
    if (detail) r.detail = detail;
    return r;
}

CheckResult fail(const char* id, std::string detail, std::string fix = {}) {
    CheckResult r;
    r.id       = id;
    r.status   = Status::Fail;
    r.detail   = std::move(detail);
    r.fix_hint = std::move(fix);
    return r;
}

CheckResult skip(const char* id, std::string detail) {
    CheckResult r;
    r.id     = id;
    r.status = Status::Skip;
    r.detail = std::move(detail);
    return r;
}

std::string uname_release() {
    struct utsname u;
    if (::uname(&u) != 0) return {};
    return u.release;
}

// Find the ESP path the same way boot_sync's helper does. Empty
// string when there's no separate ESP mount (merged /boot=ESP layout).
fs::path detect_esp_path() {
    std::string out;
    if (run_capture({"bootctl", "--print-esp-path"}, out)) {
        while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
        if (!out.empty()) return out;
    }
    // Fallback candidates.
    for (const char* cand : { "/efi", "/boot/efi" }) {
        // Is it actually a mountpoint? Cheap test: stat parent vs child.
        if (!fs::is_directory(cand)) continue;
        std::error_code ec;
        auto a = fs::space("/boot", ec);
        auto b = fs::space(cand, ec);
        if (ec) continue;
        if (a.capacity != b.capacity) return cand;
    }
    return {};
}

}  // namespace

// A1 — `/lib/modules/$(uname -r)/modules.dep` exists. The running
// kernel's module tree being gone has two distinct causes that need
// different fixes:
//   (a) Stale running kernel: pacman upgraded `linux`, the upgrade
//       swept /lib/modules/<old>/ as part of the transaction, the
//       system is still booted on the old kernel until next reboot.
//       Detected by: at least one OTHER /lib/modules/<X>/modules.dep
//       exists. Fix: reboot.
//   (b) Genuine partial upgrade: the kernel package install was
//       interrupted; no module tree landed for any kernel.
//       Fix: reinstall + mkinitcpio -P.
CheckResult a1_kernel_modules_dep() {
    std::string kver = uname_release();
    if (kver.empty()) {
        return skip("A1", "uname() failed — can't determine running kernel version");
    }
    fs::path dep = fs::path("/lib/modules") / kver / "modules.dep";
    if (fs::exists(dep)) return pass("A1");

    // Distinguish stale-running vs. genuine partial-upgrade by looking
    // for ANY other module tree that does have its modules.dep.
    bool other_tree_present = false;
    std::string other_kver;
    std::error_code ec;
    if (fs::is_directory("/lib/modules", ec)) {
        for (const auto& e : fs::directory_iterator("/lib/modules", ec)) {
            if (!e.is_directory()) continue;
            if (e.path().filename().string() == kver) continue;
            if (fs::exists(e.path() / "modules.dep")) {
                other_tree_present = true;
                other_kver = e.path().filename().string();
                break;
            }
        }
    }
    if (other_tree_present) {
        return fail("A1",
            "running kernel " + kver + " is missing its module tree (" + dep.string() +
            " absent); installed kernel `" + other_kver + "` has a valid module tree, "
            "so this is the stale-running-kernel case (pacman upgraded `linux` mid-session)",
            "reboot — the bootloader will pick up the installed kernel and its modules");
    }
    return fail("A1",
        "running kernel " + kver + " is missing its module tree (" + dep.string() +
        " absent), and no other installed kernel has a module tree either — "
        "this is a genuine partial-upgrade state",
        "sudo pacman -S linux && sudo mkinitcpio -P");
}

// A2 — `pacman -Qkk linux linux-lts` reports zero missing files.
// Catches the case where a kernel package install was interrupted
// AFTER the db update but BEFORE all files landed. Slow (~1s) because
// pacman stats every owned file.
CheckResult a2_pacman_qkk_linux() {
    std::string out;
    // -Qkk does a stricter check than -Qk (mode + size + mtime + sha256).
    // Pacman reports each package's "N total files, M altered files".
    // A non-zero altered count for either linux or linux-lts indicates
    // corruption. Combined exit code is 0 if everything matches.
    bool ok = run_capture({"pacman", "-Qkk", "linux", "linux-lts"}, out);
    if (out.empty()) {
        // pacman might not be installed (test env, container).
        return skip("A2", "pacman not available");
    }
    // Even when at least one of {linux, linux-lts} isn't installed,
    // pacman writes "error: package 'linux-lts' was not found" to
    // stderr and continues with what IS installed. We only fail when
    // a present package reports altered files.
    std::regex altered_line(R"(([a-z0-9-]+):\s+\d+\s+total files,\s+(\d+)\s+altered files)");
    std::smatch m;
    std::string cursor = out;
    bool any_present = false;
    while (std::regex_search(cursor, m, altered_line)) {
        any_present = true;
        int altered = std::stoi(m[2]);
        if (altered > 0) {
            return fail("A2",
                "package " + std::string(m[1]) + " reports " +
                std::to_string(altered) + " altered file(s) vs. its installed copy",
                "sudo pacman -S " + std::string(m[1]));
        }
        cursor = m.suffix();
    }
    if (!any_present) {
        // Neither linux nor linux-lts installed — exotic but possible
        // (some users boot a custom kernel). Skip rather than fail.
        return skip("A2", "no linux/linux-lts packages installed");
    }
    (void)ok;
    return pass("A2");
}

// A3 — the running kernel is a currently-INSTALLED package's kernel, i.e. you
// haven't upgraded the kernel without rebooting (which jumps versions and leaves
// the running kernel's module tree swept). Resolved by OWNERSHIP, not a version
// string: `pacman -Qo /usr/lib/modules/<uname>/pkgbase` succeeds iff the running
// kernel's exact module tree still belongs to an installed package. This is
// correct for linux / linux-lts / linux-zen alike. The old check compared uname
// against a string-munged `pacman -Q linux` (MAINLINE only), so every lts/zen-
// booted box that also had mainline installed false-failed → preflight aborted a
// healthy system. (String-munging can't win it anyway: lts pkgver "6.18.36-1"
// never carries the "-lts" that uname "6.18.36-1-lts" does.)

// Pure verdict from the two facts the check gathers; exposed for unit tests.
//   owned       = pacman owns /usr/lib/modules/<uname>/pkgbase
//   tree_exists = /usr/lib/modules/<uname>/ is present at all
Status a3_verdict(bool owned, bool tree_exists) {
    if (owned)       return Status::Pass;   // running kernel == an installed package's kernel
    if (tree_exists) return Status::Skip;   // present but unowned → custom / non-pacman kernel
    return Status::Fail;                     // tree swept → stale running kernel (reboot pending)
}

CheckResult a3_vmlinuz_matches_kver() {
    std::string running = uname_release();
    if (running.empty()) return skip("A3", "uname() failed");

    fs::path moddir       = fs::path("/usr/lib/modules") / running;
    fs::path pkgbase_file = moddir / "pkgbase";

    std::error_code ec;
    bool tree_exists = fs::is_directory(moddir, ec);
    std::string out;
    bool owned = fs::exists(pkgbase_file, ec) &&
                 run_capture({"pacman", "-Qo", pkgbase_file.string()}, out);

    switch (a3_verdict(owned, tree_exists)) {
        case Status::Pass: return pass("A3");
        case Status::Skip:
            return skip("A3", "running kernel " + running +
                        " is not pacman-managed (custom kernel) — kernel-currency check skipped");
        default:
            return fail("A3",
                "running kernel " + running + " has no module tree under /usr/lib/modules "
                "(a kernel upgrade swept it) — the next reboot will jump kernels",
                "reboot into the installed kernel");
    }
}

// A4 — when /boot is a separate filesystem from the ESP, the kernel
// + initramfs files on each side must byte-match. Drift here is what
// originally caused the retrospective incident: pacman wrote the new
// kernel to /boot, the firmware kept loading the old one from the
// ESP, the running kernel's modules got swept out, /boot wouldn't
// remount on the next boot.
CheckResult a4_esp_matches_boot() {
    fs::path boot = "/boot";
    fs::path esp  = detect_esp_path();
    if (esp.empty()) {
        return skip("A4", "no separate ESP detected (merged /boot=ESP layout)");
    }
    // Compare vmlinuz-* + initramfs-*.img + *-ucode.img across both
    // directories. We hash via std::hash<string-of-bytes>... no, we
    // just byte-compare with read+memcmp. cheap for these file sizes.
    static const std::array<const char*, 4> globs = {
        "vmlinuz-", "initramfs-", "intel-ucode.img", "amd-ucode.img"
    };
    std::vector<std::string> mismatches;
    for (auto& entry : fs::directory_iterator(boot)) {
        if (!entry.is_regular_file()) continue;
        std::string name = entry.path().filename().string();
        bool matched_pattern = false;
        for (auto* g : globs) {
            if (name.rfind(g, 0) == 0) { matched_pattern = true; break; }
        }
        if (!matched_pattern) continue;
        fs::path esp_copy = esp / name;
        if (!fs::exists(esp_copy)) {
            mismatches.push_back(name + " missing on ESP");
            continue;
        }
        std::error_code ec1, ec2;
        auto sa = fs::file_size(entry.path(), ec1);
        auto sb = fs::file_size(esp_copy,    ec2);
        if (ec1 || ec2 || sa != sb) {
            mismatches.push_back(name + " size mismatch");
            continue;
        }
        // Full byte compare. Cap at 64 MiB for safety; real kernels
        // are 10-25 MiB.
        std::ifstream fa(entry.path(), std::ios::binary);
        std::ifstream fb(esp_copy,    std::ios::binary);
        constexpr size_t CHUNK = 64 * 1024;
        std::vector<char> ba(CHUNK), bb(CHUNK);
        bool eq = true;
        while (fa && fb) {
            fa.read(ba.data(), CHUNK);
            fb.read(bb.data(), CHUNK);
            std::streamsize na = fa.gcount(), nb = fb.gcount();
            if (na != nb || std::memcmp(ba.data(), bb.data(),
                                        static_cast<size_t>(na)) != 0) {
                eq = false; break;
            }
        }
        if (!eq) mismatches.push_back(name + " bytes differ");
    }
    if (!mismatches.empty()) {
        std::string detail = "drift between /boot and " + esp.string() + ":\n";
        for (auto& m : mismatches) detail += "  - " + m + "\n";
        return fail("A4", std::move(detail),
            "sudo /usr/local/lib/foxml/esp-sync   # (re-runs boot_sync's helper)");
    }
    return pass("A4");
}

// A7 — systemd-boot `/boot/loader/entries/arch.conf` has exactly one
// `options` line, with no kernel-arg substring duplicated. This is
// the exact corruption pattern that bit the retrospective: a faulty
// iommu module re-ran on every --full and prepended the same args N
// times.
CheckResult a7_arch_conf_no_dupes() {
    fs::path entries = "/boot/loader/entries";
    if (!fs::is_directory(entries)) {
        return skip("A7", "no systemd-boot loader entries (GRUB or other bootloader)");
    }
    std::vector<std::string> problems;
    for (auto& e : fs::directory_iterator(entries)) {
        if (e.path().extension() != ".conf") continue;
        std::ifstream f(e.path());
        std::string line;
        int options_count = 0;
        std::string options_line;
        while (std::getline(f, line)) {
            if (line.rfind("options", 0) == 0) {
                ++options_count;
                options_line = line;
            }
        }
        std::string base = e.path().filename().string();
        if (options_count == 0) {
            problems.push_back(base + ": no `options` line");
            continue;
        }
        if (options_count > 1) {
            problems.push_back(base + ": " + std::to_string(options_count) +
                               " `options` lines (must be exactly one)");
            continue;
        }
        // Single options line — scan for duplicated tokens.
        std::istringstream is(options_line);
        std::vector<std::string> seen;
        std::string tok;
        bool first = true;
        while (is >> tok) {
            if (first) { first = false; continue; }  // skip "options" itself
            // A duplicate KEY (e.g. intel_iommu) typically means a
            // corrupt prepend. Compare just the part before '='.
            std::string key = tok;
            auto eq = key.find('=');
            if (eq != std::string::npos) key.resize(eq);
            for (auto& prev : seen) {
                if (prev == key) {
                    problems.push_back(base + ": duplicated kernel arg `" + key + "`");
                    goto next_entry;
                }
            }
            seen.push_back(key);
        }
      next_entry:;
    }
    if (!problems.empty()) {
        std::string detail;
        for (auto& p : problems) detail += p + "\n";
        return fail("A7", std::move(detail),
            "edit the affected file under /boot/loader/entries/ and dedupe its `options` line");
    }
    return pass("A7");
}

}  // namespace fox_health::checks
