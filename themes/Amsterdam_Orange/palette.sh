#!/bin/bash
# Amsterdam Orange — Optiver-inspired palette (scarlet #FF3300 · Cello navy #1C3255 · white)
# Opt-in alternate theme; intentionally corporate / non-feminine. The fem-forward
# aesthetic invariant is scoped to the DEFAULT theme (FoxML_Classic), not this one.
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
WALLPAPER=amsterdam_orange.jpg

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
BG=0e1729
BG_DARK=090f1c
BG_ALT=14223c
BG_HIGHLIGHT=1c3255
SELECTION=2a4068

FG=e8edf5
FG_PASTEL=cfd8e6
FG_DIM=8492ab
COMMENT=5a6a85

PRIMARY=ff3300
SECONDARY=5b86c9
ACCENT=ff8a4c
SURFACE=20345a
BLUSH=ff6b4a
GOLD=f2a93b

# ─── ANSI colors ───
RED=e5484d
RED_BRIGHT=ff5c57
GREEN=3fa66a
GREEN_BRIGHT=57c882
YELLOW=e0a33a
YELLOW_BRIGHT=ffc04d
BLUE=4c7fd0
BLUE_BRIGHT=6298e6
CYAN=3fb0c2
CYAN_BRIGHT=5fccdb
WHITE=e8edf5

# ─── Semantic aliases ───
OK=3fa66a
WARN=e0a33a

# ─── ZSH command highlight color ───
ZSH_CMD=5b86c9

# ─── Vencord deep background ───
BG_VENCORD_DEEP=070c15

# ─── Nvim extra colors ───
NVIM_BG_HL=111c31
NVIM_SEL=233a5e
WARM=d99a6c
SAND=e0a86e
WHEAT=ffb060
CLAY=ff5c2e

# ─── Nvim diff colors ───
DIFF_ADD=0f2a1c
DIFF_CHANGE=152740
DIFF_DELETE=2e1417
DIFF_TEXT=233a5e
TREESITTER_CTX=111c31

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=0e1729
# Spicetify uses deeper darks
BG_SPICETIFY=070c15
# Vencord secondary-alt
BG_VENCORD_ALT=101a30
# Spicetify card hover
CARD_HOVER=20345a

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=ff3300
FZF_ACCENT2=ff8a4c

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=46566f

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=202
ANSI_ACCENT2=215
ANSI_ACCENT3=68
ANSI_ACCENT4=110
ANSI_ACCENT5=209
ANSI_TEXT=253
ANSI_MUTED=243
ANSI_ERROR=203
ANSI_OK=78
ANSI_STANDOUT_BG=232
ANSI_PROMPT=202
ANSI_PROMPT2=68
ANSI_LOAD=215

# ─── Gradient colors (zsh navy→scarlet tones) ───
GRAD1=202
GRAD2=208
GRAD3=215
GRAD4=68
GRAD5=110

# ─── Tmux colors ───
TMUX_ACTIVE=colour202
TMUX_INACTIVE=colour243
TMUX_INACTIVE_FG=8492ab
TMUX_ACTIVE_FG=ff3300
TMUX_ACTIVE_BG=111c31

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "scarlet" "navy" "amber" "steel")
