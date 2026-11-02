#!/bin/bash
# FoxML Paper — graphite pencil on white paper
# Monochrome: hierarchy comes from pencil pressure (4B dark → 2H light),
# not hue. ANSI colors are barely-there colored-pencil tints so git /
# diagnostics / ls keep their meaning without reading as a rainbow.
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=light
NVIM_STYLE=day
NVIM_BG=light
KITTY_BG_OPACITY=0.85
POPUP_BG_OPACITY=0.92
MAKO_ICON_THEME=Papirus-Light   # also the GTK icon theme
VSCODE_UI_THEME=vs-light
FONT_FAMILY="MonaspiceKr Nerd Font"
# WARNING: SHOW_WELCOME is also the project's literal-true alias used in
# ~246 template substitutions (vim opts, yazi bold, Firefox CSS selectors,
# nvim init.lua, etc.). Setting this to false will break far more than
# the welcome message. Leave as true; gate the welcome message via the
# `[[ "{{SHOW_WELCOME}}" == "true" ]]` check in templates/zsh/welcome.zsh.
SHOW_WELCOME=true
SHOW_BANNER=true
WALLPAPER=foxml_paper.jpg

# ─── Aesthetic controls ───
# Light blur so the paper grain still shows through translucent windows.
ROUNDING=6
BLUR_SIZE=2
BLUR_PASSES=1
GAP_IN=5
GAP_OUT=10
BORDER_SIZE=1
SHADOW_RANGE=12
SHADOW_ALPHA=0.06

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
# A drawn hairline separates sheets; inactive windows stay paper, not soot.
GTK_PREFER_DARK=0
# The cursor is the highlighter pink (Catppuccin Mocha pink).
CURSOR_THEME=catppuccin-mocha-pink-cursors
PAPIRUS_FOLDER_COLOR=grey
HYPR_BORDER_SIZE=1
HYPR_BORDER_INACTIVE=9a989488
HYPR_SHADOW_ALPHA_INACTIVE=0.08
HYPR_DIM_STRENGTH=0.05
# Workspace switch: a short vertical slide-fade, like flipping a top-bound notepad.
HYPR_WS_ANIM='slidefadevert 20%'
# Comments (italic) in Monaspace Radon: handwriting beside the typed code.
KITTY_ITALIC_FONT="MonaspiceRn Nerd Font"
KITTY_DIM_OPACITY=0.7
# Name banner (zsh splash + nvim dashboard): one graphite ink, not a grey patchwork
WELCOME_INK1=237
WELCOME_INK2=237
WELCOME_INK3=237
WELCOME_INK4=237
WELCOME_INK5=237
NVIM_BANNER1=3c3c40
NVIM_BANNER2=3c3c40
NVIM_BANNER3=3c3c40
NVIM_BANNER4=3c3c40

# ─── Core palette ───
# BG matches the wallpaper's average tone (f0eee8), a hair lighter so a
# window reads as a sheet laid on the page.
BG=f4f2ed
BG_DARK=e9e7e1
BG_ALT=e2dfd8
BG_HIGHLIGHT=e6e3dc
SELECTION=f1d6de

FG=2b2b2d
FG_PASTEL=48484b
FG_DIM=6e6d70
COMMENT=7c7a76

PRIMARY=3c3c40
SECONDARY=1c1c1e
ACCENT=5e5e63
SURFACE=e6e3dc
BLUSH=55555a
GOLD=6e6a62

# ─── ANSI colors ───
RED=9a5a48
RED_BRIGHT=ae6551
GREEN=5b6b5c
GREEN_BRIGHT=6a7a6a
YELLOW=1c1c1e
YELLOW_BRIGHT=3c3c40
BLUE=55555a
BLUE_BRIGHT=6e6d70
CYAN=5e5e63
CYAN_BRIGHT=7c7a76
WHITE=2b2b2d
# kitty color8 — "bright black"; Claude Code (dark-ansi) uses it as the
# user-message / sidebar background, so on paper it is a pencil-highlight grey
ANSI_BRIGHT_BLACK=d8d5cd

# ─── Semantic aliases ───
OK=5b6b5c
WARN=8a7650

# ─── ZSH command highlight color ───
ZSH_CMD=48484b

# ─── Vencord deep background ───
BG_VENCORD_DEEP=efede7

# ─── Nvim extra colors ───
NVIM_BG_HL=e6e3dc
NVIM_SEL=f1d6de
WARM=6e6c68
SAND=7a7874
WHEAT=8a7a5a
CLAY=9a5a48

