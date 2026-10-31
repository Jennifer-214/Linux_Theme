#!/bin/bash
# FoxML Rose — rose-gold + lavender on cool dark base
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=dark
NVIM_STYLE=storm
NVIM_BG=dark
KITTY_BG_OPACITY=0.55
POPUP_BG_OPACITY=0.65
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

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
GTK_PREFER_DARK=1
CURSOR_THEME=catppuccin-mocha-peach-cursors
PAPIRUS_FOLDER_COLOR=cat-mocha-peach
HYPR_BORDER_SIZE=0
HYPR_BORDER_INACTIVE=3d354866
HYPR_SHADOW_ALPHA_INACTIVE=0.40
HYPR_DIM_STRENGTH=0.15
KITTY_ITALIC_FONT=auto
KITTY_DIM_OPACITY=0.4
WELCOME_INK1=211
WELCOME_INK2=183
WELCOME_INK3=176
WELCOME_INK4=189
WELCOME_INK5=139
NVIM_BANNER1=b06880
NVIM_BANNER2=d4b4c4
NVIM_BANNER3=f0bcd0
NVIM_BANNER4=d4a5cf

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
# kitty color8 — "bright black", the dim-text slot most CLIs use
ANSI_BRIGHT_BLACK=3d3548

# ─── Semantic aliases ───
OK=9abba8
WARN=d4b4a8

# ─── ZSH command highlight color ───
ZSH_CMD=9abba8

# ─── Vencord deep background ───
BG_VENCORD_DEEP=140a18

# ─── Nvim extra colors ───
NVIM_BG_HL=1f1525
NVIM_SEL=372228
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

# ─── Nvim rainbow delimiters / indent guides ───
NVIM_RAINBOW1=e8a4b8
NVIM_RAINBOW2=c49ac4
NVIM_RAINBOW3=8aab9a
NVIM_RAINBOW4=d4b4a8
NVIM_RAINBOW5=a8b4d4
NVIM_RAINBOW6=c46878
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
NVIM_FN_DEF=e8a4b8
NVIM_FN_DEF_BOLD=false
NVIM_KW_BOLD=true
NVIM_READONLY_BOLD=true

# ─── Nvim syntax roles ───
NVIM_SYN_VAR=e8d5d0
NVIM_SYN_MEMBER=8aab9a
NVIM_SYN_PARAM=e0c4b8
NVIM_SYN_TYPE=a8b4d4
NVIM_SYN_STRING=8aab9a
NVIM_SYN_NUMBER=d4b4a8
NVIM_SYN_CALL=e8a4b8
NVIM_SYN_OPERATOR=d4a5cf
NVIM_SYN_RETURN=d4a5cf
NVIM_SYN_COMMENT=8a7a90
NVIM_SYN_HEADER=8a7a90
NVIM_SECTION_HEADERS=false
NVIM_FAINT_FG=3d3548
NVIM_RED_PEN=b06880
NVIM_SEARCH_FG=1a1220
NVIM_SEARCH_BG=e8a4b8
NVIM_CURSEARCH_FG=1a1220
NVIM_CURSEARCH_BG=e8a4b8
NVIM_INCSEARCH_FG=1a1220
NVIM_INCSEARCH_BG=c49ac4
KITTY_SELECTION_BG=3d3548
TMUX_MODE_FG=1a1220
TMUX_MODE_BG=e8a4b8
KITTY_CURSOR=e8a4b8
KITTY_CURSOR_TEXT=111111
WAYBAR_WS_ACTIVE=f0bcd0
PI_BORDER=3d3548
PI_MUTED=d4b4c4
PI_ERROR=c46878
PI_MD_CODE=a8b4d4
PI_SYN_KEYWORD=e8a4b8
PI_SYN_FUNCTION=d4b4a8
PI_SYN_STRING=9abba8
PI_SYN_NUMBER=b06880
PI_SYN_OPERATOR=c49ac4

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=b5702f
NVIM_SYMDEPS_SYNC=68421f
NVIM_SYMDEPS_WARN=d4b483
NVIM_SYMDEPS_ALARM=b0603a
NVIM_SYMDEPS_OK=7aab88

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=241a2b
# Spicetify uses deeper darks
BG_SPICETIFY=1a0d1f
# Vencord secondary-alt
BG_VENCORD_ALT=241828
# Spicetify card hover
CARD_HOVER=3d2a40
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=2a2018

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
TMUX_INACTIVE_FG=988390
TMUX_ACTIVE_FG=e8a4b8
TMUX_ACTIVE_BG=1f1525

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "rose" "lilac" "mauve" "slate")
