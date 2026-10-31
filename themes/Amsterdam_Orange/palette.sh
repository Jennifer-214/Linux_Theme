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

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
GTK_PREFER_DARK=1
CURSOR_THEME=catppuccin-mocha-peach-cursors
PAPIRUS_FOLDER_COLOR=cat-mocha-peach
HYPR_BORDER_SIZE=0
HYPR_BORDER_INACTIVE=20345a66
HYPR_SHADOW_ALPHA_INACTIVE=0.40
HYPR_DIM_STRENGTH=0.15
KITTY_ITALIC_FONT=auto
KITTY_DIM_OPACITY=0.4
WELCOME_INK1=202
WELCOME_INK2=215
WELCOME_INK3=68
WELCOME_INK4=110
WELCOME_INK5=209
NVIM_BANNER1=ff5c2e
NVIM_BANNER2=ffb060
NVIM_BANNER3=ff6b4a
NVIM_BANNER4=ff8a4c

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
# kitty color8 — "bright black", the dim-text slot most CLIs use
ANSI_BRIGHT_BLACK=20345a

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

# ─── Nvim rainbow delimiters / indent guides ───
NVIM_RAINBOW1=ff3300
NVIM_RAINBOW2=5b86c9
NVIM_RAINBOW3=3fa66a
NVIM_RAINBOW4=e0a33a
NVIM_RAINBOW5=3fb0c2
NVIM_RAINBOW6=e5484d
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
NVIM_FN_DEF=ff3300
NVIM_FN_DEF_BOLD=false
NVIM_KW_BOLD=true
NVIM_READONLY_BOLD=true

# ─── Nvim syntax roles ───
NVIM_SYN_VAR=e8edf5
NVIM_SYN_MEMBER=3fa66a
NVIM_SYN_PARAM=ffc04d
NVIM_SYN_TYPE=3fb0c2
NVIM_SYN_STRING=3fa66a
NVIM_SYN_NUMBER=e0a33a
NVIM_SYN_CALL=ff3300
NVIM_SYN_OPERATOR=ff8a4c
NVIM_SYN_RETURN=ff8a4c
NVIM_SYN_COMMENT=5a6a85
NVIM_SYN_HEADER=5a6a85
NVIM_SECTION_HEADERS=false
NVIM_FAINT_FG=20345a
NVIM_RED_PEN=ff5c2e
NVIM_SEARCH_FG=0e1729
NVIM_SEARCH_BG=ff3300
NVIM_CURSEARCH_FG=0e1729
NVIM_CURSEARCH_BG=ff3300
NVIM_INCSEARCH_FG=0e1729
NVIM_INCSEARCH_BG=5b86c9
KITTY_SELECTION_BG=20345a
TMUX_MODE_FG=0e1729
TMUX_MODE_BG=ff3300
KITTY_CURSOR=ff3300
KITTY_CURSOR_TEXT=111111
WAYBAR_WS_ACTIVE=ff6b4a
PI_BORDER=20345a
PI_MUTED=ffb060
PI_ERROR=e5484d
PI_MD_CODE=3fb0c2
PI_SYN_KEYWORD=ff3300
PI_SYN_FUNCTION=e0a33a
PI_SYN_STRING=57c882
PI_SYN_NUMBER=ff5c2e
PI_SYN_OPERATOR=5b86c9

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=b5702f
NVIM_SYMDEPS_SYNC=68421f
NVIM_SYMDEPS_WARN=d4b483
NVIM_SYMDEPS_ALARM=b0603a
NVIM_SYMDEPS_OK=7aab88

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=0e1729
# Spicetify uses deeper darks
BG_SPICETIFY=070c15
# Vencord secondary-alt
BG_VENCORD_ALT=101a30
# Spicetify card hover
CARD_HOVER=20345a
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=2a2018

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