# ─── Nvim diff colors ───
DIFF_ADD=e3e9e0
DIFF_CHANGE=e9e7e1
DIFF_DELETE=efe2e0
DIFF_TEXT=dcd9d2
TREESITTER_CTX=e9e7e1

# ─── Nvim rainbow delimiters / indent guides ───
# Pencil pressure, not hue: dark → mid → light, twice over.
NVIM_RAINBOW1=1c1c1e
NVIM_RAINBOW2=5e5e63
NVIM_RAINBOW3=85837f
NVIM_RAINBOW4=3c3c40
NVIM_RAINBOW5=6e6d70
NVIM_RAINBOW6=8e8c88
NVIM_INDENT1=dedad2
NVIM_INDENT2=d6d2ca
NVIM_INDENT3=dedad2
NVIM_INDENT4=d6d2ca
NVIM_INDENT5=dedad2
NVIM_INDENT6=d6d2ca
NVIM_IBL_SCOPE=8e8c88

# ─── Nvim state backgrounds (diagnostics / git / conflicts / word highlight) ───
NVIM_DIAG_ERR_BG=f2e4e2
NVIM_DIAG_WARN_BG=ece9e3
NVIM_GIT_MOD=8a7650
NVIM_GIT_DEL=9a5a58
NVIM_CONFLICT_CUR=f0e0de
NVIM_CONFLICT_CUR_LABEL=e8d2cf
NVIM_CONFLICT_INC=e2eae0
NVIM_CONFLICT_INC_LABEL=d6e2d3
NVIM_ILLUMINATE=e2dfd8

# ─── Nvim definition / keyword weight ───
# A signature is the darkest, boldest line; keywords inside the body stay regular weight.
NVIM_FN_DEF=1c1c1e
NVIM_FN_DEF_BOLD=true
NVIM_KW_BOLD=false
NVIM_READONLY_BOLD=false

# ─── Nvim syntax roles ───
# Typed code in dark graphite; comments a lighter handwritten pencil; section banners inked bold.
NVIM_SYN_VAR=1c1c1e
NVIM_SYN_MEMBER=3c3c40
NVIM_SYN_PARAM=3c3c40
NVIM_SYN_TYPE=48484b
NVIM_SYN_STRING=55555a
NVIM_SYN_NUMBER=3c3c40
NVIM_SYN_CALL=1c1c1e
NVIM_SYN_OPERATOR=6e6d70
NVIM_SYN_RETURN=1c1c1e
NVIM_SYN_COMMENT=9a9894
NVIM_SYN_HEADER=2b2b2d
NVIM_SECTION_HEADERS=true
NVIM_FAINT_FG=a8a6a0
# Errors in raspberry red pen — the one bright mark on the page
NVIM_RED_PEN=9a5a48
# Pink highlighter: selection + search wash over the graphite, text stays dark
NVIM_SEARCH_FG=1c1c1e
NVIM_SEARCH_BG=ecc6d2
NVIM_CURSEARCH_FG=1c1c1e
NVIM_CURSEARCH_BG=e2aec0
NVIM_INCSEARCH_FG=1c1c1e
NVIM_INCSEARCH_BG=e2aec0
KITTY_SELECTION_BG=f1d6de
TMUX_MODE_FG=1c1c1e
TMUX_MODE_BG=f1d6de
# Graphite caret (paper-colored letter under it); blush active-workspace pill in the pen's raspberry. pi: graphite syntax, visible hairlines.
KITTY_CURSOR=3c3c40
KITTY_CURSOR_TEXT=f4f2ed
WAYBAR_WS_ACTIVE=b8336a
PI_BORDER=c8c5be
PI_MUTED=7c7a76
PI_ERROR=9a5a48
PI_MD_CODE=3c3c40
PI_SYN_KEYWORD=1c1c1e
PI_SYN_FUNCTION=1c1c1e
PI_SYN_STRING=55555a
PI_SYN_NUMBER=3c3c40
PI_SYN_OPERATOR=6e6d70

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=f1d6de
NVIM_SYMDEPS_SYNC=e6e3dc
NVIM_SYMDEPS_WARN=1c1c1e
NVIM_SYMDEPS_ALARM=9a5a48
NVIM_SYMDEPS_OK=5b6b5c

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=e9e7e1
# Spicetify uses warm paper
BG_SPICETIFY=f4f2ed
# Vencord secondary-alt
BG_VENCORD_ALT=e9e7e1
# Spicetify card hover
CARD_HOVER=e2dfd8
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=e9e7e1

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=3c3c40
FZF_ACCENT2=6e6d70

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=9a9894

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=238
ANSI_ACCENT2=241
ANSI_ACCENT3=243
ANSI_ACCENT4=240
ANSI_ACCENT5=242
ANSI_TEXT=235
ANSI_MUTED=245
ANSI_ERROR=131
ANSI_OK=65
ANSI_STANDOUT_BG=255
ANSI_PROMPT=238
ANSI_PROMPT2=243
ANSI_LOAD=245

