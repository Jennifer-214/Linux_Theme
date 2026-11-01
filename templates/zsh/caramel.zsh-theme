# ╭──────────────────────────────────────────────╮
# │          Fox ML — caramel zsh theme          │
# ╰──────────────────────────────────────────────╯
# Palette: peach({{ANSI_ACCENT1}}) pink({{ANSI_ACCENT1}},{{ANSI_ACCENT1}}) mauve({{ANSI_ACCENT2}}) lavender({{ANSI_ACCENT5}},141)

# ─── Config ──────────────────────────────────────
CARAMEL_CMD_THRESHOLD=${CARAMEL_CMD_THRESHOLD:-3}

# ─── Timer (tracks command execution time) ─────

_caramel_timer_start=0

function caramel_preexec() {
  zmodload -F zsh/datetime p:EPOCHREALTIME
  _caramel_timer_start=${EPOCHREALTIME}
}

add-zsh-hook preexec caramel_preexec

# ─── Smart path: shorten only when deep (>3 segments) ───

function smart_path() {
  local full="${PWD/#$HOME/~}"
  local -a parts
  parts=("${(@s:/:)full}")

  # Count real segments (skip empty from leading /)
  local count=0
  for p in "${parts[@]}"; do [[ -n "$p" ]] && ((count++)); done

  # Short enough — show full path
  if (( count <= 3 )); then
    echo "$full"
    return
  fi

  # Deep — abbreviate middle segments
  local prefix="" start=1
  if [[ "${parts[1]}" = "~" ]]; then
    prefix="~/"
    start=2
  elif [[ -z "${parts[1]}" ]]; then
    prefix="/"
    start=2
  fi

  local last="${parts[-1]}"
  local mid=""
  local end_idx=$(( ${#parts} - 1 ))

  for ((i=start; i<=end_idx; i++)); do
    local seg="${parts[$i]}"
    [[ -z "$seg" ]] && continue
    mid+="${seg[1]}/"
  done

  echo "${prefix}${mid}${last}"
}

# ─── Gradient across path segments (peach → pink → lavender) ───

function gradient_path() {
  local raw="$1"
  local -a colors=({{ANSI_ACCENT2}} {{ANSI_ACCENT1}} {{ANSI_ACCENT3}} {{ANSI_ACCENT2}} {{ANSI_ACCENT1}} {{ANSI_ACCENT3}} {{ANSI_ACCENT2}})
  local -a segments
  local result="" idx=0

  local prefix=""
  if [[ "$raw" = "~/"* ]]; then
    prefix="%{%F{{{ANSI_ACCENT2}}}%} ~%{%F{{{ANSI_ACCENT1}}}%}/%{%f%}"
    raw="${raw#\~/}"
  elif [[ "$raw" = "~" ]]; then
    echo "%{%F{{{ANSI_ACCENT2}}}%} ~%{%f%}"
    return
  elif [[ "$raw" = /* ]]; then
    prefix="%{%F{{{ANSI_ACCENT1}}}%}/%{%f%}"
    raw="${raw#/}"
  fi

  segments=("${(@s:/:)raw}")
  local total=${#segments}

  for ((j=1; j<=total; j++)); do
    local seg="${segments[$j]}"
    [[ -z "$seg" ]] && continue
    local c=${colors[idx % ${#colors} + 1]}
    result+="%{%F{$c}%}${seg}"
    if (( j < total )); then
      result+="%{%F{{{ANSI_ACCENT1}}}%}/"
    fi
    ((idx++))
  done

  echo "${prefix}${result}%{%f%}"
}

# ─── Format elapsed time as human-readable ─────

function fmt_elapsed() {
  local t=$1
  if (( t >= 3600 )); then
    printf '%dh%dm%ds' $((t/3600)) $((t%3600/60)) $((t%60))
  elif (( t >= 60 )); then
    printf '%dm%ds' $((t/60)) $((t%60))
  else
    printf '%ds' $t
  fi
}

# ─── Git ────────────────────────────────────────

ZSH_THEME_GIT_PROMPT_PREFIX="%{%F{{{ANSI_ACCENT1}}}%} "
ZSH_THEME_GIT_PROMPT_SUFFIX="%{%f%}"
# Error ink as a raw SGR (a palette value can't start with '#', so truecolour can't go through %F{})
_fox_err=$'\e[{{ANSI_ERROR_SGR}}m'
ZSH_THEME_GIT_PROMPT_DIRTY=" %{${_fox_err}%}%{%f%}"
ZSH_THEME_GIT_PROMPT_CLEAN=" %{%F{{{ANSI_OK}}}%}%{%f%}"

# ─── Precmd (runs before each prompt) ──────────

function caramel_precmd() {
  local exit_code=$?

  # ── Exit status indicator ──
  if [[ $exit_code -eq 0 ]]; then
    PROMPT_INDICATOR="%{%F{{{ANSI_ACCENT2}}}%}❯%{%f%}"
  else
    PROMPT_INDICATOR="%{${_fox_err}%}❯ %{%F{{{ANSI_ACCENT2}}}%}${exit_code}%{%f%}"
  fi

  # ── Command execution time (show if >= 3s) ──
  ELAPSED_PROMPT=""
  if (( _caramel_timer_start > 0 )); then
    zmodload -F zsh/datetime p:EPOCHREALTIME
    local elapsed=$(( ${EPOCHREALTIME} - ${_caramel_timer_start} ))
    local elapsed_int=${elapsed%.*}
    if (( elapsed_int >= CARAMEL_CMD_THRESHOLD )); then
      ELAPSED_PROMPT=" %{%F{{{ANSI_ACCENT1}}}%} $(fmt_elapsed $elapsed_int)%{%f%}"
    fi
    _caramel_timer_start=0
  fi

  # ── Conda / venv ──
  VENV_PROMPT=""
  if [[ -n "$CONDA_DEFAULT_ENV" && "$CONDA_DEFAULT_ENV" != "base" ]]; then
    VENV_PROMPT=" %{%F{{{ANSI_ACCENT3}}}%} %{%F{{{ANSI_ACCENT2}}}%}$(basename "$CONDA_DEFAULT_ENV")%{%f%}"
  elif [[ -n "$VIRTUAL_ENV" ]]; then
    VENV_PROMPT=" %{%F{{{ANSI_ACCENT3}}}%} %{%F{{{ANSI_ACCENT2}}}%}$(basename "$VIRTUAL_ENV")%{%f%}"
  fi

  # ── SSH indicator ──
  SSH_PROMPT=""
  if [[ -n "$SSH_CONNECTION" ]]; then
    SSH_PROMPT="%{%F{{{ANSI_ACCENT1}}}%} %m%{%f%} "
  fi

  # ── Background jobs ──
  JOBS_PROMPT=""
  local njobs=${(M)#jobstates}
  if (( njobs > 0 )); then
    JOBS_PROMPT=" %{%F{{{ANSI_ACCENT1}}}%} ${njobs}%{%f%}"
  fi

  # ── Host + Path + Git ──
  CARAMEL_HOST="%{%F{{{ANSI_ACCENT1}}}%}%n%{%F{{{ANSI_ACCENT3}}}%}@%{%F{{{ANSI_ACCENT1}}}%}%m%{%f%}"
  CARAMEL_PATH="$(gradient_path "$(smart_path)")"
  CARAMEL_GIT="$(git_prompt_info)"
}

add-zsh-hook precmd caramel_precmd

# ─── Prompt layout ──────────────────────────────
# Line 1:  user@host  path  git  venv  jobs  elapsed
# Line 2:  ❯ (peach = ok, red + exit code = fail)
# Right:   timestamp (dimmed)

setopt PROMPT_SUBST
PROMPT='
 ${SSH_PROMPT}${CARAMEL_HOST} ${CARAMEL_PATH}${CARAMEL_GIT}${VENV_PROMPT}${JOBS_PROMPT}${ELAPSED_PROMPT}
 ${PROMPT_INDICATOR} '

RPROMPT='%{%F{{{ANSI_ACCENT1}}}%}%*%{%f%}'

# ─── Transient prompt (collapse after enter) ──

function _caramel_accept_line() {
  # Save the full prompt, replace with minimal
  _caramel_saved_prompt="$PROMPT"
  _caramel_saved_rprompt="$RPROMPT"
  PROMPT=' %{%F{{{ANSI_OK}}}%}•%{%f%} '
  RPROMPT=''
  zle reset-prompt
  # Restore for next command
  PROMPT="$_caramel_saved_prompt"
  RPROMPT="$_caramel_saved_rprompt"
  zle accept-line
}

zle -N _caramel_accept_line
bindkey '^M' _caramel_accept_line
