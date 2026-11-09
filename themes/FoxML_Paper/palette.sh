#!/bin/bash
# FoxML Paper — graphite pencil on white paper
# Graphite inks retain distinct pressure and subtle warm/cool roles.
# A stronger blush and readable secondary ink suit lower-contrast screens.
# ANSI colors are quiet colored-pencil tints so git /
# diagnostics / ls keep their meaning without reading as a rainbow.
# All hex values are WITHOUT the # prefix

# ─── Theme metadata ───
THEME_TYPE=light
NVIM_STYLE=day
NVIM_BG=light
KITTY_BG_OPACITY=0.70
POPUP_BG_OPACITY=0.98
MAKO_ICON_THEME=Papirus-Light
GTK_ICON_THEME=FoxML-Paper
VSCODE_UI_THEME=vs
FONT_FAMILY="MonaspiceKr Nerd Font"
# WARNING: SHOW_WELCOME is also the project's literal-true alias used in
# ~246 template substitutions (vim opts, yazi bold, Firefox CSS selectors,
# nvim init.lua, etc.). Setting this to false will break far more than
# the welcome message. Leave as true; gate the welcome message via the
# `[[ "{{SHOW_WELCOME}}" == "true" ]]` check in templates/zsh/welcome.zsh.
SHOW_WELCOME=true
SHOW_BANNER=true
WALLPAPER=foxml_paper_botanical_color.png

# ─── Aesthetic controls ───
# Light blur so the paper grain still shows through translucent windows.
ROUNDING=6
BLUR_SIZE=2
BLUR_PASSES=1
GAP_IN=5
GAP_OUT=10
BORDER_SIZE=1
SHADOW_RANGE=6
SHADOW_ALPHA=0.06

# ─── Desktop chrome (GTK settings.ini · cursor · Hyprland window edges · kitty text · banner) ───
# A drawn hairline separates sheets; inactive windows stay paper, not soot.
GTK_PREFER_DARK=0
# Built by the installer from Catppuccin: the highlighter hue, stronger than SELECTION because
# e2a4ba disappears at cursor size, with a graphite outline. base:src_fill:src_outline:fill:outline[:flower]; flower
# swaps the busy cursors for a slowly turning flower in the same inks.
CURSOR_THEME=foxml-paper-cursors
CURSOR_RECOLOR=catppuccin-mocha-pink-cursors:f5c2e7:1e1e2e:edb0c4:3c3c40:flower
# Stock Papirus has no blush: built from Catppuccin's pink with the pointer's pink and
# graphite emblems. base:from=to,from=to
PAPIRUS_FOLDER_COLOR=foxml-blush
PAPIRUS_FOLDER_RECOLOR=cat-mocha-pink:F5C2E7=edb0c4,E1AED3=d99ab0,CDD6F4=f0ede7,313244=3c3c40
HYPR_BORDER_SIZE=1
HYPR_BORDER_INACTIVE=9a989488
HYPR_SHADOW_ALPHA_INACTIVE=0.08
# Keep text equally visible when focus moves to another screen.
HYPR_DIM_STRENGTH=0.0
HYPR_INACTIVE_OPACITY=1.0
# Workspace switch: a short vertical slide-fade, like flipping a top-bound notepad.
HYPR_WS_ANIM='slidefadevert 20%'
HYPR_WIN_CURVE=foxSettle
# Comments (italic) in Monaspace Radon: handwriting beside the typed code.
KITTY_ITALIC_FONT="MonaspiceRn Nerd Font"
KITTY_TAB_BAR_STYLE=hidden
KITTY_DIM_OPACITY=1.0
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
# Warm bone paper stays close to white, with graphite ink and visible blush.
BG=f0ede7
BG_DARK=e4dfd6
BG_ALT=e2dfd8
BG_HIGHLIGHT=e6e3dc
SELECTION=e2a4ba

FG=202024
FG_PASTEL=48484b
FG_DIM=59565b
COMMENT=625b60

PRIMARY=353238
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
NVIM_SEL=e2a4ba
WARM=6e6c68
SAND=7a7874
WHEAT=8a7a5a
CLAY=9a5a48

