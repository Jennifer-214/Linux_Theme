#!/bin/bash
# FoxML Theme Hub — source → destination mappings
# Format: "relative-path|system-destination"
# ~ is expanded at runtime

# ─────────────────────────────────────────
# Template files (rendered with palette colors)
# Source: templates/ directory
# ─────────────────────────────────────────
TEMPLATE_MAPPINGS=(
    # Hyprland
    "hyprland/theme.conf|~/.config/hypr/modules/theme.conf"
    "hyprlock/hyprlock.conf|~/.config/hypr/hyprlock.conf"

    # Neovim
    "nvim/init.lua|~/.config/nvim/init.lua"

    # Kitty
    "kitty/kitty.conf|~/.config/kitty/kitty.conf"

    # Waybar — style.css carries __SIZE__ tokens that start_waybar.sh
    # substitutes at runtime based on detected monitor scale, so we deploy
    # it as .tmpl. The wrapper writes the live style.css on first launch.
    "waybar/style.css|~/.config/waybar/style.css.tmpl"

    # Tmux
    "tmux/.tmux.conf|~/.tmux.conf"

    # Zsh
    "zsh/.zshrc|~/.zshrc"
    "zsh/colors.zsh|~/.config/zsh/colors.zsh"
    "zsh/welcome.zsh|~/.config/zsh/welcome.zsh"
    "zsh/caramel.zsh-theme|~/.oh-my-zsh/themes/caramel.zsh-theme"

    # ReGreet (login screen — needs sudo to install to /etc/greetd/)
    # "regreet/regreet.css|/etc/greetd/regreet.css"

    # Mako
    "mako/config|~/.config/mako/config"

    # Dunst
    "dunst/dunstrc|~/.config/dunst/dunstrc"

    # Fastfetch
    "fastfetch/config.jsonc|~/.config/fastfetch/config.jsonc"

    # Rofi
    "rofi/glass.rasi|~/.config/rofi/glass.rasi"

    # GTK
    "gtk-3.0/gtk.css|~/.config/gtk-3.0/gtk.css"
    "gtk-4.0/gtk.css|~/.config/gtk-4.0/gtk.css"

    # btop
    "btop/foxml.theme|~/.config/btop/themes/foxml.theme"

    # Yazi
    "yazi/theme.toml|~/.config/yazi/theme.toml"

    # Lazygit
    "lazygit/config.yml|~/.config/lazygit/config.yml"

    # Zathura
    "zathura/zathurarc|~/.config/zathura/zathurarc"

    # Eww

    # Bat
    "bat/foxml.tmTheme|~/.config/bat/themes/Fox ML.tmTheme"

    # Border colors for scripts
    "hyprland/border_colors.sh|~/.config/hypr/modules/border_colors.sh"

    # AI Agent — AGENT_DIR placeholder is resolved by the special handler,
    # which jq-merges into the user's settings.json to preserve security.auth.
    "gemini/settings.json|AGENT_DIR/settings.json"

    # OpenCode TUI theme — palette-driven; deploy as a custom theme that
    # opencode.json references via "theme": "foxml".
    "opencode/foxml.json|~/.config/opencode/themes/foxml.json"

    # Git (delta pager — included from ~/.gitconfig, doesn't touch user identity)
    "git/delta.gitconfig|~/.config/git/delta-foxml.gitconfig"

    # FoxML Shared ANSI colors (for C++ CLI tools)
    "foxml/ansi_colors.json|~/.config/foxml/ansi_colors.json"

    # Cursor/VS Code
    "cursor/foxml-color-theme.json|~/.cursor/extensions/foxml-theme/themes/foxml-color-theme.json"

    # Firefox
    "firefox/userChrome.css|FIREFOX_PROFILE/chrome/userChrome.css"
    "firefox/userContent.css|FIREFOX_PROFILE/chrome/userContent.css"
)

# ─────────────────────────────────────────
# Shared files (copied as-is, no rendering)
# Source: shared/ directory, with _ replacing /
# ─────────────────────────────────────────
SHARED_MAPPINGS=(
    # Hyprland
    "hyprland.conf|~/.config/hypr/hyprland.conf"
    "hyprland_hypridle_ac.conf|~/.config/hypr/hypridle-ac.conf"
    "hyprland_hypridle_battery.conf|~/.config/hypr/hypridle-battery.conf"

    # Launcher toggle scripts (referenced by keybinds.conf)
    "launchers/toggle/toggle_btop.sh|~/.config/launchers/toggle/toggle_btop.sh"
    "launchers/toggle/toggle_yazi.sh|~/.config/launchers/toggle/toggle_yazi.sh"

    # Neovim
    "nvim_lazy-lock.json|~/.config/nvim/lazy-lock.json"
    "nvim_ftplugin/cpp.lua|~/.config/nvim/ftplugin/cpp.lua"

    # Rofi config
    "rofi_config.rasi|~/.config/rofi/config.rasi"

    # GTK settings
    "gtk-3.0_settings.ini|~/.config/gtk-3.0/settings.ini"
    "gtk-4.0_settings.ini|~/.config/gtk-4.0/settings.ini"

    # Zsh non-color
    "zsh_aliases.zsh|~/.config/zsh/aliases.zsh"
    "zsh_git.zsh|~/.config/zsh/git.zsh"
    "zsh_paths.zsh|~/.config/zsh/paths.zsh"
    "zsh_conda.zsh|~/.config/zsh/conda.zsh"
    "zsh_history_scrub.zsh|~/.config/zsh/history-scrub.zsh"
    "bin/fox-aider|~/.local/bin/fox-aider"
    "bin/fox-ai-swap|~/.local/bin/fox-ai-swap"
    "bin/fox-wallpaper|~/.local/bin/fox-wallpaper"
    "bin/fox-ai-status|~/.local/bin/fox-ai-status"
    "bin/fox-ai-commit|~/.local/bin/fox-ai-commit"
    "bin/fox-ai-purge|~/.local/bin/fox-ai-purge"
    "bin/fox-ai-log|~/.local/bin/fox-ai-log"
    "bin/fox-ai-quick|~/.local/bin/fox-ai-quick"
    "bin/fox-ai-find|~/.local/bin/fox-ai-find"
    "bin/fox-ai-bench|~/.local/bin/fox-ai-bench"
    "bin/fox-new-project|~/.local/bin/fox-new-project"
    "bin/fox-distro-guide|~/.local/bin/fox-distro-guide"
    "bin/fox-distro-build|~/.local/bin/fox-distro-build"
    "bin/fox-distro-flash|~/.local/bin/fox-distro-flash"
    "bin/findex|~/.local/bin/findex"
    "bin/fask|~/.local/bin/fask"
    "bin/fhelp|~/.local/bin/fhelp"
    "bin/fox-word-count|~/.local/bin/fox-word-count"

    # Distro profiles
    "foxml-profile.json|~/.local/share/foxml/distro/foxml-profile.json"

    # Waybar config
    "waybar_config|~/.config/waybar/config.tmpl"
    "waybar_config_secondary|~/.config/waybar/config_secondary.tmpl"

    # ReGreet (login screen — needs sudo to install to /etc/greetd/)
    # "regreet.toml|/etc/greetd/regreet.toml"
)

# ─────────────────────────────────────────
# Shared interactive helpers
# ─────────────────────────────────────────