# ─── Gradient colors (zsh graphite pressure) ───
GRAD1=236
GRAD2=238
GRAD3=240
GRAD4=242
GRAD5=244

# ─── Tmux colors ───
TMUX_ACTIVE=colour238
TMUX_INACTIVE=colour246
TMUX_INACTIVE_FG=858380
TMUX_ACTIVE_FG=2b2b2d
TMUX_ACTIVE_BG=e6e3dc

# ─── Bar · terminal quiet layer (waybar states · logo · kitty ANSI · tmux footer) ───
# Paper: state icons stay graphite (warnings in the darkest ink, real failures in the raspberry pen),
# no logo or window glyphs (bare workspace numbers), lighter prompt rules (ANSI white), neutral ANSI blue, and a faint dotted footer.
WAYBAR_LOGO='{}'
WAYBAR_WS_FORMAT='{name}'
WAYBAR_WARN=1c1c1e
WAYBAR_CRIT=9a5a48
WAYBAR_UPD_LOW=3c3c40
WAYBAR_UPD_MID=3c3c40
WAYBAR_UPD_HIGH=3c3c40
WAYBAR_PPD_BALANCED=6e6d70
WAYBAR_PPD_SAVER=6e6d70
SENTRY_CRIT=9a5a48
SENTRY_WARN=1c1c1e
SENTRY_OK=6e6d70
SENTRY_DIM=a8a6a0
KITTY_OPACITY=0.92
ANSI_WHITE=55555a
ANSI_BLUE=55555a
ANSI_BLUE_BRIGHT=6e6d70
TMUX_FOOTER_ACTIVE=7c7a76
TMUX_FOOTER_INACTIVE=249
TMUX_MARK_ACTIVE=✎
TMUX_MARK_INACTIVE=·
TMUX_SEP=·
# The active pane's footer: a pencil mark on the pink highlighter, like the line you're writing on.
TMUX_FOOTER_HIGHLIGHT=fox-tmux-hl-on

WELCOME_LAYOUT=centered

# Little hidden touches: the bar clock's colon becomes a heart when its two halves match
# (09♡09), the weather reads as a monochrome glyph, and a ✿ notification arrives when a
# long command succeeds while you're looking elsewhere. Other themes: fox-little-details-off.
LITTLE_DETAILS=fox-little-details-on

# ─── Cohesive surfaces (lock screen · mako · rofi · btop · lazygit · fzf · nvim floats) ───
# Paper: one hairline (c8c5be) for every frame, the pink highlighter for every selection,
# the raspberry pen for every failure, graphite for everything else.
HYPRLOCK_VIBRANCY=0.0
HYPRLOCK_BRIGHTNESS=1.0
HYPRLOCK_CONTRAST=1.0
HYPRLOCK_BRAND_Y=9999
HYPRLOCK_DOTS_Y=9999
HYPRLOCK_CLOCK_TEXT='<i>$TIME</i>'
HYPRLOCK_CLOCK_COLOR=2b2b2dee
HYPRLOCK_CLOCK_FONT="MonaspiceRn Nerd Font"
HYPRLOCK_DIM_COLOR=6e6d70cc
HYPRLOCK_INPUT_BORDER=c8c5beff
# Password dots are little outline flowers, pencil-weight like the ♡ below them.
HYPRLOCK_DOTS_STYLE='dots_text_format = ❀'
HYPRLOCK_FAIL=9a5a48
HYPRLOCK_CAPS=1c1c1e
# Date as a code tag, like the // [SECTION] banners in the code.
HYPRLOCK_DATE_TEXT='cmd[update:60000] date +"// [DATE] [%Y-%m-%d] [%^a]"'
# A handwritten sign-off under the password field (other themes park it off-screen).
HYPRLOCK_NOTE='<i>see you soon ♡</i>'
HYPRLOCK_NOTE_Y=-140
MAKO_BORDER=c8c5be
MAKO_CRIT_BORDER=9a5a48
MAKO_AGENT_BORDER=9a9894
MAKO_MEDIA_BORDER=c8c5be
MAKO_OSD_APP=fox-osd
ROFI_RADIUS=8
ROFI_INPUT_RADIUS=4px
ROFI_ITEM_RADIUS=4
ROFI_BORDER=c8c5be
ROFI_SELECTED=f1d6de
ROFI_SELECTED_ALPHA=0.9
BTOP_SELECTED_BG=f1d6de
BTOP_LINE=c8c5be
BTOP_COOL=9a9894
BTOP_WARM=6e6d70
BTOP_HOT=9a5a48
BTOP_UPLOAD_END=1c1c1e
LAZYGIT_INACTIVE_BORDER=c8c5be
LAZYGIT_UNSTAGED=9a5a48
FZF_BORDER=c8c5be
FZF_SESH_SELECTED=f1d6de
NVIM_LIST_SEL=f1d6de
NVIM_MENU_SEL=f1d6de
YAZI_HOVER_FG=1c1c1e
YAZI_HOVER_BG=f1d6de
NVIM_FLOAT_BG=e9e7e1
NVIM_FLOAT_BORDER=c8c5be

