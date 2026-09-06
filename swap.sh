#!/bin/bash
# FoxML Theme Hub — Theme Swapper with color previews
# Usage: ./swap.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEMES_DIR="$SCRIPT_DIR/themes"
ACTIVE_FILE="$SCRIPT_DIR/.active-theme"

ACTIVE_THEME=""
[[ -f "$ACTIVE_FILE" ]] && ACTIVE_THEME="$(cat "$ACTIVE_FILE")"

# ─────────────────────────────────────────
# Discover themes
# ─────────────────────────────────────────
themes=()
for d in "$THEMES_DIR"/*/; do
    [[ -f "$d/palette.sh" && -f "$d/theme.conf" ]] || continue
    themes+=("$(basename "$d")")
done

if [[ ${#themes[@]} -eq 0 ]]; then
    echo "No themes found in $THEMES_DIR"
    exit 1
fi

# ⚠ KNOWN ISSUE — theme-swapping is unreliable / under rework. It re-renders the
# config files but does NOT restart the live apps (waybar, dunst, GTK/thunar,
# wallpaper daemon), so a swap won't fully apply until you re-login. Each surface
# (folder icons, cursor, GTK, wallpaper) is themed separately; a unified theming
# pipeline is a planned rework. Reliable path today: a full theme re-install.
echo "⚠  theme-swap is UNRELIABLE right now — it re-renders configs but doesn't"
echo "   restart the live apps (waybar/dunst/GTK/wallpaper), so changes apply"
echo "   fully only after re-login. Known issue; unified theming rework planned."
echo

# ─────────────────────────────────────────
# Lean swap path: bypass install.sh (skips boot pre-flight,
# git self-update, sudo warmup, and every default-on security
# module). Only the modules that actually rewrite the theme run.
# ─────────────────────────────────────────
_do_swap() {
    local theme="$1"
    local force="${2:-}"
    local fox_install="$SCRIPT_DIR/src/fox-install/fox-install"

    if [[ ! -x "$fox_install" ]]; then
        echo ":: Building fox-install..."
        make -C "$SCRIPT_DIR/src/fox-install" >/dev/null || {
            echo "fox-install build failed; falling back to install.sh"
            exec "$SCRIPT_DIR/install.sh" ${force:+--reapply} "$theme"
        }
    fi

    # NOT --full. On hardware like this laptop, --full's everything-on selection
    # survives --only via detect's auto-enable and pulls in nvidia (driver +
    # initramfs) and fprint/fprint_pam/sudo_fingerprint (PAM edits) -- red-zone
    # modules with no business in a theme swap -- while *dropping* render itself.
    # --reapply is the narrow primitive: it sets the same force_reapply that
    # render.cpp's drift guard tests, and leaves module selection untouched.
    local force_args=()
    [[ -n "$force" ]] && force_args=(--reapply)

    # post_install is what actually MAKES a swap take effect: it writes
    # .active-theme, finalises per-monitor wallpaper variants + hyprlock,
    # re-renders waybar for the layout, and restarts/reloads waybar, dunst
    # and mako. Leaving it out was why swapping only ever rewrote files.
    # FOXML_SKIP_PLUGIN_SYNC drops its nvim Lazy/Treesitter passes (60s+120s
    # caps) -- plugin maintenance, irrelevant to a recolour.
    echo ":: Swapping to $theme..."
    local rc=0
    # FOXML_THEME_ONLY confines the greetd module to the greeter's LOOK:
    # css/toml/hyprland.conf/wallpaper only. It must never rewrite
    # /etc/greetd/config.toml or touch service state from a recolour -- a
    # theme swap cannot be allowed to cost a login. Needs sudo; without it
    # greetd warns and skips and the rest of the swap still succeeds.
    FOXML_SKIP_PLUGIN_SYNC=1 FOXML_THEME_ONLY=1 \
    "$fox_install" "$theme" "${force_args[@]}" \
        --only theme,render,symlinks,specials,personalize,greetd,post_install \
        --yes --quiet || rc=$?

    if (( rc != 0 )); then
        # exit 2 = render aborted to protect live ~/.config edits. fox-install
        # suggests "--full", but it can't know it was invoked through swap.sh,
        # which takes only a theme name -- so print a hint that actually works here.
        if (( rc == 2 )) && [[ -z "$force" ]]; then
            echo ""
            echo "swap aborted: live ~/.config edits would be overwritten."
            echo "  keep them  : ./update.sh          # capture into templates first"
            echo "  overwrite  : ./swap.sh --full $theme"
        else
            echo "swap failed"
        fi
        exit "$rc"
    fi

    if command -v hyprctl >/dev/null 2>&1; then
        hyprctl reload >/dev/null 2>&1 || true
    fi

    # A render rewrites hyprlock.conf back to the template's hardcoded
    # wallpaper. rotate_wallpaper --static re-points it at the live pick;
    # it's a silent no-op for the desktop when that's already correct.
    _rot="${HOME}/.config/hypr/scripts/rotate_wallpaper.sh"
    [[ -x "$_rot" ]] && "$_rot" --static >/dev/null 2>&1 || true

    # tmux renders from the palette but nothing reloads it -- a running server
    # keeps whatever colours it started with. Re-source so open sessions
    # recolour in place. (post_install covers waybar/dunst/mako.)
    if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
        tmux source-file "${HOME}/.tmux.conf" >/dev/null 2>&1 \
            && echo ":: tmux reloaded" || true
    fi

    echo ":: Done."
}

# ─────────────────────────────────────────
# Flags. --full is the user-facing spelling for "overwrite live edits" (it's what
# fox-install's own error text suggests); it maps to --reapply internally -- see
# _do_swap. Everything else is treated as the theme name.
# ─────────────────────────────────────────
FORCE=""
_positional=()
for _a in "$@"; do
    case "$_a" in
        --full|--force|-f) FORCE=1 ;;
        -h|--help)
            echo "Usage: ./swap.sh [--full] [theme-name]"
            echo "  --full   overwrite live ~/.config edits instead of aborting"
            echo "  (no args) interactive menu"
            exit 0 ;;
        *) _positional+=("$_a") ;;
    esac
done
set -- ${_positional+"${_positional[@]}"}

# ─────────────────────────────────────────
# Non-interactive: `swap.sh [--full] <theme-name>`
# ─────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    requested="$1"
    for t in "${themes[@]}"; do
        if [[ "$t" == "$requested" ]]; then
            _do_swap "$requested" "$FORCE"
            exit 0
        fi
    done
    echo "Unknown theme: $requested"
    echo "Available: ${themes[*]}"
    exit 1
fi

# ─────────────────────────────────────────
# Render color swatch (truecolor)
# ─────────────────────────────────────────
hex_to_rgb() {
    local hex="$1"
    printf "%d %d %d" "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

render_swatch() {
    local hex="$1"
    local r g b
    read r g b <<< "$(hex_to_rgb "$hex")"
    printf "\033[48;2;%d;%d;%dm      \033[0m" "$r" "$g" "$b"
}

# ─────────────────────────────────────────
# Display
# ─────────────────────────────────────────
echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│                    FoxML Theme Swapper                          │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""

if [[ -n "$ACTIVE_THEME" ]]; then
    echo "Current theme: $ACTIVE_THEME"
else
    echo "Current theme: (none)"
fi
echo ""

for i in "${!themes[@]}"; do
    name="${themes[$i]}"

    # Load palette
    unset BG FG PRIMARY SECONDARY ACCENT SURFACE PALETTE_LABELS
    source "$THEMES_DIR/$name/palette.sh"

    # Load theme.conf
    local_type=$(grep '^type=' "$THEMES_DIR/$name/theme.conf" | cut -d= -f2)

    # Active indicator
    active_mark=""
    if [[ "$name" == "$ACTIVE_THEME" ]]; then
        active_mark="  ● ACTIVE"
    fi

    printf "[%d] %s (%s)%s\n" "$((i+1))" "$name" "$local_type" "$active_mark"

    # Render swatches
    printf "    "
    render_swatch "$BG"
    printf " "
    render_swatch "$FG"
    printf " "
    render_swatch "$PRIMARY"
    printf " "
    render_swatch "$SECONDARY"
    printf " "
    render_swatch "$ACCENT"
    printf " "
    render_swatch "$SURFACE"
    echo ""

    # Labels
    printf "    "
    for label in "${PALETTE_LABELS[@]}"; do
        printf "%-7s" "$label"
    done
    echo ""
    echo ""
done

# ─────────────────────────────────────────
# Selection
# ─────────────────────────────────────────
read -p "Select theme to install [1-${#themes[@]}] (q to quit): " choice

if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "Cancelled."
    exit 0
fi

if [[ "$choice" -ge 1 && "$choice" -le ${#themes[@]} ]] 2>/dev/null; then
    selected="${themes[$((choice-1))]}"
    echo ""
    _do_swap "$selected" "$FORCE"
else
    echo "Invalid selection."
    exit 1
fi