# Prompt the user with a yes/no question, returning 0 on Y/y and 1 on
# anything else. Survives every input we've seen break naive read-based
# prompts:
#   * non-Y/N input (a digit, a word) — treated as "no", does not crash
#   * EOF / no TTY (curl-bash) — treated as "no" without hanging
#   * read failure under `set -e` — masked with `|| true` so a missing
#     terminal doesn't abort the whole installer
#
# Use as `if foxml_prompt_yn "...prompt..."; then ...; fi`.
foxml_prompt_yn() {
    local prompt="$1" reply=""
    if [[ ! -t 0 ]]; then
        return 1
    fi
    # NOTE: do NOT redirect stderr away from `read -p` — bash writes the
    # prompt itself to stderr, so `2>/dev/null` would silently eat the
    # question and leave the user staring at a blank screen wondering
    # what to type.
    read -p "$prompt" -n 1 -r reply || true
    echo ""
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────
# Special install handlers
# ─────────────────────────────────────────

get_firefox_profile() {
    # Firefox 150+ on Arch defaults to XDG paths (~/.config/mozilla/firefox);
    # older versions and other distros still use the legacy ~/.mozilla path.
    # Check both, preferring whichever has a *.default-release profile.
    for base in "$HOME/.config/mozilla/firefox" "$HOME/.mozilla/firefox"; do
        local hit
        hit=$(find "$base" -maxdepth 1 -name "*.default-release*" -type d 2>/dev/null | head -1)
        [[ -n "$hit" ]] && { echo "$hit"; return; }
    done
}

install_specials() {
    local rendered_dir="$1"

    # Firefox — resolve FIREFOX_PROFILE placeholder
    local ff_profile
    ff_profile="$(get_firefox_profile)"
    if [[ -n "$ff_profile" ]]; then
        for css in userChrome.css userContent.css; do
            if [[ -f "$rendered_dir/firefox/$css" ]]; then
                mkdir -p "$ff_profile/chrome"
                backup_and_copy "$rendered_dir/firefox/$css" "$ff_profile/chrome/$css"
                command -v foxml_substep >/dev/null && foxml_substep "Firefox $css" || echo "  Firefox $css"
            fi
        done
        # Set the legacy stylesheet pref via user.js so userChrome/userContent
        # actually load — user.js is read on every launch and overrides
        # prefs.js, so this stays correct even if Firefox rewrites prefs.
        local ff_userjs="$ff_profile/user.js"
        local ff_pref='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
        if ! grep -qF 'toolkit.legacyUserProfileCustomizations.stylesheets' "$ff_userjs" 2>/dev/null; then
            printf '// FoxML theming\n%s\n' "$ff_pref" >> "$ff_userjs"
            command -v foxml_substep >/dev/null && foxml_substep "Firefox user.js (legacy stylesheet pref)" || echo "  Firefox user.js (legacy stylesheet pref)"
        fi

        # Restart Firefox so the new userChrome/userContent loads. SIGTERM
        # gives Firefox time to write session state; restore brings tabs,
        # form fields, and scroll positions back on the next launch.
        # Skipped silently if Firefox isn't running.
        if pgrep -x firefox >/dev/null 2>&1; then
            pkill -TERM -x firefox || true
            # Wait up to 10s for graceful exit; bail out either way.
            for _ in {1..20}; do
                pgrep -x firefox >/dev/null 2>&1 || break
                sleep 0.5
            done
            setsid -f firefox >/dev/null 2>&1 &
            disown || true
            command -v foxml_substep >/dev/null && foxml_substep "Firefox restarted (session restore brings tabs back)" || echo "  Firefox restarted (session restore brings tabs back)"
        fi
    else
        echo "  No Firefox profile found, skipping"
    fi

    # Cursor/VS Code — package.json setup
    for ext_dir in ~/.cursor/extensions ~/.vscode/extensions; do
        if [[ -d "$ext_dir" && -f "$rendered_dir/cursor/foxml-color-theme.json" ]]; then
            mkdir -p "$ext_dir/foxml-theme/themes"
            backup_and_copy "$rendered_dir/cursor/foxml-color-theme.json" "$ext_dir/foxml-theme/themes/foxml-color-theme.json"
            cat > "$ext_dir/foxml-theme/package.json" << 'PKGJSON'
{
  "name": "foxml-theme",
  "displayName": "Fox ML Theme",
  "version": "1.0.0",
  "publisher": "foxml",
  "engines": { "vscode": "^1.60.0" },
  "categories": ["Themes"],
  "contributes": {
    "themes": [{ "label": "Fox ML", "uiTheme": "vs-dark", "path": "./themes/foxml-color-theme.json" }]
  }
}
PKGJSON
            echo "  $(basename "$ext_dir" | sed 's/^\.//') theme"
        fi
    done

    # Bat cache rebuild
    if command -v bat &>/dev/null; then
        bat cache --build &>/dev/null
        command -v foxml_substep >/dev/null && foxml_substep "Bat cache rebuilt" || echo "  Bat cache rebuilt"
    fi

    # AI Agent (Gemini) — merge the rendered config into the user's settings.json.
    # `.hooks` and `.ui` are *replaced* wholesale (not deep-merged) so a removed
    # event (e.g. a previous install's bogus SubagentStop) doesn't linger; other
    # top-level keys like `security` are preserved.
    local gemini_dir="${GEMINI_CONFIG_HOME:-$HOME/.gemini}"
    local gemini_settings="$gemini_dir/settings.json"
    if [[ -f "$rendered_dir/gemini/settings.json" ]]; then
        if [[ -f "$gemini_settings" ]]; then
            local tmp_settings; tmp_settings="$(mktemp)"
            if jq --slurpfile new "$rendered_dir/gemini/settings.json" '
                    . * $new[0]
                    | .hooks = $new[0].hooks
                    | .ui    = $new[0].ui
                ' "$gemini_settings" > "$tmp_settings" 2>/dev/null; then
                mv "$tmp_settings" "$gemini_settings"
                command -v foxml_substep >/dev/null && foxml_substep "Gemini settings (hooks + theme) merged" || echo "  Gemini settings (hooks + theme) merged"
            else
                rm -f "$tmp_settings"
                echo "  Gemini merge failed (jq error), skipping"
            fi
        else
            mkdir -p "$(dirname "$gemini_settings")"
            cp "$rendered_dir/gemini/settings.json" "$gemini_settings"
            command -v foxml_substep >/dev/null && foxml_substep "Gemini settings installed" || echo "  Gemini settings installed"
        fi
    fi

    # Claude CLI — ensure Stop / SubagentStop / Notification hooks are wired
    # in ~/.claude/settings.json. Hooks shell out to agent_notify.sh, which
    # sources border_colors.sh at fire time — so a palette swap takes effect
    # without re-running install.sh, and the embedded command is short enough
    # to round-trip through jq cleanly.
    local claude_settings="$HOME/.claude/settings.json"
    if command -v claude &>/dev/null || [[ -d "$HOME/.claude" ]]; then
        mkdir -p "$HOME/.claude"

        local hooks_json; hooks_json="$(mktemp)"
        cat > "$hooks_json" << 'JSON'
{
  "hooks": {
    "Stop": [
      {"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude stop"}]}
    ],
    "SubagentStop": [
      {"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude subagent"}]}
    ],
    "Notification": [
      {"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude notification"}]}
    ]
  }
}
JSON

        # dark-ansi routes Claude Code's UI through the terminal's ANSI
        # palette, which kitty.conf already paints with the FoxML colors —
        # so the TUI inherits the active theme without any per-element work.
        if [[ ! -f "$claude_settings" ]]; then
            if command -v jq &>/dev/null; then
                jq '. + {theme: "dark-ansi"}' "$hooks_json" > "$claude_settings"
            else
                cp "$hooks_json" "$claude_settings"
            fi
            command -v foxml_substep >/dev/null && foxml_substep "Claude settings (hooks + theme) created" || echo "  Claude settings (hooks + theme) created"
        elif command -v jq &>/dev/null; then
            # Deep-merge: replaces .hooks.Stop / .hooks.SubagentStop /
            # .hooks.Notification arrays wholesale, preserves everything else.
            # Also force-sets theme to dark-ansi so re-runs migrate users who
            # were created before the ansi flip (previous default was "dark").
            local tmp_claude; tmp_claude="$(mktemp)"
            if jq -s '.[0] * .[1] * {theme: "dark-ansi"}' "$claude_settings" "$hooks_json" > "$tmp_claude" 2>/dev/null; then
                mv "$tmp_claude" "$claude_settings"
                command -v foxml_substep >/dev/null && foxml_substep "Claude settings (hooks + theme) merged" || echo "  Claude settings (hooks + theme) merged"
            else
                rm -f "$tmp_claude"
                echo "  Claude merge failed (jq error), skipping"
            fi
        fi
        rm -f "$hooks_json"
    fi

    # ~/.local/bin helpers, Hyprland scripts, Waybar scripts, Hyprland
    # modules — each block previously echoed one line per file, which
    # produced a 100+ line dump during install_specials. Switched to
    # foxml_progress-style "section + count" output so it reads like
    # the rest of the install (pacman aesthetic). Per-file diagnostics
    # are still available via fox-doctor.

    # ~/.local/bin helpers.
    if [[ -d "$SCRIPT_DIR/shared/bin" ]]; then
        mkdir -p "$HOME/.local/bin"
        local _bins=("$SCRIPT_DIR/shared/bin/"*) _n=0 _total
        _total=$(find "$SCRIPT_DIR/shared/bin/" -maxdepth 1 -type f 2>/dev/null | wc -l)
        for bin in "${_bins[@]}"; do
            [[ -f "$bin" ]] || continue
            backup_and_copy "$bin" "$HOME/.local/bin/$(basename "$bin")"
            chmod +x "$HOME/.local/bin/$(basename "$bin")"
            _n=$((_n+1))
            command -v foxml_progress >/dev/null && foxml_progress "$_n" "$_total" "Installing bin tools"
        done
        echo ""
    fi

    # Hyprland scripts.
    if [[ -d "$SCRIPT_DIR/shared/hyprland_scripts" ]]; then
        mkdir -p ~/.config/hypr/scripts
        local _n=0 _total
        _total=$(find "$SCRIPT_DIR/shared/hyprland_scripts/" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l)
        for script in "$SCRIPT_DIR/shared/hyprland_scripts/"*.sh; do
            [[ -f "$script" ]] || continue
            backup_and_copy "$script" "$HOME/.config/hypr/scripts/$(basename "$script")"
            chmod +x "$HOME/.config/hypr/scripts/$(basename "$script")"
            _n=$((_n+1))
            command -v foxml_progress >/dev/null && foxml_progress "$_n" "$_total" "Installing Hyprland scripts"
        done
        echo ""
    fi

    # Waybar scripts.
    if [[ -d "$SCRIPT_DIR/shared/waybar_scripts" ]]; then
        mkdir -p ~/.config/waybar/scripts
        local _n=0 _total
        _total=$(find "$SCRIPT_DIR/shared/waybar_scripts/" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l)
        for script in "$SCRIPT_DIR/shared/waybar_scripts/"*.sh; do
            [[ -f "$script" ]] || continue
            backup_and_copy "$script" "$HOME/.config/waybar/scripts/$(basename "$script")"
            chmod +x "$HOME/.config/waybar/scripts/$(basename "$script")"
            _n=$((_n+1))
            command -v foxml_progress >/dev/null && foxml_progress "$_n" "$_total" "Installing Waybar scripts"
        done
        echo ""
    fi

    # Hyprland modules — pre-filter the skip list so the progress bar's
    # $_total reflects what we'll actually install. Previously the bar
    # showed 9/12 = 75% because theme.conf / nvidia.conf / (sometimes
    # existing) monitors.conf got skipped via `continue` but they were
    # still counted in $_total. Now we build the list of mods we'll
    # install FIRST, then iterate that fixed-size list.
    if [[ -d "$SCRIPT_DIR/shared/hyprland_modules" ]]; then
        mkdir -p ~/.config/hypr/modules
        local _mods=()
        for mod in "$SCRIPT_DIR/shared/hyprland_modules/"*.conf; do
            [[ -f "$mod" ]] || continue
            local _name="$(basename "$mod")"
            [[ "$_name" == "theme.conf" ]] && continue
            [[ "$_name" == "nvidia.conf" ]] && continue
            if [[ "$_name" == "monitors.conf" && -f "$HOME/.config/hypr/modules/monitors.conf" ]]; then
                continue
            fi
            _mods+=("$mod")
        done
        local _total=${#_mods[@]} _n=0
        for mod in "${_mods[@]}"; do
            backup_and_copy "$mod" "$HOME/.config/hypr/modules/$(basename "$mod")"
            _n=$((_n+1))
            command -v foxml_progress >/dev/null && foxml_progress "$_n" "$_total" "Installing Hyprland modules"
        done
        (( _total > 0 )) && echo ""
    fi

    # ReGreet (login screen) — stage files for install_greetd() to consume.
    # The actual sudo install to /etc/greetd/ happens in install_greetd()
    # (called from install.sh after install_specials).
    if [[ -f "$rendered_dir/regreet/regreet.css" ]]; then
        mkdir -p ~/.config/regreet
        backup_and_copy "$rendered_dir/regreet/regreet.css"            "$HOME/.config/regreet/regreet.css"
        backup_and_copy "$rendered_dir/regreet/regreet.toml"           "$HOME/.config/regreet/regreet.toml"
        backup_and_copy "$SCRIPT_DIR/shared/greetd_hyprland.conf"      "$HOME/.config/regreet/hyprland.conf"
        backup_and_copy "$SCRIPT_DIR/shared/greetd_select_monitor.sh"  "$HOME/.config/regreet/select-monitor.sh"
        chmod +x ~/.config/regreet/select-monitor.sh
        echo "  ReGreet staged to ~/.config/regreet/ (install_greetd will deploy)"
    fi

    # KEYBINDS.md — deployed to ~/.local/share/foxml/ so fox-cheatsheet
    # can find it on installed systems without depending on the repo path.
    if [[ -f "$SCRIPT_DIR/KEYBINDS.md" ]]; then
        mkdir -p "$HOME/.local/share/foxml"
        backup_and_copy "$SCRIPT_DIR/KEYBINDS.md" "$HOME/.local/share/foxml/KEYBINDS.md"
        command -v foxml_substep >/dev/null && foxml_substep "KEYBINDS.md → ~/.local/share/foxml/" \
            || echo "  KEYBINDS.md → ~/.local/share/foxml/"
    fi

    # Wallpapers — progress bar instead of one-per-line dump.
    if [[ -d "$SCRIPT_DIR/shared/wallpapers" ]]; then
        mkdir -p ~/.wallpapers
        shopt -s nullglob nocaseglob
        local _wps=("$SCRIPT_DIR/shared/wallpapers/"*.{jpg,jpeg,png,webp})
        local _total=${#_wps[@]} _n=0
        for wp in "${_wps[@]}"; do
            backup_and_copy "$wp" "$HOME/.wallpapers/$(basename "$wp")"
            _n=$((_n+1))
            command -v foxml_progress >/dev/null && foxml_progress "$_n" "$_total" "Installing wallpapers"
        done
        shopt -u nullglob nocaseglob
        (( _total > 0 )) && echo ""
    fi

    # Cursor theme — Catppuccin Mocha Peach matches the FoxML earthy palette.
    # The Hyprland env + GTK ini both reference it; this fetches the theme
    # files from the upstream GitHub release if they're not already present.
    local cursor_name="catppuccin-mocha-peach-cursors"
    local cursor_dir="$HOME/.local/share/icons/$cursor_name"
    if [[ ! -d "$cursor_dir" ]]; then
        local cursor_url="https://github.com/catppuccin/cursors/releases/download/v2.0.0/${cursor_name}.zip"
        local tmp_zip; tmp_zip="$(mktemp --suffix=.zip)"
        if curl -fsSL -o "$tmp_zip" "$cursor_url"; then
            mkdir -p "$HOME/.local/share/icons"
            unzip -o -q "$tmp_zip" -d "$HOME/.local/share/icons/"
            rm -f "$tmp_zip"
            command -v foxml_substep >/dev/null && foxml_substep "cursor theme: $cursor_name" || echo "  cursor theme: $cursor_name"
        else
            command -v foxml_warn >/dev/null && foxml_warn "cursor download failed; install from AUR or skip" \
                || echo "  cursor download failed; install from AUR or skip"
        fi
    else
        command -v foxml_substep >/dev/null && foxml_substep "cursor theme already present" || echo "  cursor theme already present"
    fi
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.desktop.interface cursor-theme "$cursor_name" || true
        gsettings set org.gnome.desktop.interface cursor-size 30 || true
    fi

    # Icon theme — Papirus-Dark with Catppuccin Mocha Peach folders. The
    # GTK ini already references Papirus-Dark; this fetches the theme
    # user-locally (no sudo) and recolors folders to match the cursor.
    #
    # Prefer the AUR package (papirus-icon-theme) for signature-verified
    # install. Falls back to the curl-pipe-bash path only if no AUR
    # helper is present yet. The script-pipe is the historical method
    # PapirusDevelopmentTeam ships; downloading to /tmp + diff'ing against
    # a known hash would be more rigorous but the AUR fallback covers
    # the same concern with less ceremony.
    # Look for Papirus in BOTH /usr/share/icons (system) and
    # ~/.local/share/icons (per-user). Previously we only checked the
    # per-user path, which meant pacman-installed Papirus (in /usr/share)
    # was reported as "already present" but the folder-recolor step
    # below silently skipped because $icons_dir/Papirus didn't exist.
    local icons_dir="$HOME/.local/share/icons"
    local papirus_root=""
    if [[ -d /usr/share/icons/Papirus ]]; then
        papirus_root=/usr/share/icons
    elif [[ -d "$icons_dir/Papirus" ]]; then
        papirus_root="$icons_dir"
    fi

    if [[ -z "$papirus_root" ]] && ! pacman -Qi papirus-icon-theme &>/dev/null; then
        local _papirus_done=0
        for aur in yay paru; do
            if command -v "$aur" >/dev/null 2>&1; then
                if "$aur" -S --needed --noconfirm papirus-icon-theme >/dev/null 2>&1; then
                    command -v foxml_substep >/dev/null && foxml_substep "Papirus icon theme (via $aur / AUR)" \
                        || echo "  Papirus icon theme (via $aur / AUR)"
                    _papirus_done=1
                    papirus_root=/usr/share/icons
                fi
                break
            fi
        done
        if (( ! _papirus_done )); then
            if curl -fsSL "https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-icon-theme/master/install.sh" \
                    | DESTDIR="$icons_dir" sh &>/dev/null; then
                command -v foxml_substep >/dev/null && foxml_substep "Papirus icon theme (upstream script)" \
                    || echo "  Papirus icon theme (upstream script — no AUR helper available)"
                papirus_root="$icons_dir"
            else
                command -v foxml_warn >/dev/null && foxml_warn "Papirus install failed; skipping folder recolor" \
                    || echo "  Papirus install failed; skipping folder recolor"
            fi
        fi
    else
        command -v foxml_substep >/dev/null && foxml_substep "Papirus already present (${papirus_root:-pacman})" \
            || echo "  Papirus already present"
        [[ -z "$papirus_root" ]] && papirus_root=/usr/share/icons
    fi

    if [[ -n "$papirus_root" && -d "$papirus_root/Papirus" ]]; then
        # Catppuccin folder injection — clone + tree-walk takes 8-15s
        # over a slow connection. Marker file makes the second run a
        # 0.01s no-op. Manually delete the marker to force re-inject.
        local cat_marker
        if [[ -w "$papirus_root" ]] || sudo -n true 2>/dev/null; then
            cat_marker="$papirus_root/.foxml-catppuccin-injected"
        else
            cat_marker="$HOME/.config/foxml/catppuccin-papirus-injected.marker"
        fi
        if [[ -f "$cat_marker" ]]; then
            command -v foxml_substep >/dev/null && foxml_substep "Catppuccin folder palette already injected" \
                || echo "  Catppuccin folder palette already injected"
        else
            local cat_tmp; cat_tmp="$(mktemp -d)"
            if git clone --depth 1 --quiet \
                    https://github.com/catppuccin/papirus-folders.git "$cat_tmp/repo" 2>/dev/null; then
                backup_and_copy_dir "$cat_tmp/repo/src" "$papirus_root/Papirus" || true
                command -v foxml_substep >/dev/null && foxml_substep "Catppuccin folder palette injected" \
                    || echo "  Catppuccin folder palette injected"
                # Drop marker (root or user-local depending on permissions).
                if [[ "$cat_marker" == /usr/* ]]; then
                    sudo touch "$cat_marker" 2>/dev/null
                else
                    mkdir -p "$(dirname "$cat_marker")" && touch "$cat_marker"
                fi
            fi
            rm -rf "$cat_tmp"
        fi

        # papirus-folders helper. Skip if marker exists AND gsettings
        # already reports the cat-mocha-peach folder set.
        local pf_marker="$HOME/.config/foxml/catppuccin-folders-applied.marker"
        if [[ -f "$pf_marker" ]]; then
            command -v foxml_substep >/dev/null && foxml_substep "folders already cat-mocha-peach" \
                || echo "  folders already cat-mocha-peach"
        else
            local pf_script
            if command -v papirus-folders &>/dev/null; then
                pf_script="papirus-folders"
            else
                pf_script="$(mktemp)"
                curl -fsSL -o "$pf_script" \
                    "https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/master/papirus-folders" \
                    && chmod +x "$pf_script"
            fi
            if [[ -x "$pf_script" ]]; then
                "$pf_script" -C cat-mocha-peach -t Papirus-Dark &>/dev/null || true
                command -v foxml_substep >/dev/null && foxml_substep "folders → cat-mocha-peach" \
                    || echo "  folders → cat-mocha-peach"
                [[ "$pf_script" != "papirus-folders" ]] && rm -f "$pf_script"
                mkdir -p "$(dirname "$pf_marker")" && touch "$pf_marker"
            fi
        fi

        if command -v gsettings &>/dev/null; then
            gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark" || true
        fi
    fi

    # bat — write a tiny config that selects the FoxML tmTheme by name
    local bat_dir="$HOME/.config/bat"
    if [[ -d "$bat_dir/themes" ]]; then
        if [[ -f "$bat_dir/config" ]] && grep -q '^--theme=' "$bat_dir/config"; then
            sed -i -E 's|^--theme=.*|--theme="Fox ML"|' "$bat_dir/config"
        else
            mkdir -p "$bat_dir"
            printf -- '--theme="Fox ML"\n' >> "$bat_dir/config"
        fi
        command -v foxml_substep >/dev/null && foxml_substep "bat --theme=\"Fox ML\"" || echo "  bat --theme=\"Fox ML\""
    fi

    # delta — wire the rendered FoxML gitconfig in via [include] so the user's
    # ~/.gitconfig (identity, etc.) stays untouched. git-config -e replaces the
    # same key on re-runs, and we only add the include if delta is installed.
    if command -v delta &>/dev/null && [[ -f "$rendered_dir/git/delta.gitconfig" ]]; then
        local delta_inc="$HOME/.config/git/delta-foxml.gitconfig"
        if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$delta_inc"; then
            git config --global --add include.path "$delta_inc"
        fi
        echo "  git delta include → $delta_inc"
    fi

    # btop — point btop.conf at the FoxML theme. If btop hasn't run yet there's
    # no btop.conf; create a one-line config (btop auto-fills the rest of the
    # defaults on first launch). Without this branch the theme silently no-ops
    # on first install.
    local btop_conf="$HOME/.config/btop/btop.conf"
    if [[ ! -f "$btop_conf" ]]; then
        mkdir -p "$(dirname "$btop_conf")"
        echo 'color_theme = "foxml"' > "$btop_conf"
        echo "  btop.conf created with FoxML theme"
    elif grep -qE '^color_theme\s*=\s*"foxml"' "$btop_conf"; then
        command -v foxml_substep >/dev/null && foxml_substep "btop already on FoxML theme" || echo "  btop already on FoxML theme"
    elif grep -qE '^color_theme\s*=' "$btop_conf"; then
        sed -i -E 's|^(color_theme\s*=\s*).*|\1"foxml"|' "$btop_conf"
        echo "  btop color_theme → foxml"
    else
        echo 'color_theme = "foxml"' >> "$btop_conf"
        echo "  btop color_theme → foxml"
    fi

    # Systemd user units (wallpaper rotation timer, etc.)
    if [[ -d "$SCRIPT_DIR/shared/systemd_user" ]]; then
        mkdir -p ~/.config/systemd/user
        local installed_any=0
        for unit in "$SCRIPT_DIR/shared/systemd_user/"*.{service,timer}; do
            [[ -f "$unit" ]] || continue
            backup_and_copy "$unit" "$HOME/.config/systemd/user/$(basename "$unit")"
            echo "  systemd/$(basename "$unit")"
            installed_any=1
        done
        if (( installed_any )); then
            systemctl --user daemon-reload &>/dev/null || true
            for timer in "$SCRIPT_DIR/shared/systemd_user/"*.timer; do
                [[ -f "$timer" ]] || continue
                systemctl --user enable --now "$(basename "$timer")" &>/dev/null || true
            done
            echo "  systemd user timers enabled"
            # Auto-enable the long-running fox-* watchers. Backgrounding from
            # Hyprland's exec-once is unreliable (parent SIGHUP race), so we
            # take the systemd path instead — Restart=on-failure makes them
            # self-heal. Other services (power-state-watcher, etc.) stay
            # opt-in.
            for svc in fox-monitor-watch.service foxml-focus-pulse.service; do
                [[ -f "$HOME/.config/systemd/user/$svc" ]] || continue
                systemctl --user enable --now "$svc" &>/dev/null \
                    && echo "  systemd $svc enabled"
            done
        fi
    fi

    # Reload the live notification daemon so the freshly-rendered [app-name=Claude]
    # / [app-name=Gemini] rules are active without a relog. Hook config in
    # ~/.claude/settings.json and ~/.gemini/settings.json is read by the agent
    # processes at startup, so already-running agent sessions still need to be
    # restarted to pick up new hooks — that part can't be fixed from here.
    if pgrep -x mako >/dev/null 2>&1 && command -v makoctl >/dev/null 2>&1; then
        makoctl reload &>/dev/null || true
        command -v foxml_substep >/dev/null && foxml_substep "mako reloaded" || echo "  mako reloaded"
    fi
    if pgrep -x dunst >/dev/null 2>&1; then
        # dunst has no reload command; SIGUSR2 is a no-op, so kick it cleanly.
        # killall is preferred so any running instance picks up the new config
        # via the user's autostart.
        killall -HUP dunst &>/dev/null || true
        echo "  dunst reloaded (SIGHUP)"
    fi
}

# ─────────────────────────────────────────
# Multi-monitor setup — interactive picker for anchor + position +
# orientation. Each external is anchored to primary OR any
# previously-placed external, so daisy-chained setups (3+ monitors in a
# row, stacked sidecars, etc.) compose correctly without overlapping.
# Writes ~/.config/hypr/modules/monitors.conf (per-machine, name-keyed so
# unplugged monitors are silently ignored) and a small sidecar at
# ~/.config/foxml/monitor-layout.conf consumed by start_waybar.sh and
# rotate_wallpaper.sh.
# ─────────────────────────────────────────

# Prompt for a HiDPI scale (1x / 1.25x / 1.5x / 2x) and echo the chosen
# decimal + its *100 integer form on a single line, e.g. "1.5 150". The
# *100 form is what configure_monitors uses for integer arithmetic when
# dividing physical dimensions into logical (scaled) bounds — bash has
# no native float math, and Hyprland's coordinate system is logical, not
# physical (a 4K monitor at scale 2 occupies a 1920x1080 logical box
# regardless of its 3840x2160 panel). Falls back silently to 1x on any
# non-matching input, including blank / EOF / no TTY.
_pick_scale() {
    local s_choice=""
    if [[ ! -t 0 ]]; then
        echo "1 100"
        return
    fi
    echo "    Scale (HiDPI):"                                    >&2
    echo "      [1] 1x   [2] 1.25x   [3] 1.5x   [4] 2x"          >&2
    read -p "    Choice [1]: " s_choice || true
    case "$s_choice" in
        2) echo "1.25 125" ;;
        3) echo "1.5 150" ;;
        4) echo "2 200" ;;
        *) echo "1 100" ;;
    esac
}

# _read_sidecar — safely load monitor-layout.conf into the caller's
# scope WITHOUT `source`-ing. Sourcing the file means any shell
# metacharacters in a monitor name from a spoofed hyprctl response
# would execute as code. This parser only honours the four expected
# keys, strips surrounding quotes, and leaves the value as a plain
# string — so `$(rm -rf ~)` in a monitor name becomes just a string,
# not a shell command.
#
# Sets these in the caller's scope:
#   PRIMARY, PORTRAIT_OUTPUTS, SECONDARY_OUTPUTS, MONITOR_RESOLUTIONS
# Returns 0 if the file existed and parsed, 1 otherwise.
_read_sidecar() {
    local file="$1"
    PRIMARY=""
    PORTRAIT_OUTPUTS=""
    SECONDARY_OUTPUTS=""
    MONITOR_RESOLUTIONS=""
    [[ -r "$file" ]] || return 1
    local key val
    while IFS='=' read -r key val; do
        # Strip surrounding double-quotes from "value"
        val="${val#\"}"
        val="${val%\"}"
        case "$key" in
            PRIMARY)             PRIMARY="$val" ;;
            PORTRAIT_OUTPUTS)    PORTRAIT_OUTPUTS="$val" ;;
            SECONDARY_OUTPUTS)   SECONDARY_OUTPUTS="$val" ;;
            MONITOR_RESOLUTIONS) MONITOR_RESOLUTIONS="$val" ;;
        esac
    done < <(grep -E '^(PRIMARY|PORTRAIT_OUTPUTS|SECONDARY_OUTPUTS|MONITOR_RESOLUTIONS)=' "$file" 2>/dev/null)
    return 0
}

_generate_per_monitor_wallpapers() {
    # Pre-render each source wallpaper at every panel resolution listed in
    # MONITOR_RESOLUTIONS so awww and hyprlock can apply pixel-perfect
    # images with no runtime scaling. Naming: ${base}_${WxH}.${ext}.
    # Idempotent — skips when the variant already exists.
    local wall_dir="${HOME}/.wallpapers"
    local layout="${HOME}/.config/foxml/monitor-layout.conf"
    [[ -d "$wall_dir" ]] || return 0
    [[ -f "$layout"   ]] || return 0

    local PRIMARY="" PORTRAIT_OUTPUTS="" SECONDARY_OUTPUTS="" MONITOR_RESOLUTIONS=""
    _read_sidecar "$layout"
    [[ -z "${MONITOR_RESOLUTIONS}" ]] && return 0

    local magick_bin=""
    command -v magick  >/dev/null 2>&1 && magick_bin="magick"
    command -v convert >/dev/null 2>&1 && [[ -z "$magick_bin" ]] && magick_bin="convert"
    if [[ -z "$magick_bin" ]]; then
        echo "  imagemagick missing — install imagemagick to enable per-monitor wallpapers"
        return 0
    fi

    # Dedupe across monitors — two 1920x1080 panels share one rendered file.
    local -A seen_res=()
    local entry res
    for entry in $MONITOR_RESOLUTIONS; do
        res="${entry##*:}"
        [[ -z "$res" || "$res" == "$entry" ]] && continue
        seen_res[$res]=1
    done
    (( ${#seen_res[@]} == 0 )) && return 0

    local generated=0 src base ext name out w h
    shopt -s nullglob nocaseglob
    for src in "$wall_dir"/*.{jpg,jpeg,png}; do
        [[ -f "$src" ]] || continue
        base="$(basename "$src")"
        ext="${base##*.}"
        name="${base%.*}"
        # Skip legacy _portrait siblings and any prior WxH variant — re-running
        # the generator against its own output would otherwise produce
        # foo_1920x1080_1920x1080.jpg etc.
        [[ "$name" == *_portrait ]]          && continue
        [[ "$name" =~ _[0-9]+x[0-9]+$ ]]     && continue

        for res in "${!seen_res[@]}"; do
            w="${res%x*}"; h="${res#*x}"
            out="${wall_dir}/${name}_${res}.${ext}"
            [[ -f "$out" ]] && continue
            # -resize WxH^ scales the source so the smaller edge fills the box,
            # -extent center-crops to exact WxH. No padding, subject stays
            # centered. Pre-rendered means awww applies with --resize fit and
            # never re-scales at fade time.
            "$magick_bin" "$src" -resize "${w}x${h}^" -gravity center \
                -extent "${w}x${h}" "$out" 2>/dev/null \
                && generated=$((generated + 1))
        done
    done
    shopt -u nullglob nocaseglob

    if (( generated > 0 )); then
        echo "  + ${generated} per-monitor wallpaper variant(s) generated"
    fi
    # Explicit success — the (( )) test returns 1 on a no-op rerun, and
    # `set -e` in install.sh would otherwise treat that as a failure.
    return 0
}

_personalize_hyprlock() {
    # Rewrite the background block(s) in ~/.config/hypr/hyprlock.conf to one
    # named block per monitor in MONITOR_RESOLUTIONS, each pointing at the
    # matching pre-rendered wallpaper variant. Idempotent: the block range
    # is delimited by sentinel comments left in place by the template, so
    # re-running converges on the same output without growing the file.
    local hyprlock_conf="$HOME/.config/hypr/hyprlock.conf"
    local layout="$HOME/.config/foxml/monitor-layout.conf"
    [[ -f "$hyprlock_conf" ]] || return 0
    [[ -f "$layout"        ]] || return 0

    local PRIMARY="" PORTRAIT_OUTPUTS="" SECONDARY_OUTPUTS="" MONITOR_RESOLUTIONS=""
    _read_sidecar "$layout"
    [[ -z "${MONITOR_RESOLUTIONS}" ]] && return 0

    if ! grep -q '^# foxml:hyprlock-backgrounds-begin' "$hyprlock_conf"; then
        echo "  ! hyprlock.conf missing sentinel — skipping personalisation"
        echo "    re-run install.sh to deploy the updated template"
        return 0
    fi

    # Active wallpaper basename. Prefer the palette var (in scope when called
    # from install.sh / swap.sh); fall back to parsing the current path line
    # inside the sentinel range so this function works standalone.
    local active="${WALLPAPER:-}"
    if [[ -z "$active" ]]; then
        active=$(awk '
            /^# foxml:hyprlock-backgrounds-begin/ { inblk=1; next }
            /^# foxml:hyprlock-backgrounds-end/   { exit }
            inblk && /^[[:space:]]*path[[:space:]]*=/ {
                n=split($0, a, "/"); print a[n]; exit
            }
        ' "$hyprlock_conf")
    fi
    [[ -z "$active" ]] && return 0

    # Strip a _WxH variant suffix if the active path was already a
    # pre-rendered variant (foxml_earthy_1920x1080.jpg). Without this,
    # a re-run would treat "foxml_earthy_1920x1080" as the source name
    # and look for "foxml_earthy_1920x1080_1920x1080.jpg" — which never
    # exists, so every monitor falls back to the same (wrong) source
    # path. We want to walk back to the actual source filename.
    local active_base="${active%.*}"
    local active_ext="${active##*.}"
    if [[ "$active_base" =~ _[0-9]+x[0-9]+$ ]]; then
        active_base="${active_base%_*}"
        active="${active_base}.${active_ext}"
    fi

    # Shared block tail. Must mirror the template's defaults so a re-run
    # produces no diff beyond the monitor + path lines.
    local block_tail="    blur_size = 8
    blur_passes = 3
    vibrancy = 0.20
    brightness = 0.45
    contrast = 1.10"

    local blocks="" entry name res variant_disk variant_path mons=0 fallbacks=0
    for entry in $MONITOR_RESOLUTIONS; do
        name="${entry%%:*}"
        res="${entry##*:}"
        [[ -z "$name" || -z "$res" || "$name" == "$entry" ]] && continue
        variant_disk="${HOME}/.wallpapers/${active_base}_${res}.${active_ext}"
        variant_path="~/.wallpapers/${active_base}_${res}.${active_ext}"
        if [[ ! -f "$variant_disk" ]]; then
            # Variant missing — fall back to the source. awww/hyprlock will
            # runtime-crop, which is what we're trying to avoid, so log it.
            variant_path="~/.wallpapers/${active}"
            fallbacks=$((fallbacks + 1))
        fi
        blocks+="background {
    monitor = ${name}
    path = ${variant_path}
${block_tail}
}
"
        mons=$((mons + 1))
    done
    (( mons == 0 )) && return 0
    blocks="${blocks%$'\n'}"

    local tmp
    tmp=$(mktemp)
    awk -v new_blocks="$blocks" '
        /^# foxml:hyprlock-backgrounds-begin/ { print; print new_blocks; skip=1; next }
        /^# foxml:hyprlock-backgrounds-end/   { skip=0; print; next }
        !skip { print }
    ' "$hyprlock_conf" > "$tmp" && mv "$tmp" "$hyprlock_conf"

    if (( fallbacks > 0 )); then
        echo "  + hyprlock personalised for ${mons} monitor(s) (${fallbacks} on source-fallback)"
    else
        echo "  + hyprlock personalised for ${mons} monitor(s)"
    fi
    return 0
}

# Harden the ollama systemd unit with sandboxing directives. The
# upstream ollama.service doesn't enable any of these by default;
# without them, ollama runs as user `ollama` but with full filesystem
# read/write and unrestricted kernel surface. Prompt-injection attacks
# that trick the model into emitting tool-call shell commands gain less
# leverage when the process itself is constrained.
#
# Conservative tuning — doesn't break the legitimate ollama work flow:
#   ProtectHome=read-only  — fask can still pass file paths to ollama
#                            for embedding context; ollama can read them
#                            but not modify your home.
#   PrivateTmp=true        — isolated /tmp namespace.
#   ProtectKernel{Tunables,Modules,Logs}=true — no /proc/sys writes,
#                            no module load, no /dev/kmsg read.
#   RestrictNamespaces / LockPersonality / RestrictRealtime — drop
#                            unused execution paths.
#   SystemCallArchitectures=native — refuse seccomp's "execute foreign
#                            arch" trick.
# Mask the systemd-generated gnome-keyring "limited" autostart units.
#
# The gnome-keyring Arch package ships these XDG autostart entries:
#   /etc/xdg/autostart/gnome-keyring-pkcs11.desktop
#   /etc/xdg/autostart/gnome-keyring-secrets.desktop
# systemd auto-converts those into user services:
#   app-gnome\x2dkeyring\x2dpkcs11@autostart.service
#   app-gnome\x2dkeyring\x2dsecrets@autostart.service
# Those services start gnome-keyring-daemon with ONLY pkcs11+secrets
# components — no SSH, no GPG. They run BEFORE Hyprland's autostart.conf
# fires, so `gnome-keyring-daemon --start --components=…,ssh,gpg`
# becomes a no-op (daemon already running with the limited set).
# Result: $SSH_AUTH_SOCK points at a nonexistent socket and every
# `ssh` / `git@github.com:…` call fails with "Error connecting to
# agent: No such file or directory".
#
# Fix: mask the limited services so they never start. Hyprland's
# autostart.conf then becomes the single source of truth for
# gnome-keyring-daemon and brings up all 4 components (pkcs11, secrets,
# ssh, gpg). Idempotent — re-running just re-masks. Reversible with
# `systemctl --user unmask` if the user wants the systemd-default
# behaviour back.
install_keyring_full_components() {
    # systemd matches `app-gnome-keyring-pkcs11@autostart.service` against
    # the auto-generated unit name even though the internal name has
    # \x2d escapes — passing the un-escaped form to mask works and
    # creates a /dev/null symlink under ~/.config/systemd/user/.
    # Mask is idempotent: re-running just re-creates the same symlink.
    local limited_units=(
        "app-gnome-keyring-pkcs11@autostart.service"
        "app-gnome-keyring-secrets@autostart.service"
        "gnome-keyring-daemon.service"
        "gnome-keyring-daemon.socket"
    )
    local masked=0
    for unit in "${limited_units[@]}"; do
        # Use systemctl's own state machine instead of manually probing
        # for symlinks under ~/.config/systemd/user. systemd is allowed to
        # change where it stores user-level masks (e.g. /run, /var/lib);
        # `is-enabled` returns the literal string "masked" on any storage
        # backend and is the only future-proof check.
        if [[ "$(systemctl --user is-enabled "$unit" 2>/dev/null)" == "masked" ]]; then
            continue  # already masked
        fi
        if systemctl --user mask "$unit" >/dev/null 2>&1; then
            masked=$((masked + 1))
        fi
    done
    if (( masked > 0 )); then
        echo "  + masked ${masked} systemd-generated gnome-keyring autostart unit(s)"
        echo "  + on next login Hyprland will start gnome-keyring with full components (ssh + gpg)"
    else
        echo "  • gnome-keyring limited autostart units already masked"
    fi

    # Ensure `ssh` is not jailed by Firejail. The default Firejail profile for
    # ssh isolates it from agents started in other shells and breaks
    # ssh-askpass UI prompts (GTK Memfd errors).
    if [[ -L "/usr/local/bin/ssh" ]] && readlink "/usr/local/bin/ssh" | grep -q firejail; then
        if sudo rm "/usr/local/bin/ssh" 2>/dev/null; then
            echo "  + de-jailed ssh (restored native access to agents + UI prompts)"
        fi
    fi

    return 0
}

# Wire fail2ban + fox-bouncer to fox-dispatch so phone notifications fire
# on:
#   • fail2ban ban (network brute force attempt)
#   • USBGuard BLOCK while screen is locked (evil-maid attempt)
#
# Both are idempotent — re-running just verifies state and re-applies
# the action drop-in if missing. fox-bouncer runs as a user systemd
# service; the fail2ban hook lives in /etc/fail2ban/action.d/.
#
# fox-dispatch itself reads ~/.config/foxml/dispatch.conf which is NOT
# managed by the installer (it has the secret webhook URL). If absent,
# the hooks fall back to notify-send (local notification) so they're
# still useful even without phone alerts configured.
install_dispatch_hooks() {
    # 0. Install the foxml-fail2ban-notify helper script to /usr/local/bin
    # so the fail2ban daemon (running as root) can call it. The script
    # does the geo + whois enrichment + threat-log append + fox-dispatch
    # call, all in user-friendly bash that fail2ban's config parser
    # doesn't have to interpret.
    if [[ -f "$SCRIPT_DIR/shared/bin/foxml-fail2ban-notify" ]]; then
        sudo install -m 0755 "$SCRIPT_DIR/shared/bin/foxml-fail2ban-notify" \
            /usr/local/bin/foxml-fail2ban-notify 2>/dev/null \
            && echo "  + foxml-fail2ban-notify installed to /usr/local/bin/" \
            || echo "  ! couldn't install fail2ban-notify helper (sudo cold?)"
    fi

    # fail2ban setup — order matters! The validation has to happen
    # AFTER both the action.d file AND the jail.local dedupe, not
    # between them. Otherwise we test against a config that's half-
    # updated and report a false-positive failure.
    if pacman -Qi fail2ban &>/dev/null && command -v fox-dispatch >/dev/null 2>&1; then
        local action="/etc/fail2ban/action.d/foxml-dispatch.conf"
        # Always rewrite the action drop-in to ensure we have the
        # clean helper-script form. Idempotent on re-runs.
        sudo tee "$action" >/dev/null <<EOF
# foxml-managed — fires fox-dispatch on every fail2ban ban.
# Revert: sudo rm $action and remove "action = foxml-dispatch" from jail.local.
[Definition]
actionban  = /usr/local/bin/foxml-fail2ban-notify <ip> <name> <failures> ${USER}
actionunban = /bin/true
[Init]
EOF
        echo "  + fail2ban action.d/foxml-dispatch.conf written (clean helper-script form)"

        # Splice the action into jail.local's [sshd] section.
        local jail_local=/etc/fail2ban/jail.local
        if [[ -f "$jail_local" ]]; then
            # Self-heal: strip every existing foxml-dispatch action
            # stanza (the previous version's idempotency grep was
            # broken — it looked for `^action.*foxml-dispatch` on one
            # line, but the inserted text spans two: `action = ...`
            # on one line + `         foxml-dispatch` as a continuation
            # on the next. The grep never matched on re-runs, so we
            # appended a duplicate stanza every time, and fail2ban-
            # client -t fails with "option 'action' in section 'sshd'
            # already exists".
            #
            # Approach: gawk -i inplace edits the file directly as root.
            # The previous version used mktemp + `sudo tee` to a temp
            # path under /tmp, which failed on machines with AppArmor
            # profiles restricting tee's /tmp access (the install hits
            # this on the very system it's hardening — 83 profiles +
            # one of them locks tee out of /tmp). Inplace edit avoids
            # the temp-file dance entirely.
            sudo gawk -i inplace '
                # On a fresh "action = %(action_)s" line, peek ahead:
                # if the next line is the foxml-dispatch continuation,
                # skip both. Otherwise, print normally.
                /^action[[:space:]]*=[[:space:]]*%\(action_\)s[[:space:]]*$/ {
                    getline next_line
                    if (next_line ~ /^[[:space:]]+foxml-dispatch[[:space:]]*$/) {
                        next   # skip both this line and the continuation
                    } else {
                        print
                        print next_line
                        next
                    }
                }
                { print }
            ' "$jail_local"
            sudo chmod 644 "$jail_local"

            # Now insert exactly one stanza after the [sshd] header.
            sudo sed -i '/^\[sshd\]/a action = %(action_)s\n         foxml-dispatch' "$jail_local"
            echo "  + jail.local sshd → exactly one foxml-dispatch action (deduped on re-run)"
        fi

        # Validate the final state (action.d + jail.local both updated).
        # Single validation point, single restart point — no false-
        # positive failures from intermediate states.
        if sudo fail2ban-client -t >/dev/null 2>&1; then
            sudo systemctl restart fail2ban >/dev/null 2>&1 \
                && echo "    fail2ban restarted — phone alerts live" \
                || echo "    ! fail2ban restart failed — systemctl status fail2ban"
        else
            echo "    ! fail2ban-client -t fails — leaving daemon as-is"
            echo "      diagnose: sudo fail2ban-client -t"
        fi
    else
        echo "  • fail2ban or fox-dispatch missing — skipping ban-hook"
    fi

    # 2. fox-bouncer user service (USB-blocked-while-locked alerts).
    if command -v fox-bouncer >/dev/null 2>&1; then
        if systemctl --user is-enabled --quiet fox-bouncer.service 2>/dev/null; then
            echo "  • fox-bouncer already enabled"
        else
            fox-bouncer --install >/dev/null 2>&1 \
                && echo "  + fox-bouncer.service enabled" \
                || echo "  ! fox-bouncer install failed (run manually: fox-bouncer --install)"
        fi
    fi

    # 2b. fox-sentry-audit — kernel-level honeypot watcher. Drops a
    # plausibly-named fake credential file in ~/Documents and adds an
    # auditd watch with key=foxml_honey; a user systemd unit tails the
    # journal for that key and fires fox-dispatch on any read.
    # Strong complement to fox-tripwire (userspace inotify): auditd
    # runs in the kernel so userspace ptrace/inotify tricks can't
    # bypass it. Both stay on by default — they alert, don't act.
    if command -v fox-sentry-audit >/dev/null 2>&1 && pacman -Qi audit &>/dev/null; then
        if systemctl --user is-enabled --quiet fox-sentry-audit.service 2>/dev/null; then
            echo "  • fox-sentry-audit already enabled"
        else
            fox-sentry-audit --install >/dev/null 2>&1 \
                && echo "  + fox-sentry-audit.service enabled (kernel-level honeypot)" \
                || echo "  ! fox-sentry-audit install failed (run manually: fox-sentry-audit --install)"
        fi
    fi

    # 3. Offer to configure fox-dispatch webhook if it's not set up yet.
    # Only when at a TTY and not --yes — silent in unattended mode.
    # Touch a `.skipped-dispatch` marker on decline so the same
    # question doesn't re-fire from fox-arm later in the --heavy flow.
    # User can `rm ~/.config/foxml/.skipped-dispatch` to re-trigger.
    if [[ -t 0 ]] && ! ${ASSUME_YES:-false}; then
        local _skip_marker="$HOME/.config/foxml/.skipped-dispatch"
        if [[ -f "$HOME/.config/foxml/dispatch.conf" ]]; then
            echo "  • fox-dispatch webhook already configured"
        elif [[ -f "$_skip_marker" ]]; then
            echo "  • fox-dispatch previously declined ($_skip_marker — remove to re-prompt)"
        else
            echo ""
            echo "  fox-dispatch (phone alerts) is not yet configured."
            if foxml_prompt_yn "  Set up Discord/Telegram webhook now? [y/N] "; then
                fox-dispatch --setup
            else
                mkdir -p "$HOME/.config/foxml" 2>/dev/null
                touch "$_skip_marker"
                echo "  • run later: fox dispatch --setup  (or: rm $_skip_marker && fox install --full)"
            fi
        fi
    fi
}

# Endlessh — SSH tarpit. Listens on port 22 (or wherever the world
# expects sshd to be) and feeds connecting bots an infinitely slow
# stream of random SSH banner lines, one every 10 seconds. Bots wait
# forever for a password prompt that never comes; meanwhile real sshd
# is on a custom port (set by the SSH hardening wizard) where bots
# never look. Net effect: every brute-force script gets tarpitted.
#
# Legal: defensive — we're just slow-responding to connections on our
# own port. No active intrusion, no scanning back. Fully within CFAA /
# Computer Misuse Act bounds.
#
# Conflict: requires port 22 to be FREE. If real sshd is on 22, abort.
install_endlessh_tarpit() {
    # Only meaningful if real sshd has been moved off 22. Without that,
    # we'd kick our own SSH service off the port.
    local real_ssh_port=""
    if [[ -f /etc/ssh/sshd_config.d/50-foxml-hardening.conf ]]; then
        real_ssh_port=$(awk '/^Port /{print $2}' /etc/ssh/sshd_config.d/50-foxml-hardening.conf 2>/dev/null)
    fi
    if [[ -z "$real_ssh_port" || "$real_ssh_port" == "22" ]]; then
        echo "  • Endlessh skipped — real sshd on port 22 (move it via the SSH wizard first)"
        return 0
    fi

    # Install endlessh from the AUR if not already. Try the candidate
    # package names in order; the user can also pre-install manually.
    # endlessh-go was the original name but isn't in AUR — the real
    # AUR package is `endlessh` (or sometimes `endlessh-git`).
    if ! command -v endlessh >/dev/null 2>&1; then
        local aur=""
        command -v yay  &>/dev/null && aur="yay"
        [[ -z "$aur" ]] && command -v paru &>/dev/null && aur="paru"
        if [[ -z "$aur" ]]; then
            echo "  ! endlessh needs an AUR helper (yay or paru) — skipping"
            return 0
        fi
        echo "  Installing endlessh from AUR (makepkg build, ~30-60s)..."
        local _installed=0
        for pkg in endlessh endlessh-git; do
            # Probe AUR first.
            if $aur -Si "$pkg" &>/dev/null; then
                echo "    → building $pkg..."
                # DON'T redirect output — silent yay during a 30-60s
                # makepkg build looks like a frozen install. Pipe
                # through a 4-space indent so it visually nests under
                # the foxml_section header. Last 8 lines of output are
                # kept in /tmp/foxml-aur.log on failure for debugging.
                if $aur -S --needed --noconfirm "$pkg" 2>&1 \
                        | tee /tmp/foxml-aur.log \
                        | sed 's/^/    /' \
                        ; then
                    _installed=1
                    echo "  + endlessh installed via $aur ($pkg)"
                    rm -f /tmp/foxml-aur.log
                    break
                fi
            fi
        done
        if (( ! _installed )); then
            echo "  ! AUR install of endlessh failed"
            echo "    last 8 lines of build log:"
            tail -8 /tmp/foxml-aur.log 2>/dev/null | sed 's/^/      /'
            echo "    workaround: $aur -S endlessh   (then re-run fox install)"
            return 0
        fi
    fi

    # Drop the config: bind on 22 for both v4 and v6, 10-second banner
    # interval (default), 4 max line length (default), unlimited clients.
    local conf=/etc/endlessh/config
    if [[ ! -f "$conf" ]] || ! sudo grep -q '^# foxml-managed' "$conf" 2>/dev/null; then
        sudo install -d /etc/endlessh
        sudo tee "$conf" >/dev/null <<'EOF'
# foxml-managed — SSH tarpit on port 22.
# Real sshd lives on the custom port set by install_security's SSH
# wizard. Bots scanning :22 get fed slow banners forever.
Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
BindFamily 0
EOF
        echo "  + endlessh config written to $conf"
    fi

    # Allow port 22 through UFW (endlessh wants connections, not blocks).
    sudo ufw allow 22/tcp >/dev/null 2>&1 || true
    echo "    UFW: port 22 allowed for endlessh tarpit (real sshd on $real_ssh_port stays limited)"

    # Enable + start the service. `|| true` chains so a failure of
    # either variant doesn't trip set -e and abort the entire install.
    # The diagnostic message below tells the user what happened.
    sudo systemctl enable --now endlessh.service >/dev/null 2>&1 \
        || sudo systemctl enable --now endlessh-go.service >/dev/null 2>&1 \
        || true
    if sudo systemctl is-active --quiet endlessh 2>/dev/null \
        || sudo systemctl is-active --quiet endlessh-go 2>/dev/null; then
        echo "  + endlessh tarpit active on :22 (bots will hang forever)"
    else
        echo "  ! endlessh service didn't start — check with: systemctl status endlessh"
        echo "    (continuing install; the tarpit is a nice-to-have, not critical)"
    fi
}

# etckeeper — git-version /etc. Records every config change with a
# pacman hook so any post-install drift is visible via `git log`. We
# DON'T auto-revert (a legit `ufw allow` change from `fox ports` would
# get clobbered) — we just alert when sensitive files change outside
# the expected pacman / fox-tool flow.
install_etckeeper() {
    if ! command -v etckeeper >/dev/null 2>&1; then
        if command -v yay  &>/dev/null; then
            yay -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true
        elif command -v paru &>/dev/null; then
            paru -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true
        else
            sudo pacman -S --needed --noconfirm etckeeper >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v etckeeper >/dev/null 2>&1; then
        echo "  ! etckeeper install failed — skipping"
        return 0
    fi

    # Initialize /etc as a git repo if not already. etckeeper handles
    # both the init + the pacman hook (drops /etc/pacman.d/hooks/etckeeper.hook).
    # The commit can fail with exit 128 when root has no git user.email
    # set, or when there's no diff to commit on a clean re-run. Suppress
    # both — the init alone is the useful work; subsequent pacman runs
    # will commit organically via the hook.
    if [[ ! -d /etc/.git ]]; then
        sudo etckeeper init >/dev/null 2>&1 || true
        echo "  + etckeeper initialised /etc/.git"
    else
        echo "  • etckeeper already initialised in /etc"
    fi

    # Always ensure a default git identity for root if missing (etckeeper commits
    # as root and refuses without user.email/user.name).
    sudo git -C /etc config user.email "etckeeper@$(uname -n)" 2>/dev/null || true
    sudo git -C /etc config user.name  "etckeeper" 2>/dev/null || true
    # Attempt an initial or catch-up commit; fails silently if tree is clean
    sudo etckeeper commit "foxml: /etc snapshot" >/dev/null 2>&1 || true

    # Drop a systemd path unit that fires fox-dispatch when sensitive
    # subdirs change outside of pacman / etckeeper's own commits.
    local watcher="$HOME/.config/systemd/user/fox-etcwatch.path"
    local svc="$HOME/.config/systemd/user/fox-etcwatch.service"
    if [[ ! -f "$watcher" ]]; then
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$watcher" <<'EOF'
[Unit]
Description=fox-etcwatch — alert on changes to sensitive /etc subdirs

[Path]
PathChanged=/etc/ssh
PathChanged=/etc/sudoers.d
PathChanged=/etc/pam.d
PathChanged=/etc/ufw
PathChanged=/etc/fail2ban
PathChanged=/etc/audit/rules.d
PathChanged=/etc/sysctl.d

[Install]
WantedBy=default.target
EOF
        cat > "$svc" <<EOF
[Unit]
Description=fox-etcwatch — dispatch /etc change

[Service]
Type=oneshot
# Suppress alerts that fire from etckeeper's own commits by checking
# /etc/.git/HEAD mtime — if it was touched in the last 30s, the change
# is almost certainly etckeeper itself, not an out-of-band edit. We
# avoid \`sudo git log\` here because user systemd units have no TTY
# for password prompts; stat works on the directory entry without
# needing read access to the .git contents.
ExecStart=/bin/sh -c 'stamp=\$(stat -c %%Y /var/lib/foxml/etc-last-commit 2>/dev/null || echo 0); now=\$(date +%%s); age=\$((now - stamp)); if [ "\$age" -gt 30 ]; then fox-dispatch "etc-change" "/etc modified outside an etckeeper commit (paths: ssh/sudoers.d/pam.d/ufw/fail2ban/audit/sysctl.d). Run: sudo etckeeper unclean" 2>/dev/null || true; fi'
EOF
        systemctl --user daemon-reload >/dev/null 2>&1
        systemctl --user enable --now fox-etcwatch.path >/dev/null 2>&1
        echo "  + fox-etcwatch.path enabled (alerts on /etc/{ssh,sudoers.d,pam.d,ufw,fail2ban,audit,sysctl.d} changes)"
    else
        echo "  • fox-etcwatch already configured"
    fi
}

# /proc with hidepid=2 — anyone but the owner sees nothing in /proc.
# A compromised low-priv shell running `ps aux` only sees its own
# processes; can't enumerate VPN daemons, password manager bg workers,
# trading bots, etc. Systemd mount unit so it survives reboot.
install_hidepid() {
    local unit=/etc/systemd/system/proc-hidepid.service
    if [[ -f "$unit" ]] && sudo grep -q '^# foxml-managed' "$unit" 2>/dev/null; then
        echo "  • /proc hidepid already configured"
        return 0
    fi
    sudo tee "$unit" >/dev/null <<'EOF'
# foxml-managed — apply hidepid=2 to /proc on boot.
[Unit]
Description=Remount /proc with hidepid=2 (foxml)
DefaultDependencies=no
After=local-fs.target
Before=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,hidepid=2 /proc
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable proc-hidepid.service >/dev/null 2>&1 || true
    # Apply live so the user sees it work without rebooting.
    sudo mount -o remount,hidepid=2 /proc 2>/dev/null && echo "  + /proc remounted hidepid=2 (other users' processes hidden)" \
        || echo "  + /proc hidepid=2 enabled on next boot"
}

# noexec / nosuid / nodev on /tmp + /dev/shm. Many Linux malware drop
# their second-stage payload in /tmp and exec it; this kills that
# class entirely. WARNING: breaks any tool that legit-execs from /tmp
# (rare but: some build scripts, in-place ELF tests). Opt-in only.
install_noexec_tmp() {
    local fstab=/etc/fstab
    sudo cp "$fstab" "${fstab}.foxml-bak" 2>/dev/null
    # /tmp on tmpfs — add or amend.
    if ! grep -qE '^\S+\s+/tmp\s+tmpfs' "$fstab"; then
        echo "tmpfs   /tmp        tmpfs   defaults,noexec,nosuid,nodev,size=4G  0 0" | sudo tee -a "$fstab" >/dev/null
        echo "  + /tmp added to /etc/fstab as tmpfs with noexec,nosuid,nodev"
    else
        # Append flags if missing.
        sudo sed -i -E '/^\S+\s+\/tmp\s+tmpfs.*defaults/{
            /noexec/!s/defaults/defaults,noexec/
            /nosuid/!s/defaults/defaults,nosuid/
            /nodev/!s/defaults/defaults,nodev/
        }' "$fstab"
        echo "  + /tmp tmpfs entry amended with noexec,nosuid,nodev"
    fi
    # /dev/shm — almost always a tmpfs already; just remount.
    sudo mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null \
        && echo "  + /dev/shm live-remounted noexec,nosuid,nodev (persistent via systemd default)" \
        || echo "  + /dev/shm flags will apply on next reboot"

    # Try /tmp live too — kernel rejects if any open file holds /tmp
    # busy, but most install-time runs succeed. Falls back to a clear
    # "reboot to apply" note so fox doctor / fox harden doesn't keep
    # flagging a half-applied state.
    if findmnt /tmp 2>/dev/null | grep -q noexec; then
        echo "  • /tmp already noexec live"
    elif sudo mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null; then
        echo "  + /tmp live-remounted noexec,nosuid,nodev"
    else
        echo "  + /tmp fstab updated — reboot to apply noexec live (kernel refused live remount: busy)"
    fi
    echo "  ${C_DIM:-}note: backup at ${fstab}.foxml-bak — if a build script breaks, revert with: sudo mv ${fstab}.foxml-bak $fstab${C_RST:-}"
}

# IOMMU / DMA protection. Plugged-in Thunderbolt / PCIe device can do
# DMA reads of RAM (Inception, etc.). intel_iommu=on iommu=pt isolates
# devices behind the kernel's IOMMU. AMD systems use amd_iommu=on.
install_iommu() {
    local cmdline_file=""
    if [[ -f /boot/loader/entries/arch.conf ]]; then
        cmdline_file=/boot/loader/entries/arch.conf
    elif [[ -f /etc/default/grub ]]; then
        cmdline_file=/etc/default/grub
    fi
    if [[ -z "$cmdline_file" ]]; then
        echo "  ! no recognised bootloader config — skipping IOMMU enable"
        return 0
    fi

    # Detect vendor.
    local vendor=""
    grep -qi 'GenuineIntel' /proc/cpuinfo && vendor="intel"
    grep -qi 'AuthenticAMD' /proc/cpuinfo && vendor="amd"
    [[ -z "$vendor" ]] && { echo "  ! unknown CPU vendor — skipping IOMMU"; return 0; }

    local iommu_args
    if [[ "$vendor" == "intel" ]]; then iommu_args="intel_iommu=on iommu=pt"; else iommu_args="amd_iommu=on iommu=pt"; fi

    # Append kernel.lockdown=integrity. This restricts what root can
    # do AT the kernel level — blocks loading unsigned modules,
    # /dev/kmem writes, kexec to unsigned kernels, raw I/O port
    # access, etc. Even a root-level exploit can't drop a rootkit
    # or live-patch the running kernel after this is on. Major
    # rootkit barrier; effectively turns root into "almost-root."
    # `integrity` mode allows reading kernel data (less strict than
    # `confidentiality` which blocks even /proc/kallsyms — that's a
    # step further but breaks some debug tooling).
    iommu_args="$iommu_args lockdown=integrity"

    if sudo grep -q "$iommu_args" "$cmdline_file" 2>/dev/null; then
        echo "  • IOMMU already enabled in $cmdline_file"
        return 0
    fi
    sudo cp "$cmdline_file" "${cmdline_file}.foxml-bak" 2>/dev/null
    if [[ "$cmdline_file" == */loader/entries/* ]]; then
        sudo sed -i "s|^options |options $iommu_args |" "$cmdline_file"
    else
        sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$iommu_args |" "$cmdline_file"
        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi
    echo "  + IOMMU enabled ($iommu_args) — REBOOT to activate"
}

# Disable core dumps. A crashing app (browser, password manager) can
# write a full RAM dump containing your secrets to disk. Set
# systemd-coredump → /dev/null and hard ulimit core = 0.
install_no_coredumps() {
    local conf=/etc/systemd/coredump.conf.d/foxml-no-coredumps.conf
    sudo mkdir -p "$(dirname "$conf")"
    if ! [[ -f "$conf" ]] || ! sudo grep -q '^# foxml-managed' "$conf"; then
        sudo tee "$conf" >/dev/null <<'EOF'
# foxml-managed — refuse to write core dumps to disk.
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
        echo "  + systemd-coredump set to Storage=none (no crash RAM hits disk)"
    else
        echo "  • coredump-disable already in place"
    fi
    # Hard ulimit via /etc/security/limits.d. Some Arch setups don't
    # ship the limits.d directory pre-created (pam-limits is optional);
    # mkdir -p first, then write. `|| true` so a failure here doesn't
    # abort the installer — the systemd-coredump conf above is the
    # main defense; the ulimit is belt-and-suspenders.
    local lim=/etc/security/limits.d/99-foxml-no-coredumps.conf
    if ! [[ -f "$lim" ]]; then
        sudo mkdir -p "$(dirname "$lim")" 2>/dev/null || true
        if echo "* hard core 0" | sudo tee "$lim" >/dev/null 2>&1; then
            echo "  + /etc/security/limits.d hard core=0 (applies next login)"
        else
            echo "  • /etc/security/limits.d not writable — skipping (systemd-coredump conf is primary)"
        fi
    fi
    sudo systemctl daemon-reexec 2>/dev/null || true
}

# Hardened makepkg CFLAGS — any AUR build done after this is compiled
# with stack protector, FORTIFY_SOURCE, PIE, control-flow-integrity.
# Doesn't help the system pacman binaries (those are pre-compiled by
# Arch's builders) but DOES protect every AUR package the user builds
# after install (knockd, fwknop, ollama-bin builds-from-source paths,
# etc.). Drop-in pattern means we don't trample the user's customisations.
install_makepkg_hardening() {
    local drop=/etc/makepkg.conf.d/99-foxml-hardening.conf
    sudo install -d /etc/makepkg.conf.d 2>/dev/null
    if [[ ! -f "$drop" ]] || ! sudo grep -q '^# foxml-managed' "$drop" 2>/dev/null; then
        sudo tee "$drop" >/dev/null <<'EOF'
# foxml-managed — hardened CFLAGS/LDFLAGS for AUR builds.
# Revert: sudo rm /etc/makepkg.conf.d/99-foxml-hardening.conf
CFLAGS="$CFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fcf-protection -fPIE -fstack-clash-protection"
CXXFLAGS="$CXXFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fcf-protection -fPIE -fstack-clash-protection"
LDFLAGS="$LDFLAGS -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,--as-needed -pie"
DEBUG_CFLAGS="$DEBUG_CFLAGS -fno-omit-frame-pointer"
EOF
        echo "  + makepkg hardening drop-in (FORTIFY_SOURCE=3 + stack-protector + CFI + PIE + RELRO)"
    else
        echo "  • makepkg hardening already present"
    fi
}

install_ollama_hardening() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
        echo "  • ollama.service not present — skipping ollama hardening"
        return 0
    fi
    # Re-prime sudo BEFORE any sudo command below. install.sh's keepalive
    # is torn down after the deps phase, and a long AI install (model
    # pulls, gh clones) can blow past the 5-minute sudo cache. Without
    # this check, `sudo install -d` would silently fail with "terminal
    # required for password" / fingerprint timeout, the heredoc would
    # write nothing, and we'd leave no drop-in. Make the failure loud.
    if ! sudo -v 2>/dev/null; then
        echo "  ! ollama hardening needs sudo (cache expired or no TTY)"
        echo "    re-run: source mappings.sh && install_ollama_hardening"
        return 1
    fi
    local drop_in=/etc/systemd/system/ollama.service.d
    sudo install -d "$drop_in" || { echo "  ! sudo install -d failed"; return 1; }

    # Build ReadWritePaths dynamically — listing a missing dir causes
    # systemd to fail mount-namespace setup with status=226/NAMESPACE,
    # silently bricking ollama. Only include paths that actually exist.
    local rw_paths=""
    for p in /usr/share/ollama /var/lib/ollama "${OLLAMA_MODELS:-}"; do
        [[ -n "$p" && -d "$p" ]] && rw_paths+="$p "
    done
    rw_paths="${rw_paths% }"

    # Detect a discrete GPU. PrivateDevices=true is the strongest sandbox
    # but it strips access to /dev/nvidia* / /dev/dri/*, killing GPU
    # inference. Auto-relax to PrivateDevices=false on GPU systems and
    # explicitly DeviceAllow only the device classes ollama needs.
    local has_gpu="no"
    local device_allow=""
    if compgen -G '/dev/nvidia*' >/dev/null 2>&1; then
        has_gpu="nvidia"
        device_allow="DeviceAllow=/dev/nvidia0 rw
DeviceAllow=/dev/nvidiactl rw
DeviceAllow=/dev/nvidia-modeset rw
DeviceAllow=/dev/nvidia-uvm rw
DeviceAllow=/dev/nvidia-uvm-tools rw"
    elif [[ -d /dev/dri ]]; then
        has_gpu="amd-or-intel"
        device_allow="DeviceAllow=char-drm rw"
    fi

    local private_devices="true"
    [[ "$has_gpu" != "no" ]] && private_devices="false"

    sudo tee "$drop_in/foxml-hardening.conf" >/dev/null <<EOF
# foxml-managed — systemd sandbox for ollama.service.
# Revert: sudo rm /etc/systemd/system/ollama.service.d/foxml-hardening.conf
#
# Auto-tuned for this machine:
#   GPU:              ${has_gpu}
#   ReadWritePaths:   ${rw_paths:-<none — ollama will use defaults>}
#   PrivateDevices:   ${private_devices}  (false on GPU systems so /dev/nvidia* are visible)
[Service]
NoNewPrivileges=true
ProtectHome=read-only
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=${private_devices}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=false
SystemCallArchitectures=native
${device_allow}
ReadWritePaths=${rw_paths}
EOF
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl is-active --quiet ollama; then
        if sudo systemctl restart ollama >/dev/null 2>&1; then
            # Brief wait + sanity check the restart actually stayed up;
            # status=226/NAMESPACE shows up here if a directive is wrong.
            sleep 2
            if systemctl is-active --quiet ollama; then
                echo "  ollama hardened + restarted (PrivateDevices=${private_devices}, ${rw_paths// /, } RW)"
            else
                echo "  ! ollama failed to start after hardening apply — reverting drop-in"
                sudo rm -f "$drop_in/foxml-hardening.conf"
                sudo systemctl daemon-reload >/dev/null 2>&1 || true
                sudo systemctl restart ollama >/dev/null 2>&1 || true
                echo "    investigate with: systemctl status ollama -l"
            fi
        fi
    else
        echo "  ollama hardening dropped in (will apply on next start; tuned for ${has_gpu} GPU)"
    fi
    return 0
}

_personalize_workspace_rules() {
    # Rewrite the workspace 1 pin in ~/.config/hypr/modules/rules.conf to
    # bind to monitor-layout.conf's PRIMARY. Default in the shared module
    # is eDP-1 (laptop-friendly), but desktops and machines where the user
    # picked a different primary need the real value. Idempotent — bounded
    # by sentinel comments left in place by the shared module.
    local rules_conf="$HOME/.config/hypr/modules/rules.conf"
    local layout="$HOME/.config/foxml/monitor-layout.conf"
    [[ -f "$rules_conf" ]] || return 0
    [[ -f "$layout"     ]] || return 0

    local PRIMARY="" PORTRAIT_OUTPUTS="" SECONDARY_OUTPUTS="" MONITOR_RESOLUTIONS=""
    _read_sidecar "$layout"
    [[ -z "$PRIMARY" ]] && return 0

    if ! grep -q '^# foxml:workspace-pin-begin' "$rules_conf"; then
        # Old rules.conf without sentinels — skip rather than guess where
        # to splice. Re-run install.sh to deploy the updated shared module.
        return 0
    fi

    local new_line="workspace = 1, monitor:${PRIMARY}, default:true"
    local tmp
    tmp=$(mktemp)
    awk -v new_line="$new_line" '
        /^# foxml:workspace-pin-begin/ { print; print new_line; skip=1; next }
        /^# foxml:workspace-pin-end/   { skip=0; print; next }
        !skip { print }
    ' "$rules_conf" > "$tmp" && mv "$tmp" "$rules_conf"

    echo "  + workspace pin → ${PRIMARY}"
    return 0
}

configure_monitors() {
    if ! command -v hyprctl &>/dev/null; then
        echo "  hyprctl not found — skipping monitor configuration"
        return
    fi
    if ! command -v jq &>/dev/null; then
        echo "  jq not installed — skipping monitor configuration"
        return
    fi

    local monitors_json
    monitors_json=$(hyprctl monitors -j 2>/dev/null) || {
        echo "  Hyprland not running — skipping monitor configuration"
        echo "  (Re-run install.sh from inside a Hyprland session to configure)"
        return
    }

    local count
    count=$(echo "$monitors_json" | jq 'length')

    mkdir -p "$HOME/.config/foxml"
    local layout="$HOME/.config/foxml/monitor-layout.conf"

    if (( count <= 1 )); then
        # Single monitor — clear any stale layout from a previous dock.
        local solo_name solo_w solo_h
        solo_name=$(echo "$monitors_json" | jq -r '.[0].name // ""')
        solo_w=$(echo "$monitors_json" | jq -r '.[0].width // 0')
        solo_h=$(echo "$monitors_json" | jq -r '.[0].height // 0')
        : > "$layout"
        echo "PRIMARY=\"${solo_name}\""                                   >> "$layout"
        echo 'PORTRAIT_OUTPUTS=""'                                        >> "$layout"
        echo 'SECONDARY_OUTPUTS=""'                                       >> "$layout"
        if [[ -n "$solo_name" && "$solo_w" != "0" && "$solo_h" != "0" ]]; then
            echo "MONITOR_RESOLUTIONS=\"${solo_name}:${solo_w}x${solo_h}\"" >> "$layout"
            _generate_per_monitor_wallpapers
            _personalize_hyprlock
            _personalize_workspace_rules
        else
            echo 'MONITOR_RESOLUTIONS=""'                                 >> "$layout"
            # Even with an unparseable solo monitor, workspace pin still
            # benefits from PRIMARY-by-name, so personalise rules.conf too.
            _personalize_workspace_rules
        fi
        return
    fi

    echo ""
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│   Multi-Monitor Setup                                            │"
    echo "├──────────────────────────────────────────────────────────────────┤"
    printf "│   Detected %d monitors:                                            \n" "$count"
    echo "$monitors_json" | jq -r '.[] | "│     • \(.name)  \(.width)x\(.height)  — \(.description)"'
    echo "╰──────────────────────────────────────────────────────────────────╯"

    # Primary picker:
    #   - If a laptop panel (eDP-*) is detected, use it (current behavior).
    #     Override is rare; users plugging an external as primary on a
    #     laptop is the exception, not the rule.
    #   - Otherwise (desktop with multiple identical externals, or
    #     non-eDP-named laptop), prompt the user to pick. Without this,
    #     "primary" was whatever monitor jq listed first — non-deterministic
    #     and frequently wrong on multi-output desktops.
    local primary
    primary=$(echo "$monitors_json" | jq -r '[.[] | select(.name | startswith("eDP"))] | .[0].name // empty')
    if [[ -z "$primary" ]] && (( count > 1 )) && [[ -t 0 ]]; then
        echo ""
        echo "  No laptop panel detected — pick a primary monitor:"
        local i=1
        local -a all_names=()
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            all_names+=("$n")
            local nw nh
            nw=$(echo "$monitors_json" | jq -r --arg n "$n" '.[] | select(.name==$n) | .width')
            nh=$(echo "$monitors_json" | jq -r --arg n "$n" '.[] | select(.name==$n) | .height')
            echo "    [$i] $n  (${nw}x${nh})"
            i=$((i+1))
        done < <(echo "$monitors_json" | jq -r '.[].name')
        local pri_choice=""
        read -p "    Choice [1]: " pri_choice || true
        if [[ "$pri_choice" =~ ^[0-9]+$ ]] \
            && (( pri_choice >= 1 && pri_choice <= ${#all_names[@]} )); then
            primary="${all_names[$((pri_choice-1))]}"
        else
            primary="${all_names[0]}"
        fi
    fi
    # Last-resort fallback: still empty after the picker (no TTY desktop
    # case) → first listed monitor, same as pre-picker behavior.
    [[ -z "$primary" ]] && primary=$(echo "$monitors_json" | jq -r '.[0].name')

    # TTY-gated rather than --yes-gated. Monitor layout has no sensible
    # auto-default — "is HDMI-A-1 to the left or the right of eDP-1?"
    # genuinely needs a human. If we have a terminal, prompt; if we
    # don't (curl-bash), fall through silently and use the right+landscape
    # default per external (matches pre-fix behavior under --yes).
    if [[ -t 0 ]]; then
        if ! foxml_prompt_yn "Configure layout interactively? [y/N] "; then
            echo "  Skipping — current monitors.conf left as-is"
            return
        fi
    fi

    local primary_w primary_h
    primary_w=$(echo "$monitors_json" | jq -r --arg n "$primary" '.[] | select(.name==$n) | .width')
    primary_h=$(echo "$monitors_json" | jq -r --arg n "$primary" '.[] | select(.name==$n) | .height')

    # Primary HiDPI scale — prompted up front so primary's logical
    # bounds are correct before any external is anchored to it. On a
    # 4K laptop panel you'd typically want 2x; on a 1080p panel, 1x.
    local primary_scale primary_scale_x100
    if [[ -t 0 ]]; then
        echo ""
        echo "  Primary: $primary  (${primary_w}x${primary_h})"
    fi
    local primary_scale_pair
    primary_scale_pair="$(_pick_scale)"
    primary_scale="${primary_scale_pair% *}"
    primary_scale_x100="${primary_scale_pair#* }"
    local primary_logical_w=$(( primary_w * 100 / primary_scale_x100 ))
    local primary_logical_h=$(( primary_h * 100 / primary_scale_x100 ))

    local rules="" portrait_outputs="" secondary_outputs=""
    # Physical panel WxH per monitor (post-transform, pre-scale). Consumed by
    # _generate_per_monitor_wallpapers and _personalize_hyprlock — awww and
    # hyprlock write to physical pixels, so scale is intentionally not folded
    # in here. Primary is assumed transform=0 (current picker doesn't rotate
    # primary). Externals append below in the loop.
    local monitor_resolutions="${primary}:${primary_w}x${primary_h}"
    local externals
    externals=$(echo "$monitors_json" | jq -r --arg p "$primary" '.[] | select(.name != $p) | .name')

    # Track every placed monitor's bounds so subsequent externals can be
    # anchored to it, not just to primary. Keyed by monitor name. Bounds
    # are LOGICAL (post-rotation, post-scale) since Hyprland's coordinate
    # system is logical — a 4K external at 2x scale occupies a 1920x1080
    # box for the purposes of placing its neighbors.
    declare -A ANCHOR_X ANCHOR_Y ANCHOR_W ANCHOR_H
    ANCHOR_X[$primary]=0
    ANCHOR_Y[$primary]=0
    ANCHOR_W[$primary]=$primary_logical_w
    ANCHOR_H[$primary]=$primary_logical_h
    local placed=("$primary")

    # Read externals from FD 3 so the inner read prompts still hit stdin/tty.
    while IFS= read -r -u 3 ext; do
        [[ -z "$ext" ]] && continue
        local ext_w ext_h
        ext_w=$(echo "$monitors_json" | jq -r --arg n "$ext" '.[] | select(.name==$n) | .width')
        ext_h=$(echo "$monitors_json" | jq -r --arg n "$ext" '.[] | select(.name==$n) | .height')

        local pos="right" orient="landscape" anchor="$primary"

        # Same TTY gate as the outer prompt — interactive prompts run
        # whenever we have a terminal, regardless of --yes. The case
        # statements have a wildcard default so any non-numeric input
        # silently falls back to the documented default rather than
        # erroring out.
        if [[ -t 0 ]]; then
            echo ""
            echo "  External: $ext  (${ext_w}x${ext_h})"

            # Anchor selection — only prompted when more than one
            # already-placed monitor is available. Default = primary.
            # Skipped silently for the first external (only choice is
            # primary anyway).
            if (( ${#placed[@]} > 1 )); then
                echo "    Position relative to which monitor:"
                local i=1
                for cand in "${placed[@]}"; do
                    if [[ "$cand" == "$primary" ]]; then
                        echo "      [$i] $cand (primary)"
                    else
                        echo "      [$i] $cand"
                    fi
                    i=$((i+1))
                done
                local a_choice=""
                read -p "    Choice [1]: " a_choice || true
                if [[ "$a_choice" =~ ^[0-9]+$ ]] \
                    && (( a_choice >= 1 && a_choice <= ${#placed[@]} )); then
                    anchor="${placed[$((a_choice-1))]}"
                fi
            fi

            echo "    Position relative to ${anchor}:"
            echo "      [1] left   [2] right   [3] above   [4] below"
            local p_choice="" o_choice=""
            read -p "    Choice [2]: " p_choice || true
            case "$p_choice" in
                1) pos="left" ;;
                3) pos="above" ;;
                4) pos="below" ;;
                *) pos="right" ;;
            esac

            echo "    Orientation:"
            echo "      [1] landscape   [2] portrait, rotated left   [3] portrait, rotated right"
            read -p "    Choice [1]: " o_choice || true
            case "$o_choice" in
                2) orient="portrait-left" ;;
                3) orient="portrait-right" ;;
                *) orient="landscape" ;;
            esac
        fi

        # HiDPI scale — affects logical bounds, layout, and the rule.
        local ext_scale_pair ext_scale ext_scale_x100
        ext_scale_pair="$(_pick_scale)"
        ext_scale="${ext_scale_pair% *}"
        ext_scale_x100="${ext_scale_pair#* }"

        # Physical panel dimensions post-transform, pre-scale. Used for the
        # MONITOR_RESOLUTIONS sidecar entry — awww writes pixels, so we want
        # the panel res that imagemagick should render to (e.g. 1080x1920
        # for a rotated 1920x1080 monitor regardless of HiDPI scale).
        local phys_w="$ext_w" phys_h="$ext_h"
        # Effective dimensions (post-rotation, post-scale = logical bounds).
        local eff_w="$ext_w" eff_h="$ext_h" transform=0
        case "$orient" in
            portrait-left)  eff_w="$ext_h"; eff_h="$ext_w"; transform=3 ;;  # 270°
            portrait-right) eff_w="$ext_h"; eff_h="$ext_w"; transform=1 ;;  #  90°
        esac
        if (( transform != 0 )); then
            phys_w="$ext_h"; phys_h="$ext_w"
        fi
        eff_w=$(( eff_w * 100 / ext_scale_x100 ))
        eff_h=$(( eff_h * 100 / ext_scale_x100 ))

        # Position relative to the chosen anchor's bounds. Hyprland accepts
        # negative coords, so we just compute and let it normalize visually.
        local ax ay aw ah
        ax=${ANCHOR_X[$anchor]}; ay=${ANCHOR_Y[$anchor]}
        aw=${ANCHOR_W[$anchor]}; ah=${ANCHOR_H[$anchor]}
        local ext_x=0 ext_y=0
        case "$pos" in
            right) ext_x=$(( ax + aw ));            ext_y=$(( ay + (ah - eff_h) / 2 )) ;;
            left)  ext_x=$(( ax - eff_w ));         ext_y=$(( ay + (ah - eff_h) / 2 )) ;;
            above) ext_x=$(( ax + (aw - eff_w) / 2 )); ext_y=$(( ay - eff_h )) ;;
            below) ext_x=$(( ax + (aw - eff_w) / 2 )); ext_y=$(( ay + ah )) ;;
        esac

        if (( transform != 0 )); then
            rules+="monitor = ${ext}, preferred, ${ext_x}x${ext_y}, ${ext_scale}, transform, ${transform}"$'\n'
            portrait_outputs+="${ext} "
        else
            rules+="monitor = ${ext}, preferred, ${ext_x}x${ext_y}, ${ext_scale}"$'\n'
        fi
        secondary_outputs+="${ext} "
        monitor_resolutions+=" ${ext}:${phys_w}x${phys_h}"

        # Record this external's bounds so a later external can anchor to it.
        ANCHOR_X[$ext]=$ext_x
        ANCHOR_Y[$ext]=$ext_y
        ANCHOR_W[$ext]=$eff_w
        ANCHOR_H[$ext]=$eff_h
        placed+=("$ext")
    done 3<<< "$externals"

    # Write monitors.conf
    local conf="$HOME/.config/hypr/modules/monitors.conf"
    {
        echo "# ╭──────────────────────────────────────────────────────────────────╮"
        echo "# │                          Monitors                                │"
        echo "# ╰──────────────────────────────────────────────────────────────────╯"
        echo "# Generated by install.sh — re-run to reconfigure."
        echo "# Per-monitor rules below; if a monitor is unplugged, Hyprland"
        echo "# silently ignores its rule. The catch-all at the bottom handles"
        echo "# unknown displays at runtime."
        echo ""
        echo "monitor = ${primary}, preferred, 0x0, ${primary_scale}"
        printf '%s' "$rules"
        echo ""
        echo "# Catch-all for any unknown/disconnected displays at runtime"
        echo "monitor = , preferred, auto, 1"
    } > "$conf"

    # Write layout sidecar (consumed by start_waybar.sh and rotate_wallpaper.sh)
    {
        echo "# Auto-generated by install.sh"
        echo "PRIMARY=\"${primary}\""
        echo "PORTRAIT_OUTPUTS=\"${portrait_outputs% }\""
        echo "SECONDARY_OUTPUTS=\"${secondary_outputs% }\""
        echo "MONITOR_RESOLUTIONS=\"${monitor_resolutions}\""
    } > "$layout"

    echo ""
    echo "  + monitors.conf written ($conf)"
    echo "  + layout sidecar       ($layout)"

    # Pre-render per-monitor wallpaper variants at each panel's native res
    # so awww and hyprlock can apply pixel-perfect images without runtime
    # scaling. Then rewrite hyprlock.conf's background blocks to one per
    # monitor, and pin workspace 1 to PRIMARY in rules.conf. All idempotent.
    _generate_per_monitor_wallpapers
    _personalize_hyprlock
    _personalize_workspace_rules
}

# ─────────────────────────────────────────
# Nvidia (full Wayland session on dGPU) — opt-in via install.sh --nvidia
# Wires Hyprland env vars + mkinitcpio MODULES + kernel cmdline so the
# nvidia driver loads at boot and Aquamarine targets the discrete card.
# Idempotent: rerunning detects existing config and skips edits.
# ─────────────────────────────────────────

install_nvidia() {
    # Detect dGPU and iGPU PCI addresses. Aquamarine needs BOTH because the
    # eDP display is hardwired to the iGPU on Optimus laptops — nvidia
    # renders, intel scans out via DMA-BUF.
    local nvidia_addr="" intel_addr=""
    for dev in /sys/bus/pci/devices/*/; do
        local vendor class
        vendor="$(cat "$dev/vendor" 2>/dev/null)"
        class="$(cat "$dev/class" 2>/dev/null)"
        [[ "$class" == 0x03* ]] || continue   # display controllers only
        case "$vendor" in
            0x10de) [[ -z "$nvidia_addr" ]] && nvidia_addr="$(basename "$dev")" ;;
            0x8086) [[ -z "$intel_addr" ]]  && intel_addr="$(basename "$dev")" ;;
            0x1002) [[ -z "$intel_addr" ]]  && intel_addr="$(basename "$dev")" ;;  # AMD iGPU also fits the scanout role
        esac
    done

    if [[ -z "$nvidia_addr" ]]; then
        echo "  No NVIDIA GPU found, skipping nvidia setup"
        return
    fi

    # Resolve by-path symlinks to /dev/dri/cardN — aquamarine splits
    # AQ_DRM_DEVICES on ':', and the by-path names contain ':' themselves
    # (pci-0000:01:00.0-card), which shreds the list. cardN is colon-free.
    local nvidia_drm intel_drm
    nvidia_drm="$(readlink -f "/dev/dri/by-path/pci-${nvidia_addr}-card" 2>/dev/null)"
    if [[ -z "$nvidia_drm" || ! -e "$nvidia_drm" ]]; then
        echo "  Could not resolve /dev/dri/by-path/pci-${nvidia_addr}-card — is the nvidia driver loaded?"
        return
    fi
    local aq_drm_devices="$nvidia_drm"
    if [[ -n "$intel_addr" ]]; then
        intel_drm="$(readlink -f "/dev/dri/by-path/pci-${intel_addr}-card" 2>/dev/null)"
        if [[ -n "$intel_drm" && -e "$intel_drm" ]]; then
            aq_drm_devices+=":${intel_drm}"
            echo "  Detected NVIDIA at ${nvidia_addr} (${nvidia_drm}), iGPU at ${intel_addr} (${intel_drm})"
        else
            echo "  Detected NVIDIA at ${nvidia_addr} (${nvidia_drm}); iGPU at ${intel_addr} but no DRM node yet — listing nvidia only"
        fi
    else
        echo "  Detected NVIDIA at ${nvidia_addr} (${nvidia_drm}) (no iGPU — single-GPU box)"
    fi

    # Hyprland env-var module
    if [[ -f "$SCRIPT_DIR/shared/hyprland_modules/nvidia.conf" ]]; then
        mkdir -p ~/.config/hypr/modules
        sed "s|AQ_DRM_DEVICES,.*|AQ_DRM_DEVICES, ${aq_drm_devices}|" \
            "$SCRIPT_DIR/shared/hyprland_modules/nvidia.conf" \
            > ~/.config/hypr/modules/nvidia.conf
        echo "  modules/nvidia.conf (AQ_DRM_DEVICES → ${aq_drm_devices})"

        local hypr_main="$HOME/.config/hypr/hyprland.conf"
        if [[ -f "$hypr_main" ]] && ! grep -qF 'modules/nvidia.conf' "$hypr_main"; then
            printf '\n# Nvidia (added by install.sh --nvidia)\nsource = ~/.config/hypr/modules/nvidia.conf\n' \
                >> "$hypr_main"
            echo "  hyprland.conf sources nvidia.conf"
        fi
    fi

    # /etc/mkinitcpio.conf — early-load nvidia modules so they claim the device
    # before kms / nouveau can. Idempotent: skip if nvidia_drm already listed.
    #
    # Guard against tiny EFI System Partitions: nvidia-bearing initramfs grows
    # to ~135 MB on this driver line, and a half-written .img on a full /boot
    # leaves the system unbootable. Refuse to edit if /boot has under 80 MB free.
    local mkinit="/etc/mkinitcpio.conf"
    if [[ -f "$mkinit" ]] && ! grep -qE '^MODULES=.*nvidia_drm' "$mkinit"; then
        local boot_free_mb
        boot_free_mb=$(df --output=avail -BM /boot 2>/dev/null | tail -1 | tr -dc '0-9')
        if [[ -n "$boot_free_mb" && "$boot_free_mb" -lt 80 ]]; then
            echo "  /boot has only ${boot_free_mb} MB free — skipping mkinitcpio edit"
            echo "    nvidia-bearing initramfs needs ~135 MB. Free space in /boot"
            echo "    (older kernels, fallback initramfs) and re-run, or skip this"
            echo "    step — the dGPU will still render via udev module loading."
        else
            sudo sed -i.foxml-bak \
                's/^MODULES=([^)]*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
                "$mkinit"
            echo "  mkinitcpio MODULES updated (backup: ${mkinit}.foxml-bak)"
            sudo mkinitcpio -P 2>&1 | tail -3
        fi
    else
        echo "  • mkinitcpio already has nvidia modules"
    fi

    # systemd-boot loader entry — add kernel cmdline for DRM modeset.
    # Other bootloaders (GRUB, refind) need manual editing; we warn here.
    local boot_entry="/boot/loader/entries/arch.conf"
    if [[ -f "$boot_entry" ]]; then
        if ! grep -qF 'nvidia_drm.modeset=1' "$boot_entry"; then
            sudo sed -i.foxml-bak \
                -E 's/^(options .*)$/\1 nvidia_drm.modeset=1 nvidia_drm.fbdev=1/' \
                "$boot_entry"
            echo "  kernel cmdline updated (backup: ${boot_entry}.foxml-bak)"
        else
            echo "  • kernel cmdline already has nvidia_drm.modeset=1"
        fi
    elif [[ -f /etc/default/grub ]]; then
        echo "  GRUB detected — add 'nvidia_drm.modeset=1 nvidia_drm.fbdev=1'"
        echo "    to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then"
        echo "    run: sudo grub-mkconfig -o /boot/grub/grub.cfg"
    else
        echo "  Unknown bootloader — add 'nvidia_drm.modeset=1 nvidia_drm.fbdev=1'"
        echo "    to your kernel cmdline manually."
    fi

    echo ""
    echo "  Reboot to load the nvidia driver."
    echo "  Recovery: if Hyprland fails to start, switch to a TTY"
    echo "  (Ctrl+Alt+F2), restore ${mkinit}.foxml-bak and"
    echo "  ${boot_entry}.foxml-bak, run 'sudo mkinitcpio -P', reboot."
}

