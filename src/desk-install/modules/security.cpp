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
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "audit_rules.hpp"
#include "boot_files.hpp"
#include "iommu.hpp"
#include "ssh_follow.hpp"
#include "ssh_port.hpp"

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

namespace desk_install {

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

// ════════════════════════════════════════════════════════════════════
// install_kernel_hardening — sysctl drop-in
// ════════════════════════════════════════════════════════════════════
constexpr const char* KERNEL_HARDENING_BODY =
    "# FoxML kernel hardening — auto-applied by desk-install --secure.\n"
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
    // An error, not a warning: the security baseline is not in place, and the run must not read as complete.
    if (!have("usbguard")) { ui::err("usbguard not installed — USB device control is NOT on; install with --deps, then re-run --security"); return; }

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
    std::error_code ec;
    if (!fs::is_directory(entries_dir, ec)) return;
    int modified = 0;
    std::vector<fs::path> entries;
    for (fs::directory_iterator it(entries_dir, ec), end; !ec && it != end; it.increment(ec)) entries.push_back(it->path());
    if (boot_files::unreadable(ec)) { ui::warn("cannot list " + entries_dir.string() + " (" + ec.message() + ") — AppArmor's cmdline left as it is"); return; }
    for (const auto& path : entries) {
        const fs::directory_entry e(path, ec);
        if (!e.is_regular_file(ec)) continue;
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
        // This run's copy is the revert point: an options line that lost root= or rw, or still lacks apparmor, goes back.
        auto apply = [&](const std::string& program) {
            const std::string entry = e.path().string(), preedit = entry + ".foxml-preedit";
            sh::run({"sudo", "cp", entry, preedit});
            sh::run({"sudo", "sed", "-i", "-E", program, entry});
            std::string options, line;
            std::istringstream lines(read_file(e.path()));
            while (std::getline(lines, line)) if (line.rfind("options ", 0) == 0) { options = line; break; }
            if (cmdline_options_sane(options) && options.find("apparmor") != std::string::npos) {
                sh::run({"sudo", "rm", "-f", preedit});
                return true;
            }
            sh::run({"sudo", "mv", preedit, entry});
            ui::err(entry + ": the options line failed its check after adding apparmor — reverted");
            return false;
        };
        if (body.find("\nlsm=") == std::string::npos &&
            body.find(" lsm=") == std::string::npos) {
            // No lsm= yet — append the full recommendation.
            backup_entry();
            if (apply("s|^options (.*)$|options \\1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf|")) {
                ui::ok(e.path().string() + ": apparmor added to kernel cmdline (backup: .foxml-bak)");
                ++modified;
            }
            continue;
        }
        // Already contains an lsm= but missing apparmor?
        std::string re_check = "^options .*\\blsm=[^[:space:]]*apparmor";
        if (sh::run({"sh", "-c",
                     "grep -qE \"" + re_check + "\" " + e.path().string()}) == 0) {
            continue;
        }
        backup_entry();
        if (apply("s|(^options .*\\blsm=)([^[:space:]]*)|\\1\\2,apparmor|")) {
            ui::ok(e.path().string() + ": apparmor added to kernel cmdline (backup: .foxml-bak)");
            ++modified;
        }
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
    ui::ok("grub default cmdline updated (/etc/default/grub)");
    // GRUB regen intentionally LEFT NON-FUNCTIONAL: a naked `grub-mkconfig -o
    // grub.cfg` truncates grub.cfg before the generator writes, so a failed or
    // garbled regen bricks boot with no revert. Rather than auto-run it, we leave
    // it to the user until this is made validate-before-swap (the iommu.cpp
    // generate→grub_cfg_sane()→atomic-swap→revert pattern) — deferred until a host
    // here actually uses a GRUB loader. The cmdline edit above is safe + backed up
    // and takes effect on the next grub.cfg regeneration.
    ui::warn("GRUB detected — grub.cfg NOT auto-regenerated (avoids an unguarded "
             "regen that can brick boot)");
    ui::substep("apply when ready: sudo grub-mkconfig -o /boot/grub/grub.cfg");
    return true;
}

}  // namespace