# ─── Nvim diff colors ───
DIFF_ADD=d7e1d3
DIFF_CHANGE=e4dfd6
DIFF_DELETE=eddad7
DIFF_TEXT=dcd9d2
TREESITTER_CTX=e4dfd6

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
NVIM_DIAG_ERR_BG=f0dcd9
NVIM_DIAG_WARN_BG=ece9e3
NVIM_GIT_MOD=8a7650
NVIM_GIT_DEL=9a5a58
NVIM_CONFLICT_CUR=f0dcda
NVIM_CONFLICT_CUR_LABEL=e8d2cf
NVIM_CONFLICT_INC=d8e4d5
NVIM_CONFLICT_INC_LABEL=cbddc7
NVIM_ILLUMINATE=e2dfd8

# ─── Nvim definition / keyword weight ───
# Soft highlighter behind graphite signatures; calls stay on the plain page.
NVIM_FN_DEF=3f2d4b
NVIM_FN_DEF_BOLD=true
NVIM_KW_BOLD=false
NVIM_READONLY_BOLD=false

# ─── Nvim syntax roles ───
# Dark typed code and warm handwritten comments, with blush behind literals.
NVIM_SYN_VAR=1d1b23
NVIM_SYN_MEMBER=2b2733
NVIM_SYN_PARAM=513c5a
NVIM_SYN_TYPE=34485f
NVIM_SYN_STRING=355042
NVIM_SYN_NUMBER=713f59
NVIM_SYN_CALL=302538
NVIM_SYN_OPERATOR=4a474e
NVIM_SYN_RETURN=1c1c1e
NVIM_SYN_COMMENT=755845
NVIM_SYN_HEADER=755845
NVIM_SECTION_HEADERS=true
NVIM_FAINT_FG=66615f
# Errors in raspberry red pen — the one bright mark on the page
NVIM_RED_PEN=9a5a48
# Pink highlighter: selection + search wash over the graphite, text stays dark
NVIM_SEARCH_FG=1c1c1e
NVIM_SEARCH_BG=dda0b8
NVIM_CURSEARCH_FG=1c1c1e
NVIM_CURSEARCH_BG=d48aa6
NVIM_INCSEARCH_FG=1c1c1e
NVIM_INCSEARCH_BG=d48aa6
KITTY_SELECTION_BG=e2a4ba
TMUX_MODE_FG=1c1c1e
TMUX_MODE_BG=e2a4ba
# Graphite caret (paper-colored letter under it); blush active-workspace pill in the pen's raspberry. pi: graphite syntax, visible hairlines.
KITTY_CURSOR=3c3c40
KITTY_CURSOR_TEXT=f0ede7
KITTY_POINTER_SHAPE=arrow
ZATHURA_HIGHLIGHT="rgba(226,164,186,0.70)"
ZATHURA_HIGHLIGHT_ACTIVE="rgba(237,176,196,0.70)"
WAYBAR_WS_ACTIVE=b8336a
PI_BORDER=a9a19b
PI_MUTED=625d58
PI_ERROR=9a5a48
PI_MD_CODE=3c3c40
PI_SYN_KEYWORD=1c1c1e
PI_SYN_FUNCTION=1c1c1e
PI_SYN_STRING=373f36
PI_SYN_NUMBER=3c3c40
PI_SYN_OPERATOR=4a474e

# ─── fox-symdeps HUD (selection bar · asm sync band · warn / alarm / ok) ───
NVIM_SYMDEPS_SEL=e2a4ba
NVIM_SYMDEPS_SYNC=e6e3dc
NVIM_SYMDEPS_WARN=1c1c1e
NVIM_SYMDEPS_ALARM=9a5a48
NVIM_SYMDEPS_OK=5b6b5c

# ─── App-specific overrides ───
# Dunst uses a slightly different bg
BG_DUNST=e4dfd6
# Spicetify uses warm paper
BG_SPICETIFY=f0ede7
# Vencord secondary-alt
BG_VENCORD_ALT=e4dfd6
# Spicetify card hover
CARD_HOVER=e2dfd8
# Firefox new-tab / about: page card surface
FIREFOX_CARD_BG=e4dfd6

# ─── FZF colors (24-bit hex) ───
FZF_ACCENT1=3c3c40
FZF_ACCENT2=6e6d70

# ─── ZSH autosuggestion color ───
ZSH_SUGGEST=756e73

