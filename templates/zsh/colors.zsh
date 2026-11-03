# ╭──────────────────────────────────────────────╮
# │          Fox ML — terminal colors            │
# ╰──────────────────────────────────────────────╯

typeset -g FOXML_FZF_POINTER='◆' FOXML_FZF_MARKER='●'
if [[ "{{LITTLE_DETAILS}}" == fox-little-details-on ]]; then
  FOXML_FZF_POINTER='›'
  FOXML_FZF_MARKER=' '
  zle_highlight=("${(@)zle_highlight:#(region|isearch|paste):*}"
    'region:fg=#{{FG}},bg=#{{SELECTION}}'
    'isearch:fg=#{{FG}},bg=#{{SELECTION}}'
    'paste:fg=#{{FG}},bg=#{{SELECTION}}')
fi

# ─── LS_COLORS (Semantic FoxML palette) ──────
export LS_COLORS="\
di=38;5;{{ANSI_ACCENT1}};1:\
ln=38;5;{{ANSI_ACCENT2}}:\
ex=38;5;{{ANSI_ACCENT4}};1:\
fi=38;5;{{ANSI_TEXT}}:\
mi={{ANSI_ERROR_SGR}}:\
or={{ANSI_ERROR_SGR}};9:\
pi=38;5;{{ANSI_ACCENT1}}:\
so=38;5;{{ANSI_ACCENT3}}:\
bd=38;5;{{ANSI_ACCENT1}}:\
cd=38;5;{{ANSI_ACCENT1}}:\
*.md=38;5;{{ANSI_ACCENT1}}:\
*.txt=38;5;{{ANSI_TEXT}}:\
*.py=38;5;{{ANSI_ACCENT1}}:\
*.lua=38;5;{{ANSI_ACCENT1}}:\
*.sh=38;5;{{ANSI_ACCENT4}}:\
*.zsh=38;5;{{ANSI_ACCENT4}}:\
*.c=38;5;{{ANSI_ACCENT2}}:\
*.cpp=38;5;{{ANSI_ACCENT2}}:\
*.h=38;5;{{ANSI_ACCENT3}}:\
*.hpp=38;5;{{ANSI_ACCENT3}}:\
*.rs=38;5;{{ANSI_ACCENT1}}:\
*.go=38;5;{{ANSI_ACCENT1}}:\
*.js=38;5;{{ANSI_ACCENT3}}:\
*.ts=38;5;{{ANSI_ACCENT3}}:\
*.json=38;5;{{ANSI_TEXT}}:\
*.yaml=38;5;{{ANSI_TEXT}}:\
*.yml=38;5;{{ANSI_TEXT}}:\
*.toml=38;5;{{ANSI_TEXT}}:\
*.conf=38;5;{{ANSI_TEXT}}:\
*.cfg=38;5;{{ANSI_TEXT}}:\
*.ini=38;5;{{ANSI_TEXT}}:\
*.css=38;5;{{ANSI_ACCENT3}}:\
*.html=38;5;{{ANSI_ACCENT1}}:\
*.xml=38;5;{{ANSI_TEXT}}:\
*.jpg=38;5;{{ANSI_ACCENT3}}:\
*.jpeg=38;5;{{ANSI_ACCENT3}}:\
*.png=38;5;{{ANSI_ACCENT3}}:\
*.gif=38;5;{{ANSI_ACCENT3}}:\
*.svg=38;5;{{ANSI_ACCENT3}}:\
*.mp4=38;5;{{ANSI_ACCENT3}}:\
*.mkv=38;5;{{ANSI_ACCENT3}}:\
*.mp3=38;5;{{ANSI_ACCENT2}}:\
*.flac=38;5;{{ANSI_ACCENT2}}:\
*.wav=38;5;{{ANSI_ACCENT2}}:\
*.zip=38;5;{{ANSI_ACCENT5}}:\
*.tar=38;5;{{ANSI_ACCENT5}}:\
*.gz=38;5;{{ANSI_ACCENT5}}:\
*.xz=38;5;{{ANSI_ACCENT5}}:\
*.7z=38;5;{{ANSI_ACCENT5}}:\
*.git=38;5;{{ANSI_MUTED}}:\
*.gitignore=38;5;{{ANSI_MUTED}}:\
*.log=38;5;{{ANSI_MUTED}}:\
*.bak=38;5;{{ANSI_MUTED}}:\
*.tmp=38;5;{{ANSI_MUTED}}:\
"