# ─────────────────────────────────────────
# Catppuccin cursor (referenced by GTK / Hyprland env / regreet.toml).
# Not in official Arch repos; pull from upstream GitHub releases and drop
# into ~/.local/share/icons (per-user, no sudo). Idempotent.
# ─────────────────────────────────────────

install_catppuccin_cursor() {
    local theme="catppuccin-mocha-peach-cursors"
    local user_dir="$HOME/.local/share/icons"
    local sys_dir="/usr/share/icons"

    if [[ -d "$sys_dir/$theme" || -d "$user_dir/$theme" ]]; then
        echo "  • $theme already installed"
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "  curl not found — install curl or fetch $theme manually"
        return
    fi

    # GitHub release asset name (catppuccin/cursors ships one zip per flavor).
    local asset="${theme}.zip"
    local api="https://api.github.com/repos/catppuccin/cursors/releases/latest"
    local url
    url=$(curl -fsSL "$api" 2>/dev/null \
            | grep -oE "https://[^\"]+/${asset}" \
            | head -1)

    if [[ -z "$url" ]]; then
        echo "  Couldn't resolve $asset from $api — skipping cursor install"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    if ! curl -fsSL -o "$tmp/$asset" "$url"; then
        echo "  Download failed: $url"
        rm -rf "$tmp"
        return
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        echo "  unzip not found — pacman -S unzip then re-run"
        rm -rf "$tmp"
        return
    fi

    mkdir -p "$user_dir"
    unzip -q -o "$tmp/$asset" -d "$user_dir"
    rm -rf "$tmp"

    if [[ -d "$user_dir/$theme" ]]; then
        echo "  $theme → $user_dir"
    else
        echo "  Extraction did not produce $user_dir/$theme — check asset layout"
    fi
}

