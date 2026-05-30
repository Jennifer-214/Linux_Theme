// modules/ssh_harden.cpp — interactive SSH hardening wizard (native port).
//
// Mirrors install.sh.legacy's SSH Hardening Wizard inside install_security:
//   1. Custom port (validated 1..65535, fallback 22).
//   2. authorized_keys present? Optionally import via
//      curl https://github.com/<user>.keys.
//   3. Decide password-auth posture (keys-only if keys detected; password+keys
//      when there are no keys, to prevent lockout).
//   4. Write /etc/ssh/sshd_config.d/50-foxml-hardening.conf with hardened
//      defaults (no root, no kbd-interactive, MaxAuthTries=3, etc.).
//   5. UFW: allow the new port, drop 22 if we moved off it.
//   6. Restart sshd.
//
// The SPA / port-knock sub-prompt at the end of the bash wizard is
// intentionally out of scope here — it ships as its own module so users
// opt in deliberately.

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

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool tty_in() { return ::isatty(STDIN_FILENO); }

std::string strip(std::string s) {
    auto a = s.find_first_not_of(" \t\r\n");
    auto b = s.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    return s.substr(a, b - a + 1);
}

std::string prompt_line(const std::string& msg, const std::string& def = "") {
    std::cout << msg << std::flush;
    std::string line;
    if (!std::getline(std::cin, line)) return def;
    line = strip(line);
    return line.empty() ? def : line;
}

// Use ui::ask_yn for y/n prompts (single-char, no Enter, guards stray keys).

bool write_root_file(const fs::path& path, const std::string& body,
                     const std::string& mode = "0644") {
    char tmpl[] = "/tmp/foxin.XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) return false;
    {
        std::ofstream w(tmpl);
        w << body;
    }
    ::close(fd);
    sh::run({"sudo", "install", "-d", path.parent_path().string()});
    int rc = sh::run({"sudo", "install", "-m", mode,
                      "-o", "root", "-g", "root", tmpl, path.string()});
    fs::remove(tmpl);
    return rc == 0;
}

int parsed_port_or_fallback(const std::string& raw) {
    try {
        int n = std::stoi(raw);
        if (n >= 1 && n <= 65535) return n;
    } catch (...) {}
    ui::warn("'" + raw + "' is not a valid port number — falling back to 22");
    return 22;
}

// Returns count of parsable public-key lines in `path` (rsa/ed25519/dss/ecdsa/sk-).
int count_authorized_keys(const fs::path& path) {
    std::ifstream f(path);
    if (!f) return 0;
    std::regex pat(R"(^(ssh-(rsa|ed25519|dss|ecdsa)|sk-) )");
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        if (std::regex_search(line, pat)) ++n;
    }
    return n;
}

// GitHub usernames are `[A-Za-z0-9][A-Za-z0-9-]{0,38}` (1-39 chars,
// alphanumeric + hyphen, no leading hyphen). Anything else is either a
// typo or a shell-injection attempt against import_github_keys.
bool valid_gh_username(const std::string& u) {
    if (u.empty() || u.size() > 39) return false;
    if (u.front() == '-') return false;
    for (char c : u) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    return true;
}

// Confirm key-based login actually authenticates before we disable
// password auth. BatchMode=yes + PasswordAuthentication=no forbid any
// password/interactive fallback, so a 0 exit means a key (or hostbased)
// authenticated against the currently-running sshd. The new drop-in
// keeps the same keys, so success here predicts success after restart.
// ANY failure (sshd not running yet, no agent, wrong key) is treated as
// "can't confirm" → caller keeps passwords on. Errs toward not locking out.
bool key_login_works() {
    const char* user = std::getenv("USER");
    if (!user || !*user) return false;
    std::string cmd =
        std::string("ssh -o BatchMode=yes -o PasswordAuthentication=no ")
        + "-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "
        + user + "@127.0.0.1 true >/dev/null 2>&1";
    return sh::run({"sh", "-c", cmd.c_str()}) == 0;
}

bool import_github_keys(const Context& ctx, const std::string& gh_user) {
    if (!valid_gh_username(gh_user)) {
        ui::warn("rejected: '" + gh_user + "' is not a valid GitHub username");
        return false;
    }
    fs::path ssh_dir = ctx.home / ".ssh";
    fs::path keys    = ssh_dir / "authorized_keys";
    fs::create_directories(ssh_dir);
    fs::permissions(ssh_dir, fs::perms::owner_all, fs::perm_options::replace);

    std::string fetched;
    if (!sh::capture({"curl", "-fsSL",
                      "https://github.com/" + gh_user + ".keys"}, fetched)
        || fetched.empty()) {
        ui::warn("failed to fetch keys for user: " + gh_user);
        return false;
    }
    {
        std::ofstream o(keys, std::ios::app);
        if (!o) {
            ui::warn("could not open " + keys.string() + " for append");
            return false;
        }
        o << fetched;
        if (!fetched.empty() && fetched.back() != '\n') o << '\n';
    }
    fs::permissions(keys,
        fs::perms::owner_read | fs::perms::owner_write,
        fs::perm_options::replace);
    ui::ok("imported keys from GitHub (" + gh_user + ")");
    return true;
}

}  // namespace