# ─── ANSI 256-color codes ───
ANSI_ACCENT1=238
ANSI_ACCENT2=241
ANSI_ACCENT3=243
ANSI_ACCENT4=240
ANSI_ACCENT5=242
ANSI_TEXT=235
ANSI_MUTED=242
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
# tmux pane dividers: a double pencil line (═), the active pane's in blush.
TMUX_BORDER=a39d96
TMUX_BORDER_ACTIVE=c67596
TMUX_BORDER_LINES=double
TMUX_INACTIVE_FG=756e73
TMUX_ACTIVE_FG=202024
TMUX_ACTIVE_BG=e6e3dc

# ─── Bar · terminal quiet layer (waybar states · logo · kitty ANSI · tmux footer) ───
# Paper: state icons stay graphite (warnings in the darkest ink, real failures in the raspberry pen),
# a pencil launcher and window glyphs, lighter prompt rules (ANSI white), neutral ANSI blue, and a faint dotted footer.
WAYBAR_LOGO='✎'
WAYBAR_WS_FORMAT='{name} {windows}'
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
SENTRY_DIM=76716e
KITTY_OPACITY=0.70
ANSI_WHITE=55555a
ANSI_BLUE=55555a
ANSI_BLUE_BRIGHT=6e6d70
TMUX_FOOTER_ACTIVE=7c7a76
TMUX_FOOTER_INACTIVE=244
TMUX_MARK_ACTIVE=✎
TMUX_MARK_INACTIVE=·
TMUX_SEP=·
# The active pane's footer: a pencil mark on the pink highlighter, like the line you're writing on.
TMUX_FOOTER_HIGHLIGHT=fox-tmux-hl-on

WELCOME_LAYOUT=centered

# Paper uses botanical illustrations and quiet pencil details.
# Other themes: fox-little-details-off.
LITTLE_DETAILS=fox-little-details-on

# ─── Cohesive surfaces (lock screen · mako · rofi · btop · lazygit · fzf · nvim floats) ───
# Paper: one hairline (a9a19b) for every frame, the pink highlighter for every selection,
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
HYPRLOCK_INPUT_BORDER=a9a19bff
# Password entry uses plain dots.
HYPRLOCK_DOTS_STYLE='dots_text_format = •'
HYPRLOCK_FAIL=9a5a48
HYPRLOCK_FAIL_TEXT='<i>try again · $FAIL</i>'
HYPRLOCK_CAPS=1c1c1e
# A handwritten date with a blush underline, beside the botanical study.
HYPRLOCK_DATE_TEXT='cmd[update:60000] sh "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/date-label.sh"'
# A handwritten sign-off under the password field (other themes park it off-screen).
HYPRLOCK_NOTE='<i>locked</i>'
HYPRLOCK_NOTE_Y=-140
HYPRLOCK_CAT_Y=-228
MAKO_BORDER=a9a19b
MAKO_CRIT_BORDER=9a5a48
MAKO_AGENT_BORDER=9a9894
MAKO_MEDIA_BORDER=a9a19b
MAKO_OSD_APP=fox-osd
ROFI_RADIUS=8
ROFI_INPUT_RADIUS=4px
ROFI_ITEM_RADIUS=4
ROFI_BORDER=a9a19b
ROFI_SELECTED=e2a4ba
ROFI_SELECTED_ALPHA=0.95
BTOP_SELECTED_BG=e2a4ba
BTOP_HI_FG=b8336a
BTOP_SELECTED_FG=b8336a
BTOP_PROC_MISC=b8336a
BTOP_LINE=a9a19b
BTOP_COOL=9a9894
BTOP_WARM=6e6d70
BTOP_HOT=9a5a48
BTOP_UPLOAD_END=1c1c1e
LAZYGIT_INACTIVE_BORDER=a9a19b
LAZYGIT_UNSTAGED=9a5a48
FZF_BORDER=a9a19b
FZF_SESH_SELECTED=e2a4ba
NVIM_LIST_SEL=e2a4ba
NVIM_MENU_SEL=e2a4ba
YAZI_HOVER_FG=1c1c1e
YAZI_HOVER_BG=e2a4ba
NVIM_FLOAT_BG=e4dfd6
NVIM_FLOAT_BORDER=a9a19b

