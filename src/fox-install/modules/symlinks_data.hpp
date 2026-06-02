#ifndef FOX_INSTALL_MODULES_SYMLINKS_DATA_HPP
#define FOX_INSTALL_MODULES_SYMLINKS_DATA_HPP

// Source-of-truth deploy tables for `--symlinks`.
//
// Adding a new file to deploy:
//   1. Drop it under templates/<subdir>/ (template, will be palette-substituted)
//      OR shared/<path>  (literal copy, no rendering).
//   2. Add one entry below: { "relative/source/path", "~/dest/path" }.
//      Tilde is expanded to $HOME at deploy time. Special placeholders
//      AGENT_DIR and FIREFOX_PROFILE are skipped here — `modules/specials.cpp`
//      resolves them.
//
// Mirrors mappings.sh's TEMPLATE_MAPPINGS + SHARED_MAPPINGS verbatim.

namespace fox_install::symlinks {

struct Mapping {
    const char* src;      // relative path under rendered_dir or shared_dir
    const char* dest;     // absolute path with ~ allowed; placeholders expanded later
};

// Rendered (palette-substituted) configs. Skipped entries containing
// AGENT_DIR / FIREFOX_PROFILE are handled by the specials module.
inline constexpr Mapping TEMPLATE_MAPPINGS[] = {
    // Hyprland
    { "hyprland/theme.conf",          "~/.config/hypr/modules/theme.conf" },
    { "hyprlock/hyprlock.conf",       "~/.config/hypr/hyprlock.conf" },

    // Neovim
    { "nvim/init.lua",                "~/.config/nvim/init.lua" },

    // Kitty
    { "kitty/kitty.conf",             "~/.config/kitty/kitty.conf" },

    // Waybar — style.css has __SIZE__ tokens; start_waybar.sh substitutes
    // at launch based on monitor scale. Deploy as .tmpl.
    { "waybar/style.css",             "~/.config/waybar/style.css.tmpl" },

    // Tmux
    { "tmux/.tmux.conf",              "~/.tmux.conf" },

    // Zsh
    { "zsh/.zshrc",                   "~/.zshrc" },
    { "zsh/colors.zsh",               "~/.config/zsh/colors.zsh" },
    { "zsh/welcome.zsh",              "~/.config/zsh/welcome.zsh" },
    { "zsh/caramel.zsh-theme",        "~/.oh-my-zsh/themes/caramel.zsh-theme" },

    // Mako
    { "mako/config",                  "~/.config/mako/config" },

    // Dunst
    { "dunst/dunstrc",                "~/.config/dunst/dunstrc" },

    // Fastfetch
    { "fastfetch/config.jsonc",       "~/.config/fastfetch/config.jsonc" },

    // Rofi
    { "rofi/glass.rasi",              "~/.config/rofi/glass.rasi" },

    // GTK
    { "gtk-3.0/gtk.css",              "~/.config/gtk-3.0/gtk.css" },
    { "gtk-4.0/gtk.css",              "~/.config/gtk-4.0/gtk.css" },

    // btop
    { "btop/foxml.theme",             "~/.config/btop/themes/foxml.theme" },

    // Yazi
    { "yazi/theme.toml",              "~/.config/yazi/theme.toml" },

    // Lazygit
    { "lazygit/config.yml",           "~/.config/lazygit/config.yml" },

    // Zathura
    { "zathura/zathurarc",            "~/.config/zathura/zathurarc" },

    // Bat — final filename intentionally has a space.
    { "bat/foxml.tmTheme",            "~/.config/bat/themes/Fox ML.tmTheme" },

    // Hyprland border-color script
    { "hyprland/border_colors.sh",    "~/.config/hypr/modules/border_colors.sh" },

    // AI Agent — AGENT_DIR placeholder, handled by specials.
    { "gemini/settings.json",         "AGENT_DIR/settings.json" },

    // OpenCode TUI theme
    { "opencode/foxml.json",          "~/.config/opencode/themes/foxml.json" },

    // Git delta pager — included from ~/.gitconfig
    { "git/delta.gitconfig",          "~/.config/git/delta-foxml.gitconfig" },

    // FoxML Shared ANSI colors (for C++ CLI tools)
    { "foxml/ansi_colors.json",       "~/.config/foxml/ansi_colors.json" },

    // Cursor / VS Code
    { "cursor/foxml-color-theme.json","~/.cursor/extensions/foxml-theme/themes/foxml-color-theme.json" },

    // Firefox — FIREFOX_PROFILE placeholder, handled by specials.
    { "firefox/userChrome.css",       "FIREFOX_PROFILE/chrome/userChrome.css" },
    { "firefox/userContent.css",      "FIREFOX_PROFILE/chrome/userContent.css" },
};

// Shared (non-templated) files. Some entries are directories — see the
// nvim_ftplugin case; symlinks::run handles dir-typed source with a
// recursive copy.
inline constexpr Mapping SHARED_MAPPINGS[] = {
    // Hyprland
    { "hyprland.conf",                "~/.config/hypr/hyprland.conf" },
    { "hyprland_hypridle_ac.conf",    "~/.config/hypr/hypridle-ac.conf" },
    { "hyprland_hypridle_battery.conf","~/.config/hypr/hypridle-battery.conf" },

    // Launcher toggle scripts (referenced by keybinds.conf)
    { "launchers/toggle/toggle_btop.sh","~/.config/launchers/toggle/toggle_btop.sh" },
    { "launchers/toggle/toggle_yazi.sh","~/.config/launchers/toggle/toggle_yazi.sh" },

    // Neovim
    { "nvim_lazy-lock.json",          "~/.config/nvim/lazy-lock.json" },
    { "nvim_ftplugin/cpp.lua",        "~/.config/nvim/ftplugin/cpp.lua" },

    // Rofi config
    { "rofi_config.rasi",             "~/.config/rofi/config.rasi" },

    // GTK settings
    { "gtk-3.0_settings.ini",         "~/.config/gtk-3.0/settings.ini" },
    { "gtk-4.0_settings.ini",         "~/.config/gtk-4.0/settings.ini" },

    // Zsh non-color
    { "zsh_aliases.zsh",              "~/.config/zsh/aliases.zsh" },
    { "zsh_git.zsh",                  "~/.config/zsh/git.zsh" },
    { "zsh_paths.zsh",                "~/.config/zsh/paths.zsh" },
    { "zsh_conda.zsh",                "~/.config/zsh/conda.zsh" },
    { "zsh_history_scrub.zsh",        "~/.config/zsh/history-scrub.zsh" },

    // User-facing fox-* shell wrappers
    { "bin/fox-aider",                "~/.local/bin/fox-aider" },
    { "bin/fox-ai-swap",              "~/.local/bin/fox-ai-swap" },
    { "bin/fox-wallpaper",           "~/.local/bin/fox-wallpaper" },
    { "bin/fox-ai-status",            "~/.local/bin/fox-ai-status" },
    { "bin/fox-ai-commit",            "~/.local/bin/fox-ai-commit" },
    { "bin/fox-ai-purge",             "~/.local/bin/fox-ai-purge" },
    { "bin/fox-ai-log",               "~/.local/bin/fox-ai-log" },
    { "bin/fox-ai-quick",             "~/.local/bin/fox-ai-quick" },
    { "bin/fox-ai-find",              "~/.local/bin/fox-ai-find" },
    { "bin/fox-ai-bench",             "~/.local/bin/fox-ai-bench" },
    { "bin/fox-new-project",          "~/.local/bin/fox-new-project" },
    { "bin/fox-distro-guide",         "~/.local/bin/fox-distro-guide" },
    { "bin/fox-distro-build",         "~/.local/bin/fox-distro-build" },
    { "bin/fox-distro-flash",         "~/.local/bin/fox-distro-flash" },
    { "bin/findex",                   "~/.local/bin/findex" },
    { "bin/fask",                     "~/.local/bin/fask" },
    { "bin/fhelp",                    "~/.local/bin/fhelp" },

    // Distro profile
    { "foxml-profile.json",           "~/.local/share/foxml/distro/foxml-profile.json" },

    // Waybar config templates (runtime-finalised by start_waybar.sh)
    { "waybar_config",                "~/.config/waybar/config.tmpl" },
    { "waybar_config_secondary",      "~/.config/waybar/config_secondary.tmpl" },
};

constexpr std::size_t TEMPLATE_MAPPINGS_COUNT =
    sizeof(TEMPLATE_MAPPINGS) / sizeof(TEMPLATE_MAPPINGS[0]);
constexpr std::size_t SHARED_MAPPINGS_COUNT =
    sizeof(SHARED_MAPPINGS) / sizeof(SHARED_MAPPINGS[0]);

}  // namespace fox_install::symlinks

#endif