void run_ssh_harden(Context& ctx) {
    ui::section("SSH hardening wizard");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would: prompt for port, validate keys, write "
                    "/etc/ssh/sshd_config.d/50-foxml-hardening.conf, "
                    "update UFW, restart sshd");
        return;
    }
    if (!tty_in() || ctx.assume_yes) {
        ui::warn("--ssh-harden needs an interactive TTY (skipping under --yes / no-TTY)");
        return;
    }

    std::cout <<
        "\n╭──────────────────────────────────────────────────────────────────╮\n"
        "│   SSH Hardening Wizard                                           │\n"
        "├──────────────────────────────────────────────────────────────────┤\n"
        "│ Configures a custom port and (optionally) disables password     │\n"
        "│ login. WARNING: ensure you have SSH keys before disabling pwd.  │\n"
        "╰──────────────────────────────────────────────────────────────────╯\n";

    if (!ui::ask_yn("Run SSH hardening wizard?", false, ctx.assume_yes)) return;

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // 1. Custom port.
    int port = parsed_port_or_fallback(
        prompt_line("  Enter custom SSH port [default: 22]: ", "22"));

    // 2. Keys check + optional GitHub import.
    fs::path keys = ctx.home / ".ssh/authorized_keys";
    bool has_keys = fs::exists(keys);
    if (!has_keys) {
        std::cout << "  No ~/.ssh/authorized_keys found.\n";
        std::string gh_user = prompt_line(
            "  Import public keys from GitHub? (Enter username, or blank to skip): ");
        if (!gh_user.empty()) {
            has_keys = import_github_keys(ctx, gh_user);
        }
    }

    // 3. Password-auth posture.
    std::string disable_pass = "yes";        // "PasswordAuthentication yes" = on
    if (has_keys) {
        int n = count_authorized_keys(keys);
        if (n == 0) {
            ui::warn("authorized_keys exists but no recognised public keys parsed");
            ui::substep("keeping password auth ENABLED to avoid lockout");
            disable_pass = "yes";
        } else {
            std::cout << "  Detected " << n << " authorized public key(s).\n";
            // Verify key auth actually works before offering keys-only — a
            // present-but-non-working key (wrong machine, agent not
            // forwarding the private half) would otherwise lock the admin
            // out with no password fallback.
            if (!key_login_works()) {
                ui::warn("couldn't confirm key-based login works (ssh self-test to 127.0.0.1 failed)");
                ui::substep("keeping password auth ENABLED to avoid lockout");
                ui::substep("verify your key logs in (and that sshd is running), then re-run --ssh-harden");
                disable_pass = "yes";
            } else {
                std::cout << "  Key-based login verified.\n"
                             "  Disabling password auth is the recommended secure default.\n";
                if (ui::ask_yn("  Disable password authentication (keys-only)?", true, ctx.assume_yes)) {
                    disable_pass = "no";      // "PasswordAuthentication no" = keys-only
                }
            }
        }
    } else {
        std::cout << "  No authorized_keys — forcing 'PasswordAuthentication yes' to prevent lockout.\n";
    }

    // 4. Apply config.
    std::ostringstream body;
    body << "# FoxML SSH Hardening — generated by fox-install --ssh-harden\n"
            "Port "                          << port << "\n"
            "Protocol 2\n"
            "PasswordAuthentication "        << disable_pass << "\n"
            "PubkeyAuthentication yes\n"
            "PermitRootLogin no\n"
            "MaxAuthTries 3\n"
            "KbdInteractiveAuthentication no\n"
            "ChallengeResponseAuthentication no\n"
            "LoginGraceTime 30\n"
            "ClientAliveInterval 300\n"
            "ClientAliveCountMax 2\n";

    fs::path drop_in = "/etc/ssh/sshd_config.d/50-foxml-hardening.conf";
    if (!write_root_file(drop_in, body.str(), "0644")) {
        ui::err("could not write " + drop_in.string());
        return;
    }
    ui::ok("SSH config written to " + drop_in.string());
    ui::substep("PermitRootLogin no, MaxAuthTries 3, no kbd-interactive");

    // 5. UFW updates.
    if (port != 22) {
        sh::run({"sudo", "ufw", "allow", std::to_string(port) + "/tcp"});
        sh::run({"sh", "-c",
                 "sudo ufw delete allow 22 >/dev/null 2>&1 || true"});
        ui::ok("UFW: allowed " + std::to_string(port) + ", removed allow-22");
    }

    // 6. Validate the merged config BEFORE restarting. A bad drop-in
    // (ours or a pre-existing one) would otherwise take sshd down on
    // restart, locking out a headless admin. `sshd -t` parses the full
    // config without touching the running daemon.
    if (sh::run({"sudo", "sshd", "-t"}) != 0) {
        ui::err("sshd config failed validation (`sudo sshd -t`) — NOT restarting");
        ui::substep("the running sshd is untouched (your current session is safe)");
        ui::substep("our drop-in: " + drop_in.string() + " — remove it if it's the culprit, then restart sshd");
        return;
    }
    if (sh::run({"sudo", "systemctl", "restart", "sshd"}) == 0) {
        ui::ok("sshd restarted (config validated)");
    } else {
        ui::warn("sshd restart failed — `sudo systemctl status sshd` for details");
    }

    std::cout << "\n";
    if (disable_pass == "no") {
        ui::ok("SSH locked to keys-only on port " + std::to_string(port));
        ui::substep("test before logging out: ssh -p " +
                    std::to_string(port) + " -o BatchMode=yes " +
                    std::getenv("USER") + "@127.0.0.1 true");
    } else {
        ui::ok("SSH on port " + std::to_string(port) + ", passwords still ENABLED");
        ui::substep("add your key to ~/.ssh/authorized_keys, then re-run --ssh-harden");
    }
}

}  // namespace fox_install
