// modules/ssh_harden.cpp — the SSH wizard: one port for sshd, which UFW, fail2ban and endlessh then follow
// (ssh_port.hpp / ssh_follow.hpp), and keys-only login only once a key has logged in on the port sshd listens on.
//
//   1. The port: asked (Enter keeps the one sshd listens on), or FOXML_SSH_PORT=<port> for an unattended run
//      (a headless server, a VM). A port another program holds is refused.
//   2. authorized_keys present? Optionally import via https://github.com/<user>.keys.
//   3. A key self-test on the port sshd listens on now. Only a key that logs in there turns passwords off; with none,
//      passwords stay on and the module says why. Off already (keys only) with none: they go back on only if she
//      says so, and an unattended run changes nothing.
//   4. /etc/ssh/sshd_config.d/50-foxml-hardening.conf (the previous one kept as .foxml-bak) is written and checked
//      with `sshd -t` before sshd is touched; sshd reloads and a login on the new port is proven — any failure puts
//      the previous file back and restarts sshd on it (ssh_apply.hpp).
//   5. UFW opens the new port before the reload and closes the one sshd left after the proof; fail2ban's jail moves
//      with it. Logged in over SSH, the port you came in on stays until you log in on the new one. A port UFW denies
//      (desk knock / desk spa) or narrows is never opened.
//   Locked out anyway: the console (a TTY here, a server's provider console); RECOVERY.md.
//
// The SPA / port-knock sub-prompt at the end of the bash wizard is intentionally out of scope here: desk knock and
// desk spa are their own tools, so users opt in deliberately.

#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "ssh_apply.hpp"
#include "ssh_follow.hpp"
#include "ssh_port.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace desk_install {

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

