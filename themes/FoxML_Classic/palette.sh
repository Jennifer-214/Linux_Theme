#!/bin/bash
# FoxML Classic — full palette
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=dark
NVIM_STYLE=storm
NVIM_BG=dark
KITTY_BG_OPACITY=0.6
POPUP_BG_OPACITY=0.7
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
ROUNDING=14
BLUR_SIZE=3
BLUR_PASSES=2
GAP_IN=6
GAP_OUT=12
BORDER_SIZE=0
SHADOW_RANGE=35
SHADOW_ALPHA=0.70

# ─── Core palette ───
BG=1a1214
BG_DARK=150f0f
BG_ALT=2d1a2d
BG_HIGHLIGHT=2d1f27
SELECTION=4d2f34

FG=d5c4b0
FG_PASTEL=c4b4a0
FG_DIM=7a7a7a
COMMENT=7a8290

PRIMARY=d4985a
SECONDARY=b8967a
ACCENT=8a9a7a
SURFACE=3a414b
BLUSH=c89eb5
GOLD=e8c989

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
WHITE=d5d5d5

# ─── Semantic aliases ───
OK=7aab88
WARN=c4b48a

# ─── ZSH command highlight color ───
ZSH_CMD=7aab88

# ─── Vencord deep background ───
BG_VENCORD_DEEP=150a15

# ─── Nvim extra colors ───
NVIM_BG_HL=1f1519
NVIM_SEL=3d2a1e
WARM=b0a498
SAND=a89a7a
WHEAT=d4b483
CLAY=b0603a

# ─── Nvim diff colors ───
DIFF_ADD=1a2e1a
DIFF_CHANGE=2d2a1a
DIFF_DELETE=2e1a1a
DIFF_TEXT=3d3a1a
TREESITTER_CTX=1f1519

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=1f242b
# Spicetify uses deeper darks
BG_SPICETIFY=1a0d1a
# Vencord secondary-alt
BG_VENCORD_ALT=241424
# Spicetify card hover
CARD_HOVER=3d2a3d

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=c49aab
FZF_ACCENT2=c4956e

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=7d5e6b

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=173
ANSI_ACCENT2=180
ANSI_ACCENT3=138
ANSI_ACCENT4=144
ANSI_ACCENT5=139
ANSI_TEXT=253
ANSI_MUTED=240
ANSI_ERROR=167
ANSI_OK=108
ANSI_STANDOUT_BG=232
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
TMUX_ACTIVE=colour180
TMUX_INACTIVE=colour240
TMUX_INACTIVE_FG=8c8070
TMUX_ACTIVE_FG=d4985a
TMUX_ACTIVE_BG=1f1519

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "peach" "pink" "lav" "slate")
