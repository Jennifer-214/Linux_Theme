# Foreground commands keep their original shell and status. Use fjob for captured output,
# background jobs, and a supervisor that outlives the agent that started it.
fjob() { command fox-work run -- "$@"; }

_foxml_work_preexec() {
    (( $+commands[fox-work] )) || return 0
    [[ $1 == ' '* || $1 == *'&' || $1 == *fox-work* || $1 == fjob\ * ]] && return 0
    if (( $+functions[zsh_history_scrub_preexec] )); then
        zsh_history_scrub_preexec "$1" || return 0
    fi
    typeset -g _foxml_work_id
    _foxml_work_id=$(command fox-work begin --root "$PWD" --pid "$$" --command "$1" 2>/dev/null)
    return 0
}
_foxml_work_precmd() {
    local work_exit=$?
    if [[ -n ${_foxml_work_id:-} ]]; then
        command fox-work finish --id "$_foxml_work_id" --exit "$work_exit" >/dev/null 2>&1
        _foxml_work_id=''
    fi
    # A nonzero precmd hook prevents later prompt hooks from running.
    return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _foxml_work_preexec
add-zsh-hook precmd _foxml_work_precmd
