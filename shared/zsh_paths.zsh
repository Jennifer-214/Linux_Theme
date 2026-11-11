# ─── PATH ────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/.opencode/bin" ]] && export PATH="$HOME/.opencode/bin:$PATH"
typeset -U path PATH

# ─── Linux_Theme Project Awareness ──────────────────
_fox_project_check() {
    if [[ -f "AGENT.md" || -d ".agent" ]]; then
        export FOXML_PROJECT_ROOT=$(pwd)
        export FOXML_PROJECT_NAME=$(basename $(pwd))
    else
        unset FOXML_PROJECT_ROOT
        unset FOXML_PROJECT_NAME
    fi
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _fox_project_check
_fox_project_check

# ─── tmux sessions named for their project ────
# A session tmux only numbered takes its project's name on the first cd into one (never a name you set).
_fox_tmux_name() { [[ -n "$TMUX" ]] && (( $+commands[tmux-name-session] )) && { tmux-name-session "$PWD" &! } 2>/dev/null }
add-zsh-hook chpwd _fox_tmux_name
_fox_tmux_name
