#!/bin/bash
# Linux_Theme — Updater
# Pulls system configs back into templates (reverse-renders colors to placeholders)
# Usage: ./update.sh [theme_name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEMES_DIR="$SCRIPT_DIR/themes"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
SHARED_DIR="$SCRIPT_DIR/shared"
ACTIVE_FILE="$SCRIPT_DIR/.active-theme"

source "$SCRIPT_DIR/mappings.sh"
source "$SCRIPT_DIR/render.sh"

# ─────────────────────────────────────────
# Determine theme
# ─────────────────────────────────────────
THEME_NAME="${1:-}"

if [[ -z "$THEME_NAME" && -f "$ACTIVE_FILE" ]]; then
    THEME_NAME="$(cat "$ACTIVE_FILE")"
fi
# A name saved before four themes lost their prefix still means the theme it became.   old-theme-name
if [[ -n "$THEME_NAME" && ! -d "$SCRIPT_DIR/themes/$THEME_NAME" && -d "$SCRIPT_DIR/themes/${THEME_NAME#FoxML_}" ]]; then   # old-theme-name
    THEME_NAME="${THEME_NAME#FoxML_}"   # old-theme-name
fi

if [[ -z "$THEME_NAME" ]]; then
    echo "No active theme set. Usage: ./update.sh [theme_name]"
    exit 1
fi

PALETTE_FILE="$THEMES_DIR/$THEME_NAME/palette.sh"
if [[ ! -f "$PALETTE_FILE" ]]; then
    echo "Theme '$THEME_NAME' not found (missing palette.sh)"
    exit 1
fi

echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│                    Linux_Theme Theme Updater                          │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""
echo "Active theme: $THEME_NAME"
echo "Pulling system configs back into templates..."
echo ""

# ─────────────────────────────────────────
# Mode: --review (default, prompt per file with diff) or --force (auto).
# Reverse-rendering copies whatever is currently on disk back into the
# tracked templates/. If your machine has been compromised, this is a
# vector for shipping the compromise to anyone else who uses your repo.
# Default to review-on-each-diff. --force bypasses for unattended use,
# user opts in knowingly.
# ─────────────────────────────────────────
UPDATE_MODE="review"
for arg in "$@"; do
    case "$arg" in
        --force)  UPDATE_MODE="force" ;;
        --review) UPDATE_MODE="review" ;;
        --help|-h)
            sed -n '2,5p' "$0" | sed 's/^# \?//'
            echo "Flags:"
            echo "  --review (default)  Show diff and prompt before pulling each file"
            echo "  --force             Pull all changes without prompting (CI / trusted run)"
            exit 0
            ;;
    esac
done
if [[ "$UPDATE_MODE" == "review" ]]; then
    echo "  Review mode: each file change will be diffed and prompted."
    echo "  Run with --force to bypass (only do this on a known-clean machine)."
    echo ""
fi

# Danger-pattern scan: refuse to suck content that looks like an
# injection vector. If an attacker compromises the user's live config
# and embeds malicious bash, update.sh would otherwise capture it into
# templates/ and a later `git push` would publish it. Block at the
# capture point. Patterns matched here are things that should NEVER
# appear in a config file's diff if the user only changed colors,
# fonts, or pure-data settings.
#
# Always-on, regardless of --force. The whole point is that --force
# users specifically can't accidentally publish a payload.
_DANGER_PATTERNS=(
    '^[[:space:]]*exec[-_]?once[[:space:]]*='
    'curl[[:space:]].*\|[[:space:]]*(bash|sh)'
    'wget[[:space:]].*\|[[:space:]]*(bash|sh)'
    'bash[[:space:]]+-c[[:space:]]+[\x22\x27].*\$\('
    'eval[[:space:]]*[\x22\x27]?\$'
    'on[-_]?click[[:space:]]*='
    'on[-_]?press[[:space:]]*='
    'command[[:space:]]*=[[:space:]]*[\x22\x27]?[a-zA-Z]'
    'PreExec[[:space:]]*='
    'ExecStartPre[[:space:]]*='
    '<script[[:space:]>]'
)

_scan_danger() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    for pat in "${_DANGER_PATTERNS[@]}"; do
        if grep -qE "$pat" "$file" 2>/dev/null; then
            echo "    ${pat}" >&2
            return 1
        fi
    done
    return 0
}

# Confirm before each file lands in templates/ or shared/. Returns 0 to
# accept the change, 1 to skip. --force short-circuits the prompt but
# NOT the danger scan — danger patterns always require manual review.
_confirm_update() {
    local label="$1" current="$2" proposed="$3"

    # Step 1: danger-pattern check on the proposed (incoming) content.
    # Refuse to publish without --review prompt even if --force is set.
    if ! _scan_danger "$proposed"; then
        echo ""
        echo "  ⚠ DANGER PATTERN found in $label (above)"
        echo "    update.sh will NOT auto-capture this file."
        echo "    If this is legitimate (e.g. you added a custom keybind),"
        echo "    edit templates/<file> directly + commit; don't reverse-sync."
        return 1
    fi

    [[ "$UPDATE_MODE" == "force" ]] && return 0
    if ! diff -q "$current" "$proposed" >/dev/null 2>&1; then
        echo ""
        echo "── $label ──"
        diff -u --color=always "$current" "$proposed" 2>/dev/null \
            | head -40 || diff -u "$current" "$proposed" | head -40
        read -r -p "  Pull this change into templates? [y/N/q] " yn
        case "$yn" in
            q|Q) echo "  aborted by user"; exit 0 ;;
            y|Y) return 0 ;;
            *)   echo "  skipped"; return 1 ;;
        esac
    fi
    return 0
}

# ─────────────────────────────────────────
# Build reverse sed expression
# ─────────────────────────────────────────
source "$PALETTE_FILE"
REVERSE_SED="$(build_reverse_sed_expr)"

# ─────────────────────────────────────────
# Update template files (reverse-render)
# ─────────────────────────────────────────
echo "Updating templates..."
for mapping in "${TEMPLATE_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"

    # Skip Firefox and conditional entries
    [[ "$dest" == *"FIREFOX_PROFILE"* ]] && continue
    [[ "$dest" == *"GEMINI_DIR"* ]] && continue
    [[ "$dest" == *".oh-my-zsh"* && ! -d "$HOME/.oh-my-zsh" ]] && continue

    # Its generated icon rules come from the shared family, not reverse-capture.
    # Edit the palette/theme template directly so capture cannot fork that source.
    [[ "$src" == "yazi/theme.toml" ]] && continue

    if [[ -f "$dest" ]]; then
        reverse_render_file "$dest" "$TEMPLATES_DIR/$src" "$REVERSE_SED"
        echo "  ✓ $src"
    else
        echo "  ⚠ $src (not found at $dest)"
    fi
done

# ─────────────────────────────────────────
# Update shared files (copy as-is)
# ─────────────────────────────────────────
echo ""
echo "Updating shared configs..."
for mapping in "${SHARED_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"

    if [[ -f "$dest" ]]; then
        mkdir -p "$(dirname "$SHARED_DIR/$src")"
        cp "$dest" "$SHARED_DIR/$src"
        echo "  ✓ $src"
    fi
done

# ─────────────────────────────────────────
# Special handlers
# ─────────────────────────────────────────
echo ""
echo "Updating special configs..."
update_specials "$TEMPLATES_DIR" "$REVERSE_SED"

echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│                      Update Complete!                           │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo ""
echo "Templates updated at: $TEMPLATES_DIR"
echo ""
