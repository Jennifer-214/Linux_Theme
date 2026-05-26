#!/bin/bash
# FoxML Rose — rose-gold + lavender on cool dark base
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=dark
NVIM_STYLE=storm
NVIM_BG=dark
KITTY_BG_OPACITY=0.55
POPUP_BG_OPACITY=0.65
MAKO_ICON_THEME=Papirus-Dark
VSCODE_UI_THEME=vs-dark
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
ROUNDING=16
BLUR_SIZE=5
BLUR_PASSES=3
GAP_IN=8
GAP_OUT=16
BORDER_SIZE=1
SHADOW_RANGE=35
SHADOW_ALPHA=0.70

# ─── Core palette ───
BG=1a1220
BG_DARK=140d1a
BG_ALT=2a1d35
BG_HIGHLIGHT=2d1f33
SELECTION=4d2f4d

FG=e8d5d0
FG_PASTEL=d4bcc4
FG_DIM=8a7a85
COMMENT=8a7a90

PRIMARY=e8a4b8
SECONDARY=c49ac4
ACCENT=d4a5cf
SURFACE=3d3548
BLUSH=f0bcd0
GOLD=e8c4a0

# ─── ANSI colors ───
RED=c46878
RED_BRIGHT=d47888
GREEN=8aab9a
GREEN_BRIGHT=9abba8
YELLOW=d4b4a8
YELLOW_BRIGHT=e0c4b8
BLUE=9aa5d4
BLUE_BRIGHT=a8b4e0
CYAN=a8b4d4
CYAN_BRIGHT=b4c4d8
WHITE=e8d8e0

# ─── Semantic aliases ───
OK=9abba8
WARN=d4b4a8

# ─── ZSH command highlight color ───
ZSH_CMD=9abba8

# ─── Vencord deep background ───
BG_VENCORD_DEEP=140a18

# ─── Nvim extra colors ───
NVIM_BG_HL=1f1525
NVIM_SEL=3d2a48
WARM=c4a4b0
SAND=b89aa8
WHEAT=d4b4c4
CLAY=b06880

# ─── Nvim diff colors ───
DIFF_ADD=1a2e22
DIFF_CHANGE=2a1d35
DIFF_DELETE=2e1a22
DIFF_TEXT=3d2a35
TREESITTER_CTX=1f1525

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=241a2b
# Spicetify uses deeper darks
BG_SPICETIFY=1a0d1f
# Vencord secondary-alt
BG_VENCORD_ALT=241828
# Spicetify card hover
CARD_HOVER=3d2a40

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=e8a4b8
FZF_ACCENT2=c49ac4

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=7d5e70

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=211
ANSI_ACCENT2=183
ANSI_ACCENT3=176
ANSI_ACCENT4=189
ANSI_ACCENT5=139
ANSI_TEXT=253
ANSI_MUTED=240
ANSI_ERROR=167
ANSI_OK=108
ANSI_STANDOUT_BG=232
ANSI_PROMPT=211
ANSI_PROMPT2=183
ANSI_LOAD=176

# ─── Gradient colors (zsh rose-lavender tones) ───
GRAD1=211
GRAD2=176
GRAD3=183
GRAD4=189
GRAD5=139

# ─── Tmux colors ───
TMUX_ACTIVE=colour211
TMUX_INACTIVE=colour240
TMUX_INACTIVE_FG=8a747c
TMUX_ACTIVE_FG=e8a4b8
TMUX_ACTIVE_BG=1f1525

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "rose" "lilac" "mauve" "slate")
