// modules/deps.cpp — base package install.
//
// Mirrors install.sh's PACMAN_PKGS list (the base set; per-module deps
// like fail2ban/audit/lynis live in their own modules and get added
// when that module is enabled). Idempotent under `pacman --needed`.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

// pacman_conf_ensure_uncomment — uncomment the [multilib] block in
// /etc/pacman.conf. Mirrors bash:
//   sed -i '/#\[multilib\]/,/#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//'
// Returns true on a state change (file was edited).
bool enable_multilib() {
    if (sh::run({"sh", "-c", "grep -q '^\\[multilib\\]' /etc/pacman.conf"}) == 0) {
        return false;        // already enabled
    }
    int rc = sh::run({"sudo", "sed", "-i",
        "/#\\[multilib\\]/,/#Include = \\/etc\\/pacman.d\\/mirrorlist/ s/^#//",
        "/etc/pacman.conf"});
    if (rc != 0) return false;
    // After enable, refresh pacman's package db so the new repo's
    // packages become resolvable.
    sh::run({"sudo", "pacman", "-Sy"});
    return true;
}

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
    // Run BEFORE the package install so the [multilib] repo is
    // queryable when we try to pull `steam`, and so ParallelDownloads
    // speeds up the rest of this module's pacman call.
    if (!sh::dry_run()) {
        if (enable_parallel_downloads()) {
            ui::ok("ParallelDownloads enabled in /etc/pacman.conf");
        }
        if (enable_multilib()) {
            ui::ok("[multilib] enabled in /etc/pacman.conf (Steam install ready)");
        }
    }

    // Grouped by purpose so future contributors can find the right
    // bucket. pacman --needed makes order and duplicates safe.
    const std::vector<std::string> pkgs = {
        // Fonts
        "ttf-hack-nerd", "ttf-jetbrains-mono-nerd",
        "noto-fonts", "noto-fonts-cjk", "noto-fonts-emoji",

        // Compositor, lock, wallpaper, idle
        "hyprland", "hyprlock", "awww", "hypridle", "hyprpolkitagent",
        // Themed login
        "greetd", "greetd-regreet",

        // Secrets / keyring
        "gnome-keyring", "libsecret", "seahorse", "gnupg",

        // Editor / terminal / multiplexer
        "neovim", "kitty", "tmux",

        // Neovim runtime deps (Copilot LSP, Mason, tree-sitter latex grammar)
        "nodejs", "npm", "tree-sitter-cli",

        // Bar, launcher, notifications
        "waybar", "rofi-wayland", "mako", "dunst",

        // Build tools
        "cmake", "base-devel",

        // CLI tools
        "zsh", "fzf", "eza", "bat", "yazi", "btop", "fd", "zoxide",
        "jq", "git-delta", "github-cli", "pacman-contrib",
        "rofi-calc", "rofi-emoji", "lazygit", "ncspot", "cliphist",
        "cloc", "tree", "rsync", "shellcheck", "ripgrep",

        // Networking, audio, power telemetry
        "networkmanager", "wireplumber", "libnotify", "upower", "lm_sensors",

        // misc utilities install.sh's later sections rely on
        "unzip",
        "grim", "slurp", "wl-clipboard", "playerctl", "brightnessctl",
        "pavucontrol", "wlsunset", "swappy",

        // Bluetooth
        "bluez", "bluez-utils", "blueman",

        // Fingerprint
        "fprintd",

        // Apps + viewers
        "firefox", "zathura", "zathura-pdf-mupdf", "xdg-utils", "thunar", "steam",

        // Runtime libs commonly pulled by AUR/proprietary packages
        "libutf8proc", "xsimd",

        // Tools
        "hyprpicker", "imagemagick",

        // socat → Hyprland socket2 streaming for legacy bash watchers
        "socat",

        // Power profile switcher
        "power-profiles-daemon", "python-gobject",

        // ufw is always installed; the install_ufw_baseline equivalent
        // lives in the security module but the package is needed even
        // when --secure isn't passed (default-deny inbound).
        "ufw",
    };

    int rc = sh::pacman(pkgs);
    if (rc != 0) {
        // Most common failure mode: a single package has an unresolvable
        // dep (libtree-sitter ABI skew on neovim, etc.) and pacman
        // aborts the ENTIRE --needed transaction, so packages that
        // would've installed fine get skipped along with it. Auto-
        // recover: run a full system upgrade (pulls newer co-deps),
        // then retry the original batch. If THAT still fails, fall
        // back to per-package installs so at least the ones with no
        // conflicts land.
        ui::warn("pacman batch failed — running `sudo pacman -Syu` to refresh deps, then retrying");
        if (sh::run({"sudo", "pacman", "-Syu", "--noconfirm"}) == 0) {
            rc = sh::pacman(pkgs);
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
        // ollama-bin, opencode-bin) AUR-install. Bootstrap yay first
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
        // Prefer the signature-verified AUR install (oh-my-zsh-git);
        // fall back to upstream curl-sh only if no AUR helper present.
        // Without OMZ, the deployed .zshrc + caramel theme + plugin
        // list error out on first shell open.
        fs::path omz_dir = ctx.home / ".oh-my-zsh";
        if (!fs::is_directory(omz_dir)) {
            ui::substep("installing Oh My Zsh");
            std::string aur;
            if      (have_cmd("yay"))  aur = "yay";
            else if (have_cmd("paru")) aur = "paru";
            bool installed = false;
            if (!aur.empty()) {
                installed = sh::run({aur, "-S", "--needed", "--noconfirm",
                                     "oh-my-zsh-git"}) == 0;
            }
            if (!installed) {
                installed = sh::run({"sh", "-c",
                    "sh -c \"$(curl -fsSL "
                    "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
                    " '' --unattended"}) == 0;
            }
            if (installed) ui::ok("Oh My Zsh installed");
            else           ui::warn("Oh My Zsh install failed — zsh_plugins will skip");
        }

        // ─── NPM globals (Gemini + Claude CLIs) ────────────────────
        // Idempotent: only installs ones missing from PATH.
        if (have_cmd("npm")) {
            std::vector<std::string> npm_globals;
            if (!have_cmd("gemini")) npm_globals.push_back("@google/gemini-cli");
            if (!have_cmd("claude")) npm_globals.push_back("@anthropic-ai/claude-code");
            if (!npm_globals.empty()) {
                ui::substep("installing CLI tools (npm -g): " +
                            (npm_globals.size() == 1 ? npm_globals[0] :
                             npm_globals[0] + " + " + npm_globals[1]));
                std::vector<std::string> argv = {"sudo", "npm", "install", "-g"};
                for (auto& g : npm_globals) argv.push_back(g);
                if (sh::run(argv) == 0) {
                    ui::ok("Gemini CLI + Claude Code ready");
                } else {
                    ui::warn("npm install failed — see output above");
                }
            }
        }
    }
}

}  // namespace fox_install
