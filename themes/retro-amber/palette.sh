#!/bin/bash
# retro-amber — an amber phosphor terminal: one colour in brightness steps on a warm near-black.
# All hex values are WITHOUT the # prefix
#
# Steps used throughout:  ffd466 brightest · ffc640 bright · ffb000 amber (P3) · e0a020 soft · c88a00 mid ·
#                         9c6c14 dim · 5c3d00 faint · 3a2700 deep · 1c1408 highlight · 0c0a06 background
# Second hues, kept faint: rust d0541c for errors and deletions, straw d4c46a for additions.

# ─── Theme metadata ───
THEME_TYPE=dark
NVIM_STYLE=storm
NVIM_BG=dark
KITTY_BG_OPACITY=0.6
POPUP_BG_OPACITY=0.96
MAKO_ICON_THEME=Papirus-Dark   # also the GTK icon theme
GTK_ICON_THEME=Papirus-Dark
VSCODE_UI_THEME=vs-dark
FONT_FAMILY="BigBlueTerm437 Nerd Font Mono"
# WARNING: SHOW_WELCOME is also the project's literal-true alias (see Classic's palette). Leave as true.
SHOW_WELCOME=true
SHOW_BANNER=true
WALLPAPER=retro_amber.png

# ─── Aesthetic controls ───
ROUNDING=0
BLUR_SIZE=2
BLUR_PASSES=1
GAP_IN=4
GAP_OUT=8
BORDER_SIZE=1
SHADOW_RANGE=2
SHADOW_ALPHA=0.85

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
GTK_PREFER_DARK=1
CURSOR_THEME=foxml-amber-cursors
CURSOR_RECOLOR=catppuccin-mocha-peach-cursors:fab387:1e1e2e:ffb000:0c0a06
PAPIRUS_FOLDER_COLOR=foxml-amber
PAPIRUS_FOLDER_RECOLOR=cat-mocha-peach:FAB387=ffb000,E69F73=c88a00,CDD6F4=3a2700
HYPR_BORDER_SIZE=1
HYPR_BORDER_INACTIVE=3a270099
HYPR_BORDER_ACTIVE=ffb000ff
HYPR_BORDER_ACTIVE_END=ffb000ff
HYPR_GROUPBAR_ACTIVE=ffb000bb
HYPR_DIM_INACTIVE=true
HYPR_SHADOW_ALPHA_INACTIVE=0.6
HYPR_DIM_STRENGTH=0.18
HYPR_INACTIVE_OPACITY=1.0
HYPR_WS_ANIM=fade
HYPR_WIN_CURVE=foxSnap
KITTY_ITALIC_FONT=auto
KITTY_TAB_BAR_STYLE=separator
KITTY_DIM_OPACITY=0.55
# kitty's own bloom + crt shaders (shared/kitty/crt-glow.pipeline). Off: KITTY_SHADER_LINE='env DESK_KITTY_SHADERS=off'
KITTY_SHADER_LINE='custom_shaders crt-glow'
# globinclude: silent while desk-crt has never run (a plain include logs a missing file at every start).
KITTY_SHADER_STATE='globinclude desk-crt.conf'
WELCOME_INK1=214
WELCOME_INK2=220
WELCOME_INK3=178
WELCOME_INK4=172
WELCOME_INK5=136
NVIM_BANNER1=ffb000
NVIM_BANNER2=ffc640
NVIM_BANNER3=e0a020
NVIM_BANNER4=c88a00

# ─── Core palette ───
BG=0c0a06
BG_DARK=070604
BG_ALT=16110a
BG_HIGHLIGHT=1c1408
SELECTION=4a3200

FG=ffb000
FG_PASTEL=e0a020
FG_DIM=9c6c14
COMMENT=9c6c14

PRIMARY=ffb000
SECONDARY=c88a00
ACCENT=e0a020
SURFACE=3a2700
BLUSH=ffc640
GOLD=ffd466

# ─── ANSI colors ───
# One colour in steps: blue, cyan and magenta become amber shades; red and green keep a faint rust and straw.
RED=f07838
RED_BRIGHT=ff8a48
GREEN=f0e0a0
GREEN_BRIGHT=f8ecc0
YELLOW=ffc640
YELLOW_BRIGHT=ffd466
BLUE=c88a00
BLUE_BRIGHT=e0a020
CYAN=b37a00
CYAN_BRIGHT=d99a1a
WHITE=ffcc33
# kitty color8 — "bright black", the dim-text slot most CLIs use
ANSI_BRIGHT_BLACK=9c6c14

