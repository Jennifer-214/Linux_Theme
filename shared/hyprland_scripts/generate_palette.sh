#!/bin/bash
# FoxML Auto-Theme Generator
# Extracts colors from a wallpaper and creates a FoxML palette

IMG="$1"
if [[ ! -f "$IMG" ]]; then
    notify-send "Auto-Theme" "No wallpaper found at $IMG"
    exit 1
fi

if ! command -v convert >/dev/null 2>&1; then
    notify-send "Auto-Theme" "ImageMagick (convert) is required for color extraction."
    exit 1
fi

notify-send "Auto-Theme" "Generating earthy palette from wallpaper..."

# Create a temporary directory for color analysis
TMP_PALETTE=$(mktemp -d)
# Resize and reduce colors to 8 dominant earthy tones
convert "$IMG" -resize 200x200 -colors 8 -unique-colors txt:- > "$TMP_PALETTE/colors.txt"

# Extract hex codes (skipping the first line header)
HEX_CODES=($(grep -oE '#[0-9A-Fa-f]{6}' "$TMP_PALETTE/colors.txt"))

# Assign colors to FoxML variables
# We try to pick the best fits for BG, PRIMARY, etc.
# This is a simple mapping: 
BG=${HEX_CODES[0]#\#}
PRIMARY=${HEX_CODES[1]#\#}
ACCENT=${HEX_CODES[2]#\#}
SURFACE=${HEX_CODES[3]#\#}
FG=${HEX_CODES[4]#\#}
WARN=${HEX_CODES[5]#\#}

# Clean up
rm -rf "$TMP_PALETTE"

# Prepare the Generated theme directory
GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../themes/Generated" 2>/dev/null && pwd || echo "$HOME/.config/foxml/themes/Generated")"
mkdir -p "$GEN_DIR"

# Sanitize the filename used in the heredoc comment. The heredoc
# itself isn't shell-evaluating its output, but defence-in-depth: a
# wallpaper named `$(touch pwned).jpg` would render as a literal
# comment now, and even if a future change started sourcing this
# comment line the value couldn't smuggle in metacharacters.
_img_basename=$(basename "$IMG")
_img_basename="${_img_basename//[^A-Za-z0-9._-]/_}"

# Write the palette.sh
cat > "$GEN_DIR/palette.sh" <<EOF
# Generated FoxML Palette from ${_img_basename}
THEME_TYPE="Generated"
BG="${BG}"
BG_DARK="${BG}"
BG_ALT="${SURFACE}"
FG="${FG}"
FG_DIM="${FG}"
PRIMARY="${PRIMARY}"
ACCENT="${ACCENT}"
SURFACE="${SURFACE}"
WARN="${WARN}"
RED="e67e80"
GREEN="a7c080"
YELLOW="dbbc7f"
BLUE="7fbbb3"
MAGENTA="d699b6"
CYAN="83c092"
WHITE="d3c6aa"

# Inherit some standard earthy defaults
FONT_FAMILY="MonaspiceKr Nerd Font"
KITTY_BG_OPACITY="0.85"
EOF

# Copy a dummy theme.conf if it doesn't exist
if [[ ! -f "$GEN_DIR/theme.conf" ]]; then
    cat > "$GEN_DIR/theme.conf" <<EOF
type=Generated
description=Auto-generated from wallpaper
EOF
fi

# Run the installer for the Generated theme. Script lives at
# shared/hyprland_scripts/generate_palette.sh so the repo root is two
# levels up, not three (the prior ../../../ went one above the repo
# and silently broke wallpaper-derived theming).
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
./install.sh Generated --yes

notify-send "Auto-Theme" "Theme synchronized with wallpaper!"
