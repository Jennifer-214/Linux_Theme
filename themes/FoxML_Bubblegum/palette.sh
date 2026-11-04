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
GTK_ICON_THEME=Papirus-Dark
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
CURSOR_RECOLOR=none
PAPIRUS_FOLDER_COLOR=cat-mocha-peach
PAPIRUS_FOLDER_RECOLOR=none
HYPR_BORDER_SIZE=0
HYPR_BORDER_INACTIVE=3c2a4466
HYPR_SHADOW_ALPHA_INACTIVE=0.40
HYPR_DIM_STRENGTH=0.15
HYPR_WS_ANIM=slide
KITTY_ITALIC_FONT=auto
KITTY_TAB_BAR_STYLE=powerline
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
KITTY_POINTER_SHAPE=beam
ZATHURA_HIGHLIGHT="rgba(255,95,162,0.25)"
ZATHURA_HIGHLIGHT_ACTIVE="rgba(199,125,255,0.40)"
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

# ─── Bar · terminal quiet layer (waybar states · logo · kitty ANSI · tmux footer) ───
WAYBAR_LOGO=🦊
WAYBAR_WS_FORMAT='{name} {windows}'
WAYBAR_WARN=e6c07d
WAYBAR_CRIT=d93b54
WAYBAR_UPD_LOW=5fbf8f
WAYBAR_UPD_MID=e6c07d
WAYBAR_UPD_HIGH=d93b54
WAYBAR_PPD_BALANCED=9ab4ff
WAYBAR_PPD_SAVER=7ad4a5
SENTRY_CRIT=b05555
SENTRY_WARN=c4b48a
SENTRY_OK=7aab88
SENTRY_DIM=8a8a8a
KITTY_OPACITY=0.6
ANSI_WHITE=f2dce8
ANSI_BLUE=7d9aff
ANSI_BLUE_BRIGHT=9ab4ff
TMUX_FOOTER_ACTIVE=ff5fa2
TMUX_FOOTER_INACTIVE=240
TMUX_MARK_ACTIVE=◆
TMUX_MARK_INACTIVE=◇
TMUX_SEP=•
TMUX_FOOTER_HIGHLIGHT=fox-tmux-hl-off

WELCOME_LAYOUT=banner
LITTLE_DETAILS=fox-little-details-off

# ─── Cohesive surfaces (lock screen · mako · rofi · btop · lazygit · fzf · nvim floats) ───
HYPRLOCK_VIBRANCY=0.20
HYPRLOCK_BRIGHTNESS=0.45
HYPRLOCK_CONTRAST=1.10
HYPRLOCK_BRAND_Y=200
HYPRLOCK_DOTS_Y=164
HYPRLOCK_CLOCK_TEXT='$TIME'
HYPRLOCK_CLOCK_COLOR=f2dce866
HYPRLOCK_CLOCK_FONT="MonaspiceKr Nerd Font"
HYPRLOCK_DIM_COLOR=f2dce842
HYPRLOCK_INPUT_BORDER=ff5fa259
HYPRLOCK_DOTS_STYLE='dots_rounding = -1'
HYPRLOCK_FAIL=d93b54
HYPRLOCK_CAPS=e6c07d
HYPRLOCK_DATE_TEXT='cmd[update:3600000] date +"%A · %B %-d"'
HYPRLOCK_NOTE='<i>see you soon ♡</i>'
HYPRLOCK_NOTE_Y=9999
HYPRLOCK_CAT_Y=9999
MAKO_BORDER=ffb3d9
MAKO_CRIT_BORDER=d93b54
MAKO_AGENT_BORDER=ff5fa2
MAKO_MEDIA_BORDER=ff9ecd
MAKO_OSD_APP=fox-osd-off
ROFI_RADIUS=18
ROFI_INPUT_RADIUS=0
ROFI_ITEM_RADIUS=12
ROFI_BORDER=ff5fa2
ROFI_SELECTED=ff5fa2
ROFI_SELECTED_ALPHA=0.25
BTOP_SELECTED_BG=2b1826
BTOP_HI_FG=ff5fa2
BTOP_SELECTED_FG=f2dce8
BTOP_PROC_MISC=ff9ecd
BTOP_LINE=3c2a44
BTOP_COOL=5fbf8f
BTOP_WARM=e6c07d
BTOP_HOT=d93b54
BTOP_UPLOAD_END=7d9aff
LAZYGIT_INACTIVE_BORDER=3c2a44
LAZYGIT_UNSTAGED=d93b54
FZF_BORDER=ff5fa2
FZF_SESH_SELECTED=2b1826
NVIM_LIST_SEL=1d0f1a
NVIM_MENU_SEL=3c2a44
YAZI_HOVER_FG=150a12
YAZI_HOVER_BG=ff5fa2
NVIM_FLOAT_BG=150a12
NVIM_FLOAT_BORDER=ff5fa2

# ─── Greeter (regreet) ───
REGREET_PREFER_DARK=true
REGREET_EXTRA_SCOPE='window.foxml-off'
REGREET_LINE=ffb3d9
REGREET_LINE_FOCUS=ff5fa2
REGREET_GREETING="F O X M L"
REGREET_CLOCK_FORMAT="%A · %I:%M %p"

