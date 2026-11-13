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

namespace desk_install::symlinks {

struct Mapping {
    const char* src;      // relative path under rendered_dir or shared_dir
    const char* dest;     // absolute path with ~ allowed; placeholders expanded later
};

// Rendered (palette-substituted) configs. Skipped entries containing
// AGENT_DIR / FIREFOX_PROFILE are handled by the specials module.
inline constexpr Mapping TEMPLATE_MAPPINGS[] = {
    // Hyprland
    { "hyprland/theme.conf",          "~/.config/hypr/modules/theme.conf" },
    { "hyprland/theme.lua",           "~/.config/hypr/modules/theme.lua" },   // Hyprland 0.57+ (Lua-only)
    { "hyprland/hyprtoolkit.conf",     "~/.config/hypr/hyprtoolkit.conf" },
    { "hyprlock/hyprlock.conf",       "~/.config/hypr/hyprlock.conf" },
    { "hyprlock/capslock-label.sh",   "~/.config/hypr/scripts/capslock-label.sh" },
    { "hyprlock/date-label.sh",       "~/.config/hypr/scripts/date-label.sh" },

    // Neovim
    { "nvim/init.lua",                "~/.config/nvim/init.lua" },
    { "swappy/config",                "~/.config/swappy/config" },

    // Kitty
    { "kitty/kitty.conf",             "~/.config/kitty/kitty.conf" },

    // Waybar — style.css has __SIZE__ tokens; start_waybar.sh substitutes
    // at launch based on monitor scale. Deploy as .tmpl.
    { "waybar/style.css",             "~/.config/waybar/style.css.tmpl" },
    { "waybar/config",                "~/.config/waybar/config.tmpl" },
    { "waybar/config_secondary",      "~/.config/waybar/config_secondary.tmpl" },

    // Tmux
    { "tmux/.tmux.conf",              "~/.tmux.conf" },

    // Zsh
    { "zsh/.zshrc",                   "~/.zshrc" },
    { "zsh/colors.zsh",               "~/.config/zsh/colors.zsh" },
    { "eza/theme.yml",                "~/.config/eza/theme.yml" },
    { "ripgrep/config",               "~/.config/ripgrep/config" },
    { "qt/gtk-palette.json",          "~/.config/foxml/qt-palette.json" },
    { "zsh/fzf-tab.zsh",              "~/.config/zsh/fzf-tab.zsh" },
    { "zsh/welcome.zsh",              "~/.config/zsh/welcome.zsh" },
    { "zsh/caramel.zsh-theme",        "~/.oh-my-zsh/themes/caramel.zsh-theme" },

    // Mako
    { "mako/config",                  "~/.config/mako/config" },

    // Dunst

    // Fastfetch
    { "fastfetch/config.jsonc",       "~/.config/fastfetch/config.jsonc" },

    // Rofi

    // GTK
    { "gtk-3.0/gtk.css",              "~/.config/gtk-3.0/gtk.css" },
    { "gtk-4.0/gtk.css",              "~/.config/gtk-4.0/gtk.css" },
    { "gtk-3.0/settings.ini",         "~/.config/gtk-3.0/settings.ini" },
    { "gtk-4.0/settings.ini",         "~/.config/gtk-4.0/settings.ini" },

    // btop
    { "btop/foxml.theme",             "~/.config/btop/themes/foxml.theme" },

    // Yazi
    { "yazi/theme.toml",              "~/.config/yazi/theme.toml" },
    { "yazi/init.lua",                "~/.config/yazi/init.lua" },

    // Lazygit
    { "lazygit/config.yml",           "~/.config/lazygit/config.yml" },

    // Zathura
    { "zathura/zathurarc",            "~/.config/zathura/zathurarc" },

    // Bat — final filename intentionally has a space.
    { "bat/foxml.tmTheme",            "~/.config/bat/themes/Fox ML.tmTheme" },

    // Hyprland border-color script
    { "hyprland/border_colors.sh",    "~/.config/hypr/modules/border_colors.sh" },

    // OpenCode TUI theme
    { "opencode/foxml.json",          "~/.config/opencode/themes/foxml.json" },

    // Codex CLI syntax theme — select once with /theme; swaps replace its colors.
    { "codex/foxml.tmTheme",          "~/.codex/themes/foxml.tmTheme" },

    // Claude Code theme (custom:foxml) — message box and diff colours; specials selects it once it is here.
    { "claude/foxml-theme.json",      "~/.claude/themes/foxml.json" },
    { "claude/statusline.sh",         "~/.claude/statusline.sh" },
    // The paper mod's palette; its code is in SHARED_MAPPINGS. specials names the folder in CLAUDE_CODE_PLUGIN_DIRS.
    { "claude/mods/foxml-paper/hooks/theme.ts", "~/.claude/mods/foxml-paper/hooks/theme.ts" },

    // pi coding agent TUI theme
    { "pi/foxml.json",                "~/.pi/agent/themes/foxml.json" },

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
    { "nvim_lua/foxml/claude.lua",    "~/.config/nvim/lua/foxml/claude.lua" },
    { "nvim_lua/foxml/review.lua",    "~/.config/nvim/lua/foxml/review.lua" },
    { "nvim_lua/foxml/sync.lua",      "~/.config/nvim/lua/foxml/sync.lua" },
    { "nvim_lua/foxml/menu.lua",      "~/.config/nvim/lua/foxml/menu.lua" },
    { "redzone.json",                 "~/.config/foxml/redzone.json" },
    { "nvim_lua/foxml/work.lua",      "~/.config/nvim/lua/foxml/work.lua" },
    { "nvim_lua/foxml/work_events.lua", "~/.config/nvim/lua/foxml/work_events.lua" },
    { "nvim_lua/foxml/workspace.lua", "~/.config/nvim/lua/foxml/workspace.lua" },
    { "nvim_lua/foxml/build.lua", "~/.config/nvim/lua/foxml/build.lua" },
    { "nvim_lua/foxml/planmarks.lua", "~/.config/nvim/lua/foxml/planmarks.lua" },

    // Rofi config

    // Zsh non-color
    { "zsh_aliases.zsh",              "~/.config/zsh/aliases.zsh" },
    { "zsh_git.zsh",                  "~/.config/zsh/git.zsh" },
    { "zsh_paths.zsh",                "~/.config/zsh/paths.zsh" },
    { "zsh_conda.zsh",                "~/.config/zsh/conda.zsh" },
    { "zsh_history_scrub.zsh",        "~/.config/zsh/history-scrub.zsh" },
    { "zsh_work.zsh",                 "~/.config/zsh/work.zsh" },

    // User-facing fox-* shell wrappers. Compiled tools (ai-swap, fask, findex, …)
    // are NOT shipped here: `make install` (install.sh) builds them from src/ — a copied
    // binary would land after it and overwrite the fresh build with a stale one.
    { "bin/desk-aider",                "~/.local/bin/desk-aider" },
    { "bin/desk-wallpaper",           "~/.local/bin/desk-wallpaper" },
    { "bin/ai-status",            "~/.local/bin/ai-status" },
    { "bin/ai-commit",            "~/.local/bin/ai-commit" },
    { "bin/ai-purge",             "~/.local/bin/ai-purge" },
    { "bin/ai-log",               "~/.local/bin/ai-log" },
    { "bin/ai-quick",             "~/.local/bin/ai-quick" },
    { "bin/ai-find",              "~/.local/bin/ai-find" },
    { "bin/ai-bench",             "~/.local/bin/ai-bench" },
    { "bin/new-project",          "~/.local/bin/new-project" },
    { "bin/distro-guide",         "~/.local/bin/distro-guide" },
    { "bin/pi",                       "~/.local/bin/pi" },
    { "bin/distro-build",         "~/.local/bin/distro-build" },
    { "bin/distro-flash",         "~/.local/bin/distro-flash" },
    { "bin/fhelp",                    "~/.local/bin/fhelp" },

    // Local-LLM stack: daily refresh/sync + discovery, one shared model list,
    // pi extensions (permission gate, notifications, per-project skills).
    { "bin/llm-update",           "~/.local/bin/llm-update" },
    { "bin/llm-discover",         "~/.local/bin/llm-discover" },
    { "bin/llm-serve",            "~/.local/bin/llm-serve" },
    { "bin/llm-run",              "~/.local/bin/llm-run" },
    { "bin/llm-grade",            "~/.local/bin/llm-grade" },
    { "llm/roles.default",            "~/.config/foxml/llm/roles.default" },
    { "llm/core-models.txt",          "~/.config/foxml/llm/core-models.txt" },
    { "pi/extensions/fox-guard.ts",   "~/.pi/agent/extensions/fox-guard.ts" },
    { "pi/extensions/fox-notify.ts",  "~/.pi/agent/extensions/fox-notify.ts" },
    { "pi/extensions/foxml/build.ts", "~/.pi/agent/extensions/foxml/build.ts" },
    { "pi/extensions/claude-skills.ts","~/.pi/agent/extensions/claude-skills.ts" },
    { "pi/extensions/fox-trim.ts",    "~/.pi/agent/extensions/fox-trim.ts" },
    { "pi/extensions/fox-budget.ts",  "~/.pi/agent/extensions/fox-budget.ts" },
    { "pi/extensions/fox-credits.ts", "~/.pi/agent/extensions/fox-credits.ts" },
    { "pi/extensions/fox-scope.ts",   "~/.pi/agent/extensions/fox-scope.ts" },
    { "bin/word-count",           "~/.local/bin/word-count" },
    { "bin/pob",                      "~/.local/bin/pob" },

    // Claude Code paper mod: notebook pane, red-zone band, toasts, spinner words (templates/ renders its theme.ts).
    { "claude/mods/foxml-paper/.claude-plugin/plugin.json", "~/.claude/mods/foxml-paper/.claude-plugin/plugin.json" },
    { "claude/mods/foxml-paper/hooks/hooks.json",   "~/.claude/mods/foxml-paper/hooks/hooks.json" },
    { "claude/mods/foxml-paper/hooks/register.tsx", "~/.claude/mods/foxml-paper/hooks/register.tsx" },
    { "claude/mods/foxml-paper/hooks/build.ts", "~/.claude/mods/foxml-paper/hooks/build.ts" },
    { "claude/mods/foxml-paper/hooks/ledger.ts",    "~/.claude/mods/foxml-paper/hooks/ledger.ts" },
    { "claude/mods/foxml-paper/hooks/work.ts",      "~/.claude/mods/foxml-paper/hooks/work.ts" },
    { "claude/mods/foxml-paper/hooks/notebook.ts",  "~/.claude/mods/foxml-paper/hooks/notebook.ts" },
    { "claude/mods/foxml-paper/types/index.d.ts",   "~/.claude/mods/foxml-paper/types/index.d.ts" },
    // /goodnight: a where-we-left-off note, what is uncommitted, then the goodnight Power page.
    { "claude/commands/goodnight.md",               "~/.claude/commands/goodnight.md" },

    // Distro profile
    { "foxml-profile.json",           "~/.local/share/foxml/distro/foxml-profile.json" },

};

constexpr std::size_t TEMPLATE_MAPPINGS_COUNT =
    sizeof(TEMPLATE_MAPPINGS) / sizeof(TEMPLATE_MAPPINGS[0]);
constexpr std::size_t SHARED_MAPPINGS_COUNT =
    sizeof(SHARED_MAPPINGS) / sizeof(SHARED_MAPPINGS[0]);

}  // namespace desk_install::symlinks

#endif
