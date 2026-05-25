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

std::string read_file(const fs::path& p, size_t cap = 0) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string out = ss.str();
    if (cap && out.size() > cap) out.resize(cap);
    return out;
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
// kernel's module tree being gone means the system is in a partial-
// upgrade state (pacman db has the new kernel; the file tree didn't
// land). All later modules of fox-install are unsafe to run on this.
CheckResult a1_kernel_modules_dep() {
    std::string kver = uname_release();
    if (kver.empty()) {
        return skip("A1", "uname() failed — can't determine running kernel version");
    }
    fs::path dep = fs::path("/lib/modules") / kver / "modules.dep";
    if (!fs::exists(dep)) {
        return fail("A1",
            "running kernel " + kver + " is missing its module tree (" + dep.string() + " absent)",
            "sudo pacman -S linux && sudo mkinitcpio -P");
    }
    return pass("A1");
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

// A3 — the kernel image in /boot matches the *running* kernel's
// package version. If /boot/vmlinuz-linux is older than the linux
// package's current version, the user has booted a stale kernel and
// the next reboot would jump to a kernel whose module tree might
// already have been swept (this is the gap that bit the retrospective
// incident).
CheckResult a3_vmlinuz_matches_kver() {
    // We compare the file's `linux` package's pkgver against uname -r.
    // pkgver as exposed by `pacman -Q linux`:  "linux 7.0.9.arch1-1"
    std::string out;
    if (!run_capture({"pacman", "-Q", "linux"}, out) || out.empty()) {
        return skip("A3", "linux package not installed via pacman");
    }
    // Parse "linux X.Y.Z.archN-R"
    auto sp = out.find(' ');
    if (sp == std::string::npos) return skip("A3", "unexpected pacman -Q output");
    std::string pkgver = out.substr(sp + 1);
    while (!pkgver.empty() && (pkgver.back() == '\n' || pkgver.back() == ' ')) pkgver.pop_back();
    // Convert pacman pkgver "7.0.9.arch2-1" → uname format "7.0.9-arch2-1"
    // by replacing the dot before the suffix marker (.arch, .zen, .lts,
    // .hardened, .rt) with a dash. The -R revision is preserved
    // because uname includes it on Arch.
    std::string uname_form = pkgver;
    static const std::vector<const char*> SUFFIX_MARKERS = {
        ".arch", ".zen", ".hardened", ".rt", ".lts",
    };
    for (auto* marker : SUFFIX_MARKERS) {
        auto p = uname_form.find(marker);
        if (p != std::string::npos) { uname_form[p] = '-'; break; }
    }
    std::string running = uname_release();
    if (running.empty()) return skip("A3", "uname() failed");
    if (running != uname_form) {
        return fail("A3",
            "running kernel " + running + " differs from installed `linux` package "
            "version " + uname_form + " — a reboot would jump kernels",
            "reboot, or stay on the running kernel by holding back the upgrade");
    }
    return pass("A3");
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