# ─────────────────────────────────────────
# greetd + regreet (themed login screen)
# Auto-runs when greetd-regreet is installed. Idempotent.
# Replaces the README's manual "sudo cp + tee" post-install dance.
# ─────────────────────────────────────────

# Disable systemd-resolved's DNSSEC enforcement so name resolution doesn't
# silently fail on zones whose upstream DNS returns unsigned answers (most
# NTP pool subdomains, plenty of smaller zones). In strict DNSSEC=yes mode
# the resolver rejects those responses outright, so e.g. chronyd lands "8
# sources with unknown address" and the system clock never syncs.
#
# DNSSEC=allow-downgrade isn't enough here: it only relaxes when upstream
# explicitly signals "I don't speak DNSSEC." Many ISPs/recursive resolvers
# advertise DNSSEC support but return unsigned answers anyway, which
# allow-downgrade still rejects. DNSSEC=no is the only setting that fixes
# the actual failure mode end-to-end.
#
# Drop-in at /etc/systemd/resolved.conf.d/ so future systemd package
# upgrades don't clobber the change and the main resolved.conf is left
# alone. No-op when systemd-resolved isn't the active resolver (NM-dnsmasq
# setups, custom resolvconf, etc.).
install_resolved_dnssec() {
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "  • systemd-resolved not active, skipping DNSSEC tweak"
        return
    fi

    if ! sudo -v 2>/dev/null; then
        echo "  ⚠ sudo unavailable, skipping DNSSEC tweak"
        return
    fi

    # DNSSEC can be set in three places that all need to agree before the
    # drop-in actually takes effect. Audit + fix each:
    #
    #   1. /etc/systemd/resolved.conf       — main config; an explicit
    #      DNSSEC=yes here can win against a drop-in in some load orders.
    #   2. /etc/systemd/resolved.conf.d/    — drop-in directory; this is
    #      where we write the override.
    #   3. NetworkManager connection.dnssec — NM pushes per-link DNSSEC
    #      settings to resolved that beat the global setting outright.
    #      A connection with connection.dnssec=yes will keep failing
    #      regardless of what resolved.conf says.

    # 1. Main resolved.conf — comment out any explicit DNSSEC= line.
    if [[ -f /etc/systemd/resolved.conf ]] && \
       grep -qE '^[[:space:]]*DNSSEC=' /etc/systemd/resolved.conf; then
        sudo sed -i 's/^\([[:space:]]*\)DNSSEC=/\1#DNSSEC=/' /etc/systemd/resolved.conf
        echo "  commented active DNSSEC= line in /etc/systemd/resolved.conf"
    fi

    # 2. Drop-in. Interactive picker (skipped under --yes / no-TTY):
    #   0 / off       no validation (DoH path-encryption only)
    #   1 / relaxed   validate-when-signed (recommended for laptops)
    #   2 / strict    refuse unsigned answers (best, can wedge on
    #                 hotel / café wifi + clock skew)
    # User can flip later anytime via `fox dnssec 0/1/2`.
    local conf=/etc/systemd/resolved.conf.d/00-foxml-dnssec.conf
    sudo install -d /etc/systemd/resolved.conf.d
    local current_val="" desired_val="allow-downgrade"   # default = relaxed
    [[ -f "$conf" ]] && current_val=$(grep -h '^DNSSEC=' "$conf" 2>/dev/null | head -1 | awk -F= '{print $2}')

    if [[ -t 0 ]] && ! ${ASSUME_YES:-false}; then
        echo ""
        echo "  ${C_BOLD:-}DNSSEC strictness:${C_RST:-}"
        echo "    [0] off — DoH only (no validation)"
        echo "    [1] relaxed (allow-downgrade) ${C_DIM:-}(recommended; current default)${C_RST:-}"
        echo "    [2] strict (yes) — can wedge DNS on hotel/café wifi"
        local _lvl
        read -rp "  choose [1]: " -n 1 -r _lvl; echo
        case "${_lvl:-1}" in
            0) desired_val="no" ;;
            2) desired_val="yes" ;;
            *) desired_val="allow-downgrade" ;;
        esac
    fi

    if [[ "$current_val" != "$desired_val" ]]; then
        printf '[Resolve]\nDNSSEC=%s\n' "$desired_val" | sudo tee "$conf" >/dev/null
        echo "  DNSSEC=$desired_val → $conf  ${C_DIM:-}(change later: fox dnssec 0/1/2)${C_RST:-}"
    else
        echo "  • DNSSEC=$desired_val already configured  ${C_DIM:-}(change: fox dnssec 0/1/2)${C_RST:-}"
    fi

    # Strip DNSSEC lines from sibling drop-ins so 00-foxml-dnssec.conf
    # is the sole source of truth. systemd-resolved merges drop-ins
    # in lexical order; without this cleanup, foxml-doh.conf's
    # DNSSEC= line (added by install_privacy) would override the
    # user's picked level above because it sorts later.
    for sibling in /etc/systemd/resolved.conf.d/*.conf; do
        [[ "$sibling" == "$conf" ]] && continue
        [[ -f "$sibling" ]] || continue
        if sudo grep -q '^DNSSEC=' "$sibling" 2>/dev/null; then
            sudo sed -i '/^DNSSEC=/d' "$sibling"
            echo "  • stripped redundant DNSSEC= from $sibling"
        fi
    done

    # 3. Clear NetworkManager per-connection DNSSEC overrides. Empty value
    # means "inherit from systemd-resolved global." Iterates every
    # connection NM knows about; cheap, idempotent, no-op when none have
    # a non-default value.
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local cleared=0 uuid cur
        while IFS= read -r uuid; do
            [[ -z "$uuid" ]] && continue
            cur=$(nmcli -t -g connection.dnssec connection show "$uuid" 2>/dev/null)
            if [[ -n "$cur" && "$cur" != "--" && "$cur" != "default" ]]; then
                sudo nmcli connection modify "$uuid" connection.dnssec "" 2>/dev/null && cleared=$((cleared+1))
            fi
        done < <(nmcli -t -f UUID connection show 2>/dev/null)
        [[ "$cleared" -gt 0 ]] && echo "  cleared NetworkManager per-link DNSSEC on $cleared connection(s)"
    fi

    # Apply: restart resolved + flush caches so any stuck NXDOMAIN /
    # validation failures don't linger.
    sudo systemctl restart systemd-resolved 2>/dev/null
    sudo resolvectl flush-caches 2>/dev/null
    echo "  systemd-resolved restarted + cache flushed"

    # NetworkManager pushes per-link DNSSEC to resolved at connection-up
    # time; modifying connection.dnssec only updates the persistent
    # profile, not the active link. Restart NM so cleared values actually
    # propagate. Brief network blip (~3s) is acceptable mid-install.
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        sudo systemctl restart NetworkManager 2>/dev/null
        sleep 3
        echo "  NetworkManager restarted (pushed DNSSEC=default to active links)"
    fi

    # Verify with retries — the NetworkManager restart above triggers a
    # ~3-10s reconnection window during which resolvectl queries can
    # transiently fail even though the DNSSEC config is correct. Try the
    # known-unsigned zone (the actual fix target), then fall back to a
    # signed zone (archlinux.org — sanity check that resolved is alive
    # at all). Only warn if both probe targets fail across three retries.
    local probe_ok=0 probe_target=""
    for probe_target in 2.arch.pool.ntp.org archlinux.org; do
        local attempt
        for attempt in 1 2 3; do
            if resolvectl query "$probe_target" >/dev/null 2>&1; then
                probe_ok=1
                break 2
            fi
            sleep 2
        done
    done

    if (( probe_ok == 1 )); then
        echo "  ✓ DNSSEC verified ($probe_target resolved cleanly)"
    else
        echo "  ⚠ DNSSEC fix applied but verification queries still fail"
        echo "    run 'resolvectl status' to inspect upstream / per-link state"
    fi
}

# One-shot clock correction via Cloudflare NTP at a hardcoded IP. Bypasses
# DNS entirely (no DNSSEC, no resolved, no chrony pool resolution) so the
# system clock can jump to correct time even when name resolution is
# wedged. chrony's normal slew mode won't fix a multi-hour offset because
# it refuses to step beyond a small threshold; -q runs one synchronous
# burst and exits, jumping the clock if needed. After this, ongoing chrony
# sync handles drift normally.
#
# Cloudflare's time.cloudflare.com (162.159.200.1 / .123) is a stable,
# globally-anycast NTP service. UDP/123 to a known IP — works on any
# network where outbound NTP isn't firewalled, which covers virtually
# every home/coffee-shop/corporate WiFi.
#
# Skipped if chrony isn't installed (no chronyd binary). Persists the
# corrected time to the RTC so a power-off doesn't undo it.
install_clock_sync() {
    if ! command -v chronyd >/dev/null 2>&1; then
        echo "  • chrony not installed, skipping one-shot clock sync"
        return
    fi
    if ! sudo -v 2>/dev/null; then
        echo "  ⚠ sudo unavailable, skipping clock sync"
        return
    fi

    # Stop the daemon so chronyd -q doesn't fight an already-running
    # instance for the NTP socket.
    local was_running=0
    if systemctl is-active --quiet chronyd 2>/dev/null; then
        was_running=1
        sudo systemctl stop chronyd
    fi

    # -q = one shot, set time, exit. -t 8 = give up after 8s if no
    # response (port blocked, etc.). Try Cloudflare first, fall back to
    # Google Public NTP if Cloudflare is unreachable.
    local synced=0
    if sudo chronyd -q -t 8 'server 162.159.200.1 iburst' 2>&1 | grep -q 'System clock'; then
        synced=1
        echo "  ✓ clock corrected via Cloudflare NTP (162.159.200.1)"
    elif sudo chronyd -q -t 8 'server 216.239.35.0 iburst' 2>&1 | grep -q 'System clock'; then
        synced=1
        echo "  ✓ clock corrected via Google NTP (216.239.35.0)"
    else
        echo "  ⚠ one-shot NTP failed (UDP/123 may be blocked on this network)"
    fi

    if [[ "$synced" -eq 1 ]]; then
        sudo hwclock --systohc 2>/dev/null && echo "  RTC updated to match"
    fi

    [[ "$was_running" -eq 1 ]] && sudo systemctl start chronyd 2>/dev/null
}

# Extend gpg-agent's cached-passphrase TTL so agent-driven commits don't
# re-prompt every 10 minutes (gpg-agent default). Idempotent — leaves any
# user-set TTL alone, only adds the keys if they're missing. No-op for
# users who don't sign commits with GPG.
#
# Override the cache duration with FOXML_GPG_CACHE_TTL=<seconds> when
# invoking install.sh; defaults to 3600 (1h). Power users on personal
# laptops may want 28800 (8h).
install_gpg_agent_cache() {
    if ! command -v gpg >/dev/null 2>&1; then
        echo "  • gpg not installed, skipping gpg-agent cache TTL"
        return
    fi

    # Only act if the user actually signs commits or has GPG secret keys.
    local signs has_keys
    signs=$(git config --global --get commit.gpgsign 2>/dev/null)
    has_keys=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:')
    if [[ "$signs" != "true" && "$has_keys" -eq 0 ]]; then
        echo "  • commit.gpgsign=false and no GPG secret keys, skipping cache TTL"
        return
    fi

    local ttl="${FOXML_GPG_CACHE_TTL:-3600}"
    local conf="$HOME/.gnupg/gpg-agent.conf"
    mkdir -p "$HOME/.gnupg" && chmod 700 "$HOME/.gnupg"

    if [[ ! -f "$conf" ]]; then
        cat > "$conf" <<EOF
# Cache the signing-key passphrase so agent commits don't re-prompt every
# 10 minutes (gpg-agent default). Override at install time with
# FOXML_GPG_CACHE_TTL=<seconds>; current value: ${ttl}s.
default-cache-ttl ${ttl}
max-cache-ttl ${ttl}
EOF
        chmod 600 "$conf"
        echo "  gpg-agent cache TTL → ${ttl}s (new ~/.gnupg/gpg-agent.conf)"
    else
        local touched=0
        if ! grep -qE '^[[:space:]]*default-cache-ttl[[:space:]]' "$conf"; then
            echo "default-cache-ttl ${ttl}" >> "$conf"
            touched=1
        fi
        if ! grep -qE '^[[:space:]]*max-cache-ttl[[:space:]]' "$conf"; then
            echo "max-cache-ttl ${ttl}" >> "$conf"
            touched=1
        fi
        if [[ "$touched" -eq 1 ]]; then
            echo "  gpg-agent cache TTL → ${ttl}s (appended to existing config)"
        else
            echo "  • gpg-agent.conf already has cache TTLs — leaving as-is"
        fi
    fi

    gpgconf --reload gpg-agent 2>/dev/null && echo "  gpg-agent reloaded"
}

# Generate a commit-signing GPG key, upload it to GitHub, and turn on
# git's auto-sign config. Called from install_github_workspace after the
# SSH key block so it can rely on `gh` already being installed and
# authenticated. Idempotent — skips key generation if a usable secret
# key already exists for the configured git email, and skips upload if
# the public key body is already on GitHub.
#
# Key shape: ed25519 sign-only, no expiry. Pinentry will prompt for a
# passphrase during generation (gpg-agent.conf cache TTL keeps it from
# re-prompting mid-session). On non-interactive runs without a TTY,
# generation is skipped with a hint.
install_github_gpg_signing() {
    if ! command -v gpg >/dev/null 2>&1; then
        echo "  • gpg not installed, skipping commit-signing setup"
        return
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "  • gh not installed, skipping commit-signing setup"
        return
    fi

    local email name keyid
    email="$(git config --global user.email 2>/dev/null)"
    name="$(git config --global user.name 2>/dev/null)"
    if [[ -z "$email" ]]; then
        echo "  • git user.email unset, skipping commit-signing setup"
        return
    fi

    # Look for an existing secret key that matches this email AND can
    # sign (capability 's' on a non-revoked, non-expired key). gpg's
    # colon format: fpr line right after a sec line gives the fingerprint.
    keyid="$(gpg --list-secret-keys --with-colons "$email" 2>/dev/null \
        | awk -F: '
            $1=="sec" && $2!="r" && $2!="e" && index($12,"s") {found=1; next}
            found && $1=="fpr" {print $10; exit}
        ')"

    if [[ -z "$keyid" ]]; then
        if [[ ! -t 0 ]]; then
            echo "  • no TTY for pinentry passphrase prompt, skipping GPG key generation"
            echo "    Re-run interactively, or generate manually: gpg --quick-generate-key \"$name <$email>\" ed25519 sign 0"
            return
        fi
        echo "    Generating ed25519 GPG signing key for $email..."
        echo "    pinentry will prompt for a passphrase — this protects the key on disk."
        # Fresh-bootstrap shells don't inherit the user's .zshrc, so
        # pinentry-curses needs an explicit TTY hint to find the terminal.
        export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null)}"
        if ! gpg --quick-generate-key "$name <$email>" ed25519 sign 0; then
            echo "  ! GPG key generation failed, skipping the rest of commit-signing setup"
            return
        fi
        keyid="$(gpg --list-secret-keys --with-colons "$email" 2>/dev/null \
            | awk -F: '$1=="fpr" {print $10; exit}')"
        if [[ -z "$keyid" ]]; then
            echo "  ! could not locate freshly-generated key, skipping upload"
            return
        fi
        echo "      Key: $keyid"
    else
        echo "    Reusing existing GPG signing key: $keyid"
    fi

    # Upload pubkey to GitHub if not already registered there. The colon
    # format from `gh gpg-key list` includes the full fingerprint, so a
    # plain substring match is enough.
    local pubkey
    pubkey="$(gpg --armor --export "$keyid")"
    if [[ -z "$pubkey" ]]; then
        echo "  ! pubkey export empty, skipping upload"
    elif gh gpg-key list 2>/dev/null | grep -qF "$keyid"; then
        echo "    GPG key already on GitHub, skipping upload"
    else
        if ! gh auth status 2>&1 | grep -q 'write:gpg_key'; then
            echo "    Refreshing gh auth to include write:gpg_key scope..."
            gh auth refresh -h github.com -s write:gpg_key || true
        fi
        echo "    Uploading GPG key to GitHub..."
        printf '%s\n' "$pubkey" | gh gpg-key add - --title "$(hostname)" \
            || echo "    ! upload failed — run 'gh auth refresh -s write:gpg_key' and retry"
    fi

    # Configure git to auto-sign with this key. Only set fields that are
    # missing so we don't clobber a power-user override.
    git config --global user.signingkey "$keyid"
    [[ -z "$(git config --global commit.gpgsign)" ]] && git config --global commit.gpgsign true
    [[ -z "$(git config --global tag.gpgsign)" ]]    && git config --global tag.gpgsign true
    echo "    git configured to sign commits + tags with $keyid"

    # Re-run the cache TTL setup now that a signing key exists. On
    # fresh-PC bootstrap, install_gpg_agent_cache runs earlier in the
    # installer and short-circuits because no key was present yet —
    # this second call lets it actually apply the TTL config.
    install_gpg_agent_cache
}

# Default-deny incoming firewall baseline. Auto-applied (not behind
# --secure) because it's pure-win on a personal laptop: blocks unsolicited
# inbound, leaves outbound free, reversible with `sudo ufw disable`.
#
# Port 22 is only opened when sshd is actually enabled on this host —
# otherwise punching it would leave a permissive rule pointing at a
# nonexistent service. The `--secure` module's SSH hardening wizard
# handles port-22-vs-custom-port logic separately.
install_ufw_baseline() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "  • ufw not installed, skipping firewall baseline"
        return
    fi

    # Always re-apply the baseline defaults (deny incoming, allow
    # outgoing). The previous "skip if active" guard was too permissive:
    # fox-doctor catches drift on existing installs, but we then refused
    # to fix it. Default policies are idempotent — `default deny
    # incoming` on an already-deny-incoming UFW is a no-op. We DO skip
    # the `--force reset` when UFW is already active, so existing
    # user-added rules (custom port allows, etc.) survive.
    local active=0
    sudo ufw status 2>/dev/null | grep -q '^Status: active' && active=1
    if (( active )); then
        echo "  • UFW active — re-applying baseline policy (preserves existing rules)"
    else
        echo "  Applying UFW baseline (deny incoming, allow outgoing)..."
        sudo ufw --force reset >/dev/null 2>&1 || true
    fi
    sudo ufw default deny incoming  >/dev/null
    sudo ufw default allow outgoing >/dev/null

    if systemctl is-enabled --quiet sshd 2>/dev/null \
       || systemctl is-active  --quiet sshd 2>/dev/null; then
        # `limit` instead of `allow`: rate-limits brute force. UFW drops
        # connections when the same source IP makes >6 attempts in 30s.
        # Free win over `allow ssh` for the same port-22-open effect.
        sudo ufw limit ssh >/dev/null
        echo "    sshd detected — port 22 allowed with rate-limit (limit ssh)"
    fi

    # Interactive port allowlist: prompt the user for any additional
    # ports they want exposed (LAN dev servers, game launchers, sync
    # tools, etc). Skipped silently in --yes / no-TTY mode so unattended
    # installs aren't blocked. Format accepted: "8080 3000 5432" — space
    # or comma separated, optional "/tcp"/"/udp" suffix per entry.
    if [[ -t 0 ]] && ! ${ASSUME_YES:-false}; then
        echo
        echo "  Open additional ports? (e.g. 8080 3000/tcp 51820/udp)"
        echo "  Press Enter to skip, or list ports separated by spaces:"
        read -r -p "  ports> " _extra_ports
        if [[ -n "$_extra_ports" ]]; then
            # Split on whitespace OR commas. Validate each entry.
            IFS=' ,' read -ra _port_list <<<"$_extra_ports"
            local p num proto
            for p in "${_port_list[@]}"; do
                [[ -z "$p" ]] && continue
                # Allow "port" or "port/tcp" or "port/udp".
                num="${p%%/*}"
                proto=""
                if [[ "$p" == */* ]]; then
                    proto="${p#*/}"
                    [[ "$proto" != tcp && "$proto" != udp ]] && {
                        echo "    ! skipping '$p' — proto must be tcp or udp"; continue
                    }
                fi
                if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > 65535 )); then
                    echo "    ! skipping '$p' — not a valid port"
                    continue
                fi
                if [[ -n "$proto" ]]; then
                    sudo ufw allow "${num}/${proto}" >/dev/null
                    echo "    + allowed ${num}/${proto}"
                else
                    sudo ufw allow "$num" >/dev/null
                    echo "    + allowed ${num}"
                fi
            done
        fi
    fi

    # SSH lockout safety: if we're being run over SSH (e.g. `fox install`
    # from a remote shell), the deny-incoming default would kill the
    # current session mid-install. SSH_CONNECTION format is
    # "client_ip client_port server_ip server_port" — explicitly allow
    # the server port we're connected to before enabling.
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local _ssh_port
        _ssh_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
        if [[ "$_ssh_port" =~ ^[0-9]+$ ]] && (( _ssh_port > 0 && _ssh_port < 65536 )); then
            sudo ufw limit "${_ssh_port}/tcp" >/dev/null 2>&1 || true
            echo "    active SSH session on port ${_ssh_port} — allowed (rate-limited) to avoid lockout"
        fi
    fi

    # Enable low-volume logging — captures denied attempts to
    # /var/log/ufw.log without flooding disk. "low" includes blocked
    # packets but not every allowed connection. Useful tripwire for
    # spotting scans on hostile networks.
    sudo ufw logging low >/dev/null 2>&1 || true
    echo "y" | sudo ufw enable >/dev/null
    sudo systemctl enable --now ufw >/dev/null 2>&1 \
        || echo "    ! ufw enable failed — re-run with: sudo -v && fox install --full"
    echo "    UFW enabled (deny incoming + low logging)"
}

