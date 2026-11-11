// modules/deps.cpp — base package install.
//
// Mirrors install.sh's PACMAN_PKGS list (the base set; per-module deps
// like fail2ban/audit/lynis live in their own modules and get added
// when that module is enabled). Idempotent under `pacman --needed`.

#include "../core/deps_list.hpp"
#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"

#include <pwd.h>
#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

// ParallelDownloads in /etc/pacman.conf for faster pacman fetches.
// Bash mostly assumed Arch's stock 5 was fine; we ensure it's >= 5
// (uncomment if commented out, leave alone if already set).
bool enable_parallel_downloads() {
    // Already a non-commented ParallelDownloads line?
    if (sh::run({"sh", "-c",
                 "grep -qE '^ParallelDownloads' /etc/pacman.conf"}) == 0) {
        return false;
    }
    // Commented version present? Uncomment it.
    if (sh::run({"sh", "-c",
                 "grep -qE '^#ParallelDownloads' /etc/pacman.conf"}) == 0) {
        sh::run({"sudo", "sed", "-i",
                 "s/^#ParallelDownloads/ParallelDownloads/",
                 "/etc/pacman.conf"});
        return true;
    }
    // Neither — append a line in the [options] section.
    // idempotent: only reached when neither ^ParallelDownloads nor
    // ^#ParallelDownloads matched above — guarded, so the append fires once.
    sh::run({"sh", "-c",
             "sudo sed -i '/^\\[options\\]/a ParallelDownloads = 5' "
             "/etc/pacman.conf"});
    return true;
}

