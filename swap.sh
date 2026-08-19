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
    local fox_install="$SCRIPT_DIR/src/fox-install/fox-install"

    if [[ ! -x "$fox_install" ]]; then
        echo ":: Building fox-install..."
        make -C "$SCRIPT_DIR/src/fox-install" >/dev/null || {
            echo "fox-install build failed; falling back to install.sh"
            exec "$SCRIPT_DIR/install.sh" "$theme"
        }
    fi

    echo ":: Swapping to $theme..."
    "$fox_install" "$theme" \
        --only theme,render,symlinks,specials,personalize --yes --quiet \
        || { echo "swap failed"; exit 1; }

    if command -v hyprctl >/dev/null 2>&1; then
        hyprctl reload >/dev/null 2>&1 || true
    fi
    echo ":: Done."
}

# ─────────────────────────────────────────
# Non-interactive: `swap.sh <theme-name>`
# ─────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    requested="$1"
    for t in "${themes[@]}"; do
        if [[ "$t" == "$requested" ]]; then
            _do_swap "$requested"
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
    _do_swap "$selected"
else
    echo "Invalid selection."
    exit 1
fi