# ─── Semantic aliases ───
OK=f0e0a0
WARN=ffc640

# ─── ZSH command highlight color ───
ZSH_CMD=ffc640

# ─── Vencord deep background ───
BG_VENCORD_DEEP=070604

# ─── Nvim extra colors ───
NVIM_BG_HL=1c1408
NVIM_SEL=6a4800
WARM=e0a020
SAND=c88a00
WHEAT=ffc640
CLAY=d0541c

# ─── Nvim diff colors ───
DIFF_ADD=4a3608
DIFF_CHANGE=33240a
DIFF_DELETE=33240a
DIFF_TEXT=3a2a08
TREESITTER_CTX=1c1408

# ─── Nvim rainbow delimiters / indent guides ───
NVIM_RAINBOW1=ffb000
NVIM_RAINBOW2=e0a020
NVIM_RAINBOW3=c88a00
NVIM_RAINBOW4=ffc640
NVIM_RAINBOW5=b37a00
NVIM_RAINBOW6=e8b84a
NVIM_INDENT1=2a1d06
NVIM_INDENT2=261a06
NVIM_INDENT3=221806
NVIM_INDENT4=2a1f08
NVIM_INDENT5=241a06
NVIM_INDENT6=2e1c08
NVIM_IBL_SCOPE=c88a00

# ─── Nvim state backgrounds (diagnostics / git / conflicts / word highlight) ───
NVIM_DIAG_ERR_BG=2a1008
NVIM_DIAG_WARN_BG=2a1f06
NVIM_GIT_MOD=e0a020
NVIM_GIT_DEL=f07838
NVIM_CONFLICT_CUR=2a1008
NVIM_CONFLICT_CUR_LABEL=3a160a
NVIM_CONFLICT_INC=1c1a08
NVIM_CONFLICT_INC_LABEL=2a2610
NVIM_ILLUMINATE=3a2700

# ─── Nvim definition / keyword weight ───
# Meaning by brightness and weight: keywords and definitions bold and bright, comments dim.
NVIM_FN_DEF=ffc640
NVIM_FN_DEF_BOLD=true
NVIM_KW_BOLD=true
NVIM_READONLY_BOLD=false
# Tag-comment markers in // comments ([KEY], values, nested [CHIPS], [END_*] closers).
NVIM_TAG_KEY=c88a00
NVIM_TAG_VALUE=9c6c14
NVIM_TAG_CHIP=b37a00
NVIM_TAG_END=8a5c00

# ─── Nvim syntax roles ───
NVIM_SYN_VAR=ffb000
NVIM_SYN_MEMBER=ffb000
NVIM_SYN_PARAM=e8b84a
NVIM_SYN_TYPE=ffe9a8
NVIM_SYN_STRING=d8a840
NVIM_SYN_NUMBER=d8a840
NVIM_SYN_CALL=ffe9a8
NVIM_SYN_OPERATOR=b37a00
NVIM_SYN_RETURN=ffd466
NVIM_SYN_COMMENT=9c6c14
NVIM_SYN_HEADER=c88a00
NVIM_SECTION_HEADERS=false
NVIM_FAINT_FG=5c3d00
NVIM_RED_PEN=f07838
NVIM_SEARCH_FG=0c0a06
NVIM_SEARCH_BG=ffb000
NVIM_CURSEARCH_FG=0c0a06
NVIM_CURSEARCH_BG=ffe9a8
NVIM_INCSEARCH_FG=0c0a06
NVIM_INCSEARCH_BG=e0a020
KITTY_SELECTION_BG=4a3200
TMUX_MODE_FG=0c0a06
TMUX_MODE_BG=ffb000
KITTY_CURSOR=ffcc00
KITTY_CURSOR_TEXT=0c0a06
KITTY_POINTER_SHAPE=beam
ZATHURA_HIGHLIGHT="rgba(255,176,0,0.25)"
ZATHURA_HIGHLIGHT_ACTIVE="rgba(255,198,64,0.40)"
WAYBAR_WS_ACTIVE=ffb000
PI_BORDER=5c3d00
PI_MUTED=c88a00
PI_ERROR=d0541c
PI_MD_CODE=e0a020
PI_SYN_KEYWORD=ffc640
PI_SYN_FUNCTION=ffd466
PI_SYN_STRING=e6c36a
PI_SYN_NUMBER=e6c36a
PI_SYN_OPERATOR=b37a00

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=c88a00
NVIM_SYMDEPS_SYNC=5c3d00
NVIM_SYMDEPS_WARN=ffc640
NVIM_SYMDEPS_ALARM=f07838
NVIM_SYMDEPS_OK=d4c46a

