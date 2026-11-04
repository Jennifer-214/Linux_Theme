#!/bin/bash
# FoxML Theme Hub — Template Renderer
# Sources a palette and renders templates with {{PLACEHOLDER}} substitution
#
# Usage: ./render.sh <palette.sh> <template_dir> <output_dir>
# Or source this file and call render_all / render_file directly.

set -e

# ─────────────────────────────────────────
# Compute RGB components from hex
# ─────────────────────────────────────────
hex_to_rgb() {
    local hex="$1"
    printf "%d %d %d" "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# ─────────────────────────────────────────
# Build sed expression from palette variables
# ─────────────────────────────────────────
# Parse a palette.sh file and split its uppercase assignments into hex
# colours vs everything else. Output is written into two name-referenced
# arrays so the caller can stay decoupled from the parsing rules.
#
# Classification:
#   - 6-char hex (e.g. f4b58a, A1B2C3)         → hex_vars
#   - PALETTE_LABELS or PALETTE_NAME           → skipped (handled elsewhere)
#   - everything else (paths, labels, opts)     → str_vars
#
# Designed to match the legacy behaviour exactly, then extend cleanly.
_derive_palette_vars() {
    local palette_file="$1"
    local -n _hex="$2"
    local -n _str="$3"
    [[ -r "$palette_file" ]] || return 1

    local line name val
    while IFS= read -r line; do
        # Skip comments / blanks / non-assignments.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue

        name="${line%%=*}"
        val="${line#*=}"
        # Strip surrounding quotes, trailing inline comments, whitespace.
        val="${val%%#*}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        val="${val##[[:space:]]}"; val="${val%%[[:space:]]}"

        case "$name" in
            PALETTE_LABELS|PALETTE_NAME|PALETTE_DESCRIPTION) continue ;;
        esac

        if [[ "$val" =~ ^[0-9a-fA-F]{6}$ ]]; then
            _hex+=("$name")
        else
            _str+=("$name")
        fi
    done < "$palette_file"
}

# ─────────────────────────────────────────
# Compute hex alpha from float opacity (0.0 - 1.0)
# ─────────────────────────────────────────
opacity_to_hex() {
    local opacity="$1"
    # Use awk for float math, then printf for hex
    awk -v o="$opacity" 'BEGIN { printf "%02x", int(o * 255 + 0.5) }'
}

build_sed_expr() {
    local sed_expr=""

    # Auto-derive hex_vars + str_vars from the active palette file rather
    # than hardcoding them. With the hardcoded arrays, contributors who
    # added a new palette colour silently broke template substitution
    # because the new {{VAR}} placeholder had no matching entry in the
    # array — the rendered output still contained the literal {{VAR}}
    # text. _derive_palette_vars parses palette.sh, classifies every
    # ALL_CAPS assignment by value pattern, and pushes the result into
    # the local arrays. Falls through to the legacy hardcoded list if
    # the palette path isn't available (e.g. unit-test invocation).
    local -a hex_vars=() str_vars=()
    if declare -F _derive_palette_vars >/dev/null && [[ -n "${_PALETTE_FILE:-}" ]]; then
        _derive_palette_vars "$_PALETTE_FILE" hex_vars str_vars
    fi
    if (( ${#hex_vars[@]} == 0 )); then
        hex_vars=(
            BG BG_DARK BG_ALT BG_HIGHLIGHT SELECTION
            FG FG_PASTEL FG_DIM COMMENT
            PRIMARY SECONDARY ACCENT SURFACE
            RED RED_BRIGHT GREEN GREEN_BRIGHT
            YELLOW YELLOW_BRIGHT BLUE BLUE_BRIGHT
            CYAN CYAN_BRIGHT WHITE OK WARN
            BG_DUNST BG_SPICETIFY BG_VENCORD_ALT BG_VENCORD_DEEP CARD_HOVER
            FZF_ACCENT1 FZF_ACCENT2 ZSH_SUGGEST ZSH_CMD
            TMUX_INACTIVE_FG TMUX_ACTIVE_FG TMUX_ACTIVE_BG
            DIFF_ADD DIFF_CHANGE DIFF_DELETE DIFF_TEXT TREESITTER_CTX
            WARM SAND WHEAT CLAY NVIM_BG_HL NVIM_SEL
        )
        str_vars=(
            THEME_TYPE NVIM_STYLE NVIM_BG KITTY_BG_OPACITY POPUP_BG_OPACITY SHOW_WELCOME SHOW_BANNER WALLPAPER
            MAKO_ICON_THEME GTK_ICON_THEME VSCODE_UI_THEME FONT_FAMILY
            ANSI_ACCENT1 ANSI_ACCENT2 ANSI_ACCENT3 ANSI_ACCENT4 ANSI_ACCENT5
            ANSI_TEXT ANSI_MUTED ANSI_ERROR ANSI_OK ANSI_STANDOUT_BG
            ANSI_PROMPT ANSI_PROMPT2 ANSI_LOAD
            GRAD1 GRAD2 GRAD3 GRAD4 GRAD5
            TMUX_ACTIVE TMUX_INACTIVE
        )
    fi

    # Use `|` as sed delimiter instead of `/`. Both hex colours (6-char
    # hex) and the string vars below are guaranteed not to contain `|`,
    # while `/` showed up freely in filesystem-path values and required
    # ad-hoc escaping. Switching the delimiter removes the escape and
    # the corresponding "what if someone adds a path-valued var later"
    # footgun flagged in audit.
    for var in "${hex_vars[@]}"; do
        local val="${!var}"
        [[ -z "$val" ]] && continue
        sed_expr+="s|{{${var}}}|${val}|g;"

        # Compute RGB
        local r g b
        read r g b <<< "$(hex_to_rgb "$val")"
        sed_expr+="s|{{${var}_R}}|${r}|g;"
        sed_expr+="s|{{${var}_G}}|${g}|g;"
        sed_expr+="s|{{${var}_B}}|${b}|g;"
    done

    # String/number variables: {{VAR}} → value, copied literally like
    # fox-render-fast does. sed would otherwise read `\` (MAKO_FORMAT's `\n`
    # became a real line break), `&` (the matched text) and the `|` delimiter
    # in a value, so escape those three. Quoted patterns keep bash 5.2's
    # patsub_replacement from treating `&` specially.
    for var in "${str_vars[@]}"; do
        local val="${!var}"
        [[ -z "$val" ]] && continue
        local esc=$val
        esc=${esc//'\'/'\\'}
        esc=${esc//'&'/'\&'}
        esc=${esc//'|'/'\|'}
        sed_expr+="s|{{${var}}}|${esc}|g;"

        # Special case: convert *_BG_OPACITY (0.0-1.0) to hex alpha (00-ff).
        # KITTY_BG_OPACITY → {{KITTY_BG_OPACITY_HEX}}  (used by kitty)
        # POPUP_BG_OPACITY → {{POPUP_BG_OPACITY_HEX}}  (used by mako/dunst)
        if [[ "$var" == "KITTY_BG_OPACITY" || "$var" == "POPUP_BG_OPACITY" ]]; then
            local hex_alpha
            hex_alpha=$(opacity_to_hex "$val")
            sed_expr+="s|{{${var}_HEX}}|${hex_alpha}|g;"
        fi
    done

    # PALETTE_LABELS is special (array) — skip, handled by swap.sh directly

    echo "$sed_expr"
}

# ─────────────────────────────────────────
# Render a single template file
# ─────────────────────────────────────────
render_file() {
    local template="$1"
    local output="$2"
    local sed_expr="$3"

    mkdir -p "$(dirname "$output")"
    sed "$sed_expr" "$template" > "$output"
}

# ─────────────────────────────────────────
# Pacman-style output helpers
#
# Layered to match pacman/makepkg conventions:
#   foxml_section  → ":: " bold cyan, top-level action
#   foxml_substep  → " -> " indented step under a section
#   foxml_ok       → "  +" indented success, green
#   foxml_warn     → "warning: " yellow, makepkg-style
#   foxml_err      → "error: " red, makepkg-style
#
# Colors are emitted only when stdout is a TTY and tput supports ≥8 colors.
# Falls back to plain text under pipes / log files / no-TTY installs.
# ─────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    _FOXML_BOLD="$(tput bold)"
    _FOXML_DIM="$(tput dim)"
    _FOXML_RED="$(tput setaf 1)"
    _FOXML_GREEN="$(tput setaf 2)"
    _FOXML_YELLOW="$(tput setaf 3)"
    _FOXML_CYAN="$(tput setaf 6)"
    _FOXML_RESET="$(tput sgr0)"
else
    _FOXML_BOLD=""; _FOXML_DIM=""; _FOXML_RED=""; _FOXML_GREEN=""
    _FOXML_YELLOW=""; _FOXML_CYAN=""; _FOXML_RESET=""
fi

foxml_section() {
    printf '%s%s::%s %s%s%s\n' \
        "$_FOXML_BOLD" "$_FOXML_CYAN" "$_FOXML_RESET" \
        "$_FOXML_BOLD" "$*" "$_FOXML_RESET"
}

foxml_substep() {
    printf ' %s->%s %s\n' "$_FOXML_BOLD" "$_FOXML_RESET" "$*"
}

foxml_ok() {
    printf '  %s+%s %s\n' "$_FOXML_GREEN" "$_FOXML_RESET" "$*"
}

foxml_warn() {
    printf '%swarning:%s %s\n' "$_FOXML_YELLOW" "$_FOXML_RESET" "$*" >&2
}

foxml_err() {
    printf '%serror:%s %s\n' "$_FOXML_RED" "$_FOXML_RESET" "$*" >&2
}

# Aligned summary row (label : value). Used by the end-of-install report.
# Keep label width consistent across callers — pacman's final summary is
# column-aligned and this helper enforces the same.
foxml_summary_row() {
    local label="$1" value="$2"
    printf '  %s%-22s%s : %s\n' "$_FOXML_DIM" "$label" "$_FOXML_RESET" "$value"
}

# ─────────────────────────────────────────
# Progress bar helper (pacman-style)
# ─────────────────────────────────────────
foxml_progress() {
    local current="$1"
    local total="$2"
    local label="$3"
    (( total <= 0 )) && return 0   # nothing to bar

    local width=30
    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    local bar=""
    [[ $filled -gt 0 ]] && bar+=$(printf "%${filled}s" "" | tr ' ' '#')
    [[ $empty -gt 0 ]] && bar+=$(printf "%${empty}s" "" | tr ' ' '-')

    # Right-align the bar to the terminal edge. Tail format is
    # ` [bar] NNN% (current/total)` — we reserve enough for the
    # widest expected count, pad the label to fill the rest.
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    # Tail = " [" + bar + "] NNN% (D/D)"; pre-format and measure.
    local tail
    tail=$(printf ' [%s] %3d%% (%d/%d)' "$bar" "$percent" "$current" "$total")
    local prefix=":: "
    local label_w=$(( cols - ${#prefix} - ${#tail} ))
    (( label_w < 10 )) && label_w=10
    printf "\r%s%-*s%s" "$prefix" "$label_w" "$label" "$tail"
}

# ─────────────────────────────────────────
# Render all templates
# ─────────────────────────────────────────
render_all() {
    local palette_file="$1"
    local template_dir="$2"
    local output_dir="$3"

    # Source the palette + expose its path for build_sed_expr's
    # auto-derive (fallback hardcoded list kicks in if unset).
    source "$palette_file"
    _PALETTE_FILE="$palette_file"

    # Build sed expression
    local sed_expr
    sed_expr="$(build_sed_expr)"

    # Gather files
    local template_files=()
    while IFS= read -r -d '' template; do
        template_files+=("$template")
    done < <(find "$template_dir" -type f -print0)

    local total=${#template_files[@]}
    local current=0

    # Process all template files
    for template in "${template_files[@]}"; do
        current=$((current + 1))
        local rel="${template#$template_dir/}"
        local output="$output_dir/$rel"
        foxml_progress "$current" "$total" "Rendering templates"
        render_file "$template" "$output" "$sed_expr"
    done
    local family_source="$template_dir/icons/icon-family.json"
    [[ -f "$family_source" ]] || family_source="$template_dir/../icons/icon-family.json"
    if [[ -f "$family_source" ]]; then
        local native="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src/fox-render/fox-render-fast"
        [[ -x "$native" ]] || native="$(command -v fox-render-fast || true)"
        if [[ ! -x "$native" ]]; then
            echo "Icon generation needs fox-render-fast; build src/fox-render first." >&2
            return 1
        fi
        "$native" --finish-icons "$palette_file" "$template_dir" "$output_dir" || return 1
    fi
    echo "" # newline after progress bar
}

# ─────────────────────────────────────────
# Reverse render: replace actual colors with {{PLACEHOLDER}}s
# Used by update.sh to convert system files back to templates
# ─────────────────────────────────────────
build_reverse_sed_expr() {
    local sed_expr=""

    # Same auto-derive as build_sed_expr — keeps the forward and reverse
    # paths in lockstep, so a contributor adding a palette colour
    # automatically gets correct round-trip update.sh behaviour without
    # touching this file.
    local -a hex_vars=() str_vars=()
    if declare -F _derive_palette_vars >/dev/null && [[ -n "${_PALETTE_FILE:-}" ]]; then
        _derive_palette_vars "$_PALETTE_FILE" hex_vars str_vars
    fi
    if (( ${#hex_vars[@]} == 0 )); then
        hex_vars=(
            BG BG_DARK BG_ALT BG_HIGHLIGHT SELECTION
            FG FG_PASTEL FG_DIM COMMENT
            PRIMARY SECONDARY ACCENT SURFACE
            RED RED_BRIGHT GREEN GREEN_BRIGHT
            YELLOW YELLOW_BRIGHT BLUE BLUE_BRIGHT
            CYAN CYAN_BRIGHT WHITE OK WARN
            BG_DUNST BG_SPICETIFY BG_VENCORD_ALT BG_VENCORD_DEEP CARD_HOVER
            FZF_ACCENT1 FZF_ACCENT2 ZSH_SUGGEST ZSH_CMD
            TMUX_INACTIVE_FG TMUX_ACTIVE_FG TMUX_ACTIVE_BG
            DIFF_ADD DIFF_CHANGE DIFF_DELETE DIFF_TEXT TREESITTER_CTX
            WARM SAND WHEAT CLAY NVIM_BG_HL NVIM_SEL
        )
        str_vars=(
            THEME_TYPE NVIM_STYLE NVIM_BG KITTY_BG_OPACITY POPUP_BG_OPACITY SHOW_WELCOME SHOW_BANNER WALLPAPER
            MAKO_ICON_THEME GTK_ICON_THEME VSCODE_UI_THEME FONT_FAMILY
            ANSI_ACCENT1 ANSI_ACCENT2 ANSI_ACCENT3 ANSI_ACCENT4 ANSI_ACCENT5
            ANSI_TEXT ANSI_MUTED ANSI_ERROR ANSI_OK ANSI_STANDOUT_BG
            ANSI_PROMPT ANSI_PROMPT2 ANSI_LOAD
            GRAD1 GRAD2 GRAD3 GRAD4 GRAD5
            TMUX_ACTIVE TMUX_INACTIVE
        )
    fi

    # Reverse: replace RGB triples first (longer patterns), then hex values.
    # Use | as the sed delimiter to mirror build_sed_expr — / would break
    # on any palette value containing a path-like character (and forces
    # us to escape every / in the str_vars loop below).
    for var in "${hex_vars[@]}"; do
        local val="${!var}"
        [[ -z "$val" ]] && continue
        local r g b
        read r g b <<< "$(hex_to_rgb "$val")"
        # Replace RGB triple (e.g., "244,181,138" or "244, 181, 138")
        sed_expr+="s|${r}, *${g}, *${b}|{{${var}_R}},{{${var}_G}},{{${var}_B}}|g;"
    done

    # Then replace hex values (case-insensitive)
    for var in "${hex_vars[@]}"; do
        local val="${!var}"
        [[ -z "$val" ]] && continue
        # Match both upper and lowercase hex
        local upper="${val^^}"
        local lower="${val,,}"
        if [[ "$upper" != "$lower" ]]; then
            sed_expr+="s|${lower}|{{${var}}}|g;s|${upper}|{{${var}}}|g;"
        else
            sed_expr+="s|${val}|{{${var}}}|g;"
        fi
    done

    for var in "${str_vars[@]}"; do
        local val="${!var}"
        [[ -z "$val" ]] && continue
        # With | as delimiter we no longer need to escape / — but . * |
        # remain regex metacharacters and need backslash-escaping.
        local escaped="${val//|/\\|}"
        escaped="${escaped//./\\.}"
        escaped="${escaped//\*/\\*}"
        sed_expr+="s|${escaped}|{{${var}}}|g;"
    done

    echo "$sed_expr"
}

reverse_render_file() {
    local src="$1"
    local output="$2"
    local sed_expr="$3"

    mkdir -p "$(dirname "$output")"
    sed "$sed_expr" "$src" > "$output"
}

# ─────────────────────────────────────────
# CLI mode
# ─────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 3 ]]; then
        echo "Usage: ./render.sh <palette.sh> <template_dir> <output_dir>"
        exit 1
    fi
    render_all "$1" "$2" "$3"
    echo "Rendered templates to: $3"
fi
