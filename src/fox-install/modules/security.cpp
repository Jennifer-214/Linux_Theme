// modules/security.cpp — native port of install_security sub-functions.
//
// Bash equivalents (now retired here):
//   mappings.sh:install_kernel_hardening
//   mappings.sh:install_usbguard
//   mappings.sh:install_apparmor       (+ _apparmor_systemd_boot, _apparmor_grub)
//   mappings.sh:install_polkit_strict
//   mappings.sh:install_security       (fail2ban + auditd + waybar-sudo inline)
//
// install_ufw_baseline lives in modules/ufw.cpp now (default-on, runs
// regardless of --secure — bash ran it unconditionally too).
// SSH-hardening wizard is its own module (--ssh-harden).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

std::string strip(std::string s) {
    auto a = s.find_first_not_of(" \t\r\n");
    auto b = s.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    return s.substr(a, b - a + 1);
}

std::string username() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    if (const char* u = std::getenv("LOGNAME"); u && *u) return u;
    return "user";
}

// Conservative Linux username check (adduser's NAME_REGEX shape). Used
// to refuse interpolating a junk/empty/meta-bearing name into a sudoers
// line, where a malformed entry poisons the entire sudoers parse.
bool valid_username(const std::string& u) {
    static const std::regex pat(R"(^[a-z_][a-z0-9_-]*$)");
    return !u.empty() && u.size() <= 32 && std::regex_match(u, pat);
}

bool pacman_has(const std::string& pkg) {
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) == 0;
}

bool systemctl_active(const std::string& unit) {
    return sh::run({"systemctl", "is-active", "--quiet", unit}) == 0;
}

bool systemctl_enabled(const std::string& unit) {
    return sh::run({"systemctl", "is-enabled", "--quiet", unit}) == 0;
}

// Writes `body` to `path` as root, via a tmp file + `sudo install`. The
// caller specifies the final mode (e.g. 0644) and owner; the helper does
// chown root:root automatically. Returns false on any step's failure.
bool write_root_file(const fs::path& path, const std::string& body,
                     const std::string& mode = "0644") {
    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + path.string() + " (mode " + mode + ")");
        return true;
    }
    char tmpl[] = "/tmp/foxin.XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) return false;
    {
        std::ofstream w(tmpl);
        w << body;
    }
    ::close(fd);
    // ensure target dir exists (some hardening files live in fresh dirs).
    sh::run({"sudo", "install", "-d", path.parent_path().string()});
    int rc = sh::run({"sudo", "install", "-m", mode,
                      "-o", "root", "-g", "root", tmpl, path.string()});
    fs::remove(tmpl);
    return rc == 0;
}