std::string read_file(const fs::path& p) {
    std::ifstream f(p);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Lines of authorized_keys that name a key (not blank, not a comment). Only the self-test proves one works.
int count_authorized_keys(const fs::path& path) {
    std::ifstream f(path);
    int n = 0;
    for (std::string line; std::getline(f, line);) {
        line = strip(line);
        if (!line.empty() && line[0] != '#') ++n;
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

bool quiet(const std::vector<std::string>& argv) {
    std::vector<std::string> wrapped = {"sh", "-c", "exec \"$@\" >/dev/null 2>&1", "sh"};
    wrapped.insert(wrapped.end(), argv.begin(), argv.end());
    return sh::run(wrapped) == 0;
}

// A key (or nothing) logs in as this user on `port`: BatchMode, publickey only, so never a password.
bool key_login_works(int port) {
    const char* user = std::getenv("USER");
    return user && *user && quiet(ssh_port::key_test_argv(user, port));
}

bool port_answers(int port) {
    std::string out;
    sh::probe(ssh_port::keyscan_argv(port), out);
    return ssh_port::answered(out);
}

bool sshd_active() {
    std::string out;
    return sh::probe({"systemctl", "is-active", "--quiet", "sshd"}, out) == 0;
}

// sshd takes a moment to bind after a reload: a few tries, a second apart.
bool proven(const std::function<bool()>& probe) {
    for (int i = 0; i < 5; ++i) {
        if (i) ::sleep(1);
        if (probe()) return true;
    }
    return false;
}

void ufw_close(const std::vector<int>& ports) {
    if (!sh::have("ufw")) return;
    for (int p : ports) quiet({"sudo", "ufw", "delete", "limit", std::to_string(p) + "/tcp"});
}

void fail2ban_follows(const std::vector<int>& ports) {
    if (!sh::pacman_installed("fail2ban")) return;
    if (ssh_follow::fail2ban(ports) != ssh_follow::Jail::Updated) return;
    if (sh::run({"sh", "-c", "! systemctl is-active --quiet fail2ban || "
                             "sudo systemctl reload fail2ban >/dev/null 2>&1 || "
                             "sudo systemctl restart fail2ban >/dev/null 2>&1"}) != 0)
        ui::warn("fail2ban did not reload — it bans on the old port until it restarts");
}

void recovery_hint(const std::string& drop_in, bool had) {
    ui::substep("locked out? From the console (a TTY here, or a server's provider console):");
    for (const auto& step : ssh_port::recovery_steps(drop_in, had)) ui::substep("  " + step);
}

}  // namespace

void run_ssh_harden(Context& ctx) {
    ui::section("SSH hardening wizard");
    const std::string drop_in = ssh_port::kDropIn;
    const char* env_port = std::getenv("FOXML_SSH_PORT");
    const bool unattended = env_port && *env_port;

    if (sh::dry_run()) {
        std::string now;
        const std::string at = ssh_port::sshd_t(now) && !ssh_port::listen_ports(now).empty()
                                   ? ssh_port::join(ssh_port::listen_ports(now), ", ") : "unknown (sudo cold)";
        ui::substep("[dry-run] would: read where sshd listens (sudo sshd -T: " + at + "), " +
                    (unattended ? std::string("take FOXML_SSH_PORT=") + env_port : "ask for the port") +
                    ", and test a key login there (ssh -F none -p <now> -o BatchMode=yes $USER@127.0.0.1 true)");
        ui::substep("[dry-run] then: save " + drop_in + " as .foxml-bak, ufw limit <port>/tcp, write the drop-in "
                    "(PasswordAuthentication no only if the key logged in), sudo sshd -t, systemctl reload sshd, "
                    "prove a login on <port>; on any failure put the previous file back and restart sshd");
        ui::substep("[dry-run] then: close the port sshd left in UFW (22 stays only for endlessh), "
                    "set fail2ban's [sshd] port to <port>");
        return;
    }
    if (!unattended && (!tty_in() || ctx.assume_yes)) {
        ui::warn("--ssh-harden asks questions: run it in a terminal, or set FOXML_SSH_PORT=<port> for an "
                 "unattended run (skipped)");
        return;
    }
    if (!unattended) {
        std::cout <<
            "\n╭──────────────────────────────────────────────────────────────────╮\n"
            "│   SSH Hardening Wizard                                           │\n"
            "├──────────────────────────────────────────────────────────────────┤\n"
            "│ Moves sshd to the port you pick and, once your key has logged   │\n"
            "│ in on it, turns password login off. Checked before and after.   │\n"
            "╰──────────────────────────────────────────────────────────────────╯\n";
        if (!ui::ask_yn("Run SSH hardening wizard?", false, false)) return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }
    if (!sh::have("sshd")) {
        ui::err("sshd is not installed (openssh) — nothing to harden");
        return;
    }

    // 1. Where sshd listens now: the one source everything else reads too.
    std::string sshd_now;
    if (!ssh_port::sshd_t(sshd_now) || ssh_port::listen_ports(sshd_now).empty()) {
        ui::err("`sudo sshd -T` failed: sshd's config does not parse — nothing changed (`sudo sshd -t` shows why)");
        return;
    }
    const auto current = ssh_port::listen_ports(sshd_now);
    const int now_port = current.front();
    const std::string now_s = std::to_string(now_port);

    int port = now_port;
    if (unattended) {
        const auto p = ssh_port::parse_port(env_port);
        if (!p) {
            ui::err(std::string("FOXML_SSH_PORT='") + env_port + "' is not a port (1-65535) — nothing changed");
            return;
        }
        port = *p;
    } else {
        // Enter keeps the port sshd listens on: a re-run must not move it back to 22.
        const std::string raw = prompt_line("  SSH port [Enter keeps " + now_s + "]: ", now_s);
        if (const auto p = ssh_port::parse_port(raw)) port = *p;
        else ui::warn("'" + raw + "' is not a port number — keeping " + now_s);
    }
    const std::string port_s = std::to_string(port);
    if (!ssh_port::has(current, port)) {
        for (const auto& who : ssh_port::listeners_now(port)) {
            if (who == "sshd") continue;
            ui::err("port " + port_s + " is in use" + (who.empty() ? "" : " by " + who) + " — pick another; nothing changed");
            return;
        }
    }

    // 2-3. Keys, and whether one logs in on the port sshd listens on now.
    const fs::path keys = ctx.home / ".ssh/authorized_keys";
    if (!fs::exists(keys) && !unattended) {
        std::cout << "  No ~/.ssh/authorized_keys found.\n";
        const std::string gh_user = prompt_line(
            "  Import public keys from GitHub? (Enter username, or blank to skip): ");
        if (!gh_user.empty()) import_github_keys(ctx, gh_user);
    }
    const int nkeys = count_authorized_keys(keys);
    const bool running = sshd_active();
    const bool key_ok = running && key_login_works(now_port);
    const auto passwords_now = ssh_port::password_auth(sshd_now);
    const bool off_now = passwords_now == false;
    bool keys_only = false;
    std::string why;
    if (key_ok) {
        ui::ok("a key logged in on " + now_s + " (ssh self-test to 127.0.0.1:" + now_s + ")");
        keys_only = unattended || ui::ask_yn(off_now ? "  Keep password login off (keys only)?"
                                                     : "  Turn password login off (keys only)?", true, false);
        if (!keys_only) why = "you chose so";
    } else if (!running) {
        why = "sshd is not running, so no key could prove itself";
    } else if (nkeys == 0) {
        why = "there is no key in ~/.ssh/authorized_keys";
    } else {
        why = "none of the " + std::to_string(nkeys) + " key(s) in authorized_keys logged in on " + now_s +
              " from here (the test runs on this machine: it needs your key here, or a forwarded agent, ssh -A)";
    }
    // A keys-only sshd goes back to passwords only on her yes: a re-run with no key here wrote them on (2026-11-16).
    if (!keys_only && ssh_port::would_weaken(passwords_now, key_ok)) {
        ui::warn("passwords are OFF now, and " + why + ": going on would turn them back ON");
        if (unattended || !ui::ask_yn("  Turn password login back on?", false, false)) {
            const std::string kept = "nothing changed: sshd stays keys only on " + ssh_port::join(current, ", ") +
                                     " — log in here with your key (or a forwarded agent, ssh -A), then re-run";
            if (port == now_port) ui::warn(kept);
            else ui::err(kept);
            return;
        }
    }
    if (!keys_only) ui::warn(std::string(off_now ? "passwords go back ON: " : "passwords stay ON: ") + why);

    // 4. The drop-in. Logged in over SSH on a port the move drops, sshd keeps that port too.
    const int session = ssh_port::session_port(std::getenv("SSH_CONNECTION"));
    const auto ports = ssh_port::ports_to_write(port, session, current);
    const std::string body = ssh_port::hardening_conf(ports, keys_only);
    const bool had = fs::exists(drop_in);
    const std::string prev = had ? read_file(drop_in) : std::string();

    // UFW and fail2ban follow where sshd listens afterwards (a Port line in sshd_config counts too); returns that
    // `sshd -T`.
    const auto follow = [&] {
        std::string after;
        auto now = ssh_port::sshd_t(after) ? ssh_port::listen_ports(after) : std::vector<int>{};
        if (now.empty()) now = ports;
        std::vector<int> left;
        for (int p : current) if (!ssh_port::has(now, p)) left.push_back(p);
        ssh_follow::ufw(now, left);
        fail2ban_follows(now);
        return after;
    };

    if (had && prev == body) {
        ui::skipped("sshd already set: port " + ssh_port::join(ports, ", ") + ", " +
                    (keys_only ? "keys only" : "passwords on") + " — nothing to change");
        follow();
        return;
    }

    // The new port open in UFW before sshd moves, so a remote client can follow it: only one UFW holds no rule for
    // (ssh_follow::to_open), and a failed move closes just those again. A port it denies or narrows stays so; with
    // its rules unreadable the move is not made blind.
    std::vector<int> fresh, opened;
    for (int p : ports) if (!ssh_port::has(current, p)) fresh.push_back(p);
    if (!fresh.empty() && sh::have("ufw")) {
        const auto rules = ssh_follow::ufw_rules();
        if (!rules) {
            ui::err(std::string("couldn't read UFW's rules (sudo cat ") + ssh_follow::kUserRules + ") to open " +
                    ssh_port::join(fresh, ", ") + " safely — nothing changed");
            return;
        }
        opened = ssh_follow::to_open(ports, current, *rules);
        for (int p : fresh)
            if (const auto h = ssh_follow::hold(*rules, p); !ssh_follow::may_open(h))
                ui::warn("UFW: " + std::to_string(p) + " stays as it is — " + ssh_follow::held(h) +
                         ": a login on it from elsewhere goes through that");
    }
    if (had && !sh::write_root_atomic(drop_in + ".foxml-bak", prev, "0644")) {
        ui::err("could not save " + drop_in + ".foxml-bak — nothing changed");
        return;
    }
    for (int p : opened) quiet({"sudo", "ufw", "limit", std::to_string(p) + "/tcp"});

    ssh_apply::Steps steps;
    steps.write = [&](const std::string& text) { return sh::write_root_atomic(drop_in, text, "0644"); };
    steps.remove = [&] { return sh::run({"sudo", "rm", "-f", drop_in}) == 0; };
    steps.check = [] { return sh::run({"sudo", "sshd", "-t"}) == 0; };
    steps.reload = [] { return sh::run({"sudo", "systemctl", "reload", "sshd"}) == 0; };
    steps.restart = [] {
        return sh::run({"sh", "-c", "sudo systemctl reset-failed sshd >/dev/null 2>&1; sudo systemctl restart sshd"}) == 0;
    };
    steps.answers = [&] {
        return proven([&] {
            if (!sshd_active()) return false;
            for (int p : ports) if (!port_answers(p)) return false;
            return true;
        });
    };
    steps.key_logs_in = [&] { return proven([&] { return key_login_works(port); }); };
    steps.answers_before = [&] { return proven([&] { return sshd_active() && port_answers(now_port); }); };

    switch (ssh_apply::apply(had ? std::optional<std::string>(prev) : std::nullopt, body, running, key_ok, steps)) {
    case ssh_apply::Result::Unproven:
        ui::err("keys only needs a key to log in first, and sshd is not running — nothing changed");
        ufw_close(opened);
        return;
    case ssh_apply::Result::WriteFailed:
        ui::err("could not write " + drop_in + " — nothing changed");
        ufw_close(opened);
        return;
    case ssh_apply::Result::Refused:
        ui::err("`sshd -t` refused the new config — " + std::string(had ? "the previous one is back" : "it is removed") +
                "; the running sshd was not touched (`sudo sshd -t` shows why)");
        ufw_close(opened);
        return;
    case ssh_apply::Result::Reverted:
        ui::err("sshd on " + port_s + " did not prove itself (" +
                (key_ok || keys_only ? "an answer and a key login" : "an answer") + " on " + port_s +
                ") — the previous config is back and sshd answers on " + now_s + " again");
        ufw_close(opened);
        recovery_hint(drop_in, had);
        return;
    case ssh_apply::Result::Stuck:
        ui::err("sshd could not be put back as it was — do not log out of this session");
        recovery_hint(drop_in, had);
        return;
    case ssh_apply::Result::Applied:
        break;
    }

    ui::ok("SSH config written to " + drop_in + (had ? " (the previous one: .foxml-bak)" : ""));
    ui::substep("PermitRootLogin no, MaxAuthTries 3, no kbd-interactive");
    if (running) {
        ui::ok("sshd reloaded and answering on " + ssh_port::join(ports, ", ") +
               (key_ok ? "; your key logged in on " + port_s : ""));
    } else {
        ui::warn("sshd is not running: this applies when it starts (sudo systemctl enable --now sshd); "
                 "then re-run --ssh-harden so a key can prove itself");
    }

    // 5. Everything that names the port follows it.
    const auto passwords = ssh_port::password_auth(follow());
    std::cout << "\n";
    if (keys_only && passwords && *passwords) {
        ui::warn("keys only was written, but another sshd config file turns passwords back on "
                 "(sudo sshd -T | grep -i passwordauthentication; then /etc/ssh/sshd_config and sshd_config.d/)");
    } else if (keys_only) {
        ui::ok("SSH is keys only on port " + port_s);
    } else {
        ui::ok("SSH on port " + port_s + (off_now ? ", passwords back on" : ", passwords still on"));
        if (passwords && !*passwords)
            ui::warn("another sshd config file turns passwords OFF, and no key logged in here — "
                     "make sure yours does before you log out");
    }
    if (ports.size() > 1)
        ui::substep("you came in on " + std::to_string(session) + ", so sshd keeps it: log in on " + port_s +
                    " from your own machine, then re-run --ssh-harden there (or from the console) to drop it");
    const char* user = std::getenv("USER");
    ui::substep("next login: ssh -p " + port_s + " " + (user ? user : "you") + "@<this host>");
    recovery_hint(drop_in, had);
}

}  // namespace desk_install
