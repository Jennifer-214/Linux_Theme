#!/bin/bash
# Linux_Theme — what changed on this machine since the last install
# Renders the active theme's templates and compares each with the copy deployed here (and shared/ files with
# theirs), then shows the differences. It writes nothing: move what you want to keep into templates/ (colours as
# {{TOKENS}}) or shared/ by hand, then re-render with install.sh --render.
# Usage: ./update.sh [theme_name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEMES_DIR="$SCRIPT_DIR/themes"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
SHARED_DIR="$SCRIPT_DIR/shared"
ACTIVE_FILE="$SCRIPT_DIR/.active-theme"

case "${1:-}" in
    --help|-h) sed -n '2,6p' "$0" | sed 's/^# \?//'; exit 0 ;;
    --force|--review) echo "update.sh no longer writes into templates/; it shows what differs." >&2; shift ;;
esac

source "$SCRIPT_DIR/mappings.sh"
source "$SCRIPT_DIR/render.sh"

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

RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"' EXIT
FAST="$SCRIPT_DIR/src/desk-render/desk-render-fast"
if [[ -x "$FAST" ]]; then
    "$FAST" "$PALETTE_FILE" "$TEMPLATES_DIR" "$RENDERED" >/dev/null
else
    render_all "$PALETTE_FILE" "$TEMPLATES_DIR" "$RENDERED" >/dev/null
fi

color=never
[[ -t 1 ]] && color=always
changed=0
# One file: what the repo would lay ($1, named $3) against what is deployed here ($2).
compare() {
    [[ -f "$1" && -f "$2" ]] || return 0
    diff -q "$1" "$2" >/dev/null 2>&1 && return 0
    changed=$((changed + 1))
    echo ""
    diff -u --color="$color" --label "$3" --label "${2/#$HOME/\~}" "$1" "$2" || true
}

echo "Theme $THEME_NAME: comparing what the repo would lay with what is deployed here."
for mapping in "${TEMPLATE_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"
    [[ "$dest" == *"FIREFOX_PROFILE"* || "$dest" == *"GEMINI_DIR"* ]] && continue
    compare "$RENDERED/$src" "$dest" "templates/$src (rendered)"
done
for mapping in "${SHARED_MAPPINGS[@]}"; do
    src="${mapping%%|*}"
    dest="${mapping##*|}"
    dest="${dest/#\~/$HOME}"
    compare "$SHARED_DIR/$src" "$dest" "shared/$src"
done

echo ""
if (( changed )); then
    echo "$changed deployed files differ from what the repo would lay. Nothing was written: move what you want to keep"
    echo "into templates/ (colours as {{TOKENS}}) or shared/, then re-render."
else
    echo "Every deployed file matches what the repo would lay."
fi