# Kernel hardening sysctls. Auto-applied — drop-in at
# /etc/sysctl.d/99-foxml-hardening.conf, reversible by deleting the file
# and running `sudo sysctl --system`. Settings chosen for "pure-win on a
# personal Arch+Hyprland laptop" — no server-only knobs, no settings
# that break common dev workflows (Docker, eBPF tooling for non-root
# users is the one we *do* tighten; if you need bpf as non-root, drop
# the file or override in a 100-prefixed file).
#
# Notable choices:
#   - kernel.kptr_restrict=2          hides kernel pointers in /proc
#   - kernel.dmesg_restrict=1         only root reads dmesg
#   - kernel.unprivileged_bpf_disabled=1   non-root can't load eBPF
#   - kernel.yama.ptrace_scope=1      only parent process can ptrace
#   - net.ipv4.tcp_syncookies=1       SYN-flood mitigation
#   - net.ipv4.conf.*.rp_filter=1     reverse-path filter (anti-spoof)
#   - net.ipv4.conf.*.log_martians=1  log packets with impossible src
#   - fs.suid_dumpable=0              setuid procs don't core-dump
install_kernel_hardening() {
    local conf="/etc/sysctl.d/99-foxml-hardening.conf"
    local desired
    desired="$(cat <<'EOF'
# FoxML kernel hardening — auto-applied by install.sh.
# Reversible: `sudo rm /etc/sysctl.d/99-foxml-hardening.conf && sudo sysctl --system`.
kernel.kptr_restrict             = 2
kernel.dmesg_restrict            = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope         = 1
net.ipv4.tcp_syncookies          = 1
# Mitigate TCP TIME_WAIT assassination (RFC 1337) — laptop is a client
# so we generally don't care, but cheap defence with no downside.
net.ipv4.tcp_rfc1337             = 1
# Drop ICMP echoes to the broadcast address (Smurf amplification).
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Bogus ICMP responses (RFC 1812 violations) — log but don't act.
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter      = 1
net.ipv4.conf.default.rp_filter  = 1
net.ipv4.conf.all.log_martians   = 1
net.ipv4.conf.default.log_martians = 1
# ICMP redirects: we are NOT a router. Don't accept routing updates
# from the network; don't send them either. Both directions are
# spoofing / MITM vectors that exist for legacy multi-NIC routers.
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects     = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0
# Source-routed packets — refuse. No legitimate use on a laptop, and
# they let attackers force traffic through specific paths.
net.ipv4.conf.all.accept_source_route     = 0
net.ipv4.conf.default.accept_source_route = 0
# IPv6 parity. accept_ra=1 (default) is left alone — needed for SLAAC
# on normal IPv6 networks.
net.ipv6.conf.all.accept_redirects     = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route     = 0
net.ipv6.conf.default.accept_source_route = 0
# Kernel Self-Protection Project — harden the eBPF JIT compiler against
# Spectre / side-channel and JIT-spray attacks. 2 = always-on (vs 1 =
# always-on-only-for-non-root). Costs ~5% on BPF workloads we don't
# really have on a laptop.
net.core.bpf_jit_harden = 2
fs.suid_dumpable                 = 0

# ── Extreme-hardening additions ──────────────────────────────────
# perf_event_paranoid = 3 — block unprivileged use of the perf subsystem
# entirely. Closes a known kernel-address-leak / side-channel surface.
# perf still works for root + CAP_PERFMON; only non-root unprivileged
# calls are blocked. Costs ~nothing on a personal laptop.
kernel.perf_event_paranoid       = 3

# kexec_load_disabled = 1 — prevent loading a new kernel image at runtime
# via kexec_load(). Closes the "kexec bootkit" path where an attacker
# with root could swap the running kernel without rebooting through
# UEFI / Secure Boot. One-way ratchet: once set, can't be undone until
# next boot.
kernel.kexec_load_disabled       = 1

# Explicit forwarding-off. Default is usually 0 but pin it: this is a
# laptop, not a router. Prevents accidental misconfig turning the host
# into an open relay.
net.ipv4.ip_forward              = 0
net.ipv6.conf.all.forwarding     = 0
net.ipv6.conf.default.forwarding = 0

# Drop IPv6 router advertisements — we don't need stateless autoconfig
# on a personal machine, and accepting RAs is a rogue-router attack
# vector on hostile networks (cafés, dorm WiFi).
net.ipv6.conf.all.accept_ra      = 0
net.ipv6.conf.default.accept_ra  = 0

# Close the TCP-timestamps uptime fingerprint leak. Tiny info disclosure,
# defaults to on, no downside on a desktop client.
net.ipv4.tcp_timestamps          = 0

# vm.unprivileged_userfaultfd = 0 — close the userfaultfd local-privesc
# vector (CVE-2016-3070 + several since). Only root can use userfaultfd
# now; no real-world userspace tool on a desktop needs it.
vm.unprivileged_userfaultfd      = 0

# dev.tty.ldisc_autoload = 0 — prevent unprivileged users from auto-
# loading TTY line discipline modules (historical local-privesc surface,
# e.g. CVE-2020-14381).
dev.tty.ldisc_autoload           = 0

# FS protections — Yama-style hardening of hardlink, symlink, FIFO, and
# regular-file follow semantics in world-writable dirs (e.g. /tmp).
# Closes the "TOCTOU symlink races" class of local exploits.
fs.protected_hardlinks           = 1
fs.protected_symlinks            = 1
fs.protected_fifos               = 2
fs.protected_regular             = 2

# OS fingerprint obfuscation. nmap's OS detection looks at TTL +
# TCP window sizing — defaults expose "this is a Linux 6.x box".
# TTL=128 mimics Windows (Windows ships 128, Linux ships 64), TCP
# window randomisation makes the fingerprint less stable. Doesn't
# defeat application-layer scans but blunts the network-layer
# "what OS is this?" question.
net.ipv4.ip_default_ttl          = 128
net.ipv4.tcp_invalid_ratelimit   = 500

# SysRq hardening. Default Arch kernel exposes the full Magic-SysRq
# command set, which an attacker with physical keyboard access can use
# to bypass the lock screen entirely (REISUB → sync + remount-readonly
# + kill all + reboot, no auth needed). =4 keeps only the "control
# console keyboard" subset (Alt-SysRq-K kills X/Wayland sessions, etc.)
# without granting reboot / kill-all. Set to 0 to fully disable.
kernel.sysrq                     = 4

# ARP / MITM protection on hostile networks (café WiFi, conferences).
# arp_ignore=1: only respond to ARP requests for IPs we explicitly
# configured (no broadcasting "I am that IP" for stuff we shouldn't).
# arp_announce=2: when sending ARPs, only use the source IP of the
# outgoing interface — never leak our other-interface IPs.
# Closes the "I'm the router, send your traffic to me" attack class.
net.ipv4.conf.all.arp_ignore     = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.all.arp_announce   = 2
net.ipv4.conf.default.arp_announce = 2
EOF
)"

    if [[ -f "$conf" ]] && diff -q <(printf '%s\n' "$desired") "$conf" >/dev/null 2>&1; then
        echo "  • kernel hardening sysctls already in place"
        return
    fi

    echo "  Writing kernel hardening sysctls to $conf..."
    printf '%s\n' "$desired" | sudo tee "$conf" >/dev/null
    sudo chmod 644 "$conf"
    if sudo sysctl --system >/dev/null 2>&1; then
        echo "    sysctl --system applied"
    else
        echo "  ! sysctl --system reported errors — review with 'sudo sysctl --system'"
    fi
}

