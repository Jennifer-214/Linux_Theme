#!/bin/bash
# FoxML Bubblegum — saturated bubblegum pink + orchid on a near-black plum base
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
# Minimal white mark on a near-black field -- sits a shade under BG (150a12),
# so the pink chrome carries the colour and the desktop stays quiet.
WALLPAPER=windowswallpaper.jpg

# ─── Aesthetic controls ───
ROUNDING=16
BLUR_SIZE=2
BLUR_PASSES=2
GAP_IN=6
GAP_OUT=12
BORDER_SIZE=1
SHADOW_RANGE=35
SHADOW_ALPHA=0.70

# ─── Core palette ───
BG=150a12
BG_DARK=0e0610
BG_ALT=241426
BG_HIGHLIGHT=2b1826
SELECTION=52254a

FG=f2dce8
FG_PASTEL=dcc0d2
FG_DIM=8d7686
COMMENT=8a7590

PRIMARY=ff5fa2
SECONDARY=c77dff
ACCENT=ff9ecd
SURFACE=3c2a44
BLUSH=ffb3d9
GOLD=ffd18c

# ─── ANSI colors ───
# RED stays deliberately deeper + more crimson than PRIMARY: a hot-pink
# terminal where diff-red reads as the accent color is unscannable.
RED=d93b54
RED_BRIGHT=f2586e
GREEN=5fbf8f
GREEN_BRIGHT=7ad4a5
YELLOW=e6c07d
YELLOW_BRIGHT=ffd694
BLUE=7d9aff
BLUE_BRIGHT=9ab4ff
CYAN=63d1d8
CYAN_BRIGHT=85e3e8
WHITE=f2dce8

# ─── Semantic aliases ───
OK=5fbf8f
WARN=e6c07d

# ─── ZSH command highlight color ───
ZSH_CMD=5fbf8f

# ─── Vencord deep background ───
BG_VENCORD_DEEP=0b0510

# ─── Nvim extra colors ───
NVIM_BG_HL=1d0f1a
NVIM_SEL=42203c
WARM=e0a3bd
SAND=d9a8c4
WHEAT=ffc2dd
CLAY=d9536f

# ─── Nvim diff colors ───
DIFF_ADD=13291f
DIFF_CHANGE=24182e
DIFF_DELETE=2e1220
DIFF_TEXT=3d2038
TREESITTER_CTX=1d0f1a

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=1d1120
# Spicetify uses deeper darks
BG_SPICETIFY=0e0610
# Vencord secondary-alt
BG_VENCORD_ALT=1f1024
# Spicetify card hover
CARD_HOVER=3d2340

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=ff5fa2
FZF_ACCENT2=c77dff

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=7a5470

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=205
ANSI_ACCENT2=212
ANSI_ACCENT3=141
ANSI_ACCENT4=183
ANSI_ACCENT5=218
ANSI_TEXT=253
ANSI_MUTED=240
ANSI_ERROR=167
ANSI_OK=79
ANSI_STANDOUT_BG=232
ANSI_PROMPT=205
ANSI_PROMPT2=141
ANSI_LOAD=212

# ─── Gradient colors (zsh pink→orchid ramp) ───
GRAD1=205
GRAD2=212
GRAD3=218
GRAD4=183
GRAD5=141

# ─── Tmux colors ───
TMUX_ACTIVE=colour205
TMUX_INACTIVE=colour240
TMUX_INACTIVE_FG=8d7686
TMUX_ACTIVE_FG=ff5fa2
TMUX_ACTIVE_BG=1d0f1a

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "pink" "orchid" "candy" "plum")
