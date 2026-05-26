#!/bin/bash
# Cave Data Center — full palette
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
SHOW_BANNER=false
WALLPAPER=cave_data_center.jpg

# ─── Aesthetic controls ───
ROUNDING=10
BLUR_SIZE=3
BLUR_PASSES=2
GAP_IN=6
GAP_OUT=12
BORDER_SIZE=2
SHADOW_RANGE=35
SHADOW_ALPHA=0.70

# ─── Core palette ───
BG=151526
BG_DARK=0f0f1c
BG_ALT=1a1a30
BG_HIGHLIGHT=252540
SELECTION=4a3510

FG=d8d8e8
FG_PASTEL=b8b8cc
FG_DIM=606070
COMMENT=7a7c8a

PRIMARY=2ea3f2
SECONDARY=ffb200
ACCENT=29c4a9
SURFACE=1f1f38
BLUSH=f29bb8
GOLD=ffb200

# ─── ANSI colors ───
RED=cf2e2e
RED_BRIGHT=e04848
GREEN=48b878
GREEN_BRIGHT=58d088
YELLOW=ffb200
YELLOW_BRIGHT=ffc433
BLUE=2ea3f2
BLUE_BRIGHT=58b8f5
CYAN=29c4a9
CYAN_BRIGHT=3dd4b8
WHITE=d8d8e8

# ─── Semantic aliases ───
OK=48b878
WARN=ffb200

# ─── ZSH command highlight color ───
ZSH_CMD=48b878

# ─── Nvim extra colors ───
NVIM_BG_HL=252540
NVIM_SEL=4a3510
WARM=8898b0
SAND=7888a0
WHEAT=e0a030
CLAY=d05030

# ─── Vencord deep background ───
BG_VENCORD_DEEP=0a0a14

# ─── Nvim diff colors ───
DIFF_ADD=1a2e28
DIFF_CHANGE=2e2a18
DIFF_DELETE=2e1a1a
DIFF_TEXT=3a3520
TREESITTER_CTX=1a1a2e

# ─── App-specific overrides ───
BG_DUNST=1a1a30
BG_SPICETIFY=0f0f1c
BG_VENCORD_ALT=1a1a2e
CARD_HOVER=2a2a48

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=ffb200
FZF_ACCENT2=29c4a9

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=4a4a60

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=214
ANSI_ACCENT2=39
ANSI_ACCENT3=43
ANSI_ACCENT4=253
ANSI_ACCENT5=110
ANSI_TEXT=253
ANSI_MUTED=240
ANSI_ERROR=167
ANSI_OK=72
ANSI_STANDOUT_BG=233
ANSI_PROMPT=214
ANSI_PROMPT2=39
ANSI_LOAD=214

# ─── Gradient colors (gold-to-blue) ───
GRAD1=214
GRAD2=220
GRAD3=43
GRAD4=39
GRAD5=110

# ─── Tmux colors ───
TMUX_ACTIVE=colour214
TMUX_INACTIVE=colour240
TMUX_INACTIVE_FG=9c9cb0
TMUX_ACTIVE_FG=ffb200
TMUX_ACTIVE_BG=1a1a2e

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "blue" "gold" "teal" "slate")