# ─────────────────────────────────────────
# Browser hardening — arkenfox user.js + Firefox-in-firejail.
#
# arkenfox is the de-facto Firefox hardening preset (telemetry off,
# fingerprinting resistance on, sane third-party cookie defaults).
# Latest user.js fetched from upstream and dropped into the user's
# default-release profile. firejail's bundled firefox profile gets
# auto-symlinked via `firecfg` so `firefox` runs sandboxed by default.
# Idempotent: skips downloads if a recent arkenfox is already present,
# and `firecfg` is a no-op when symlinks already exist.
# ─────────────────────────────────────────
install_browser_hardening() {
    if ! command -v firefox >/dev/null 2>&1; then
        echo "  • firefox not installed, skipping browser hardening"
        return 0
    fi

    # 1. arkenfox user.js into the default-release profile (Firefox's
    #    typical naming). If the user has multiple profiles, we touch
    #    only the one Firefox uses by default.
    local ff_dir="$HOME/.mozilla/firefox"
    local profile=""
    if [[ -d "$ff_dir" ]]; then
        profile=$(find "$ff_dir" -maxdepth 1 -type d -name '*.default-release' | head -1)
        [[ -z "$profile" ]] && profile=$(find "$ff_dir" -maxdepth 1 -type d -name '*.default' | head -1)
    fi
    if [[ -z "$profile" ]]; then
        echo "  • Firefox profile not found — launch Firefox once, then re-run for arkenfox"
    else
        local user_js="$profile/user.js"
        local overrides="$profile/user-overrides.js"
        # Re-download if missing or older than 30 days. arkenfox tags
        # quarterly; 30d is conservative.
        local should_update=1
        if [[ -f "$user_js" ]] && [[ $(find "$user_js" -mtime -30 2>/dev/null | wc -l) -gt 0 ]] \
            && grep -q "arkenfox user.js" "$user_js" 2>/dev/null; then
            should_update=0
        fi
        if (( should_update )); then
            if curl -fsSL --max-time 30 \
                https://raw.githubusercontent.com/arkenfox/user.js/master/user.js \
                -o "$user_js.tmp" 2>/dev/null; then
                mv "$user_js.tmp" "$user_js"
                echo "  arkenfox user.js → $profile (Firefox will apply on next launch)"
            else
                echo "  ! arkenfox download failed — skipping (network issue?)"
                rm -f "$user_js.tmp"
            fi
        else
            echo "  • arkenfox user.js already up-to-date"
        fi
        # Drop a personal overrides file (empty by default) so the user
        # has a clear place to relax specific arkenfox settings without
        # editing user.js itself (which the next refresh would clobber).
        if [[ ! -f "$overrides" ]]; then
            cat > "$overrides" <<'EOF'
// user-overrides.js — your personal overrides for arkenfox user.js.
//
// Anything you set here wins over the arkenfox defaults. Common
// relaxations on a personal laptop:
//
//   user_pref("privacy.resistFingerprinting", false);  // breaks dark mode + screen scaling
//   user_pref("browser.startup.page", 3);              // restore previous session
//   user_pref("browser.search.suggest.enabled", true); // search suggestions
//
// See https://github.com/arkenfox/user.js/wiki/3.1-Overrides for the full list.
EOF
            echo "  user-overrides.js stub created (edit to relax arkenfox defaults)"
        fi
    fi

    # 2. firejail symlinks for sandboxed browser launch. firecfg places
    # /usr/local/bin/firefox -> /usr/bin/firejail, which intercepts
    # `firefox` invocations and applies /etc/firejail/firefox.profile.
    if command -v firejail >/dev/null 2>&1; then
        if ! [[ -L /usr/local/bin/firefox ]] || ! readlink /usr/local/bin/firefox | grep -q firejail; then
            sudo firecfg >/dev/null 2>&1 \
                && echo "  firejail symlinks applied (firefox now runs sandboxed)"
        else
            echo "  • firejail already wired for firefox"
        fi

        # 3. Plug the Firejail DNS leak. By default, firejail-wrapped
        # Firefox can fall back to whatever DNS its sandbox sees — which
        # may bypass our systemd-resolved DoH setup if the sandbox has
        # its own /etc/resolv.conf. Pin DNS to 127.0.0.53 (resolved's
        # stub listener) via a user-local profile override so all DNS
        # queries route through DoH regardless.
        local firejail_dir="$HOME/.config/firejail"
        local firejail_override="$firejail_dir/firefox.local"
        mkdir -p "$firejail_dir"
        if [[ ! -f "$firejail_override" ]] || ! grep -q '^# foxml-managed' "$firejail_override"; then
            cat > "$firejail_override" <<'EOF'
# foxml-managed — Firejail Firefox overrides.
# Pins DNS to 127.0.0.53 (systemd-resolved stub) so the sandbox can't
# fall back to a non-DoH resolver. Without this, DNS queries from
# inside the sandbox can bypass our --privacy module's DoH config.
dns 127.0.0.53
# Belt + suspenders: route a second resolver entry as backup.
dns 127.0.0.1
EOF
            echo "  + firejail firefox.local override (DNS pinned to 127.0.0.53 for DoH)"
        else
            echo "  • firejail firefox.local already configured"
        fi
    fi

    return 0
}

# ─────────────────────────────────────────
# USBGuard — allow-list policy for USB devices.
#
# Auto-generates the initial policy from *currently connected* devices:
# anything plugged in at install time is trusted (your built-in keyboard,
# fingerprint reader, webcam, etc.). New devices plugged later are
# blocked until explicitly allowed via `sudo usbguard allow-device <id>`.
#
# Tradeoff: this is the whole POINT of usbguard, but it can lock you out
# of a freshly bought mouse/keyboard until you whitelist it. Pair with
# the `usbguard list-devices` cheat to find IDs quickly.
# ─────────────────────────────────────────
install_usbguard() {
    if ! command -v usbguard >/dev/null 2>&1; then
        echo "  • usbguard not installed, skipping"
        return 0
    fi
    local rules=/etc/usbguard/rules.conf
    if [[ ! -s "$rules" ]]; then
        # SHOW the devices before whitelisting them. If a malicious USB
        # (Rubber Ducky etc.) is plugged in during install, blind
        # `generate-policy` would trust it forever. Listing first means
        # the user can spot something unexpected and unplug it before
        # confirming.
        echo "  Devices currently connected (these will be trusted):"
        if command -v lsusb >/dev/null 2>&1; then
            lsusb | sed 's/^/    /'
        else
            sudo usbguard list-devices 2>/dev/null | sed 's/^/    /'
        fi
        echo ""
        if [[ -t 0 ]] && ! foxml_prompt_yn "Whitelist all of these as trusted devices? [y/N] "; then
            echo "  • USBGuard install aborted by user. Unplug suspicious devices and re-run --usbguard."
            return 0
        fi
        echo "  Generating initial USBGuard policy from currently connected devices..."
        # Capture the count BEFORE chmod 600 locks the file to root —
        # shell redirect (`<`) happens as the calling user, so a
        # post-chmod read would fail with EACCES. Use `sudo wc -l` on
        # the path so it opens the file in privileged context.
        sudo usbguard generate-policy | sudo tee "$rules" >/dev/null
        local _rule_count
        _rule_count=$(sudo wc -l "$rules" 2>/dev/null | awk '{print $1}')
        sudo chmod 600 "$rules"
        sudo chown root:root "$rules"
        echo "    → $rules (${_rule_count:-?} device rules)"
    else
        echo "  • USBGuard rules already present at $rules"
    fi

    # Allow current user to query and allow-device via the dbus IPC, so
    # `usbguard list-devices` works without sudo and notifications can
    # surface new-device prompts.
    local conf=/etc/usbguard/usbguard-daemon.conf
    if [[ -f "$conf" ]] && ! grep -qE "^IPCAllowedUsers=.*\b${USER}\b" "$conf"; then
        sudo sed -i -E "s|^#?IPCAllowedUsers=.*|IPCAllowedUsers=root ${USER}|" "$conf"
        echo "    IPC access granted to user ${USER}"
    fi

    if ! systemctl is-active --quiet usbguard; then
        sudo systemctl enable --now usbguard >/dev/null 2>&1 \
            && echo "    usbguard service enabled"
    else
        sudo systemctl reload usbguard >/dev/null 2>&1 || true
        echo "  • usbguard already active (reloaded)"
    fi
    return 0
}