# ─── Firefox (chrome + new tab / settings / web selection) ───
FF_EXTRA_SCOPE=':not(*)'
FF_FRAME=ff5fa2
FF_FRAME_W=2px
FF_RADIUS=0
FF_RADIUS_SM=0
FF_RADIUS_LG=10px
FF_CONTENT_RADIUS=0px
FF_SQUARE_SELECTOR='*'
FF_FOCUS_RING="0 0 8px rgba(255,179,217,0.45)"
FF_URL_ROW="rgba(255,179,217,0.25)"
FF_MENU_ROW="rgba(255,95,162,0.25)"
FF_AC_ROW="var(--fox-bg-alt)"
FF_TREE_SEL_BG="var(--fox-peach)"
FF_TREE_SEL_FG="var(--fox-bg)"
FF_BUTTON_BG="var(--fox-peach)"
FF_BUTTON_FG="var(--fox-bg)"
FF_CARD_HOVER="0 0 8px rgba(255,95,162,0.3)"
FF_SELECTION_BG="rgba(255,95,162,0.35)"
FF_SELECTION_FG=150a12

# ─── Errors · warnings · syntax roles · Thunar · one sheet opacity ───
NVIM_WARN=ffc2dd
NVIM_WARN_CURL=true
NVIM_WARN_DASH=false
ANSI_ERROR_SGR='38;5;167'
ZSH_COMMAND=7ad4a5
BAT_STRING=5fbf8f
BAT_MEMBER=5fbf8f
BAT_KEY=5fbf8f
BAT_COMMENT=8a7590
CURSOR_STRING=5fbf8f
CURSOR_COMMENT=8d7686
OPENCODE_SYN_KEYWORD=ff5fa2
OPENCODE_SYN_STRING=7ad4a5
OPENCODE_SYN_NUMBER=d9536f
OPENCODE_SYN_COMMENT=8a7590
FZF_BORDER_STYLE=sharp
GTK_SEL_BG="rgba(255,95,162,0.25)"
GTK_LABEL_SHADOW="0 1px 3px rgba(0,0,0,0.85)"
GTK_ICON_HOVER="rgba(217,83,111,0.15)"
GTK_ICON_SEL="rgba(217,83,111,0.35)"
GTK_ICON_SEL_BORDER="1px solid rgba(217,83,111,0.6)"
GTK_RUBBER_BG="rgba(255,194,221,0.20)"
GTK_RUBBER_BORDER="2px solid rgba(255,194,221,0.65)"
GTK_PANEL_ALPHA=0.95
GTK_WINDOW_ALPHA=0.65
WAYBAR_BUBBLE_ALPHA=0.7
MAKO_FORMAT='<b>%s</b>\n%b'

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "fg" "pink" "orchid" "candy" "plum")

# Small native control accents
GTK_DETAIL_SCOPE=.foxml-paper-controls-off

# Graph strokes and the optional paper notification stamp
BTOP_GRAPH_START=ff5fa2
BTOP_GRAPH_MID=c77dff
BTOP_GRAPH_END=ff9ecd
MAKO_STAMP_SUMMARIES='^foxml-paper-stamp-disabled$'

# Normal-window shadow color and direction
HYPR_SHADOW_RGB=000000
HYPR_SHADOW_OFFSET_X=0
HYPR_SHADOW_OFFSET_Y=0

# Reading and notebook labels
YAZI_TAB_ACTIVE_FG=150a12
YAZI_TAB_ACTIVE_BG=ff5fa2
NVIM_MEMBER_BOLD=false
DELTA_LABEL_STYLE=foxml-standard
DRAWER_SCROLL_GUTTER=0

# Search result ink and match decoration (shared shell / tmux pickers).
FZF_MATCH_FG=ff5fa2
FZF_MATCH_SELECTED_FG=ff5fa2
FZF_MATCH_ATTR=bold
FZF_META_FG=ff5fa2
FF_FIND_BG=ff5fa2
FF_FIND_FG=150a12

# Keep Paper compositor and application cursor shapes on the same XCursor backend.
HYPR_CURSOR_ENABLED=true

# File-listing glyphs; filenames and metadata retain their own pencil weights.
EZA_ICON_FG=ff5fa2

# File-operation marks and count badges.
YAZI_MARK_COPIED=5fbf8f
YAZI_MARK_MARKED=ff9ecd
YAZI_MARK_SELECTED=c77dff
YAZI_COPIED_FG=150a12
YAZI_COPIED_BG=5fbf8f
YAZI_SELECTED_FG=150a12
YAZI_SELECTED_BG=c77dff

# A paper footer: small blush mode labels, quiet metadata.
YAZI_MODE_FG=150a12
YAZI_MODE_ALT_FG=150a12
YAZI_MODE_NORMAL_BG=ff5fa2
YAZI_MODE_NORMAL_ALT_BG=c77dff
YAZI_MODE_SELECT_BG=c77dff
YAZI_MODE_SELECT_ALT_BG=ff9ecd
YAZI_MODE_UNSET_BG=ff9ecd
YAZI_MODE_UNSET_ALT_BG=3c2a44

# Native permission dialogs use the same selection fill and readable links.
HYPRTOOLKIT_ACCENT=ffb3d9
HYPRTOOLKIT_LINK=ffb3d9

# Personal-folder paper and tab, shared with the icon family.
ICON_FOLDER_FILL=52254a
ICON_FOLDER_TAB=ff5fa2

# Tooltip root selector; native GTK tooltip windows have no window ancestor.
GTK_TOOLTIP_SCOPE=":not(*)"