// Read a file as the calling user (most /etc files are world-readable).
std::string read_file(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// prompt_yn deleted — use ui::ask_yn(msg, default, ctx.assume_yes) at
// callsites. ui::ask_yn reads a single char without Enter and guards
// against stray keypresses.

// (install_ufw_baseline moved to modules/ufw.cpp — runs as the --ufw
// module unconditionally before --secure dispatches.)
#if 0
void install_ufw_baseline(const Context& ctx) {
    if (!have("ufw")) {
        ui::warn("ufw not installed, skipping firewall baseline");
        return;
    }

    std::string status_out;
    sh::capture({"sudo", "ufw", "status"}, status_out);
    bool active = status_out.find("Status: active") != std::string::npos;

    if (active) {
        ui::ok("UFW active — re-applying baseline (preserves existing rules)");
    } else {
        ui::substep("applying UFW baseline (deny incoming, allow outgoing)");
        sh::run({"sh", "-c", "sudo ufw --force reset >/dev/null 2>&1 || true"});
    }
    sh::run({"sudo", "ufw", "default", "deny",  "incoming"});
    sh::run({"sudo", "ufw", "default", "allow", "outgoing"});

    if (systemctl_enabled("sshd") || systemctl_active("sshd")) {
        sh::run({"sudo", "ufw", "limit", "ssh"});
        ui::ok("sshd detected — port 22 allowed with rate-limit (limit ssh)");
    }

    // Interactive port allowlist (skipped silently in --yes / no-TTY).
    if (tty_in() && !ctx.assume_yes) {
        std::cout << "\n  Open additional ports? (e.g. 8080 3000/tcp 51820/udp)\n"
                     "  Press Enter to skip, or list ports separated by spaces:\n"
                     "  ports> " << std::flush;
        std::string line;
        std::getline(std::cin, line);
        std::istringstream is(line);
        std::string tok;
        while (is >> tok) {
            // Trim trailing commas.
            while (!tok.empty() && tok.back() == ',') tok.pop_back();
            if (tok.empty()) continue;
            std::string num   = tok;
            std::string proto;
            auto slash = tok.find('/');
            if (slash != std::string::npos) {
                num   = tok.substr(0, slash);
                proto = tok.substr(slash + 1);
                if (proto != "tcp" && proto != "udp") {
                    ui::warn("skipping '" + tok + "' — proto must be tcp or udp");
                    continue;
                }
            }
            try {
                int n = std::stoi(num);
                if (n < 1 || n > 65535) throw std::runtime_error("range");
            } catch (...) {
                ui::warn("skipping '" + tok + "' — not a valid port");
                continue;
            }
            if (!proto.empty()) {
                sh::run({"sudo", "ufw", "allow", num + "/" + proto});
                ui::ok("allowed " + num + "/" + proto);
            } else {
                sh::run({"sudo", "ufw", "allow", num});
                ui::ok("allowed " + num);
            }
        }
    }

    // SSH lockout safety — preserve the current SSH connection's port.
    if (const char* conn = std::getenv("SSH_CONNECTION"); conn && *conn) {
        std::istringstream is(conn);
        std::string client_ip, client_port, server_ip, server_port;
        is >> client_ip >> client_port >> server_ip >> server_port;
        try {
            int p = std::stoi(server_port);
            if (p > 0 && p < 65536) {
                sh::run({"sh", "-c",
                         "sudo ufw limit " + server_port + "/tcp >/dev/null 2>&1 || true"});
                ui::ok("active SSH session on port " + server_port + " — rate-limited to avoid lockout");
            }
        } catch (...) {}
    }

    sh::run({"sh", "-c", "sudo ufw logging low >/dev/null 2>&1 || true"});
    sh::run({"sh", "-c", "echo y | sudo ufw enable >/dev/null"});
    if (sh::systemctl_enable("ufw", /*user=*/false) == 0) {
        ui::ok("UFW enabled (deny incoming + low logging)");
    } else {
        ui::warn("ufw enable failed — re-run with: sudo -v && fox install --full");
    }
}
#endif  // install_ufw_baseline moved to modules/ufw.cpp

// ════════════════════════════════════════════════════════════════════
// install_kernel_hardening — sysctl drop-in
// ════════════════════════════════════════════════════════════════════
constexpr const char* KERNEL_HARDENING_BODY =
    "# FoxML kernel hardening — auto-applied by fox-install --secure.\n"
    "# Reversible: `sudo rm /etc/sysctl.d/99-foxml-hardening.conf && sudo sysctl --system`.\n"
    "kernel.kptr_restrict             = 2\n"
    "kernel.dmesg_restrict            = 1\n"
    "kernel.unprivileged_bpf_disabled = 1\n"
    "kernel.yama.ptrace_scope         = 1\n"
    "net.ipv4.tcp_syncookies          = 1\n"
    "net.ipv4.tcp_rfc1337             = 1\n"
    "net.ipv4.icmp_echo_ignore_broadcasts = 1\n"
    "net.ipv4.icmp_ignore_bogus_error_responses = 1\n"
    "net.ipv4.conf.all.rp_filter      = 1\n"
    "net.ipv4.conf.default.rp_filter  = 1\n"
    "net.ipv4.conf.all.log_martians   = 1\n"
    "net.ipv4.conf.default.log_martians = 1\n"
    "net.ipv4.conf.all.accept_redirects     = 0\n"
    "net.ipv4.conf.default.accept_redirects = 0\n"
    "net.ipv4.conf.all.secure_redirects     = 0\n"
    "net.ipv4.conf.default.secure_redirects = 0\n"
    "net.ipv4.conf.all.send_redirects       = 0\n"
    "net.ipv4.conf.default.send_redirects   = 0\n"
    "net.ipv4.conf.all.accept_source_route     = 0\n"
    "net.ipv4.conf.default.accept_source_route = 0\n"
    "net.ipv6.conf.all.accept_redirects     = 0\n"
    "net.ipv6.conf.default.accept_redirects = 0\n"
    "net.ipv6.conf.all.accept_source_route     = 0\n"
    "net.ipv6.conf.default.accept_source_route = 0\n"
    "net.core.bpf_jit_harden = 2\n"
    "fs.suid_dumpable                 = 0\n"
    "kernel.perf_event_paranoid       = 3\n"
    "kernel.kexec_load_disabled       = 1\n"
    "net.ipv4.ip_forward              = 0\n"
    "net.ipv6.conf.all.forwarding     = 0\n"
    "net.ipv6.conf.default.forwarding = 0\n"
    "net.ipv6.conf.all.accept_ra      = 0\n"
    "net.ipv6.conf.default.accept_ra  = 0\n"
    "net.ipv4.tcp_timestamps          = 0\n"
    "vm.unprivileged_userfaultfd      = 0\n"
    "dev.tty.ldisc_autoload           = 0\n"
    "fs.protected_hardlinks           = 1\n"
    "fs.protected_symlinks            = 1\n"
    "fs.protected_fifos               = 2\n"
    "fs.protected_regular             = 2\n"
    "net.ipv4.ip_default_ttl          = 128\n"
    "net.ipv4.tcp_invalid_ratelimit   = 500\n"
    "kernel.sysrq                     = 4\n"
    "net.ipv4.conf.all.arp_ignore     = 1\n"
    "net.ipv4.conf.default.arp_ignore = 1\n"
    "net.ipv4.conf.all.arp_announce   = 2\n"
    "net.ipv4.conf.default.arp_announce = 2\n";

void install_kernel_hardening(const Context& ctx) {
    fs::path conf = "/etc/sysctl.d/99-foxml-hardening.conf";
    if (read_file(conf) == KERNEL_HARDENING_BODY && !ctx.force_reapply) {
        ui::skipped("kernel hardening sysctls already in place");
        return;
    }
    ui::substep("writing kernel hardening sysctls to " + conf.string());
    if (!write_root_file(conf, KERNEL_HARDENING_BODY, "0644")) {
        ui::warn("could not write " + conf.string());
        return;
    }
    if (sh::run({"sudo", "sysctl", "--system"}) == 0) {
        ui::ok("sysctl --system applied");
    } else {
        ui::warn("sysctl --system reported errors — review with `sudo sysctl --system`");
    }
}

// ════════════════════════════════════════════════════════════════════
// install_usbguard — generate-policy from connected devices + enable
// ════════════════════════════════════════════════════════════════════
void install_usbguard(const Context& ctx) {
    (void)ctx;
    if (!have("usbguard")) { ui::warn("usbguard not installed, skipping"); return; }

    fs::path rules = "/etc/usbguard/rules.conf";
    std::error_code ec;
    auto sz = fs::file_size(rules, ec);
    if (ec || sz == 0) {
        ui::substep("devices currently connected (these will be trusted):");
        if (have("lsusb")) {
            std::string out;
            sh::capture({"lsusb"}, out);
            std::istringstream is(out);
            std::string line;
            while (std::getline(is, line)) std::cout << "    " << line << "\n";
        } else {
            sh::run({"sh", "-c", "sudo usbguard list-devices 2>/dev/null | sed 's/^/    /'"});
        }
        if (!ui::ask_yn("Whitelist all of these as trusted devices?", false, ctx.assume_yes)) {
            ui::warn("USBGuard install aborted — unplug suspicious devices and re-run --secure");
            return;
        }
        ui::substep("generating initial USBGuard policy from connected devices");
        sh::run({"sh", "-c",
                 "sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf >/dev/null"});
        std::string wc_out;
        sh::capture({"sh", "-c", "sudo wc -l /etc/usbguard/rules.conf 2>/dev/null"}, wc_out);
        std::string count = strip(wc_out);
        if (auto sp = count.find(' '); sp != std::string::npos) count = count.substr(0, sp);
        sh::run({"sudo", "chmod", "600", rules.string()});
        sh::run({"sudo", "chown", "root:root", rules.string()});
        ui::ok("→ " + rules.string() + " (" + (count.empty() ? "?" : count) + " device rules)");
    } else {
        ui::skipped("USBGuard rules already present at " + rules.string());
    }

    // Grant current user IPC access so usbguard list-devices works without sudo.
    fs::path conf = "/etc/usbguard/usbguard-daemon.conf";
    std::string body = read_file(conf);
    std::string user = username();
    if (!body.empty() && body.find("IPCAllowedUsers=") != std::string::npos &&
        body.find(user) == std::string::npos) {
        sh::run({"sudo", "sed", "-i", "-E",
                 "s|^#?IPCAllowedUsers=.*|IPCAllowedUsers=root " + user + "|",
                 conf.string()});
        ui::ok("IPC access granted to user " + user);
    }

    if (!systemctl_active("usbguard")) {
        if (sh::systemctl_enable("usbguard", /*user=*/false) == 0) {
            ui::ok("usbguard service enabled");
        }
    } else {
        sh::run({"sh", "-c", "sudo systemctl reload usbguard >/dev/null 2>&1 || true"});
        ui::skipped("usbguard already active (reloaded)");
    }
}

// ════════════════════════════════════════════════════════════════════
// install_apparmor — bootloader cmdline edit + service enable
// ════════════════════════════════════════════════════════════════════
namespace {

void apparmor_systemd_boot() {
    fs::path entries_dir = "/boot/loader/entries";
    if (!fs::is_directory(entries_dir)) return;
    int modified = 0;
    for (auto& e : fs::directory_iterator(entries_dir)) {
        if (!e.is_regular_file()) continue;
        if (e.path().extension() != ".conf") continue;
        std::string body = read_file(e.path());
        // Create-if-missing backup before any in-place edit of a boot
        // entry — a botched kernel cmdline can leave the system
        // unbootable, and the recovery entry inherits these same args.
        auto backup_entry = [&] {
            sh::run({"sh", "-c",
                     "[ -e " + e.path().string() + ".foxml-bak ] || "
                     "sudo cp " + e.path().string() + " " + e.path().string() + ".foxml-bak"});
        };
        if (body.find("\nlsm=") == std::string::npos &&
            body.find(" lsm=") == std::string::npos) {
            // No lsm= yet — append the full recommendation.
            backup_entry();
            sh::run({"sudo", "sed", "-i", "-E",
                     "s|^options (.*)$|options \\1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf|",
                     e.path().string()});
            ui::ok(e.path().string() + ": apparmor added to kernel cmdline (backup: .foxml-bak)");
            ++modified;
            continue;
        }
        // Already contains an lsm= but missing apparmor?
        std::string re_check = "^options .*\\blsm=[^[:space:]]*apparmor";
        if (sh::run({"sh", "-c",
                     "grep -qE \"" + re_check + "\" " + e.path().string()}) == 0) {
            continue;
        }
        backup_entry();
        sh::run({"sudo", "sed", "-i", "-E",
                 "s|(^options .*\\blsm=)([^[:space:]]*)|\\1\\2,apparmor|",
                 e.path().string()});
        ui::ok(e.path().string() + ": apparmor added to kernel cmdline (backup: .foxml-bak)");
        ++modified;
    }
    if (modified == 0) {
        ui::skipped("all systemd-boot entries already include apparmor in lsm=");
    }
}

bool apparmor_grub() {
    fs::path defaults = "/etc/default/grub";
    if (!fs::exists(defaults)) return false;
    std::string body = read_file(defaults);
    if (body.find("lsm=") != std::string::npos &&
        body.find("apparmor") != std::string::npos) {
        ui::skipped("grub cmdline already includes apparmor");
        return true;
    }
    // Back up /etc/default/grub before editing (create-if-missing).
    sh::run({"sh", "-c",
             "[ -e /etc/default/grub.foxml-bak ] || "
             "sudo cp /etc/default/grub /etc/default/grub.foxml-bak"});
    if (body.find("lsm=") != std::string::npos) {
        sh::run({"sudo", "sed", "-i", "-E",
                 "s|(^GRUB_CMDLINE_LINUX_DEFAULT=.*\\blsm=)([^[:space:]\"]*)|\\1\\2,apparmor|",
                 defaults.string()});
    } else {
        sh::run({"sudo", "sed", "-i", "-E",
                 "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"$"
                 "|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf\"|",
                 defaults.string()});
    }
    ui::ok("grub default cmdline updated; regenerating grub.cfg");
    if (sh::run({"sh", "-c",
                 "sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1"}) == 0) {
        ui::ok("grub.cfg regenerated");
    }
    return true;
}

}  // namespace

void install_apparmor() {
    if (!pacman_has("apparmor")) {
        ui::warn("apparmor not installed (re-run with --deps --secure)");
        return;
    }

    if (fs::is_directory("/boot/loader/entries")) {
        apparmor_systemd_boot();
    } else if (apparmor_grub()) {
        // already messaged
    } else {
        ui::warn("couldn't detect bootloader (systemd-boot / grub)");
        ui::substep("manually add to kernel cmdline and regenerate: "
                    "lsm=landlock,lockdown,yama,integrity,apparmor,bpf");
    }

    if (!systemctl_enabled("apparmor")) {
        if (sh::run({"sudo", "systemctl", "enable", "apparmor.service"}) == 0) {
            ui::ok("apparmor.service enabled (loads profiles at boot)");
        }
    } else {
        ui::skipped("apparmor.service already enabled");
    }
    ui::substep("reboot to activate AppArmor; then: sudo aa-status");
    ui::substep("comprehensive profile pack: `yay -S apparmor.d` (1500+ profiles)");
}

// ════════════════════════════════════════════════════════════════════
// install_polkit_strict — re-prompt for every admin action
// ════════════════════════════════════════════════════════════════════
constexpr const char* POLKIT_STRICT_RULE =
    "// foxml-managed — require fresh password auth for every admin action.\n"
    "// Revert: sudo rm /etc/polkit-1/rules.d/99-foxml-strict.rules\n"
    "polkit.addRule(function(action, subject) {\n"
    "    if (subject.isInGroup(\"wheel\")) {\n"
    "        // Exception: switching power profiles is harmless enough to allow\n"
    "        // without a re-prompt (usually allowed for active users anyway).\n"
    "        if (action.id == \"org.freedesktop.UPower.PowerProfiles.switch-profile\") {\n"
    "            return undefined;\n"
    "        }\n"
    "        return polkit.Result.AUTH_ADMIN;\n"
    "    }\n"
    "});\n";

void install_polkit_strict() {
    fs::path rule = "/etc/polkit-1/rules.d/99-foxml-strict.rules";
    sh::run({"sudo", "install", "-d", "/etc/polkit-1/rules.d"});
    if (!write_root_file(rule, POLKIT_STRICT_RULE, "0644")) {
        ui::warn("could not write " + rule.string());
        return;
    }
    if (sh::run({"sh", "-c",
                 "sudo systemctl reload polkit 2>/dev/null || "
                 "sudo systemctl restart polkit 2>/dev/null || true"}) == 0) {
        // intentionally silent on success
    }
    ui::ok("Polkit strict mode enabled (every admin action re-prompts)");
}

// ════════════════════════════════════════════════════════════════════
// fail2ban inline — jail.local with sshd jail
// ════════════════════════════════════════════════════════════════════
// Build jail.local. ignoreip starts at localhost; when we're running
// over SSH we also whitelist the admin's own source IP, so a fumbled
// password during the install itself can't ban them out of a headless
// box (the sshd jail counts failures regardless of port).
std::string fail2ban_jail_local() {
    std::string ignore = "127.0.0.1/8 ::1";
    if (const char* sc = std::getenv("SSH_CONNECTION"); sc && *sc) {
        std::istringstream is(sc);
        std::string client_ip;
        is >> client_ip;  // SSH_CONNECTION = "<clientip> <cport> <srvip> <sport>"
        // Only accept a plain IPv4/IPv6 literal — never let arbitrary
        // text reach the config file.
        if (!client_ip.empty() &&
            client_ip.find_first_not_of("0123456789abcdefABCDEF.:") == std::string::npos) {
            ignore += " " + client_ip;
        }
    }
    static const std::string head =
        "# foxml-managed — auto-applied by fox-install --secure.\n"
        "# Delete this file to revert to the stock fail2ban defaults.\n"
        "[DEFAULT]\n"
        "bantime  = 1h\n"
        "findtime = 10m\n"
        "maxretry = 5\n"
        "backend  = systemd\n"
        "ignoreip = ";
    static const std::string tail =
        "\n\n"
        "[sshd]\n"
        "enabled  = true\n"
        "port     = ssh\n"
        "filter   = sshd\n"
        "journalmatch = _SYSTEMD_UNIT=sshd.service\n";
    return head + ignore + tail;
}

void install_fail2ban() {
    if (!pacman_has("fail2ban")) {
        ui::warn("fail2ban package not found — run with --deps --secure");
        return;
    }
    fs::path jail = "/etc/fail2ban/jail.local";
    std::string existing = read_file(jail);
    if (existing.find("# foxml-managed") == std::string::npos) {
        if (!write_root_file(jail, fail2ban_jail_local(), "0644")) {
            ui::warn("could not write " + jail.string());
            return;
        }
        ui::ok("fail2ban jail.local written (sshd jail enabled)");
    }
    if (!systemctl_active("fail2ban")) {
        if (sh::systemctl_enable("fail2ban", /*user=*/false) == 0) {
            ui::ok("fail2ban service enabled");
        } else {
            ui::warn("fail2ban enable failed (sudo cold?) — re-run after `sudo -v`");
        }
    } else {
        if (sh::run({"sh", "-c",
                     "sudo systemctl reload fail2ban >/dev/null 2>&1 || "
                     "sudo systemctl restart fail2ban >/dev/null 2>&1"}) == 0) {
            ui::skipped("fail2ban already active (reloaded for new jail.local)");
        } else {
            ui::warn("fail2ban reload failed (sudo cold?) — service still running on old config");
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// auditd inline — persistent watch rules
// ════════════════════════════════════════════════════════════════════
constexpr const char* AUDIT_RULES_BODY =
    "# foxml-managed — auto-applied by fox-install --secure.\n"
    "# Watches credential + sshd config files for modifications.\n"
    "-w /etc/passwd -p wa -k passwd_changes\n"
    "-w /etc/shadow -p wa -k shadow_changes\n"
    "-w /etc/ssh/sshd_config -p wa -k sshd_config_changes\n"
    "-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_changes\n"
    "-w /etc/sudoers -p wa -k sudoers_changes\n"
    "-w /etc/sudoers.d/ -p wa -k sudoers_changes\n";

void install_auditd() {
    if (!pacman_has("audit")) {
        ui::warn("audit package not installed — skipping persistent audit rules");
        return;
    }
    fs::path rules = "/etc/audit/rules.d/99-foxml.rules";
    std::string existing = read_file(rules);
    if (existing.find("# foxml-managed") == std::string::npos) {
        if (!write_root_file(rules, AUDIT_RULES_BODY, "0640")) {
            ui::warn("could not write " + rules.string());
            return;
        }
        sh::run({"sh", "-c", "sudo augenrules --load >/dev/null 2>&1 || true"});
        ui::ok("auditd watch rules written to " + rules.string());
    }
    if (!systemctl_active("auditd")) {
        if (sh::systemctl_enable("auditd", /*user=*/false) == 0) {
            ui::ok("auditd enabled with persistent watch rules");
        } else {
            ui::warn("auditd enable failed (sudo cold?) — re-run after `sudo -v`");
        }
    } else {
        if (sh::run({"sh", "-c", "sudo systemctl restart auditd >/dev/null 2>&1"}) == 0) {
            ui::skipped("auditd already active (restarted to load new rules)");
        } else {
            ui::skipped("auditd already active (couldn't restart — rules apply on next reboot)");
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// waybar sudoers (tight allow-list) — for the waybar overwatch module
// ════════════════════════════════════════════════════════════════════
void install_waybar_sudoers(const Context& ctx) {
    fs::path sudoers = "/etc/sudoers.d/99-foxml-waybar";
    // /etc/sudoers.d/ is mode 0750 — non-root stat() returns EACCES.
    // The error_code overload swallows the throw and returns false; we
    // then go ahead and call `sudo install` which can read the dir.
    std::error_code ec;
    if (fs::exists(sudoers, ec) && !ec && !ctx.force_reapply) {
        ui::skipped("waybar sudoers already configured");
        return;
    }
    std::string user = username();
    if (!valid_username(user)) {
        ui::warn("refusing to write waybar sudoers: '" + user +
                 "' is not a valid username — a malformed entry would poison the sudoers parse");
        return;
    }
    std::string body =
        user + " ALL=(ALL) NOPASSWD: /usr/bin/ufw status\n" +
        user + " ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status\n" +
        user + " ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status sshd\n";
    if (sh::dry_run()) {
        ui::substep("[dry-run] would validate (visudo -cf) + install " + sudoers.string());
        return;
    }
    // visudo -cf the fragment in a temp file BEFORE landing it in
    // /etc/sudoers.d/ — a syntactically-bad file there breaks EVERY sudo
    // invocation system-wide (you can't sudo to fix it). Stage, validate,
    // and only `install` on a clean parse.
    char tmpl[] = "/tmp/foxin-sudoers.XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) {
        ui::warn("sudoers write failed — could not stage temp file");
        return;
    }
    { std::ofstream w(tmpl); w << body; }
    ::close(fd);
    if (sh::run({"sudo", "visudo", "-cf", tmpl}) != 0) {
        fs::remove(tmpl);
        ui::warn("waybar sudoers failed visudo validation — not installing (overwatch may prompt)");
        return;
    }
    int rc = sh::run({"sudo", "install", "-m", "0440", "-o", "root", "-g", "root",
                      tmpl, sudoers.string()});
    fs::remove(tmpl);
    if (rc == 0) {
        ui::ok("sudoers rule added (visudo-validated; ufw + fail2ban-client status for waybar)");
    } else {
        ui::warn("sudoers install failed — waybar overwatch may prompt");
    }
}

}  // namespace

void run_security(Context& ctx) {
    ui::section("Security hardening");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold and no TTY — security needs root");
        return;
    }

    // Ensure security packages (additive; --deps installs the base set).
    sh::pacman({"fail2ban", "audit", "lynis",
                "knockd", "wireguard-tools",
                "inotify-tools", "python-virtualenv"});

    // UFW baseline runs as its own --ufw module (default-on, executes
    // before --secure in registry order). Not re-called here.
    install_kernel_hardening(ctx);
    install_usbguard(ctx);
    install_apparmor();

    // Polkit strict mode: require fresh password auth for every admin action.
    // The every-admin-action reprompt can be annoying for daily GUI use,
    // so we prompt for it here unless it was already enabled via flag.
    if (!ctx.assume_yes && ui::tty() && !ctx.install_polkit_strict) {
        if (ui::ask_yn("  • polkit-strict (every GUI sudo re-prompts — annoying for daily use)?", false, false)) {
            ctx.install_polkit_strict = true;
        }
    }
    if (ctx.install_polkit_strict) install_polkit_strict();

    install_fail2ban();
    install_auditd();
    install_waybar_sudoers(ctx);

    // SSH hardening wizard lives in its own --ssh-harden module now.
    // Runs separately so security doesn't drag the user through the
    // interactive port + keys-only flow on every --secure invocation.
    ui::ok("security hardening complete");
}

}  // namespace fox_install