# ─────────────────────────────────────────
# arch-audit — daily systemd-user timer that checks installed packages
# against the Arch Linux security advisories. Failed audits push a
# notify-send so you actually see the CVE list.
# ─────────────────────────────────────────
install_arch_audit() {
    if ! command -v arch-audit >/dev/null 2>&1; then
        echo "  • arch-audit not installed, skipping"
        return 0
    fi
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"

    cat > "$unit_dir/foxml-arch-audit.service" <<'EOF'
[Unit]
Description=FoxML — daily arch-audit check against Arch Linux security advisories
After=network-online.target

[Service]
Type=oneshot
# -uf  : upgrades-only (only show advisories that have a fix available)
# Falls through to notify-send when any CVE is open against an installed
# package. Quiet when clean.
ExecStart=/bin/sh -c '\
    out=$(arch-audit -uf 2>/dev/null); \
    if [ -n "$out" ]; then \
        count=$(printf "%%s" "$out" | wc -l); \
        notify-send -u critical -t 30000 \
            "arch-audit: $count package(s) with available fixes" \
            "$(printf "%%s" "$out" | head -10)"; \
    fi'
EOF

    cat > "$unit_dir/foxml-arch-audit.timer" <<'EOF'
[Unit]
Description=Run arch-audit daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload >/dev/null 2>&1
    systemctl --user enable --now foxml-arch-audit.timer >/dev/null 2>&1 \
        && echo "  arch-audit daily timer enabled"
    return 0
}

# ─────────────────────────────────────────
# NetworkManager MAC randomization. Opt-in only (--mac-random) because
# dorm / enterprise / captive-portal networks gatekeep on persistent
# MAC addresses — randomization breaks those setups. Standard for
# coffee-shop / hotel wifi protection though.
# ─────────────────────────────────────────
# ─────────────────────────────────────────
# AppArmor enablement.
#
# Three steps, in order:
#   1. Modify the kernel cmdline so the LSM stack includes apparmor.
#      Modern kernels (5.x+) accept `lsm=landlock,lockdown,yama,
#      integrity,apparmor,bpf` — apparmor MUST appear before bpf for
#      full coverage. Without this, even an enabled apparmor service
#      can't enforce anything.
#   2. Enable apparmor.service so the parser loads /etc/apparmor.d/
#      profiles at boot.
#   3. Tell the user to reboot — kernel cmdline changes don't apply
#      until reboot.
#
# Bootloader detection: tries systemd-boot first (Arch + greetd is the
# common case), then grub. Limine and others print a manual hint.
# Refuses to splice the cmdline twice — idempotent on re-runs.
# ─────────────────────────────────────────
_apparmor_systemd_boot() {
    local needed_lsm='landlock,lockdown,yama,integrity,apparmor,bpf'
    local modified=0
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        # Already has apparmor in some lsm= value? Skip.
        if grep -qE '^options .*\blsm=[^[:space:]]*apparmor' "$entry"; then
            continue
        fi
        if grep -qE '^options .*\blsm=' "$entry"; then
            # Append apparmor to existing lsm= list.
            sudo sed -i -E 's|(^options .*\blsm=)([^[:space:]]*)|\1\2,apparmor|' "$entry"
        else
            # No lsm= yet — append the full recommendation.
            sudo sed -i -E "s|^options (.*)$|options \\1 lsm=${needed_lsm}|" "$entry"
        fi
        modified=$((modified + 1))
        echo "  + $entry: apparmor added to kernel cmdline"
    done
    (( modified == 0 )) && echo "  • all systemd-boot entries already include apparmor in lsm="
}