# ─── App-specific overrides ───
BG_DUNST=0c0a06
BG_SPICETIFY=070604
BG_VENCORD_ALT=16110a
CARD_HOVER=2a1d06
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=16110a

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=ffc640
FZF_ACCENT2=e0a020

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=6b4800

# ─── ANSI 256-color codes ───
# The 256 palette's ambers: 214 #ffaf00 · 220 #ffd700 · 178 #d7af00 · 172 #d78700 · 136 #af8700 · 94 #875f00 ·
# 166 #d75f00 (rust) · 186 #d7d787 (straw)
ANSI_ACCENT1=214
ANSI_ACCENT2=220
ANSI_ACCENT3=178
ANSI_ACCENT4=172
ANSI_ACCENT5=136
ANSI_TEXT=214
ANSI_MUTED=94
ANSI_ERROR=166
ANSI_OK=186
ANSI_STANDOUT_BG=232
ANSI_PROMPT=214
ANSI_PROMPT2=136
ANSI_LOAD=178

# ─── Gradient colors ───
GRAD1=220
GRAD2=214
GRAD3=178
GRAD4=172
GRAD5=136

# ─── Tmux colors ───
TMUX_ACTIVE=colour214
TMUX_INACTIVE=colour94
# tmux pane dividers: drawn in the background, so splits show only their footers.
TMUX_BORDER=0c0a06
TMUX_BORDER_ACTIVE=0c0a06
TMUX_BORDER_LINES=single
TMUX_INACTIVE_FG=9c6c14
TMUX_ACTIVE_FG=ffb000
TMUX_ACTIVE_BG=1c1408

# ─── Bar · terminal quiet layer (waybar states · logo · kitty ANSI · tmux footer) ───
# Glyphs are ones Big Blue Term has (it lacks ◆ ◇ ● ⎇ ✎ ✿ …).
WAYBAR_LOGO='■'
WAYBAR_WS_FORMAT='{name} {windows}'
WAYBAR_ICON_CPU='󰻠'
WAYBAR_ICON_GPU='󰢮'
WAYBAR_ICON_MEM='󰍛'
WAYBAR_ICON_DISK='󰋊'
WAYBAR_ICON_NET_DOWN='↓'
WAYBAR_ICON_NET_UP='↑'
WAYBAR_WIN_DEFAULT='󰘔'
WAYBAR_WIN_BROWSER='󰈹'
WAYBAR_WIN_TERMINAL=''
WAYBAR_WIN_CHAT='󰙯'
WAYBAR_WIN_GAMES='󰓓'
WAYBAR_WIN_FILES=''
WAYBAR_WIN_EDITOR='󰨞'
WAYBAR_WIN_MONITOR='󰑮'
WAYBAR_WARN=ffc640
WAYBAR_CRIT=d0541c
WAYBAR_UPD_LOW=c88a00
WAYBAR_UPD_MID=ffc640
WAYBAR_UPD_HIGH=d0541c
WAYBAR_PPD_BALANCED=c88a00
WAYBAR_PPD_SAVER=d4c46a
SENTRY_CRIT=d0541c
SENTRY_WARN=ffc640
SENTRY_OK=d4c46a
SENTRY_DIM=9c6c14
# crt needs an opaque terminal.
KITTY_OPACITY=1.0
ANSI_WHITE=e0a020
ANSI_BLUE=c88a00
ANSI_BLUE_BRIGHT=e0a020
TMUX_FOOTER_ACTIVE=ffb000
TMUX_FOOTER_INACTIVE=94
TMUX_MARK_ACTIVE=■
TMUX_MARK_INACTIVE=·
TMUX_SEP=•
TMUX_FOOTER_HIGHLIGHT=fox-tmux-hl-on

WELCOME_LAYOUT=dos
LITTLE_DETAILS=fox-little-details-off
# Quickshell drawing style: paper (pencil, sprigs, hearts) | retro (blocks, cursors) | plain.
DESK_STYLE=retro