void install_apparmor() {
    if (!pacman_has("apparmor")) {
        ui::err("apparmor not installed — AppArmor is NOT on; re-run with --deps --secure");
        return;
    }

    // A /boot this user cannot read is left alone, never taken for "no systemd-boot" and GRUB's file edited instead.
    std::error_code boot_ec;
    const bool entries = fs::is_directory("/boot/loader/entries", boot_ec);
    if (boot_files::unreadable(boot_ec)) {
        ui::warn("cannot read the boot entries as your user (" + boot_ec.message() + ") — AppArmor's kernel cmdline left as it is");
        ui::substep("add by hand if missing: lsm=landlock,lockdown,yama,integrity,apparmor,bpf");
    } else if (entries) {
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
    "        // Exception: fprintd verify (covers fprintd-list) — the waybar\n"
    "        // sentry polls enrollment every 15s; strict mode turns that into\n"
    "        // a denial (no agent) or an auth-dialog storm (agent running).\n"
    "        // undefined falls through to the implicit policy, which already\n"
    "        // requires an active session. Enroll/delete stay strict.\n"
    "        if (action.id == \"net.reactivated.fprint.device.verify\") {\n"
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
// jail.local's text is ssh_follow::jail_local (pure, tests/test_ssh_follow): its [sshd] jail bans on the ports sshd
// listens on.
void install_fail2ban() {
    if (!pacman_has("fail2ban")) {
        ui::warn("fail2ban package not found — run with --deps --secure");
        return;
    }
    fs::path jail = "/etc/fail2ban/jail.local";
    std::string existing = read_file(jail);
    // The jail bans on the ports sshd listens on: `port = ssh` (22) never covered a moved sshd.
    const auto ports = ssh_port::configured();
    if (existing.find("# foxml-managed") == std::string::npos) {
        if (!write_root_file(jail, ssh_follow::jail_local(ports ? ssh_port::join(*ports, ",") : "ssh",
                                                        std::getenv("SSH_CONNECTION")), "0644")) {
            ui::warn("could not write " + jail.string());
            return;
        }
        ui::ok("fail2ban jail.local written (sshd jail enabled)");
    } else if (ports) {
        ssh_follow::fail2ban(*ports);   // rewrites only the [sshd] port line, checked; the reload below picks it up
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
void install_auditd() {
    if (!pacman_has("audit")) {
        ui::warn("audit package not installed — skipping persistent audit rules");
        return;
    }
    fs::path rules = "/etc/audit/rules.d/99-foxml.rules";
    // The file is root-only (0640), so it is read as root: read as the user it came back empty, the installer's
    // block was never found, and the whole file was rewritten on every run, dropping desk-honey's watches. A missing
    // file reads as empty; a read that fails leaves the file alone rather than lose lines it could not see.
    std::string existing;
    if (!sh::capture({"sudo", "-n", "sh", "-c", "[ ! -e \"$1\" ] || cat -- \"$1\"", "sh", rules.string()},
                     existing)) {
        if (sh::dry_run()) {
            ui::substep("[dry-run] would merge the installer's watches into " + rules.string() + " (other lines kept)");
            return;
        }
        ui::warn("could not read " + rules.string() + " (sudo cold?) — left as it is; re-run after `sudo -v`");
        return;
    }
    const std::string next = audit_rules::merged(existing);
    const bool changed = next != existing;
    bool loaded = false;
    if (changed) {
        if (!write_root_file(rules, next, "0640")) {
            ui::warn("could not write " + rules.string());
            return;
        }
        // Flush the kernel ruleset BEFORE reloading. Watches loaded at boot
        // are still resident; augenrules --load can't add a watch that
        // already exists ("Rule exists" → exit 1), so without the flush the
        // file is fixed but the live service stays failed until next reboot.
        // auditctl -D is how auditd itself reloads — the canary is
        // unwatched only for the instant between flush and reload.
        // One load, by audit-rules itself: loading here and then restarting it loaded every rule twice, and its second
        // "Rule exists" left audit-rules.service failed with the rules in place (found in the VM, 2026-11-14).
        sh::run({"sh", "-c", "sudo auditctl -D >/dev/null 2>&1 || true"});
        sh::run({"sh", "-c", "sudo systemctl reset-failed audit-rules >/dev/null 2>&1 || true"});
        loaded = sh::run({"sh", "-c", "sudo systemctl restart audit-rules >/dev/null 2>&1"}) == 0;
        if (!loaded) sh::run({"sh", "-c", "sudo augenrules --load >/dev/null 2>&1 || true"});
        ui::ok("auditd watch rules written to " + rules.string() + " (other watches in it kept)");
    }
    if (!systemctl_active("auditd")) {
        if (sh::systemctl_enable("auditd", /*user=*/false) == 0) {
            ui::ok("auditd enabled with persistent watch rules");
        } else {
            ui::warn("auditd enable failed (sudo cold?) — re-run after `sudo -v`");
        }
    } else if (!changed) {
        ui::skipped("auditd already active (watch rules unchanged)");
    } else if (loaded) {
        // Not `restart auditd`: its unit has RefuseManualStop=yes, so that always failed. audit-rules loads the rules.
        ui::skipped("auditd already active (new rules loaded)");
    } else {
        ui::skipped("auditd already active (couldn't reload audit-rules — rules apply on next reboot)");
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

    // Ensure security packages (additive; --deps installs the base set). usbguard and apparmor were never installed
    // anywhere, so a fresh machine skipped both (found in the VM, 2026-11-14).
    sh::pacman({"fail2ban", "audit", "lynis", "usbguard", "apparmor",
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

}  // namespace desk_install