# ─── Greeter (regreet) ───
# Paper: the lock screen's language. EXTRA_SCOPE switches on regreet.css's Paper section
# (paper texture, hairline fields, handwritten time and notes); elsewhere it matches nothing.
REGREET_PREFER_DARK=false
REGREET_EXTRA_SCOPE='window:not(.foxml-off)'
REGREET_LINE=c8c5be
REGREET_LINE_FOCUS=9a9894
REGREET_GREETING="welcome back"
REGREET_CLOCK_FORMAT="%-I:%M %P"

# ─── Firefox (chrome + new tab / settings / web selection) ───
# Paper: hairline frames, 6px corners (Firefox's own radii show through), the highlighter for rows and text.
FF_EXTRA_SCOPE=':root'
FF_FRAME=c8c5be
FF_FRAME_W=1px
FF_RADIUS=6px
FF_RADIUS_SM=4px
FF_RADIUS_LG=6px
FF_CONTENT_RADIUS=6px
FF_SQUARE_SELECTOR=':not(*)'
FF_FOCUS_RING="0 0 0 1px rgb(200,197,190)"
FF_URL_ROW="rgb(241,214,222)"
FF_MENU_ROW="rgb(241,214,222)"
FF_AC_ROW="rgb(241,214,222)"
FF_TREE_SEL_BG="rgb(241,214,222)"
FF_TREE_SEL_FG="var(--fox-pink)"
FF_BUTTON_BG="rgb(241,214,222)"
FF_BUTTON_FG="var(--fox-pink)"
FF_CARD_HOVER="0 1px 4px rgba(0,0,0,0.10)"
FF_SELECTION_BG="rgb(241,214,222)"
FF_SELECTION_FG=1c1c1e

# ─── Errors · warnings · syntax roles · Thunar · one sheet opacity ───
# Paper: one error red (the symdeps terracotta 9a5a48), warnings in the darkest ink, graphite syntax
# outside nvim too, the highlighter in Thunar, every sheet at 0.92, handwritten notification titles.
NVIM_WARN=1c1c1e
NVIM_WARN_CURL=false
NVIM_WARN_DASH=true
ANSI_ERROR_SGR='38;2;154;90;72'
ZSH_COMMAND=1c1c1e
BAT_STRING=55555a
BAT_MEMBER=3c3c40
BAT_KEY=2b2b2d
BAT_COMMENT=9a9894
CURSOR_STRING=55555a
CURSOR_COMMENT=9a9894
OPENCODE_SYN_KEYWORD=1c1c1e
OPENCODE_SYN_STRING=55555a
OPENCODE_SYN_NUMBER=3c3c40
OPENCODE_SYN_COMMENT=9a9894
FZF_BORDER_STYLE=rounded
GTK_SEL_BG="rgba(241,214,222,0.95)"
GTK_LABEL_SHADOW=none
GTK_ICON_HOVER="rgba(60,60,64,0.06)"
GTK_ICON_SEL="rgba(241,214,222,0.95)"
GTK_ICON_SEL_BORDER="1px solid rgb(200,197,190)"
GTK_RUBBER_BG="rgba(241,214,222,0.35)"
GTK_RUBBER_BORDER="1px solid rgb(200,197,190)"
GTK_PANEL_ALPHA=0.92
GTK_WINDOW_ALPHA=0.92
WAYBAR_BUBBLE_ALPHA=0.92
MAKO_FORMAT='<span font_family="MonaspiceRn Nerd Font" style="italic" size="large">%s</span>\n%b'

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("paper" "graphite" "4B" "HB" "2H" "smudge")