# ─── Cohesive surfaces (lock screen · mako · rofi · btop · lazygit · fzf · nvim floats) ───
HYPRLOCK_BLUR_SIZE=4
HYPRLOCK_BLUR_PASSES=2
HYPRLOCK_VIBRANCY=0.0
HYPRLOCK_BRIGHTNESS=0.55
HYPRLOCK_CONTRAST=1.0
HYPRLOCK_BRAND_Y=200
HYPRLOCK_DOTS_Y=9999
HYPRLOCK_CLOCK_TEXT='$TIME'
HYPRLOCK_CLOCK_COLOR=ffb000cc
HYPRLOCK_CLOCK_FONT="BigBlueTerm437 Nerd Font Mono"
HYPRLOCK_DIM_COLOR=ffb00066
HYPRLOCK_INPUT_BORDER=ffb00099
HYPRLOCK_DOTS_STYLE='dots_text_format = *'
HYPRLOCK_FAIL=d0541c
HYPRLOCK_FAIL_TEXT='ACCESS DENIED  $FAIL'
HYPRLOCK_CAPS=ffc640
HYPRLOCK_DATE_TEXT='cmd[update:3600000] date +"%a %d %b %Y"'
HYPRLOCK_NOTE='READY.'
HYPRLOCK_NOTE_Y=9999
HYPRLOCK_CAT_Y=9999
# Lock screen: the boot-screen summary's height (9999 = off screen), the password field's hint and corners.
HYPRLOCK_BOOT_Y=-60
HYPRLOCK_PLACEHOLDER='PASSWORD:'
HYPRLOCK_INPUT_ROUNDING=0
MAKO_BORDER=ffb000
MAKO_CRIT_BORDER=d0541c
MAKO_AGENT_BORDER=ffc640
MAKO_MEDIA_BORDER=c88a00
MAKO_OSD_APP=fox-osd-off
ROFI_RADIUS=0
ROFI_INPUT_RADIUS=0
ROFI_ITEM_RADIUS=0
ROFI_BORDER=ffb000
ROFI_SELECTED=ffb000
ROFI_SELECTED_ALPHA=0.30
BTOP_SELECTED_BG=3a2700
BTOP_HI_FG=ffd466
BTOP_SELECTED_FG=ffb000
BTOP_PROC_MISC=c88a00
BTOP_LINE=5c3d00
BTOP_COOL=c88a00
BTOP_WARM=ffb000
BTOP_HOT=ffd466
BTOP_UPLOAD_END=e0a020
LAZYGIT_INACTIVE_BORDER=5c3d00
LAZYGIT_UNSTAGED=d0541c
FZF_BORDER=ffb000
FZF_SESH_SELECTED=4a3200
NVIM_LIST_SEL=1c1408
NVIM_MENU_SEL=6a4800
YAZI_HOVER_FG=0c0a06
YAZI_HOVER_BG=ffb000
NVIM_FLOAT_BG=0c0a06
NVIM_FLOAT_BORDER=ffb000

# ─── Greeter (regreet) ───
REGREET_PREFER_DARK=true
REGREET_EXTRA_SCOPE='window.foxml-off'
REGREET_LINE=c88a00
REGREET_LINE_FOCUS=ffb000
REGREET_GREETING="READY."
REGREET_CLOCK_FORMAT="%a %d %b  %H:%M"

# ─── Firefox (chrome + new tab / settings / web selection) ───
FF_EXTRA_SCOPE=':not(*)'
# retro-amber's Firefox shape (a DOS menu-bar tab strip, the terminal font): ':root' on, ':not(*)' off.
FF_RETRO_SCOPE=':root'
FF_FRAME=ffb000
FF_FRAME_W=1px
FF_RADIUS=0
FF_RADIUS_SM=0
FF_RADIUS_LG=0
FF_CONTENT_RADIUS=0px
FF_SQUARE_SELECTOR='*'
FF_FOCUS_RING="0 0 6px rgba(255,176,0,0.45)"
FF_URL_ROW="rgba(255,176,0,0.22)"
FF_MENU_ROW="rgba(255,176,0,0.22)"
FF_AC_ROW="var(--fox-bg-alt)"
FF_TREE_SEL_BG="var(--fox-peach)"
FF_TREE_SEL_FG="var(--fox-bg)"
FF_BUTTON_BG="var(--fox-peach)"
FF_BUTTON_FG="var(--fox-bg)"
FF_CARD_HOVER="0 0 8px rgba(255,176,0,0.30)"
FF_SELECTION_BG="rgba(255,176,0,0.35)"
FF_SELECTION_FG=0c0a06

