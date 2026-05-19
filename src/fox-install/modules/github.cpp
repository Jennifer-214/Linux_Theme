// modules/github.cpp — gh CLI + workspace clone (native port).
//
// Mirrors install.sh.legacy:install_github_workspace + the helper
// _ensure_ssh_key_protected + mappings.sh:install_github_gpg_signing.
// Every shell-out goes through sh:: so --dry-run logs the plan.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include "../../fox-intel/json.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

bool tty_in() { return ::isatty(STDIN_FILENO); }

std::string strip(std::string s) {
    auto a = s.find_first_not_of(" \t\r\n");
    auto b = s.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    return s.substr(a, b - a + 1);
}

std::string git_config(const std::string& key) {
    std::string out;
    if (!sh::capture({"git", "config", "--global", key}, out)) return {};
    return strip(out);
}

std::string capture_trim(const std::vector<std::string>& argv) {
    std::string out;
    if (!sh::capture(argv, out)) return {};
    return strip(out);
}

std::string prompt_line(const std::string& msg, const std::string& fallback = "") {
    if (!tty_in()) return fallback;
    std::cout << msg << std::flush;
    std::string line;
    if (!std::getline(std::cin, line)) return fallback;
    line = strip(line);
    return line.empty() ? fallback : line;
}

// y/n prompts go through ui::ask_yn now.