# ─── Greeter (regreet) ───
# Paper: the lock screen's language. EXTRA_SCOPE switches on regreet.css's Paper section
# (paper texture, hairline fields, handwritten time and notes); elsewhere it matches nothing.
REGREET_PREFER_DARK=false
REGREET_EXTRA_SCOPE='window:not(.foxml-off)'
REGREET_LINE=a9a19b
REGREET_LINE_FOCUS=9a9894
REGREET_GREETING="welcome back"
REGREET_CLOCK_FORMAT="%-I:%M %P"

# ─── Firefox (chrome + new tab / settings / web selection) ───
# Paper: hairline frames, 6px corners (Firefox's own radii show through), the highlighter for rows and text.
FF_EXTRA_SCOPE=':root'
FF_FRAME=a9a19b
FF_FRAME_W=1px
FF_RADIUS=6px
FF_RADIUS_SM=4px
FF_RADIUS_LG=6px
FF_CONTENT_RADIUS=6px
FF_SQUARE_SELECTOR=':not(*)'
FF_FOCUS_RING="0 0 0 1px rgb(169,161,155)"
FF_URL_ROW="rgb(226,164,186)"
FF_MENU_ROW="rgb(226,164,186)"
FF_AC_ROW="rgb(226,164,186)"
FF_TREE_SEL_BG="rgb(226,164,186)"
FF_TREE_SEL_FG="var(--fox-pink)"
FF_BUTTON_BG="rgb(226,164,186)"
FF_BUTTON_FG="var(--fox-pink)"
FF_CARD_HOVER="0 1px 4px rgba(0,0,0,0.10)"
FF_SELECTION_BG="rgb(226,164,186)"
FF_SELECTION_FG=1c1c1e

# ─── Errors · warnings · syntax roles · Thunar · one sheet opacity ───
# Paper: one error red (the symdeps terracotta 9a5a48), warnings in the darkest ink, graphite syntax
# outside nvim too, the highlighter in Thunar, and handwritten notification titles.
# Translucent terminal paper keeps the wallpaper visible; text stays undimmed.
NVIM_WARN=1c1c1e
NVIM_WARN_CURL=false
NVIM_WARN_DASH=true
ANSI_ERROR_SGR='38;2;154;90;72'
ZSH_COMMAND=1c1c1e
BAT_STRING=55555a
BAT_MEMBER=3c3c40
BAT_KEY=202024
BAT_COMMENT=625d58
CURSOR_STRING=55555a
CURSOR_COMMENT=625d58
OPENCODE_SYN_KEYWORD=1c1c1e
OPENCODE_SYN_STRING=55555a
OPENCODE_SYN_NUMBER=3c3c40
OPENCODE_SYN_COMMENT=625d58
FZF_BORDER_STYLE=rounded
GTK_SEL_BG="rgba(226,164,186,0.95)"
GTK_LABEL_SHADOW=none
GTK_ICON_HOVER="rgba(60,60,64,0.06)"
GTK_ICON_SEL="rgba(226,164,186,0.95)"
GTK_ICON_SEL_BORDER="1px solid rgb(169,161,155)"
GTK_RUBBER_BG="rgba(226,164,186,0.35)"
GTK_RUBBER_BORDER="1px solid rgb(169,161,155)"
GTK_PANEL_ALPHA=0.98
GTK_WINDOW_ALPHA=0.98
WAYBAR_BUBBLE_ALPHA=0.98
MAKO_FORMAT='<span font_family="MonaspiceRn Nerd Font" style="italic" size="large">%s</span>\n%b'

# ─── Preview swatches (for swap.sh) ───
PALETTE_LABELS=("paper" "graphite" "4B" "HB" "2H" "smudge")

# Small native control accents
GTK_DETAIL_SCOPE=window

# Graph strokes and the optional paper notification stamp
BTOP_GRAPH_START=dda0b8
BTOP_GRAPH_MID=d48aa6
BTOP_GRAPH_END=9a5a58
MAKO_STAMP_SUMMARIES='.*'

# Normal-window shadow color and direction
HYPR_SHADOW_RGB=2b2b2d
HYPR_SHADOW_OFFSET_X=2
HYPR_SHADOW_OFFSET_Y=2

# Reading and notebook labels
YAZI_TAB_ACTIVE_FG=202024
YAZI_TAB_ACTIVE_BG=e2a4ba
NVIM_MEMBER_BOLD=true
DELTA_LABEL_STYLE=foxml-notebook
DRAWER_SCROLL_GUTTER=18