# ─── Errors · warnings · syntax roles · Thunar · one sheet opacity ───
NVIM_WARN=ffc640
NVIM_WARN_CURL=true
NVIM_WARN_DASH=false
ANSI_ERROR_SGR='38;5;166'
ZSH_COMMAND=ffc640
BAT_STRING=e6c36a
BAT_MEMBER=e0a020
BAT_KEY=ffc640
BAT_COMMENT=9c6c14
CURSOR_STRING=e6c36a
CURSOR_COMMENT=9c6c14
OPENCODE_SYN_KEYWORD=ffc640
OPENCODE_SYN_STRING=e6c36a
OPENCODE_SYN_NUMBER=e6c36a
OPENCODE_SYN_COMMENT=9c6c14
FZF_BORDER_STYLE=sharp
GTK_SEL_BG="rgba(255,176,0,0.25)"
GTK_LABEL_SHADOW="0 0 4px rgba(255,176,0,0.35)"
GTK_ICON_HOVER="rgba(255,176,0,0.12)"
GTK_ICON_SEL="rgba(255,176,0,0.30)"
GTK_ICON_SEL_BORDER="1px solid rgba(255,176,0,0.6)"
GTK_RUBBER_BG="rgba(255,176,0,0.15)"
GTK_RUBBER_BORDER="1px solid rgba(255,176,0,0.65)"
GTK_PANEL_ALPHA=0.98
GTK_WINDOW_ALPHA=0.96
ZATHURA_BG_ALPHA=1.0
WAYBAR_BUBBLE_ALPHA=0.9
# A DOS dialog: the title in capitals on a solid amber bar (inverse video), the message below. Quoted, so the
# '#' colours stay part of the value.
MAKO_FORMAT='<span background="#ffb000" foreground="#0c0a06" text_transform="uppercase"><b> %s </b></span>\n%b'

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("bg" "amber" "bright" "soft" "dim" "deep")

# Small native control accents
GTK_DETAIL_SCOPE=.foxml-paper-controls-off

# Graph strokes and the optional paper notification stamp
BTOP_GRAPH_START=c88a00
BTOP_GRAPH_MID=ffb000
BTOP_GRAPH_END=ffd466
MAKO_STAMP_SUMMARIES='^foxml-paper-stamp-disabled$'

# Normal-window shadow color and direction
HYPR_SHADOW_RGB=000000
HYPR_SHADOW_OFFSET_X=8
HYPR_SHADOW_OFFSET_Y=8

# Reading and notebook labels
YAZI_TAB_ACTIVE_FG=0c0a06
YAZI_TAB_ACTIVE_BG=ffb000
NVIM_MEMBER_BOLD=false
DELTA_LABEL_STYLE=foxml-standard
DRAWER_SCROLL_GUTTER=0

# Search result ink and match decoration (shared shell / tmux pickers).
FZF_MATCH_FG=ffd466
FZF_MATCH_SELECTED_FG=ffd466
FZF_MATCH_ATTR=bold
FZF_META_FG=c88a00
FF_FIND_BG=ffb000
FF_FIND_FG=0c0a06

HYPR_CURSOR_ENABLED=true

# File-listing glyphs.
EZA_ICON_FG=ffb000

# File-operation marks and count badges.
YAZI_MARK_COPIED=d4c46a
YAZI_MARK_MARKED=c88a00
YAZI_MARK_SELECTED=ffc640
YAZI_COPIED_FG=0c0a06
YAZI_COPIED_BG=d4c46a
YAZI_SELECTED_FG=0c0a06
YAZI_SELECTED_BG=ffc640

# Footer mode labels: inverse amber.
YAZI_MODE_FG=0c0a06
YAZI_MODE_ALT_FG=0c0a06
YAZI_MODE_NORMAL_BG=ffb000
YAZI_MODE_NORMAL_ALT_BG=c88a00
YAZI_MODE_SELECT_BG=ffc640
YAZI_MODE_SELECT_ALT_BG=c88a00
YAZI_MODE_UNSET_BG=c88a00
YAZI_MODE_UNSET_ALT_BG=5c3d00

# Native permission dialogs use the same selection fill and readable links.
HYPRTOOLKIT_ACCENT=ffb000
HYPRTOOLKIT_LINK=ffc640

# Personal-folder fill and tab, shared with the icon family.
ICON_FOLDER_FILL=3a2700
ICON_FOLDER_TAB=ffb000

# Tooltip root selector; native GTK tooltip windows have no window ancestor.
GTK_TOOLTIP_SCOPE=":not(*)"
TOOLTIP_BG_OPACITY=1.0