// Random 40-char alphanumeric passphrase. Matches the bash _gen_passphrase
// (LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40).
std::string gen_passphrase() {
    static const char alphabet[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<int> dist(0, 61);
    std::string out;
    out.reserve(40);
    for (int i = 0; i < 40; ++i) out.push_back(alphabet[dist(gen)]);
    return out;
}

void stash_passphrase(const Context& ctx, const std::string& pp) {
    fs::path pp_dir  = ctx.config_home / "foxml";
    fs::path pp_file = pp_dir / "ssh-passphrase.txt";
    fs::create_directories(pp_dir);
    fs::permissions(pp_dir, fs::perms::owner_all, fs::perm_options::replace);
    {
        std::ofstream f(pp_file);
        f << pp << "\n";
    }
    fs::permissions(pp_file,
        fs::perms::owner_read | fs::perms::owner_write,
        fs::perm_options::replace);
    ui::warn("SSH passphrase stashed at " + pp_file.string() + " (perms 600)");
    ui::substep("move it to a password manager, then: shred -u " + pp_file.string());
}

// ── SSH key protection (matches install.sh.legacy:_ensure_ssh_key_protected)
void ensure_ssh_key_protected(const Context& ctx, const std::string& gh_user) {
    fs::path key = ctx.home / ".ssh/id_ed25519";

    if (!fs::exists(key)) {
        // Path 1: no key yet — generate.
        fs::path ssh_dir = ctx.home / ".ssh";
        fs::create_directories(ssh_dir);
        fs::permissions(ssh_dir, fs::perms::owner_all, fs::perm_options::replace);
        std::string email = git_config("user.email");
        char hostbuf[256] = {};
        ::gethostname(hostbuf, sizeof(hostbuf) - 1);
        std::string comment = !email.empty() ? email
                                              : gh_user + "@" + hostbuf;
        if (tty_in() && !ctx.assume_yes) {
            ui::substep("generating SSH key (ed25519); ssh-keygen will prompt for a passphrase");
            sh::run({"ssh-keygen", "-t", "ed25519",
                     "-f", key.string(), "-C", comment});
        } else {
            std::string pp = gen_passphrase();
            ui::substep("generating SSH key (ed25519) with random passphrase");
            sh::run({"ssh-keygen", "-t", "ed25519", "-N", pp,
                     "-f", key.string(), "-C", comment, "-q"});
            stash_passphrase(ctx, pp);
        }
        ui::ok("key: " + key.string());
        return;
    }

    // Path 2: key exists — check passphraseless.
    // `ssh-keygen -y -P "" -f <key>` succeeds only when there's no passphrase.
    if (sh::run({"sh", "-c",
                 "ssh-keygen -y -P \"\" -f " + key.string() +
                 " >/dev/null 2>&1"}) != 0) {
        return;   // has passphrase already
    }

    ui::warn(key.string() + " has no passphrase");
    ui::substep("anyone with this file has your GitHub push access until revoked");
    if (tty_in() && !ctx.assume_yes) {
        if (!ui::ask_yn("Set a passphrase now?", true, ctx.assume_yes)) {
            ui::substep("skipped — set later with: ssh-keygen -p -f " + key.string());
            return;
        }
        if (sh::run({"ssh-keygen", "-p", "-f", key.string()}) == 0) {
            ui::ok("passphrase set on " + key.string());
        } else {
            ui::warn("passphrase change failed — re-run: ssh-keygen -p -f " + key.string());
        }
    } else {
        std::string pp = gen_passphrase();
        if (sh::run({"sh", "-c",
                     "ssh-keygen -p -P \"\" -N \"" + pp + "\" -f " +
                     key.string() + " >/dev/null 2>&1"}) == 0) {
            ui::ok("random passphrase set on " + key.string());
            stash_passphrase(ctx, pp);
        } else {
            ui::warn("could not set passphrase — re-run interactively");
        }
    }
}

// ── GPG commit-signing (matches mappings.sh:install_github_gpg_signing) ──
void install_github_gpg_signing() {
    if (!have("gpg")) { ui::warn("gpg not installed — skipping commit-signing setup"); return; }
    if (!have("gh"))  { ui::warn("gh not installed — skipping commit-signing setup");  return; }

    std::string email = git_config("user.email");
    std::string name  = git_config("user.name");
    if (email.empty()) {
        ui::warn("git user.email unset — skipping commit-signing setup");
        return;
    }

    // Look for an existing usable signing key.
    std::string colons;
    sh::capture({"gpg", "--list-secret-keys", "--with-colons", email}, colons);
    std::string keyid;
    {
        std::istringstream is(colons);
        std::string line;
        bool sec_seen = false;
        while (std::getline(is, line)) {
            std::vector<std::string> f;
            {
                std::stringstream ss(line);
                std::string tok;
                while (std::getline(ss, tok, ':')) f.push_back(tok);
            }
            if (f.size() >= 12 && f[0] == "sec"
                               && f[1] != "r" && f[1] != "e"
                               && f[11].find('s') != std::string::npos) {
                sec_seen = true;
                continue;
            }
            if (sec_seen && !f.empty() && f[0] == "fpr" && f.size() >= 10) {
                keyid = f[9];
                break;
            }
        }
    }

    if (keyid.empty()) {
        if (!tty_in()) {
            ui::warn("no TTY for pinentry — skipping GPG key generation");
            ui::substep("generate manually: gpg --quick-generate-key \"" +
                        name + " <" + email + ">\" ed25519 sign 0");
            return;
        }
        ui::substep("generating ed25519 GPG signing key for " + email);
        // Fresh-bootstrap shells don't inherit .zshrc → pinentry-curses
        // needs explicit GPG_TTY.
        std::string tty;
        sh::capture({"tty"}, tty);
        ::setenv("GPG_TTY", strip(tty).c_str(), 0);
        if (sh::run({"gpg", "--quick-generate-key",
                     name + " <" + email + ">", "ed25519", "sign", "0"}) != 0) {
            ui::warn("GPG key generation failed — skipping rest of commit-signing setup");
            return;
        }
        sh::capture({"gpg", "--list-secret-keys", "--with-colons", email}, colons);
        std::istringstream is(colons);
        std::string line;
        while (std::getline(is, line)) {
            if (line.rfind("fpr:", 0) == 0) {
                auto end = line.find(':', 4);
                if (end != std::string::npos) {
                    // colon-fmt: fpr:::::::::FINGERPRINT:
                    auto fp_start = line.find_last_of(':', end - 1);
                    keyid = line.substr(fp_start + 1, end - fp_start - 1);
                }
                break;
            }
        }
        if (keyid.empty()) {
            ui::warn("could not locate freshly-generated key — skipping upload");
            return;
        }
        ui::ok("key: " + keyid);
    } else {
        ui::substep("reusing existing GPG signing key: " + keyid);
    }

    // Upload pubkey to GitHub if not registered.
    std::string pubkey;
    sh::capture({"gpg", "--armor", "--export", keyid}, pubkey);
    if (pubkey.empty()) {
        ui::warn("pubkey export empty — skipping upload");
    } else {
        std::string keys;
        sh::capture({"gh", "gpg-key", "list"}, keys);
        if (keys.find(keyid) != std::string::npos) {
            ui::skipped("GPG key already on GitHub");
        } else {
            std::string status;
            sh::capture({"gh", "auth", "status"}, status);
            if (status.find("write:gpg_key") == std::string::npos) {
                ui::substep("refreshing gh auth to include write:gpg_key scope");
                sh::run({"gh", "auth", "refresh", "-h", "github.com",
                         "-s", "write:gpg_key"});
            }
            ui::substep("uploading GPG key to GitHub");
            char hostbuf[256] = {};
            ::gethostname(hostbuf, sizeof(hostbuf) - 1);
            std::string title = hostbuf;
            // Pipe pubkey into `gh gpg-key add - --title <host>`.
            std::string sh_cmd =
                "printf '%s\\n' " + std::string("\"$FOX_GPG\"") +
                " | gh gpg-key add - --title \"" + title + "\"";
            ::setenv("FOX_GPG", pubkey.c_str(), 1);
            sh::run({"sh", "-c", sh_cmd});
            ::unsetenv("FOX_GPG");
        }
    }

    // Wire git to sign every commit + tag.
    sh::run({"git", "config", "--global", "user.signingkey", keyid});
    sh::run({"git", "config", "--global", "commit.gpgsign", "true"});
    sh::run({"git", "config", "--global", "tag.gpgSign",    "true"});
    ui::ok("git configured to sign commits with " + keyid);
}

}  // namespace

