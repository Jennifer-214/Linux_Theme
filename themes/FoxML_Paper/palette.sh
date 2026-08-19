#!/bin/bash
# FoxML Paper — High-readability light theme
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=light
NVIM_STYLE=day
NVIM_BG=light
KITTY_BG_OPACITY=1.0
POPUP_BG_OPACITY=0.9
MAKO_ICON_THEME=Papirus-Light
VSCODE_UI_THEME=vs-light
FONT_FAMILY="Hack Nerd Font"
# WARNING: SHOW_WELCOME is also the project's literal-true alias used in
# ~246 template substitutions (vim opts, yazi bold, Firefox CSS selectors,
# nvim init.lua, etc.). Setting this to false will break far more than
# the welcome message. Leave as true; gate the welcome message via the
# `[[ "{{SHOW_WELCOME}}" == "true" ]]` check in templates/zsh/welcome.zsh.
SHOW_WELCOME=true
SHOW_BANNER=true
WALLPAPER=foxml_earthy.jpg

# ─── Aesthetic controls ───
ROUNDING=10
BLUR_SIZE=3
BLUR_PASSES=2
GAP_IN=6
GAP_OUT=12
BORDER_SIZE=1
SHADOW_RANGE=15
SHADOW_ALPHA=0.10

# ─── Core palette ───
BG=f5f5f0
BG_DARK=e8e8e3
BG_ALT=dfdfd9
BG_HIGHLIGHT=e2e2dc
SELECTION=d9d9d0

FG=1a1a1a
FG_PASTEL=3d3d3d
FG_DIM=6e6e6e
COMMENT=6e6e6e

PRIMARY=d4985a
SECONDARY=b8967a
ACCENT=8a9a7a
SURFACE=e8e8e3
BLUSH=b8607a
GOLD=b88a3a

# ─── ANSI colors ───
RED=b05555
RED_BRIGHT=c06868
GREEN=6b9a7a
GREEN_BRIGHT=7aab88
YELLOW=c4b48a
YELLOW_BRIGHT=b8a87e
BLUE=7a9ab4
BLUE_BRIGHT=8a8aab
CYAN=7a9aab
CYAN_BRIGHT=7aab9a
WHITE=1a1a1a

# ─── Semantic aliases ───
OK=6b9a7a
WARN=c4b48a

# ─── ZSH command highlight color ───
ZSH_CMD=6b9a7a

# ─── Vencord deep background ───
BG_VENCORD_DEEP=f0f0eb

# ─── Nvim extra colors ───
NVIM_BG_HL=e2e2dc
NVIM_SEL=372411
WARM=8a7a6e
SAND=9a8a7a
WHEAT=b4a483
CLAY=b0603a

# ─── Nvim diff colors ───
DIFF_ADD=e8f0e8
DIFF_CHANGE=f0f0e0
DIFF_DELETE=f0e8e8
DIFF_TEXT=e0e0d0
TREESITTER_CTX=e8e8e3

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=e8e8e3
# Spicetify uses warm paper
BG_SPICETIFY=f5f5f0
# Vencord secondary-alt
BG_VENCORD_ALT=e8e8e3
# Spicetify card hover
CARD_HOVER=e2e2dc

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=d4985a
FZF_ACCENT2=8a9a7a

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=9e9e9e

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=173
ANSI_ACCENT2=180
ANSI_ACCENT3=138
ANSI_ACCENT4=144
ANSI_ACCENT5=139
ANSI_TEXT=234
ANSI_MUTED=244
ANSI_ERROR=167
ANSI_OK=108
ANSI_STANDOUT_BG=255
ANSI_PROMPT=173
ANSI_PROMPT2=139
ANSI_LOAD=180

# ─── Gradient colors (zsh earthy tones) ───
GRAD1=173
GRAD2=180
GRAD3=138
GRAD4=144
GRAD5=139

# ─── Tmux colors ───
TMUX_ACTIVE=colour173
TMUX_INACTIVE=colour244
TMUX_INACTIVE_FG=8d8d8d
TMUX_ACTIVE_FG=1a1a1a
TMUX_ACTIVE_BG=e8e8e3

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "peach" "pink" "lav" "slate")