# Notifications: square boxes, text left.
MAKO_PADDING=12
MAKO_MARGIN=12
MAKO_OUTER_MARGIN=0
MAKO_TEXT_ALIGN=left
MAKO_ICON_LOCATION=left
MAKO_PAPER_SHAPE=none

# Fastfetch machine card: plain uppercase labels.
FASTFETCH_LOGO='"type": "small"'
FASTFETCH_KEY_INK=136
FASTFETCH_OUTPUT_INK=214
FASTFETCH_KEY_OS="OS"
FASTFETCH_KEY_KERNEL="KERNEL"
FASTFETCH_KEY_WM="DESK"
FASTFETCH_KEY_TERMINAL="TERM"
FASTFETCH_KEY_SHELL="SHELL"
FASTFETCH_KEY_UPTIME="UPTIME"
FASTFETCH_KEY_BATTERY="BATTERY"
FASTFETCH_KEY_CPU="CPU"
FASTFETCH_KEY_GPU="GPU"
FASTFETCH_KEY_MEMORY="MEMORY"
FASTFETCH_KEY_DISK="DISK"
FASTFETCH_KEY_WIDTH=10

# Claude Code (custom:foxml): amber text; diffs keep a faint straw and rust.
CLAUDE_USER_BG=3a2700
CLAUDE_USER_BG_HOVER=0c0a06
CLAUDE_DIFF_ADD=3a3a10
CLAUDE_DIFF_ADD_DIM=1e1c0a
CLAUDE_DIFF_ADD_WORD=4a4416
CLAUDE_DIFF_DEL=4a1a08
CLAUDE_DIFF_DEL_DIM=240e06
CLAUDE_DIFF_DEL_WORD=5c220c
# Claude status line: the context meter's filled and empty marks.
CLAUDE_CTX_FULL='█'
CLAUDE_CTX_EMPTY='░'

# Commit garden: the surface, then four amber steps; each at least 1.36:1 from the last.
GARDEN_0=2a1d06
GARDEN_1=5c3d00
GARDEN_2=8a5c00
GARDEN_3=c88a00
GARDEN_4=ffb000

# nvim cursor line (kept apart from Visual), zathura page recolor, desktop accent (libadwaita name).
NVIM_CURSORLINE=261b08
ZATHURA_RECOLOR=true
GTK_ACCENT_COLOR=orange
# delta changed-word backgrounds: straw and rust tints under amber text.
DELTA_DEL_WORD=4a1e0c
DELTA_ADD_WORD=3a3410
# GTK entry fill and infobar border alpha.
GTK_FIELD_ALPHA=0.9

# ─── Claude Code over dark-ansi · notebook alarms · pi thinking steps ───
# Claude's accent (claude, clawd_body, briefLabelClaude, fastMode), the selection, the sidebar and memory panels and the
# empty part of the rate-limit bar. A value is a colour Claude Code reads: ansi:<name> keeps dark-ansi's own choice.
# Retro: amber for Claude, not the rust that marks errors; the amber selection; panels as dark as the page.
CLAUDE_ACCENT='rgb(255,176,0)'
CLAUDE_SELECTION_BG='rgb(74,50,0)'
CLAUDE_PANEL_BG='rgb(28,20,8)'
CLAUDE_RATE_EMPTY='rgb(92,61,0)'
# Alarms: failed tests, context from 80%, credit under 20% (the notebook's berry, the status line's BERRY).
# Rust: GARDEN_4 and WAYBAR_WS_ACTIVE are the text amber here, so an alarm would not stand out.
CLAUDE_ALERT=f07838
# pi's thinking levels, rising: medium and xhigh (off/minimal/low/high are border/comment/muted/primary).
PI_THINKING_MEDIUM=e0a020
PI_THINKING_XHIGH=ffd466

# Diff pager, kitty tabs and cursor, notification icons, fingerprint wording, window shadow edge.
DELTA_MINUS_STYLE='"#9c6c14" strike'
DELTA_MINUS_EMPH_STYLE='"#0c0a06" "#c88a00"'
DELTA_PLUS_STYLE='syntax bold "#4a3608"'
DELTA_PLUS_EMPH_STYLE='"#0c0a06" "#ffb000" bold'
KITTY_CURSOR_BLINK=0.53
KITTY_TAB_TITLE='"[{index}] {title}"'
MAKO_ICONS=0
HYPRLOCK_FP_READY='PASSWORD OR FINGER:'
HYPRLOCK_FP_PRESENT='READING...'
HYPR_SHADOW_SHARP=true
