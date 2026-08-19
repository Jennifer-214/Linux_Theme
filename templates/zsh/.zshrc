[[ -o interactive ]] || return

# ─── Shell options ────────────────────────────
setopt correct
setopt NO_CLOBBER
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt EXTENDED_HISTORY
setopt SHARE_HISTORY
setopt HIST_REDUCE_BLANKS
typeset -U path PATH

# ─── History ─────────────────────────────────
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
# Secret scrub — preexec hook + HISTORY_IGNORE pattern keep passwords /
# API tokens / private keys out of ~/.zsh_history. Sourced from shared/.
[[ -r "$HOME/.config/zsh/history-scrub.zsh" ]] && source "$HOME/.config/zsh/history-scrub.zsh"

# ─── Environment ──────────────────────────────
export QT_QPA_PLATFORMTHEME=qt5ct

# Use seahorse's GTK ssh-askpass so the prompt picks up the FoxML GTK theme
# instead of the bright-blue x11-ssh-askpass dialog. SSH_ASKPASS_REQUIRE=prefer
# forces ssh to use the GUI even when a TTY is available.
if [[ -x /usr/lib/seahorse/ssh-askpass ]]; then
    export SSH_ASKPASS=/usr/lib/seahorse/ssh-askpass
    export SSH_ASKPASS_REQUIRE=prefer
fi
# FoxML SSH Keyring Integration
# GNOME Keyring usually starts via Hyprland exec-once, but we ensure 
# the shell is correctly linked to the socket.
if [[ -z "$SSH_AUTH_SOCK" ]]; then
    if [[ -S "$XDG_RUNTIME_DIR/keyring/ssh" ]]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/keyring/ssh"
    elif [[ -S "$HOME/.cache/keyring/ssh" ]]; then
        export SSH_AUTH_SOCK="$HOME/.cache/keyring/ssh"
    else
        # Fallback: try to start it if missing (useful for remote SSH sessions)
        eval $(gnome-keyring-daemon --start --components=ssh 2>/dev/null)
        export SSH_AUTH_SOCK
    fi
fi

# ─── Oh My Zsh ────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="caramel"
# NOTE: zsh-syntax-highlighting + zsh-autosuggestions are intentionally NOT here —
# they wrap ZLE widgets and must load AFTER fzf-tab, so they're sourced manually
# near the end of this file (see the fzf-tab section). Order is load-bearing.
plugins=(git zsh-completions vi-mode)
source "$ZSH/oh-my-zsh.sh"

# ─── Autosuggestions style ────────────────────
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#{{ZSH_SUGGEST}}'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)

# ─── Config (sourced after omz so plugins are loaded) ─
ZSHCONF="$HOME/.config/zsh"
source "$ZSHCONF/colors.zsh"
source "$ZSHCONF/aliases.zsh"
source "$ZSHCONF/git.zsh"
source "$ZSHCONF/paths.zsh"
source "$ZSHCONF/conda.zsh"
source "$ZSHCONF/welcome.zsh"

# ─── Completion styling ───────────────────────
# (no `menu select` — fzf-tab supersedes the built-in completion menu)
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{{{ANSI_ACCENT1}}}── %d ──%f'
zstyle ':completion:*:warnings' format '%F{{{ANSI_ERROR}}}no matches%f'
zstyle ':completion:*:default' list-prompt '%F{{{ANSI_ACCENT1}}}%l%f'
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' squeeze-slashes {{SHOW_WELCOME}}

# ─── Colored man pages ───────────────────────
# Uses bat with the FoxML palette to highlight manual pages.
# Zero bloat: replaces the 8+ LESS_TERMCAP lines with one robust pager command.
export MANPAGER="sh -c 'col -bx | bat -l man -p'"

# ─── fzf ──────────────────────────────────────
source /usr/share/fzf/key-bindings.zsh
FZF_COMPLETION_TRIGGER=''
source /usr/share/fzf/completion.zsh
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS="
  --color=bg+:#{{SELECTION}},bg:-1,preview-bg:-1,fg:#{{FG}},fg+:#{{FG}}
  --color=hl:#{{FZF_ACCENT1}},hl+:#{{PRIMARY}},info:#{{FZF_ACCENT1}},marker:#{{PRIMARY}}
  --color=prompt:#{{PRIMARY}},spinner:#{{FZF_ACCENT1}},pointer:#{{PRIMARY}},header:#{{FZF_ACCENT1}}
  --color=border:#{{PRIMARY}}
  --border=sharp --prompt='❯ ' --pointer='◆' --marker='●'
  --preview='bat --color=always --style=numbers --line-range=:200 {} 2>/dev/null || eza --icons --color=always {}'
  --preview-window=right:50%:hidden --bind='ctrl-/:toggle-preview,ctrl-h:abort,ctrl-j:down,ctrl-k:up,ctrl-l:accept'
"

# ─── fzf-tab + widget-wrapping plugins (ORDER-SENSITIVE) ──
# Must be: compinit (omz) → fzf → fzf-tab → autosuggestions → syntax-highlighting (last).
# fzf-tab wraps the completion widget; autosuggest/syntax-hl wrap others and must follow.
source "$ZSH/custom/plugins/fzf-tab/fzf-tab.plugin.zsh"
source "$ZSHCONF/fzf-tab.zsh"
source "$ZSH/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "$ZSH/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# ─── zoxide (smarter cd) ──────────────────────
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"

# ─── Auto-attach tmux ─────────────────────────
if [[ -z "$TMUX" && -z "$VSCODE_TERMINAL" && -z "$INTELLIJ_ENVIRONMENT_READER" && $- == *i* ]]; then
  tmux attach -t main || tmux new -s main
fi
