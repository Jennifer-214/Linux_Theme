# ╭──────────────────────────────────────────────╮
# │          Fox ML — caramel zsh theme          │
# ╰──────────────────────────────────────────────╯
# Palette: peach({{ANSI_ACCENT1}}) pink({{ANSI_ACCENT1}},{{ANSI_ACCENT1}}) mauve({{ANSI_ACCENT2}}) lavender({{ANSI_ACCENT5}},141)

# ─── Config ──────────────────────────────────────
CARAMEL_CMD_THRESHOLD=${CARAMEL_CMD_THRESHOLD:-3}
CARAMEL_DONE_AFTER=${CARAMEL_DONE_AFTER:-30}   # done note: a command at least this long (s)
typeset -gi _caramel_paper=0
[[ "{{LITTLE_DETAILS}}" == fox-little-details-on ]] && _caramel_paper=1

# ─── Timer (tracks command execution time) ─────

_caramel_timer_start=0

function caramel_preexec() {
  zmodload -F zsh/datetime p:EPOCHREALTIME
  _caramel_timer_start=${EPOCHREALTIME}
  # The command's name for the done note: skip sudo/env-style prefixes, flags, their
  # numbers and VAR=x assignments, and never keep the arguments (they can hold secrets).
  # $1 is the typed line; it's empty when history is off, so fall back to $2.
  local -a w=(${(z)${1:-$2}})
  while (( $#w )) && [[ $w[1] == (sudo|doas|time|nohup|nice|env|command|builtin|exec|noglob|-*|*=*|<->) ]]; do
    shift w
  done
  _caramel_cmd_name=${w[1]:t}
}

add-zsh-hook preexec caramel_preexec

# ─── Done note (little details) ─────────────────
# A ✿ notification when a long command succeeds while you're looking at another
# window. No note when this terminal (or, in tmux, this pane) is on screen.

function _caramel_done_note() {
  [[ "{{LITTLE_DETAILS}}" == fox-little-details-on ]] || return
  [[ -z $SSH_CONNECTION && -n $HYPRLAND_INSTANCE_SIGNATURE ]] || return
  (( $+commands[notify-send] && $+commands[hyprctl] )) || return
  [[ $(hyprctl -j activewindow 2>/dev/null) =~ '"pid": ([0-9]+)' ]] || return
  local apid=$match[1] pid=$$ st
  if [[ -n $TMUX ]]; then
    pid=0
    [[ $(tmux display-message -p -t "$TMUX_PANE" '#{window_active}#{pane_active}' 2>/dev/null) == 11 ]] \
      && pid=$(tmux display-message -p '#{client_pid}' 2>/dev/null)
  fi
  while (( pid > 1 )); do
    (( pid == apid )) && return
    [[ -r /proc/$pid/stat ]] || break
    st=$(</proc/$pid/stat)
    st=${st##*\) }
    pid=${${(s: :)st}[2]}
  done
  ( notify-send -a fox-done -u low "✿ done" "${_caramel_cmd_name:-command} · $(fmt_elapsed $1)" >/dev/null 2>&1 & )
}

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
  if (( _caramel_paper )); then
    local parent="" leaf="$raw"
    if [[ "$raw" == */* && "$raw" != / ]]; then
      parent="${raw%/*}/"
      leaf="${raw##*/}"
    fi
    # Percent signs in directory names are text, never prompt escapes.
    parent=${parent//\%/%%}
    leaf=${leaf//\%/%%}
    print -r -- "%F{#{{COMMENT}}}${parent}%f%K{#{{SELECTION}}}%F{#{{FG}}}%B ${leaf} %b%f%k"
    return
  fi
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
if (( _caramel_paper )); then
  ZSH_THEME_GIT_PROMPT_PREFIX=" %F{#{{COMMENT}}} %F{#{{FG}}}"
  ZSH_THEME_GIT_PROMPT_SUFFIX="%f"
  ZSH_THEME_GIT_PROMPT_DIRTY=" %F{#{{WARN}}}✎%f"
  ZSH_THEME_GIT_PROMPT_CLEAN=""
fi

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
    (( exit_code == 0 && elapsed_int >= CARAMEL_DONE_AFTER )) && _caramel_done_note $elapsed_int
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
  if (( _caramel_paper )); then
    CARAMEL_HOST="%F{#{{FG_DIM}}}%n@%m%f"
    if (( exit_code == 0 )); then
      PROMPT_INDICATOR="%F{#{{FG}}}❯%f"
    else
      PROMPT_INDICATOR="%{${_fox_err}%}❯ ${exit_code}%f"
    fi
    [[ -n "$ELAPSED_PROMPT" ]] && ELAPSED_PROMPT=" %F{#{{COMMENT}}}· $(fmt_elapsed $elapsed_int)%f"
    VENV_PROMPT=""
    if [[ -n "$CONDA_DEFAULT_ENV" && "$CONDA_DEFAULT_ENV" != base ]]; then
      VENV_PROMPT=" %F{#{{COMMENT}}}(${${CONDA_DEFAULT_ENV:t}//\%/%%})%f"
    elif [[ -n "$VIRTUAL_ENV" ]]; then
      VENV_PROMPT=" %F{#{{COMMENT}}}(${${VIRTUAL_ENV:t}//\%/%%})%f"
    fi
    # user@host already names the remote host; avoid printing it a second time.
    [[ -n "$SSH_PROMPT" ]] && SSH_PROMPT="%F{#{{COMMENT}}}ssh%f "
    [[ -n "$JOBS_PROMPT" ]] && JOBS_PROMPT=" %F{#{{COMMENT}}}&${njobs}%f"
  fi
  return 0
}

add-zsh-hook precmd caramel_precmd

# ─── Prompt layout ──────────────────────────────
# Line 1:  user@host  path  git  venv  jobs  elapsed
# Line 2:  ❯ (peach = ok, red + exit code = fail)
# Right:   timestamp (dimmed)

setopt PROMPT_SUBST
PROMPT='
 ${SSH_PROMPT}${CARAMEL_HOST} ${CARAMEL_PATH}$(git_prompt_info)${VENV_PROMPT}${JOBS_PROMPT}${ELAPSED_PROMPT}
 ${PROMPT_INDICATOR} '

RPROMPT='%{%F{{{ANSI_ACCENT1}}}%}%*%{%f%}'
(( _caramel_paper )) && RPROMPT='%F{#{{COMMENT}}}%*%f'
(( _caramel_paper )) && PROMPT2=' %F{#{{COMMENT}}}↳ %_%f '

# ─── Transient prompt (collapse after enter) ──

function _caramel_accept_line() {
  # Save the full prompt, replace with minimal
  _caramel_saved_prompt="$PROMPT"
  _caramel_saved_rprompt="$RPROMPT"
  PROMPT=' %{%F{{{ANSI_OK}}}%}•%{%f%} '
  (( _caramel_paper )) && PROMPT=' %F{#{{COMMENT}}}·%f '
  RPROMPT=''
  zle reset-prompt
  # Restore for next command
  PROMPT="$_caramel_saved_prompt"
  RPROMPT="$_caramel_saved_rprompt"
  zle accept-line
}

zle -N _caramel_accept_line
bindkey '^M' _caramel_accept_line
