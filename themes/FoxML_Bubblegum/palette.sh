#!/bin/bash
# FoxML Bubblegum — saturated bubblegum pink + orchid on a near-black plum base
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=dark
NVIM_STYLE=storm
NVIM_BG=dark
KITTY_BG_OPACITY=0.6
POPUP_BG_OPACITY=0.7
MAKO_ICON_THEME=Papirus-Dark   # also the GTK icon theme
VSCODE_UI_THEME=vs-dark
FONT_FAMILY="MonaspiceKr Nerd Font"
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

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
GTK_PREFER_DARK=1
CURSOR_THEME=catppuccin-mocha-peach-cursors
PAPIRUS_FOLDER_COLOR=cat-mocha-peach
HYPR_BORDER_SIZE=0
HYPR_BORDER_INACTIVE=3c2a4466
HYPR_SHADOW_ALPHA_INACTIVE=0.40
HYPR_DIM_STRENGTH=0.15
KITTY_ITALIC_FONT=auto
KITTY_DIM_OPACITY=0.4
WELCOME_INK1=205
WELCOME_INK2=212
WELCOME_INK3=141
WELCOME_INK4=183
WELCOME_INK5=218
NVIM_BANNER1=d9536f
NVIM_BANNER2=ffc2dd
NVIM_BANNER3=ffb3d9
NVIM_BANNER4=ff9ecd

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
# kitty color8 — "bright black", the dim-text slot most CLIs use
ANSI_BRIGHT_BLACK=3c2a44

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

# ─── Nvim rainbow delimiters / indent guides ───
NVIM_RAINBOW1=ff5fa2
NVIM_RAINBOW2=c77dff
NVIM_RAINBOW3=5fbf8f
NVIM_RAINBOW4=e6c07d
NVIM_RAINBOW5=63d1d8
NVIM_RAINBOW6=d93b54
NVIM_INDENT1=4d3a2e
NVIM_INDENT2=4a3040
NVIM_INDENT3=2e3d2e
NVIM_INDENT4=3d3a24
NVIM_INDENT5=2a3540
NVIM_INDENT6=402a2a
NVIM_IBL_SCOPE=e0b878

# ─── Nvim state backgrounds (diagnostics / git / conflicts / word highlight) ───
NVIM_DIAG_ERR_BG=3d1a1a
NVIM_DIAG_WARN_BG=3d2e1a
NVIM_GIT_MOD=b8a47a
NVIM_GIT_DEL=a06060
NVIM_CONFLICT_CUR=3d1f23
NVIM_CONFLICT_CUR_LABEL=4d2529
NVIM_CONFLICT_INC=1a3328
NVIM_CONFLICT_INC_LABEL=1f3d2e
NVIM_ILLUMINATE=5e4029

# ─── Nvim definition / keyword weight ───
NVIM_FN_DEF=ff5fa2
NVIM_FN_DEF_BOLD=false
NVIM_KW_BOLD=true
NVIM_READONLY_BOLD=true

# ─── Nvim syntax roles ───
NVIM_SYN_VAR=f2dce8
NVIM_SYN_MEMBER=5fbf8f
NVIM_SYN_PARAM=ffd694
NVIM_SYN_TYPE=63d1d8
NVIM_SYN_STRING=5fbf8f
NVIM_SYN_NUMBER=e6c07d
NVIM_SYN_CALL=ff5fa2
NVIM_SYN_OPERATOR=ff9ecd
NVIM_SYN_RETURN=ff9ecd
NVIM_SYN_COMMENT=8a7590
NVIM_SYN_HEADER=8a7590
NVIM_SECTION_HEADERS=false
NVIM_FAINT_FG=3c2a44
NVIM_RED_PEN=d9536f
NVIM_SEARCH_FG=150a12
NVIM_SEARCH_BG=ff5fa2
NVIM_CURSEARCH_FG=150a12
NVIM_CURSEARCH_BG=ff5fa2
NVIM_INCSEARCH_FG=150a12
NVIM_INCSEARCH_BG=c77dff
KITTY_SELECTION_BG=3c2a44
TMUX_MODE_FG=150a12
TMUX_MODE_BG=ff5fa2
KITTY_CURSOR=ff5fa2
KITTY_CURSOR_TEXT=111111
WAYBAR_WS_ACTIVE=ffb3d9
PI_BORDER=3c2a44
PI_MUTED=ffc2dd
PI_ERROR=d93b54
PI_MD_CODE=63d1d8
PI_SYN_KEYWORD=ff5fa2
PI_SYN_FUNCTION=e6c07d
PI_SYN_STRING=7ad4a5
PI_SYN_NUMBER=d9536f
PI_SYN_OPERATOR=c77dff

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=b5702f
NVIM_SYMDEPS_SYNC=68421f
NVIM_SYMDEPS_WARN=d4b483
NVIM_SYMDEPS_ALARM=b0603a
NVIM_SYMDEPS_OK=7aab88

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=1d1120
# Spicetify uses deeper darks
BG_SPICETIFY=0e0610
# Vencord secondary-alt
BG_VENCORD_ALT=1f1024
# Spicetify card hover
CARD_HOVER=3d2340
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=2a2018

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