void run_deps(Context& ctx) {
    (void)ctx;
    ui::section("Installing base packages");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold and no TTY — run `sudo -v` first");
        return;
    }

    // ─── pacman.conf prep ─────────────────────────────────────────
    // ParallelDownloads speeds up this module's pacman call. (The
    // [multilib] repo + Steam moved to the opt-in `gaming` module so the
    // base install no longer force-enables a 32-bit repo.)
    if (!sh::dry_run()) {
        if (enable_parallel_downloads()) {
            ui::ok("ParallelDownloads enabled in /etc/pacman.conf");
        }
    }

    const std::vector<std::string>& pkgs = deps_packages();

    // Sync and upgrade first. Installing against the package list the machine last synced asks for versions the mirrors
    // have since replaced (a week-old Arch install gets a wall of 404s), and -Sy without -u is a partial upgrade.
    ui::substep("Updating the system first (pacman -Syu), so packages come from today's mirrors");
    const bool synced = sh::run({"sudo", "pacman", "-Syu", "--noconfirm"}) == 0;
    if (!synced) ui::warn("pacman -Syu failed — installing anyway");

    int rc = sh::pacman(pkgs);
    if (rc != 0) {
        // Most common failure mode: a single package has an unresolvable
        // dep (libtree-sitter ABI skew on neovim, etc.) and pacman
        // aborts the ENTIRE --needed transaction, so packages that
        // would've installed fine get skipped along with it. Auto-
        // recover: run a full system upgrade (pulls newer co-deps) if the
        // one above failed, then retry the original batch. If THAT still
        // fails, fall back to per-package installs so at least the ones
        // with no conflicts land.
        if (!synced) {
            ui::warn("pacman batch failed — running `sudo pacman -Syu` again, then retrying");
            if (sh::run({"sudo", "pacman", "-Syu", "--noconfirm"}) == 0) rc = sh::pacman(pkgs);
        }
        if (rc != 0) {
            ui::warn("batch still failing — falling back to per-package install");
            int fallback_ok = 0, fallback_skipped = 0;
            for (const auto& p : pkgs) {
                if (sh::run({"sudo", "pacman", "-S", "--needed", "--noconfirm", p}) == 0) {
                    ++fallback_ok;
                } else {
                    ++fallback_skipped;
                }
            }
            ui::ok(std::to_string(fallback_ok) + " packages installed individually, " +
                   std::to_string(fallback_skipped) + " skipped (re-run after manual fix)");
        } else {
            ui::ok(std::to_string(pkgs.size()) + " base packages ensured (after -Syu)");
        }
    } else {
        ui::ok(std::to_string(pkgs.size()) + " base packages ensured");
    }

    // ─── Post-install hooks ───────────────────────────────────────
    // Things bash did in the same --deps section: enable bluez,
    // power-profiles-daemon, point xdg-open at Firefox. Each is a
    // small command and idempotent — re-runs are cheap no-ops.

    if (!sh::dry_run()) {
        // Default web browser → Firefox (so CLI auth flows like
        // gcloud / gh / oauth helpers actually spawn a browser).
        if (sh::have("xdg-settings")
            && std::ifstream("/usr/share/applications/firefox.desktop")) {
            if (sh::run({"xdg-settings", "set", "default-web-browser",
                         "firefox.desktop"}) == 0) {
                ui::ok("default browser set to Firefox");
            }
        }

        auto enable_if_installed = [](const std::string& pkg,
                                       const std::string& unit,
                                       const std::string& label) {
            if (sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) != 0) return;
            if (sh::run({"systemctl", "is-active", "--quiet", unit}) == 0) return;
            if (sh::run({"sh", "-c",
                         "sudo systemctl enable --now " + unit + " >/dev/null 2>&1"}) == 0) {
                ui::ok(label + " enabled");
            }
        };
        enable_if_installed("power-profiles-daemon", "power-profiles-daemon",
                            "power-profiles-daemon");
        enable_if_installed("bluez", "bluetooth", "bluetooth service");

        // ─── AUR helper (yay) ──────────────────────────────────────
        // Several downstream modules (endlessh, throttled, apparmor.d,
        // opencode-bin, aider-chat) AUR-install. Bootstrap yay first
        // so those don't all error with "no AUR helper". `paru`
        // works equally well — only install yay if neither is present.
        auto have_cmd = [](const std::string& bin) { return sh::have(bin); };
        if (!have_cmd("yay") && !have_cmd("paru")) {
            ui::substep("installing yay (AUR helper)");
            std::string yay_dir = "/tmp/foxin-yay-build";
            sh::run({"rm", "-rf", yay_dir});
            int rc_clone = sh::run({"git", "clone", "--quiet",
                                    "https://aur.archlinux.org/yay-bin.git", yay_dir});
            if (rc_clone == 0) {
                if (sh::run({"sh", "-c",
                             "cd " + yay_dir + " && makepkg -si --noconfirm"}) == 0) {
                    ui::ok("yay installed (AUR access ready)");
                } else {
                    ui::warn("yay makepkg failed — AUR-dependent modules will skip");
                }
                sh::run({"rm", "-rf", yay_dir});
            } else {
                ui::warn("yay clone failed — AUR-dependent modules will skip");
            }
        }

        // ─── Oh My Zsh ─────────────────────────────────────────────
        // A plain clone into the path .zshrc, the caramel theme and zsh_plugins all use. The AUR
        // package lands in /usr/share, and the upstream script edits .zshrc and the login shell.
        fs::path omz_dir = ctx.home / ".oh-my-zsh";
        if (!fs::is_directory(omz_dir)) {
            ui::substep("installing Oh My Zsh");
            if (sh::run({"git", "clone", "--depth", "1", "https://github.com/ohmyzsh/ohmyzsh.git",
                         omz_dir.string()}) == 0) ui::ok("Oh My Zsh installed");
            else ui::warn("Oh My Zsh install failed — zsh_plugins will skip");
        }

        // ─── Login shell ───────────────────────────────────────────
        // The theme's prompt, aliases and tools all live in zsh. Failing here costs a shell, never a login.
        if (const passwd* pw = ::getpwuid(::getuid());
            pw && fs::exists("/usr/bin/zsh") && fs::path(pw->pw_shell).filename() != "zsh") {
            if (sh::run({"sudo", "chsh", "-s", "/usr/bin/zsh", pw->pw_name}) == 0)
                ui::ok("login shell → zsh (from the next login)");
            else
                ui::warn("could not change the login shell — run `chsh -s /usr/bin/zsh`");
        }

        // ─── NPM globals (Claude CLI, pi coding agent) ───────────
        // Idempotent: only installs ones missing from PATH. pi is the local-model
        // agent; its config comes from `llm-update --sync` (opencode module).
        if (have_cmd("npm")) {
            std::vector<std::string> npm_globals;
            if (!have_cmd("claude")) npm_globals.push_back("@anthropic-ai/claude-code");
            if (!have_cmd("pi"))     npm_globals.push_back("@earendil-works/pi-coding-agent");  // the old @mariozechner name stops at 0.73.1
            if (!npm_globals.empty()) {
                std::string names;
                for (auto& g : npm_globals) names += (names.empty() ? "" : " + ") + g;
                ui::substep("installing CLI tools (npm -g): " + names);
                std::vector<std::string> argv = {"sudo", "npm", "install", "-g"};
                for (auto& g : npm_globals) argv.push_back(g);
                if (sh::run(argv) == 0) {
                    ui::ok("CLI tools ready: " + names);
                } else {
                    ui::warn("npm install failed — see output above");
                }
            }
        }
    }
}

}  // namespace fox_install