_apparmor_grub() {
    local default_file=/etc/default/grub
    [[ -f "$default_file" ]] || return 1
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*\blsm=[^"]*apparmor' "$default_file"; then
        echo "  • grub cmdline already includes apparmor"
        return 0
    fi
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*\blsm=' "$default_file"; then
        sudo sed -i -E 's|(^GRUB_CMDLINE_LINUX_DEFAULT=.*\blsm=)([^[:space:]"]*)|\1\2,apparmor|' "$default_file"
    else
        sudo sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$|GRUB_CMDLINE_LINUX_DEFAULT="\1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf"|' "$default_file"
    fi
    echo "  + grub default cmdline updated; regenerating grub.cfg..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
        && echo "    grub.cfg regenerated"
}

install_apparmor() {
    if ! pacman -Qi apparmor &>/dev/null; then
        echo "  • apparmor not installed (re-run with --deps --apparmor)"
        return 0
    fi

    # Patch kernel cmdline via whichever bootloader we find.
    if [[ -d /boot/loader/entries ]]; then
        _apparmor_systemd_boot
    elif [[ -f /etc/default/grub ]]; then
        _apparmor_grub
    else
        echo "  ! couldn't detect bootloader (systemd-boot / grub)."
        echo "    Manually add this to your kernel cmdline and regenerate:"
        echo "      lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
    fi

    # Enable the service so the parser runs on next boot.
    if ! systemctl is-enabled --quiet apparmor 2>/dev/null; then
        sudo systemctl enable apparmor.service >/dev/null 2>&1 \
            && echo "  apparmor.service enabled (loads profiles at boot)"
    else
        echo "  • apparmor.service already enabled"
    fi

    echo ""
    echo "  Reboot to activate AppArmor. After reboot, verify with:"
    echo "    sudo aa-status   # lists loaded profiles + processes in enforce/complain"
    echo ""
    echo "  Arch's apparmor package ships a baseline profile set in /etc/apparmor.d/."
    echo "  For comprehensive coverage (1500+ profiles incl. firefox/discord/ollama),"
    echo "  consider the AUR package 'apparmor.d':  yay -S apparmor.d"
    return 0
}

install_polkit_strict() {
    # Drop a JS rule into /etc/polkit-1/rules.d/ that forces password
    # auth for every privileged GUI action. Default polkit caches a
    # success for ~5 minutes (AUTH_ADMIN_KEEP); this changes that to
    # AUTH_ADMIN — no cache, prompts every time. Annoying for daily
    # GUI sudo, decisive against "walked away from desk → attacker
    # clicks install" attacks.
    local rule=/etc/polkit-1/rules.d/99-foxml-strict.rules
    sudo install -d /etc/polkit-1/rules.d
    sudo tee "$rule" >/dev/null <<'EOF'
// foxml-managed — require fresh password auth for every admin action.
// Revert: sudo rm /etc/polkit-1/rules.d/99-foxml-strict.rules
polkit.addRule(function(action, subject) {
    // AUTH_ADMIN means prompt for the admin password every time, no
    // 5-minute keep-window. Applies to package installs, USB mounts
    // by non-owners, NetworkManager hotspot create, etc.
    if (subject.isInGroup("wheel")) {
        // Exception: switching power profiles is harmless enough to allow
        // without a re-prompt (usually allowed for active users anyway).
        if (action.id == "org.freedesktop.UPower.PowerProfiles.switch-profile") {
            return undefined;
        }
        return polkit.Result.AUTH_ADMIN;
    }
});
EOF
    sudo chmod 644 "$rule"
    sudo systemctl reload polkit 2>/dev/null \
        || sudo systemctl restart polkit 2>/dev/null || true
    echo "  Polkit strict mode enabled (every admin action re-prompts)"
}

install_mac_random() {
    local conf=/etc/NetworkManager/conf.d/00-foxml-mac-random.conf
    sudo install -d /etc/NetworkManager/conf.d
    sudo tee "$conf" >/dev/null <<'EOF'
# foxml-managed — NetworkManager MAC randomization.
# Reverts: sudo rm /etc/NetworkManager/conf.d/00-foxml-mac-random.conf
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
# Per-SSID stable identifier so each network gets a deterministic
# (but unique) MAC. Prevents the network from churning ARP tables
# every connection while still presenting a different MAC per SSID.
connection.stable-id=${CONNECTION}/${BOOT}
EOF
    sudo systemctl reload NetworkManager 2>/dev/null || \
        sudo systemctl restart NetworkManager 2>/dev/null || true
    echo "  MAC randomization enabled (per-SSID stable, varies across networks)"
    return 0
}

# Enable fingerprint authentication for the greetd login screen on hosts

# Enable fingerprint authentication for the greetd login screen on hosts
# that have a fingerprint reader. Idempotent: leaves an existing pam_fprintd
# line wherever the user already placed it; on first install, inserts a new
# `auth sufficient pam_fprintd.so` as the first auth rule (so it short-
# circuits before pam_unix prompts for a password).
#
# Reader detection uses fprintd-list, which queries libfprint and so covers
# any bus type fprintd supports — USB, I2C, SPI hardwired sensors. Reads
# /etc/pam.d/greetd without sudo (it's mode 644) so a sudo timeout during
# the idempotency check can't be misread as "line missing" and trigger a
# duplicate insert. `sudo -v` is called before any destructive write so the
# function bails cleanly if auth times out instead of half-running.
install_greetd_fingerprint() {
    if [[ ! -f /etc/pam.d/greetd ]]; then
        echo "  • /etc/pam.d/greetd missing (greetd not installed?), skipping fingerprint PAM"
        return
    fi
    if ! command -v fprintd-list >/dev/null 2>&1; then
        echo "  • fprintd not installed, skipping fingerprint PAM"
        return
    fi

    # fprintd-list output starts with "found N devices" — N=0 means no
    # usable reader on any bus libfprint understands. Empty awk output (no
    # such line) also treats as no reader, so polkit denials and other
    # fprintd errors fail safe.
    local devs
    devs=$(fprintd-list "$USER" 2>/dev/null | awk '/^found ([0-9]+) devices/{print $2; exit}')
    if [[ -z "$devs" || "$devs" -eq 0 ]]; then
        echo "  • no fingerprint reader detected, skipping fingerprint PAM"
        return
    fi

    # /etc/pam.d/greetd is world-readable (mode 644). Reading without sudo
    # means a sudo failure can't be confused with a grep miss.
    if grep -qE '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_fprintd\.so' /etc/pam.d/greetd; then
        echo "  • /etc/pam.d/greetd already enables pam_fprintd, leaving as-is"
        return
    fi

    # Validate sudo before any destructive write so a missed fingerprint
    # prompt aborts cleanly instead of leaving a half-applied edit.
    if ! sudo -v 2>/dev/null; then
        echo "  ⚠ sudo unavailable (timed out?), skipping fingerprint PAM — rerun installer to retry"
        return
    fi

    sudo cp /etc/pam.d/greetd /etc/pam.d/greetd.foxml-bak
    if grep -q '^#%PAM-1.0' /etc/pam.d/greetd; then
        sudo sed -i '/^#%PAM-1.0/a auth      sufficient  pam_fprintd.so' /etc/pam.d/greetd
    else
        sudo sed -i '1i auth      sufficient  pam_fprintd.so' /etc/pam.d/greetd
    fi
    echo "  pam_fprintd.so → /etc/pam.d/greetd (login screen accepts fingerprint)"
    echo "  • backup at /etc/pam.d/greetd.foxml-bak"
    if ! fprintd-list "$USER" 2>/dev/null | grep -q '^ - #'; then
        echo "  • no fingerprints enrolled for $USER yet — run: fprintd-enroll"
    fi
}

install_greetd() {
    if ! pacman -Qi greetd-regreet &>/dev/null; then
        echo "  • greetd-regreet not installed, skipping login-screen setup"
        return
    fi

    local staged="$HOME/.config/regreet"
    if [[ ! -f "$staged/regreet.css" || ! -f "$staged/regreet.toml" || ! -f "$staged/hyprland.conf" || ! -f "$staged/select-monitor.sh" ]]; then
        echo "  Staged regreet files missing in $staged — skipping"
        return
    fi

    # Wallpaper referenced from regreet.toml. Read it out and copy that exact
    # file, so theme swaps that change the wallpaper Just Work.
    local wall_path
    wall_path=$(awk -F'"' '/^path *= *"/ { print $2; exit }' "$staged/regreet.toml")
    [[ -z "$wall_path" ]] && wall_path="/usr/share/wallpapers/foxml_earthy.jpg"
    local wall_name="$(basename "$wall_path")"
    local wall_src="$HOME/.wallpapers/$wall_name"

    if [[ ! -f "$wall_src" ]]; then
        echo "  Login wallpaper $wall_src missing — copy your wallpaper to ~/.wallpapers/ first"
        return
    fi

    sudo install -d /etc/greetd /usr/share/wallpapers
    sudo install -m 644 "$staged/regreet.css"      /etc/greetd/regreet.css
    sudo install -m 644 "$staged/regreet.toml"     /etc/greetd/regreet.toml
    sudo install -m 644 "$staged/hyprland.conf"    /etc/greetd/hyprland.conf
    sudo install -m 755 "$staged/select-monitor.sh" /etc/greetd/select-monitor.sh
    sudo install -m 644 "$wall_src"                "$wall_path"
    echo "  regreet css/toml/hyprland.conf → /etc/greetd/"
    echo "  monitor selector → /etc/greetd/select-monitor.sh"
    echo "  login wallpaper → $wall_path"

    # /etc/greetd/config.toml — only rewrite if it's still the stock default
    # (command = "agreety …"). Preserve any user customization beyond that.
    local cfg=/etc/greetd/config.toml
    if [[ ! -f "$cfg" ]] || sudo grep -qE '^command = "agreety' "$cfg" 2>/dev/null; then
        sudo tee "$cfg" >/dev/null <<'EOF'
[terminal]
vt = 1
[default_session]
command = "Hyprland -c /etc/greetd/hyprland.conf"
user = "greeter"
EOF
        echo "  /etc/greetd/config.toml (Hyprland greeter session)"
    else
        echo "  • /etc/greetd/config.toml already customized — leaving as-is"
    fi

    if ! systemctl is-enabled --quiet greetd 2>/dev/null; then
        sudo systemctl enable greetd && echo "  greetd enabled (login screen on next boot)"
    else
        echo "  • greetd already enabled"
    fi
}

# ─────────────────────────────────────────
# CPU throttling / power tuning — interactive wizard prompted at end of
# install. Each step is its own y/N so users can pick & choose:
#   * Intel turbo disable → /etc/tmpfiles.d/disable-turbo.conf
#     (systemd-tmpfiles re-applies on every boot, so the kernel reset
#     after suspend/wake doesn't bring turbo back)
#   * cpupower max-frequency cap → persisted via /etc/default/cpupower
#     and cpupower.service so it survives reboots
#   * Optional CPU governor (powersave / performance / schedutil / etc.)
#   * throttled — Lenovo ThinkPad MSR-based undervolt + temperature fix
#     from AUR (only offered when DMI says ThinkPad)
# Skipped under -y because every step needs a user-chosen value.
# ─────────────────────────────────────────

# Idempotent KEY=VALUE writer for /etc/default/cpupower (sourced as shell
# by the cpupower service). Replaces an existing key if present, else
# appends. Numeric values pass unquoted; quote string values at the call
# site (`'performance'`).
_persist_cpupower() {
    local key="$1" val="$2"
    sudo install -d /etc/default
    [[ -f /etc/default/cpupower ]] || echo "" | sudo tee /etc/default/cpupower >/dev/null
    if sudo grep -qE "^${key}=" /etc/default/cpupower; then
        sudo sed -i -E "s|^${key}=.*|${key}=${val}|" /etc/default/cpupower
    else
        echo "${key}=${val}" | sudo tee -a /etc/default/cpupower >/dev/null
    fi
}

install_throttling() {
    # TTY-gated rather than --yes-gated — every step inside this wizard
    # asks the user a hardware-specific question that doesn't have a
    # sensible auto-default (governor name, frequency cap MHz, etc.).
    # If we have a terminal, ask; if not (curl-bash), skip silently.
    if [[ ! -t 0 ]]; then
        echo ""
        echo "  • Throttling setup skipped (no TTY for interactive wizard)"
        return
    fi

    echo ""
    echo "╭──────────────────────────────────────────────────────────────────╮"
    echo "│   CPU Throttling / Power Setup (optional)                       │"
    echo "├──────────────────────────────────────────────────────────────────┤"
    echo "│ Configure max-frequency cap, Intel turbo, governor, and (on     │"
    echo "│ ThinkPads) the 'throttled' MSR fix. Each step is opt-in.        │"
    echo "╰──────────────────────────────────────────────────────────────────╯"
    # `return 0` (not bare `return`) — bare return propagates the
    # prompt's non-zero exit, which trips install.sh's `set -e` + ERR
    # trap and aborts the whole installer when the user picks "n".
    foxml_prompt_yn "Configure CPU throttling now? [y/N] " || return 0

    # Hardware detection
    local is_intel=false is_thinkpad=false
    grep -qi 'GenuineIntel' /proc/cpuinfo && is_intel=true
    if [[ -r /sys/class/dmi/id/product_family ]] \
        && grep -qi thinkpad /sys/class/dmi/id/product_family 2>/dev/null; then
        is_thinkpad=true
    elif [[ -r /sys/class/dmi/id/product_version ]] \
        && grep -qi thinkpad /sys/class/dmi/id/product_version 2>/dev/null; then
        is_thinkpad=true
    fi

    # Resolve AUR helper — may not be set if --deps wasn't passed earlier
    local aur=""
    command -v yay  &>/dev/null && aur="yay"
    [[ -z "$aur" ]] && command -v paru &>/dev/null && aur="paru"

    # ── 1. Intel turbo ────────────────────────────────────────────
    if $is_intel && [[ -e /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local turbo_now turbo_state="enabled"
        turbo_now=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)
        [[ "$turbo_now" == "1" ]] && turbo_state="disabled"
        echo ""
        echo "  Intel Turbo Boost is currently: ${turbo_state}"
        if foxml_prompt_yn "  Disable Intel turbo on every boot? [y/N] "; then
            sudo install -d /etc/tmpfiles.d
            sudo tee /etc/tmpfiles.d/disable-turbo.conf >/dev/null <<'EOF'
# Re-applied on every boot by systemd-tmpfiles
w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1
EOF
            sudo systemd-tmpfiles --create /etc/tmpfiles.d/disable-turbo.conf >/dev/null 2>&1 || true
            echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null
            echo "    Intel Turbo disabled (now and on every boot)"
        fi
    fi

    # ── 2. cpupower max frequency ─────────────────────────────────
    echo ""
    if foxml_prompt_yn "  Cap CPU max frequency via cpupower? [y/N] "; then
        if ! pacman -Qi cpupower &>/dev/null; then
            echo "    Installing cpupower..."
            sudo pacman -S --needed --noconfirm cpupower
        fi
        local hw_max_khz hw_max_mhz max_mhz=""
        hw_max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
        hw_max_mhz=$((hw_max_khz / 1000))
        (( hw_max_mhz > 0 )) && echo "    Hardware max: ${hw_max_mhz} MHz"
        # `|| true` so an EOF read (no TTY, redirected stdin) doesn't take
        # down the whole installer under `set -e`. Empty input → skip.
        read -p "    Cap max frequency in MHz (e.g. 2400, blank to skip): " max_mhz || true
        if [[ "$max_mhz" =~ ^[0-9]+$ ]] && (( max_mhz > 0 )); then
            local max_khz=$((max_mhz * 1000))
            if sudo cpupower frequency-set -u "${max_mhz}MHz" >/dev/null 2>&1; then
                echo "    Max set to ${max_mhz} MHz (live)"
            else
                echo "    Live cap failed — will still try to persist"
            fi
            _persist_cpupower max_freq "${max_khz}"
            echo "    Persisted via /etc/default/cpupower"
        elif [[ -n "$max_mhz" ]]; then
            echo "    '$max_mhz' is not a positive integer — skipping"
        fi
    fi

    # ── 3. CPU governor ───────────────────────────────────────────
    if command -v cpupower &>/dev/null; then
        local available_gov
        available_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
        if [[ -n "$available_gov" ]]; then
            echo ""
            echo "  Available governors: $available_gov"
            local governor=""
            read -p "  Set CPU governor (blank to skip): " governor || true
            if [[ -n "$governor" ]]; then
                # validate against the available list to avoid a confusing live-set failure
                if [[ " $available_gov " == *" $governor "* ]]; then
                    sudo cpupower frequency-set -g "$governor" >/dev/null 2>&1 || true
                    _persist_cpupower governor "'${governor}'"
                    echo "    Governor → $governor (now and persistent)"
                else
                    echo "    '$governor' not in available list — skipping"
                fi
            fi
        fi
    fi

    # Enable cpupower.service so /etc/default/cpupower applies on every boot
    if pacman -Qi cpupower &>/dev/null && [[ -f /etc/default/cpupower ]]; then
        if ! systemctl is-enabled --quiet cpupower.service 2>/dev/null; then
            sudo systemctl enable --now cpupower.service >/dev/null 2>&1 \
                && echo "  cpupower.service enabled"
        fi
    fi

    # ── 4. throttled (ThinkPad MSR fix) ───────────────────────────
    if $is_thinkpad; then
        echo ""
        echo "  ThinkPad detected — 'throttled' applies an MSR-based undervolt"
        echo "  + thermal-cap fix, configured via /etc/throttled.conf."
        echo "  A documented sample lives at shared/throttled.conf."
        if foxml_prompt_yn "  Install throttled from AUR? [y/N] "; then
            if ! pacman -Qi throttled &>/dev/null; then
                if [[ -n "$aur" ]]; then
                    "$aur" -S --needed throttled
                else
                    echo "    No AUR helper (yay/paru) found. Re-run install with"
                    echo "      --deps to install yay first, then retry this wizard."
                fi
            else
                echo "    • throttled already installed"
            fi
            if pacman -Qi throttled &>/dev/null \
                && ! systemctl is-active --quiet throttled.service; then
                sudo systemctl enable --now throttled.service >/dev/null 2>&1 \
                    && echo "    throttled enabled (edit /etc/throttled.conf to tune)"
            fi
        fi
    fi

    echo ""
    echo "  Done. Verify with: cpupower frequency-info | head -20"
}

# ─────────────────────────────────────────
# Performance — opt-in via install.sh --perf
# Enables high-precision time sync (Chrony).
# ─────────────────────────────────────────

install_performance() {
    if pacman -Qi chrony &>/dev/null; then
        if ! systemctl is-active --quiet chronyd; then
            echo "  Configuring Chrony (High-Precision Time)..."
            # Disable systemd-timesyncd first
            sudo systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
            sudo systemctl enable --now chronyd >/dev/null 2>&1 \
                || echo "    ! chronyd enable failed — time sync may drift; re-run after sudo -v"
            echo "    chronyd enabled (replaces timesyncd)"
            echo "    Precision sync active (check with: chronyc tracking)"
        else
            echo "  • chronyd already active"
        fi
    else
        echo "  chrony package not found — run with --deps --perf"
    fi
}

# ─────────────────────────────────────────
# Privacy — opt-in via install.sh --privacy
# Enables DNS-over-HTTPS (DoH) via systemd-resolved.
# ─────────────────────────────────────────

install_privacy() {
    echo "  Configuring DNS-over-HTTPS (DoH)..."
    local res_conf="/etc/systemd/resolved.conf"
    
    # 1. Update resolved.conf
    # Uses Cloudflare (1.1.1.1) and Google (8.8.8.8) with DoH enabled
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    # DNSSEC=allow-downgrade — validate when the upstream resolver
    # returns signed answers, accept gracefully when it doesn't. The
    # original DNSSEC=yes caused v2.4.7 NTP-startup deadlock; the
    # interim DNSSEC=no gave up validation entirely. allow-downgrade
    # is the audit-aware compromise: you get DNSSEC's tamper-detect
    # against compliant resolvers (Cloudflare 1.1.1.1, Google 8.8.8.8
    # both serve signed responses), don't get wedged when an unsigned
    # path is hit. DoH still handles path encryption either way.
    sudo tee /etc/systemd/resolved.conf.d/foxml-doh.conf >/dev/null <<EOF
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google
DNSOverHTTPS=yes
DNSSEC=allow-downgrade
FallbackDNS=1.1.1.1 8.8.8.8
EOF

    # 2. Enable and start resolved
    sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 \
        || echo "    ! systemd-resolved enable failed — DNSSEC unchanged; re-run after sudo -v"
    
    # 3. Link /etc/resolv.conf to systemd-resolved
    if [[ ! -L /etc/resolv.conf ]]; then
        sudo ln -rsf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    
    echo "    systemd-resolved configured with DoH (Cloudflare/Google)"
    echo "    DNS traffic now encrypted via HTTPS (Port 443)"
}

# ─────────────────────────────────────────
# Vault — opt-in via install.sh --vault
# Enables secure password management (Pass).
# ─────────────────────────────────────────

install_vault() {
    if pacman -Qi pass &>/dev/null; then
        echo "  Configuring Secure Vault (Pass)..."
        
        # 1. Detect or Generate GPG key
        local gpg_key
        gpg_key=$(gpg --list-secret-keys --keyid-format LONG | grep sec | awk '{print $2}' | cut -d/ -f2 | head -n 1)
        
        if [[ -z "$gpg_key" ]]; then
            # SAFETY: never generate a passwordless GPG key for `pass`.
            # An empty-passphrase key would let anyone with shell access
            # to this user decrypt the entire password store with zero
            # authentication — the opposite of what a password manager
            # is for. Use pinentry interactively. If we have no TTY
            # (CI / unattended install), skip and tell the user how to
            # do it themselves rather than ship a broken-by-default key.
            if [[ ! -t 0 ]]; then
                echo "    ! No GPG signing key found and no TTY for pinentry."
                echo "      Re-run install.sh interactively, or generate one yourself:"
                echo "        gpg --full-generate-key   (pick ed25519 or RSA 4096, set a passphrase)"
                echo "      Then re-run --vault to wire pass to the new key."
                return 0
            fi
            echo "    No GPG key found. Generating one (pinentry will prompt for a passphrase)..."
            echo "      Pick a strong passphrase — your password store will be encrypted with this key."
            gpg --quick-generate-key "$USER <${USER}@foxml.local>" ed25519 sign,cert 0 \
                || { echo "    ! GPG key generation failed or cancelled, skipping pass init"; return 1; }
            gpg_key=$(gpg --list-secret-keys --keyid-format LONG | grep sec | awk '{print $2}' | cut -d/ -f2 | head -n 1)
        fi
        
        # 2. Initialize pass
        if [[ ! -d "$HOME/.password-store" ]]; then
            pass init "$gpg_key" >/dev/null
            echo "    Password store initialized with key $gpg_key"
        else
            echo "    • Password store already exists"
        fi

        # 3. Git GPG Signing
        if command -v git &>/dev/null; then
            git config --global user.signingkey "$gpg_key"
            git config --global commit.gpgsign true
            echo "    Git configured to sign commits with key $gpg_key"
        fi

        # 4. AUR helper check for rofi-pass-wayland
        local aur=""
        command -v yay  &>/dev/null && aur="yay"
        [[ -z "$aur" ]] && command -v paru &>/dev/null && aur="paru"

        if [[ -n "$aur" ]]; then
            if ! pacman -Qi rofi-pass-wayland-git &>/dev/null; then
                read -p "    Install rofi-pass (Wayland) for SysHub integration? [y/N] " -n 1 -r; echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    "$aur" -S --needed rofi-pass-wayland-git
                    echo "    rofi-pass installed"
                fi
            fi
        fi
    else
        echo "  pass package not found — run with --deps --vault"
    fi
}

# ─────────────────────────────────────────
# Security Hardening — opt-in via install.sh --secure
# Enables and configures UFW (firewall) and Fail2ban.
# ─────────────────────────────────────────

install_security() {
    # Re-prime sudo before the long privileged stretch in this function.
    # Without it, an interactive install (no keepalive) hits a cold sudo
    # cache 5+ min into the run and any `sudo cmd >/dev/null 2>&1` line
    # below FAILS SILENTLY — set -e in install.sh then aborts the entire
    # installer with no error message. Loud failure here is the fix.
    if ! sudo -v 2>/dev/null; then
        echo "  ! sudo cache cold and no TTY — security hardening needs root"
        echo "    re-run: sudo -v && fox install --full"
        return 0
    fi

    # UFW is applied unconditionally by install_ufw_baseline (called from
    # install.sh BEFORE this function). Re-running it here would just do
    # the same idempotent work twice. If a future code path invokes
    # install_security in isolation (e.g. fox-doctor remediation), call
    # install_ufw_baseline yourself first; we no longer chain it here.
    if ! pacman -Qi ufw &>/dev/null; then
        echo "  ufw package not found — run with --deps --secure"
    fi

    # 2. Fail2ban (Brute-force protection)
    if pacman -Qi fail2ban &>/dev/null; then
        # Write jail.local FIRST — the stock jail.conf ships with every
        # jail disabled. Without this file, fail2ban runs but protects
        # nothing (the classic "service enabled, doing nothing" trap).
        # Idempotent: skips if a foxml-managed jail.local is already in
        # place. We don't touch a user's pre-existing jail.local.
        local jail_local=/etc/fail2ban/jail.local
        if [[ ! -f "$jail_local" ]] || ! grep -q '^# foxml-managed' "$jail_local"; then
            sudo tee "$jail_local" >/dev/null <<'EOF'
# foxml-managed — auto-applied by install.sh --secure.
# Delete this file to revert to the stock fail2ban defaults.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
# Allow the loopback so localhost-spawned test traffic doesn't ban us.
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
filter   = sshd
journalmatch = _SYSTEMD_UNIT=sshd.service
EOF
            echo "    fail2ban jail.local written (sshd jail enabled)"
        fi
        if ! systemctl is-active --quiet fail2ban; then
            if sudo systemctl enable --now fail2ban >/dev/null 2>&1; then
                echo "    fail2ban service enabled"
            else
                echo "    ! fail2ban enable failed (sudo cold?) — re-run after: sudo -v"
            fi
        else
            # Reload so the newly-written jail.local takes effect on re-runs.
            if sudo systemctl reload fail2ban >/dev/null 2>&1 \
                || sudo systemctl restart fail2ban >/dev/null 2>&1; then
                echo "  • fail2ban already active (reloaded for new jail.local)"
            else
                echo "    ! fail2ban reload failed (sudo cold?) — service still running on old config"
            fi
        fi
    else
        echo "  fail2ban package not found — run with --deps --secure"
    fi

    # 3. Auditd (System Auditing)
    if pacman -Qi audit &>/dev/null; then
        # Persistent watch rules. Previous version called `auditctl -w`
        # at runtime which DOESN'T survive reboot — auditctl writes to
        # the running kernel only. Rules in /etc/audit/rules.d/ get
        # compiled into the audit policy via augenrules on every boot.
        local audit_rules=/etc/audit/rules.d/99-foxml.rules
        if [[ ! -f "$audit_rules" ]] || ! grep -q '^# foxml-managed' "$audit_rules"; then
            sudo tee "$audit_rules" >/dev/null <<'EOF'
# foxml-managed — auto-applied by install.sh --secure.
# Watches credential + sshd config files for modifications.
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes
EOF
            # augenrules merges all .rules files in rules.d/ into the
            # active policy at /etc/audit/audit.rules, then we restart
            # the service so it picks them up. augenrules is idempotent.
            sudo augenrules --load >/dev/null 2>&1 || true
            echo "    auditd watch rules written to ${audit_rules}"
        fi
        if ! systemctl is-active --quiet auditd; then
            echo "  Configuring Auditd..."
            if sudo systemctl enable --now auditd >/dev/null 2>&1; then
                echo "    auditd enabled with persistent watch rules"
            else
                echo "    ! auditd enable failed (sudo cold?) — re-run after: sudo -v"
            fi
        else
            # `|| true` so set -e doesn't abort the installer if sudo cache
            # expired between earlier sudo and now (no TTY for prompt).
            if sudo systemctl restart auditd >/dev/null 2>&1; then
                echo "  • auditd already active (restarted to load new rules)"
            else
                echo "  • auditd already active (couldn't restart — sudo cold; rules apply on next reboot)"
            fi
        fi
    else
        echo "  • audit package not installed — skipping persistent audit rules"
    fi

    # 4. Waybar Sudoers (Seamless Overwatch).
    # Tight allow-list — no wildcards. Earlier version had
    # `fail2ban-client status *` which would have matched any jail name
    # the bar passed. Pinning to the two specific invocations the
    # waybar module actually issues (overall status + sshd jail status)
    # closes that.
    local waybar_sudo="/etc/sudoers.d/99-foxml-waybar"
    if [[ ! -f "$waybar_sudo" ]]; then
        echo "  Configuring sudoers for Waybar Overwatch..."
        if sudo tee "$waybar_sudo" >/dev/null <<EOF
${USER} ALL=(ALL) NOPASSWD: /usr/bin/ufw status
${USER} ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status
${USER} ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status sshd
EOF
        then
            sudo chmod 440 "$waybar_sudo" 2>/dev/null || true
            sudo chown root:root "$waybar_sudo" 2>/dev/null || true
            echo "    Sudoers rule added (ufw status + fail2ban-client status + sshd jail)"
        else
            echo "    ! sudoers write failed (sudo cold?) — waybar overwatch may prompt"
        fi
    else
        echo "  • waybar sudoers already configured — leaving as-is"
    fi

    # 5. SSH Hardening Wizard
            if ! $ASSUME_YES; then
        echo ""
        echo "╭──────────────────────────────────────────────────────────────────╮"
        echo "│   SSH Hardening Wizard                                          │"
        echo "├──────────────────────────────────────────────────────────────────┤"
        echo "│ This will configure a custom port and disable password login.   │"
        echo "│ WARNING: Ensure you have SSH keys set up before proceeding.    │"
        echo "╰──────────────────────────────────────────────────────────────────╯"
        if foxml_prompt_yn "Run SSH hardening wizard? [y/N] "; then
            local sshd_conf_dir="/etc/ssh/sshd_config.d"
            local hardening_conf="${sshd_conf_dir}/50-foxml-hardening.conf"
            sudo mkdir -p "$sshd_conf_dir"

            # 1. Custom Port — validate numeric + valid range so a typo
            # doesn't get spliced into sshd_config / `ufw allow` and brick
            # remote access. Anything out of [1, 65535] falls back to 22.
            local custom_port=""
            read -p "  Enter custom SSH port [default: 22]: " custom_port || true
            custom_port=${custom_port:-22}
            if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || (( custom_port < 1 || custom_port > 65535 )); then
                echo "    '$custom_port' is not a valid port number — falling back to 22"
                custom_port=22
            fi
            
            # 2. Key Check & Import
            local has_keys=false
            [[ -f "$HOME/.ssh/authorized_keys" ]] && has_keys=true
            
            if ! $has_keys; then
                echo "  No ~/.ssh/authorized_keys found."
                read -p "  Import public keys from GitHub? (Enter username or leave blank to skip): " gh_user
                if [[ -n "$gh_user" ]]; then
                    mkdir -p "$HOME/.ssh"
                    chmod 700 "$HOME/.ssh"
                    if curl -fsSL "https://github.com/${gh_user}.keys" >> "$HOME/.ssh/authorized_keys"; then
                        chmod 600 "$HOME/.ssh/authorized_keys"
                        echo "    Imported keys from GitHub (${gh_user})"
                        has_keys=true
                    else
                        echo "    Failed to fetch keys for user: ${gh_user}"
                    fi
                fi
            fi

            # Default posture: keys-only when keys exist, password+keys
            # when no keys. The prompt now defaults to secure (Y) when
            # keys are detected — Enter / empty input picks keys-only.
            # Only an explicit "n" or "N" keeps password auth on.
            #
            # Test your key BEFORE answering Y:
            #     ssh -p $custom_port -o BatchMode=yes -o ConnectTimeout=5 \\
            #         "$USER@127.0.0.1" true
            # If the test succeeds, the key works and disabling passwords
            # is safe. Physical TTY login at the laptop is your fallback
            # if you ever lose the key entirely.
            local disable_pass="yes"
            if $has_keys; then
                # Sanity-probe the key actually loads (rules out a corrupt
                # or empty authorized_keys file that exists but is useless).
                local key_count
                key_count=$(grep -cE '^(ssh-(rsa|ed25519|dss|ecdsa)|sk-) ' "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
                if (( key_count == 0 )); then
                    echo "  ! authorized_keys exists but contains no recognised public keys"
                    echo "    keeping password auth ENABLED to avoid lockout"
                    disable_pass="yes"
                else
                    echo "  Detected ${key_count} authorized public key(s)."
                    echo "  Disabling password auth is the recommended secure default."
                    local _reply=""
                    read -p "  Disable password authentication (keys-only)? [Y/n] " -n 1 -r _reply || true
                    echo ""
                    case "$_reply" in
                        [Nn]) disable_pass="yes" ;;   # explicit no → keep passwords
                        *)    disable_pass="no"  ;;   # Enter or Y → keys-only
                    esac
                fi
            else
                echo "  No authorized_keys found. Forcing 'PasswordAuthentication yes' to prevent lockout."
                disable_pass="yes"
            fi

            # 3. Apply Config. The extra knobs below are non-controversial
            # standard hardening: no root login (use sudo from a user
            # account), tighter auth retry limit, no challenge-response /
            # keyboard-interactive (cuts off old PAM-based brute force),
            # explicit Protocol 2 even though it's already default.
            sudo tee "$hardening_conf" >/dev/null <<EOF
# FoxML Security Hardening
Port $custom_port
Protocol 2
PasswordAuthentication $disable_pass
PubkeyAuthentication yes
PermitRootLogin no
MaxAuthTries 3
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
            echo "    SSH config written to $hardening_conf"
            echo "      PermitRootLogin no, MaxAuthTries 3, no kbd-interactive"

            # 4. Update UFW
            if [[ "$custom_port" != "22" ]]; then
                sudo ufw allow "$custom_port/tcp" >/dev/null
                sudo ufw delete allow 22 >/dev/null
                echo "    UFW updated: Allowed $custom_port, Blocked 22"
            fi

            # 5. Restart SSH
            sudo systemctl restart sshd
            echo "    sshd restarted"
            
            if [[ "$disable_pass" == "no" ]]; then
                echo ""
                echo "  SSH is now LOCKED DOWN to keys-only on port $custom_port."
            else
                echo ""
                echo "  SSH is on port $custom_port, but password login is still ENABLED."
                echo "    Add your key to ~/.ssh/authorized_keys to disable passwords later."
            fi

            # Port-knocking offer. Closes the SSH port entirely to
            # SSH gating — closes the custom SSH port to scanners; a
            # cryptographic / port sequence temporarily opens it for
            # the authorized source. SPA (Single Packet Auth via
            # fwknop) is strictly better than port knocking — it's
            # replay-immune (HMAC + timestamp) and undetectable to
            # passive sniffers, where port-knock sequences can be
            # recorded + replayed by anyone on the LAN.
            #
            # Default to SPA when fwknop is installable, fall back to
            # knock if not. Both are opt-in because forgetting the
            # auth method locks you out of remote SSH (physical TTY
            # login still works).
            echo ""
            echo "  ${C_BOLD:-}SSH gating (recommended)${C_RST:-} — close $custom_port to scanners; auth opens it briefly."
            echo "    [1] SPA (fwknop)      single encrypted packet, replay-immune  ${C_DIM:-}(recommended)${C_RST:-}"
            echo "    [2] knock (knockd)    port sequence, simpler, sniffable on LAN"
            echo "    [3] skip"
            local _gate_choice
            read -rp "  choose [1]: " -n 1 -r _gate_choice; echo
            _gate_choice="${_gate_choice:-1}"

            case "$_gate_choice" in
                1)
                    # Install fwknop if missing — AUR.
                    if ! command -v fwknopd >/dev/null 2>&1; then
                        local _aur=""
                        command -v yay &>/dev/null && _aur="yay"
                        [[ -z "$_aur" ]] && command -v paru &>/dev/null && _aur="paru"
                        if [[ -n "$_aur" ]]; then
                            echo "  Installing fwknop from AUR (build ~20-40s)..."
                            $_aur -S --needed --noconfirm fwknop 2>&1 | sed 's/^/    /'
                        else
                            echo "  ! fwknop not installed AND no AUR helper — install manually then run: fox spa --setup"
                        fi
                    fi
                    if command -v fwknopd >/dev/null 2>&1; then
                        fox-spa --setup || echo "  ! fox spa setup failed — re-run: fox spa --setup"
                    else
                        echo "  • SPA not ready — run later: fox spa --setup"
                    fi
                    ;;
                2)
                    # Install knockd from repos if missing.
                    if ! command -v knockd >/dev/null 2>&1; then
                        if ! pacman -Qi knockd &>/dev/null; then
                            if command -v yay &>/dev/null; then
                                yay -S --needed --noconfirm knockd 2>&1 | sed 's/^/    /'
                            elif command -v paru &>/dev/null; then
                                paru -S --needed --noconfirm knockd 2>&1 | sed 's/^/    /'
                            fi
                        fi
                    fi
                    if command -v knockd >/dev/null 2>&1; then
                        fox-knock --setup || echo "  ! fox knock setup failed — re-run: fox knock --setup"
                    else
                        echo "  ! knockd not available — install manually then run: fox knock --setup"
                    fi
                    ;;
                3|*)
                    mkdir -p "$HOME/.config/foxml" 2>/dev/null
                    touch "$HOME/.config/foxml/.skipped-ssh-gating"
                    echo "  • skipped — run later:  fox spa --setup  OR  fox knock --setup"
                    ;;
            esac
        fi
    fi

    # lynis — system hardening audit tool. Read-only; gives a 0-100
    # hardening_index + a list of suggestions. Different layer from
    # auditd/fail2ban (active monitors) — lynis is a posture report.
    # Wired up via `fox audit`. No service, just a binary.
    if ! pacman -Qi lynis &>/dev/null; then
        echo "  Installing lynis (audit tool — read-only, no daemon)..."
        sudo pacman -S --needed --noconfirm lynis 2>&1 | tail -3 | sed 's/^/    /' || true
    fi
}

# ─────────────────────────────────────────
# Special update handlers (pull system → templates)
# ─────────────────────────────────────────

update_specials() {
    local template_dir="$1"
    local sed_expr="$2"

    # Firefox
    local ff_profile
    ff_profile="$(get_firefox_profile)"
    if [[ -n "$ff_profile" ]]; then
        for css in userChrome.css userContent.css; do
            if [[ -f "$ff_profile/chrome/$css" ]]; then
                sed "$sed_expr" "$ff_profile/chrome/$css" > "$template_dir/firefox/$css"
                command -v foxml_substep >/dev/null && foxml_substep "Firefox $css" || echo "  Firefox $css"
            fi
        done
    fi

    # Cursor/VS Code
    for ext_dir in ~/.cursor/extensions ~/.vscode/extensions; do
        local src="$ext_dir/foxml-theme/themes/foxml-color-theme.json"
        if [[ -f "$src" ]]; then
            sed "$sed_expr" "$src" > "$template_dir/cursor/foxml-color-theme.json"
            echo "  foxml-color-theme.json"
            break
        fi
    done

    # Bat
    local bat_dir
    bat_dir="$(bat --config-dir 2>/dev/null || echo "$HOME/.config/bat")"
    if [[ -f "$bat_dir/themes/Fox ML.tmTheme" ]]; then
        sed "$sed_expr" "$bat_dir/themes/Fox ML.tmTheme" > "$template_dir/bat/foxml.tmTheme"
        echo "  Bat theme"
    fi

    # AI Agent — pull config back into the template; keeping security/auth out
    # of the captured template avoids leaking session creds into the repo.
    local gemini_dir="${GEMINI_CONFIG_HOME:-$HOME/.gemini}"
    local gemini_settings="$gemini_dir/settings.json"
    if [[ -f "$gemini_settings" ]]; then
        local tmp_captured; tmp_captured="$(mktemp)"
        # Capture theme, hooks, and notifications but skip security
        if jq '{ui: .ui, hooks: .hooks, hooksConfig: .hooksConfig, general: .general}' "$gemini_settings" > "$tmp_captured" 2>/dev/null; then
            mkdir -p "$template_dir/gemini"
            sed "$sed_expr" "$tmp_captured" > "$template_dir/gemini/settings.json"
            echo "  Gemini settings (captured hooks + theme)"
        fi
        rm -f "$tmp_captured"
    fi

    # Hyprland scripts
    if [[ -d ~/.config/hypr/scripts ]]; then
        mkdir -p "$SCRIPT_DIR/shared/hyprland_scripts"
        for script in ~/.config/hypr/scripts/*.sh; do
            [[ -f "$script" ]] || continue
            cp "$script" "$SCRIPT_DIR/shared/hyprland_scripts/$(basename "$script")"
            echo "  scripts/$(basename "$script")"
        done
    fi
}