# ─── eza colors (semantic matching) ─────────
export EXA_COLORS="\
da=38;5;{{ANSI_MUTED}}:\
ur=38;5;{{ANSI_TEXT}}:\
uw=38;5;{{ANSI_ACCENT1}}:\
ux=38;5;{{ANSI_ACCENT4}}:\
ue=38;5;{{ANSI_ACCENT4}}:\
gr=38;5;{{ANSI_MUTED}}:\
gw=38;5;{{ANSI_MUTED}}:\
gx=38;5;{{ANSI_MUTED}}:\
tr=38;5;{{ANSI_MUTED}}:\
tw=38;5;{{ANSI_MUTED}}:\
tx=38;5;{{ANSI_MUTED}}:\
sn=38;5;{{ANSI_ACCENT1}}:\
sb=38;5;{{ANSI_ACCENT2}}:\
df=38;5;{{ANSI_ACCENT3}}:\
ds=38;5;{{ANSI_ACCENT4}}:\
uu=38;5;{{ANSI_ACCENT3}}:\
gu=38;5;{{ANSI_ACCENT2}}:\
"


# ─── zsh-syntax-highlighting (FoML) ────────────
typeset -A ZSH_HIGHLIGHT_STYLES

ZSH_HIGHLIGHT_STYLES[default]='fg={{ANSI_TEXT}}'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#{{RED}}'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg={{ANSI_ACCENT3}},bold'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#{{ZSH_COMMAND}}'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#{{ZSH_COMMAND}}'
ZSH_HIGHLIGHT_STYLES[function]='fg=#{{ZSH_COMMAND}}'
ZSH_HIGHLIGHT_STYLES[command]='fg=#{{ZSH_COMMAND}}'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=#{{ZSH_COMMAND}},underline'
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg={{ANSI_ACCENT1}}'
ZSH_HIGHLIGHT_STYLES[path]='fg={{ANSI_ACCENT2}},underline'
ZSH_HIGHLIGHT_STYLES[path_pathseparator]='fg={{ANSI_ACCENT1}}'
ZSH_HIGHLIGHT_STYLES[globbing]='fg={{ANSI_ACCENT3}}'
ZSH_HIGHLIGHT_STYLES[history-expansion]='fg={{ANSI_ACCENT3}}'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg={{ANSI_ACCENT2}}'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg={{ANSI_ACCENT2}}'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg={{ANSI_ACCENT1}}'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg={{ANSI_ACCENT1}}'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg={{ANSI_ACCENT3}}'
ZSH_HIGHLIGHT_STYLES[back-double-quoted-argument]='fg={{ANSI_ACCENT3}}'
ZSH_HIGHLIGHT_STYLES[assign]='fg={{ANSI_TEXT}}'
ZSH_HIGHLIGHT_STYLES[redirection]='fg={{ANSI_ACCENT3}}'
ZSH_HIGHLIGHT_STYLES[comment]='fg={{ANSI_MUTED}},italic'
ZSH_HIGHLIGHT_STYLES[arg0]='fg=#{{ZSH_COMMAND}}'

if [[ "{{LITTLE_DETAILS}}" == fox-little-details-on ]]; then
  for _fox_word in alias builtin function command arg0; do
    ZSH_HIGHLIGHT_STYLES[$_fox_word]='fg=#{{ZSH_COMMAND}},bold'
  done
  for _fox_word in single-hyphen-option double-hyphen-option; do
    ZSH_HIGHLIGHT_STYLES[$_fox_word]='fg=#{{FG_DIM}}'
  done
  for _fox_word in single-quoted-argument double-quoted-argument; do
    ZSH_HIGHLIGHT_STYLES[$_fox_word]='fg=#{{FG_PASTEL}}'
  done
  ZSH_HIGHLIGHT_STYLES[path]='fg=#{{FG}},underline'
  ZSH_HIGHLIGHT_STYLES[path_pathseparator]='fg=#{{COMMENT}}'
  ZSH_HIGHLIGHT_STYLES[comment]='fg=#{{COMMENT}},italic'
  unset _fox_word
fi