# Search result ink and match decoration (shared shell / tmux pickers).
FZF_MATCH_FG=202024
FZF_MATCH_SELECTED_FG=202024
FZF_MATCH_ATTR=underline
FZF_META_FG=625d58
FF_FIND_BG=e2a4ba
FF_FIND_FG=202024

# Keep Paper compositor and application cursor shapes on the same XCursor backend.
HYPR_CURSOR_ENABLED=false

# File-listing glyphs; filenames and metadata retain their own pencil weights.
EZA_ICON_FG=202024

# File-operation marks and count badges.
YAZI_MARK_COPIED=edb0c4
YAZI_MARK_MARKED=edb0c4
YAZI_MARK_SELECTED=edb0c4
YAZI_COPIED_FG=202024
YAZI_COPIED_BG=e2a4ba
YAZI_SELECTED_FG=202024
YAZI_SELECTED_BG=e2a4ba

# A paper footer: small blush mode labels, quiet metadata.
YAZI_MODE_FG=202024
YAZI_MODE_ALT_FG=59565b
YAZI_MODE_NORMAL_BG=e2a4ba
YAZI_MODE_NORMAL_ALT_BG=f0ede7
YAZI_MODE_SELECT_BG=e2a4ba
YAZI_MODE_SELECT_ALT_BG=f0ede7
YAZI_MODE_UNSET_BG=e2a4ba
YAZI_MODE_UNSET_ALT_BG=f0ede7

# Native permission dialogs use the same selection fill and readable links.
HYPRTOOLKIT_ACCENT=e2a4ba
HYPRTOOLKIT_LINK=6e6d70

# Personal-folder paper and tab, shared with the icon family.
ICON_FOLDER_FILL=edb0c4
ICON_FOLDER_TAB=d99ab0

# Tooltip root selector; native GTK tooltip windows have no window ancestor.
GTK_TOOLTIP_SCOPE=tooltip

# Readable paper tooltip fill; text stays fully opaque.
TOOLTIP_BG_OPACITY=0.98

# Notification paper, placement and type alignment.
MAKO_PADDING=18,14,24,14
MAKO_MARGIN=0,14,10,14
MAKO_OUTER_MARGIN=0
MAKO_TEXT_ALIGN=center
MAKO_ICON_LOCATION=top
MAKO_PAPER_SHAPE=bookmark

# Fastfetch machine card and field labels.
FASTFETCH_LOGO='"type": "data", "source": "$1╭──────────────────────╮\n$1│$2       FIELD NOTES    $1│\n$1│$2                      $1│\n$1│$2          /           $1│\n$1│$2       --/--          $1│\n$1│$2        /             $1│\n$1│$2     --/              $1│\n$1│$2                      $1│\n$1╰──────────────────────╯"'
FASTFETCH_KEY_INK=245
FASTFETCH_OUTPUT_INK=238
FASTFETCH_KEY_OS="OS"
FASTFETCH_KEY_KERNEL="kernel"
FASTFETCH_KEY_WM="desk"
FASTFETCH_KEY_TERMINAL="terminal"
FASTFETCH_KEY_SHELL="shell"
FASTFETCH_KEY_UPTIME="uptime"
FASTFETCH_KEY_BATTERY="battery"
FASTFETCH_KEY_CPU="CPU"
FASTFETCH_KEY_GPU="GPU"
FASTFETCH_KEY_MEMORY="memory"
FASTFETCH_KEY_DISK="disk"
FASTFETCH_KEY_WIDTH=10

# Claude Code (custom:foxml): a soft pink behind sent messages, sage and coral diffs under dark ink.
CLAUDE_USER_BG=e8becd
CLAUDE_USER_BG_HOVER=e2a4ba
CLAUDE_DIFF_ADD=bedcbe
CLAUDE_DIFF_ADD_DIM=d6e5d2
CLAUDE_DIFF_ADD_WORD=91c791
CLAUDE_DIFF_DEL=f5c7ba
CLAUDE_DIFF_DEL_DIM=f4d9d1
CLAUDE_DIFF_DEL_WORD=ec9c88

# Commit garden: paper, then four pinks that deepen with the day's commits. Level 1 is the message-box pink
# that read on every monitor; each step is at least 1.25:1 from the last.
GARDEN_0=e3dfd8
GARDEN_1=e8becd
GARDEN_2=dc9bb3
GARDEN_3=c67596
GARDEN_4=a24f73