void run_github(Context& ctx) {
    ui::section("GitHub workspace setup");

    // Dry-run short-circuit. github does a lot of side-effecting probes
    // (ssh-keygen -y, gh api, fs::permissions on $HOME/.ssh, etc.) that
    // can't all be made sh::-routed without surgery. Rather than risk a
    // dry-run that actually writes ~/.config/foxml/ssh-passphrase.txt,
    // print the planned high-level actions and return.
    if (sh::dry_run()) {
        ui::substep("[dry-run] would: install gh, gh auth login, generate "
                    "SSH key with passphrase, upload pubkey + GPG key, "
                    "clone every repo for your gh user into ~/code/");
        return;
    }

    // Banner + opt-in confirmation (matches bash UX).
    std::cout <<
        "\n╭──────────────────────────────────────────────────────────────────╮\n"
        "│   GitHub Workspace Setup                                         │\n"
        "├──────────────────────────────────────────────────────────────────┤\n"
        "│ This will create ~/code and clone all your public/private       │\n"
        "│ repositories. It uses 'gh' (GitHub CLI) for automation.         │\n"
        "╰──────────────────────────────────────────────────────────────────╯\n";

    if (tty_in() && !ctx.assume_yes) {
        if (!ui::ask_yn("Set up GitHub workspace?", false, ctx.assume_yes)) return;
    }

    if (!have("gh")) {
        sh::pacman({"github-cli"});
    }

    if (sh::run({"sh", "-c", "gh auth status >/dev/null 2>&1"}) != 0) {
        ui::substep("running `gh auth login`");
        sh::run({"gh", "auth", "login"});
    }

    // Resolve username from gh (cheap), fall back to prompt.
    std::string gh_user = capture_trim({"gh", "api", "user", "-q", ".login"});
    if (gh_user.empty()) gh_user = prompt_line("    Enter your GitHub username: ");
    if (gh_user.empty()) { ui::warn("no username — skipping"); return; }

    // Git config sanity.
    if (git_config("user.name").empty()) {
        std::string n = prompt_line("    Enter Git name: ");
        if (!n.empty()) sh::run({"git", "config", "--global", "user.name", n});
    }
    if (git_config("user.email").empty()) {
        std::string e = prompt_line("    Enter Git email: ");
        if (!e.empty()) sh::run({"git", "config", "--global", "user.email", e});
    }

    ensure_ssh_key_protected(ctx, gh_user);

    // Upload SSH pubkey if not on GitHub.
    fs::path pub_path = ctx.home / ".ssh/id_ed25519.pub";
    if (fs::exists(pub_path)) {
        std::ifstream pf(pub_path);
        std::string pub_line;
        std::getline(pf, pub_line);
        // Second whitespace-separated field is the base64 key body.
        std::string body;
        {
            std::istringstream ss(pub_line);
            std::string tok;
            ss >> tok >> body;
        }
        std::string keys;
        sh::capture({"gh", "ssh-key", "list"}, keys);
        if (!body.empty() && keys.find(body) == std::string::npos) {
            std::string status;
            sh::capture({"gh", "auth", "status"}, status);
            if (status.find("admin:public_key") == std::string::npos) {
                ui::substep("refreshing gh auth to include admin:public_key scope");
                sh::run({"gh", "auth", "refresh", "-h", "github.com",
                         "-s", "admin:public_key"});
            }
            char hostbuf[256] = {};
            ::gethostname(hostbuf, sizeof(hostbuf) - 1);
            ui::substep("uploading SSH key to GitHub");
            sh::run({"gh", "ssh-key", "add", pub_path.string(),
                     "--title", hostbuf});
        }
    }

    install_github_gpg_signing();

    // ~/code + pre-seeded known_hosts.
    fs::path code_dir = ctx.home / "code";
    fs::create_directories(code_dir);
    fs::path known = ctx.home / ".ssh/known_hosts";
    if (!fs::exists(known) ||
        sh::run({"sh", "-c",
                 "ssh-keygen -F github.com -f " + known.string() +
                 " >/dev/null 2>&1"}) != 0) {
        fs::create_directories(known.parent_path());
        fs::permissions(known.parent_path(), fs::perms::owner_all,
                        fs::perm_options::replace);
        sh::run({"sh", "-c",
                 "ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null "
                 ">> " + known.string()});
        fs::permissions(known,
            fs::perms::owner_read | fs::perms::owner_write,
            fs::perm_options::replace);
    }

    // Clone the user's repos. Use gh's JSON output for name+sshUrl.
    ui::substep("pulling all repositories for " + gh_user);
    std::string repos_json;
    if (!sh::capture({"gh", "repo", "list", gh_user, "--limit", "1000",
                      "--json", "name,sshUrl"}, repos_json)) {
        ui::warn("gh repo list failed — skipping clone loop");
        return;
    }
    json repos;
    try { repos = json::parse(repos_json); }
    catch (const std::exception& e) {
        ui::warn(std::string("gh repo JSON parse failed: ") + e.what());
        return;
    }
    if (!repos.is_array()) { ui::warn("unexpected gh output"); return; }

    size_t cloned = 0, skipped = 0, failed = 0;
    for (auto& r : repos) {
        std::string name    = r.value("name", "");
        std::string ssh_url = r.value("sshUrl", "");
        if (name.empty() || ssh_url.empty()) continue;
        fs::path target = code_dir / name;
        if (fs::is_directory(target)) { ++skipped; continue; }
        ui::substep("↓ cloning " + name);
        int rc = sh::run({"git", "-C", code_dir.string(), "clone",
                          ssh_url, name, "--quiet"});
        if (rc == 0) ++cloned;
        else         ++failed;
    }
    ui::ok("workspace: " + std::to_string(cloned) + " cloned, " +
           std::to_string(skipped) + " already present, " +
           std::to_string(failed) + " failed");
}

}  // namespace fox_install
