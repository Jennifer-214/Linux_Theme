// core/deps_list.hpp — the base package set run_deps installs, shared with state::check_deps so the state check
// sees every package the module would install (installer audit 2026-10-15: it checked five sentinels, so --full never
// installed packages added to this list later).
#pragma once

#include <string>
#include <vector>

namespace fox_install {

// Grouped by purpose so future contributors can find the right bucket. pacman --needed makes order and duplicates
// safe.
inline const std::vector<std::string>& deps_packages() {
    static const std::vector<std::string> pkgs = {
        // Fonts
        "otf-monaspace-nerd", "ttf-hack-nerd", "ttf-jetbrains-mono-nerd",
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
        "waybar", "rofi", "mako", "dunst",   // rofi-wayland was merged into rofi

        // Build tools
        "cmake", "base-devel",

        // C/C++ intelligence (fox-symdeps.nvim): clangd + clang-format, a compile DB
        // for Make projects (bear), the plugin's python adapters (yaml), and
        // perf — `perf c2c` feeds the plugin's measured false-sharing marks.
        // capstone + its python bindings decode machine code into structured operands
        // (spills and branches read as fields, never parsed out of objdump's text), and
        // python-pyelftools reads the compiler's own debug info (DWARF) as data.
        "clang", "bear", "python-yaml", "perf",
        "capstone", "python-capstone", "python-pyelftools",

        // Called by the shipped fox-* commands and scripts, otherwise only ever
        // present by accident of another package's deps: ssh / ssh-keygen (the
        // github module, fox-spa), lsusb (fox-usb), bwrap (fox-sandbox), pass
        // (fox vault), fwknop + qrencode (fox-spa), pactl (waybar battery),
        // python3 (fox-llm-*, findex helpers), less (fox-sandbox pager).
        "openssh", "usbutils", "bubblewrap", "pass", "fwknop", "qrencode",
        "libpulse", "python", "less",

        // CLI tools
        "zsh", "fzf", "eza", "bat", "yazi", "btop", "fd", "zoxide",
        "jq", "git-delta", "github-cli", "pacman-contrib",
        "rofi-calc", "rofi-emoji", "lazygit", "ncspot", "cliphist",
        "cloc", "tree", "rsync", "shellcheck", "ripgrep",
        // reviewing changes, agents' included: difftastic diffs by syntax (GIT_EXTERNAL_DIFF=difft git diff —
        // git ships no difftastic difftool), git-absorb folds fixups into the commits they belong to
        "difftastic", "git-absorb",

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
        "firefox", "zathura", "zathura-pdf-mupdf", "xdg-utils", "thunar",

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
    return pkgs;
}

}  // namespace fox_install
