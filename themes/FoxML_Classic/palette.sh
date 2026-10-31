#!/bin/bash
# FoxML Classic — full palette
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
WALLPAPER=foxml_earth_2.jpg

# ─── Aesthetic controls ───
ROUNDING=14
BLUR_SIZE=3
BLUR_PASSES=2
GAP_IN=6
GAP_OUT=12
BORDER_SIZE=0
SHADOW_RANGE=35
SHADOW_ALPHA=0.70

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
GTK_PREFER_DARK=1
CURSOR_THEME=catppuccin-mocha-peach-cursors
PAPIRUS_FOLDER_COLOR=cat-mocha-peach
HYPR_BORDER_SIZE=0
HYPR_BORDER_INACTIVE=3a414b66
HYPR_SHADOW_ALPHA_INACTIVE=0.40
HYPR_DIM_STRENGTH=0.15
KITTY_ITALIC_FONT=auto
KITTY_DIM_OPACITY=0.4
WELCOME_INK1=173
WELCOME_INK2=180
WELCOME_INK3=138
WELCOME_INK4=144
WELCOME_INK5=139
NVIM_BANNER1=b0603a
NVIM_BANNER2=d4b483
NVIM_BANNER3=c89eb5
NVIM_BANNER4=8a9a7a

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
# kitty color8 — "bright black", the dim-text slot most CLIs use
ANSI_BRIGHT_BLACK=3a414b

# ─── Semantic aliases ───
OK=7aab88
WARN=c4b48a

# ─── ZSH command highlight color ───
ZSH_CMD=7aab88

# ─── Vencord deep background ───
BG_VENCORD_DEEP=150a15

# ─── Nvim extra colors ───
NVIM_BG_HL=1f1519
NVIM_SEL=372411
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

# ─── Nvim rainbow delimiters / indent guides ───
NVIM_RAINBOW1=d4985a
NVIM_RAINBOW2=b8967a
NVIM_RAINBOW3=6b9a7a
NVIM_RAINBOW4=c4b48a
NVIM_RAINBOW5=7a9aab
NVIM_RAINBOW6=b05555
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
NVIM_FN_DEF=d4985a
NVIM_FN_DEF_BOLD=false
NVIM_KW_BOLD=true
NVIM_READONLY_BOLD=true

# ─── Nvim syntax roles ───
NVIM_SYN_VAR=d5c4b0
NVIM_SYN_MEMBER=6b9a7a
NVIM_SYN_PARAM=b8a87e
NVIM_SYN_TYPE=7a9aab
NVIM_SYN_STRING=6b9a7a
NVIM_SYN_NUMBER=c4b48a
NVIM_SYN_CALL=d4985a
NVIM_SYN_OPERATOR=8a9a7a
NVIM_SYN_RETURN=8a9a7a
NVIM_SYN_COMMENT=7a8290
NVIM_SYN_HEADER=7a8290
NVIM_SECTION_HEADERS=false
NVIM_FAINT_FG=3a414b
NVIM_RED_PEN=b0603a
NVIM_SEARCH_FG=1a1214
NVIM_SEARCH_BG=d4985a
NVIM_CURSEARCH_FG=1a1214
NVIM_CURSEARCH_BG=d4985a
NVIM_INCSEARCH_FG=1a1214
NVIM_INCSEARCH_BG=b8967a
KITTY_SELECTION_BG=3a414b
TMUX_MODE_FG=1a1214
TMUX_MODE_BG=d4985a
KITTY_CURSOR=d4985a
KITTY_CURSOR_TEXT=111111
WAYBAR_WS_ACTIVE=c89eb5
PI_BORDER=3a414b
PI_MUTED=d4b483
PI_ERROR=b05555
PI_MD_CODE=7a9aab
PI_SYN_KEYWORD=d4985a
PI_SYN_FUNCTION=c4b48a
PI_SYN_STRING=7aab88
PI_SYN_NUMBER=b0603a
PI_SYN_OPERATOR=b8967a

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=b5702f
NVIM_SYMDEPS_SYNC=68421f
NVIM_SYMDEPS_WARN=d4b483
NVIM_SYMDEPS_ALARM=b0603a
NVIM_SYMDEPS_OK=7aab88

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=1f242b
# Spicetify uses deeper darks
BG_SPICETIFY=1a0d1a
# Vencord secondary-alt
BG_VENCORD_ALT=241424
# Spicetify card hover
CARD_HOVER=3d2a3d
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=2a2018

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
