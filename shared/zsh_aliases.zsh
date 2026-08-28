# ─── Modern tool replacements ─────────────────
alias ls='eza --color=always --icons --group-directories-first'
alias ll='eza -lh --icons --group-directories-first --git --time-style=relative'
alias la='eza -lah --icons --group-directories-first --git --time-style=relative'
alias lt='eza -T --icons --level=2 --group-directories-first'
alias cat='bat --style=plain --paging=never'
alias catp='bat'
alias grep='grep --color=auto'

# ─── Navigation ───────────────────────────────
alias proj='cd ~/Projects/BlackNode'
alias docs='cd ~/Documents'
alias dl='cd ~/Downloads'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# ─── Editors (preserve theme for sudo) ───────
alias svim='sudoedit'
alias snvim='sudo -E nvim'

# ─── Utilities ────────────────────────────────
alias myip='curl ifconfig.me'
alias sizeof='du -sh'
alias ports='ss -tulnp'
alias psg='ps aux | grep -v grep | grep -i'
alias cls='clear'
alias dashboard="~/dashboard.sh"
alias dtop='ssh desktop'
alias lock='sudo systemctl restart greetd'
alias stop='systemd-inhibit --what=idle:sleep:handle-lid-switch --why="Training models" tail -f /dev/null'
alias trade='systemd-inhibit --what=idle:sleep:handle-lid-switch --why="Trading" ./engine'

# ─── Clipboard (Terminal) ────────────────────
alias cb='cliphist list | fzf --height=40% --border --prompt="clipboard > " | cliphist decode | wl-copy'

# ─── LLM / AI ────────────────────────────────
alias @recall='~/.contextai/src/recall_with_context.sh'
alias flush='~/.contextai/src/flush_llm_cache.sh'

# Natural Language to Bash (e.g. ?? "find all jpg files")
# Quoted name + `function` keyword — zsh treats bare ?? as a glob pattern
# (matches any 2-char filename) and errors with "no matches found" while
# sourcing if it can't be expanded against the cwd.
function '??'() {
  local prompt="$*"
  local model="qwen2.5-coder:7b"
  echo "Thinking..."
  local cmd=$(ollama run "$model" "Return ONLY the linux command (no explanation, no markdown) to do the following: $prompt")
  echo -e "\n\033[1;32m$cmd\033[0m\n"
  read -p "Run this command? [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    eval "$cmd"
  fi
}

# FoxML AI Tool Wrappers
opencode() {
  if ! systemctl is-active --quiet ollama; then
    echo -e "\033[1;33m[Fox Brain is asleep. Waking up for OpenCode...]\033[0m"
    sudo systemctl start ollama
    sleep 2
  fi
  command opencode "$@"
}

# FoxML short-hand
alias fask='fask'
alias findex='findex'
alias fcommit='fox-ai-commit'
alias fstatus='fox-ai-status'
alias ffind='fox-ai-find'
alias flog='fox-ai-log'
alias fpurge='fox-ai-purge'
alias fquick='fox-ai-quick'
alias fswap='fox-ai-swap'
alias fproject='fox-new-project'
alias fbench='fox-ai-bench'
alias fdistro='fox-distro-guide'
alias fbuild='fox-distro-build'
alias fflash='fox-distro-flash'
alias fhelp='fhelp'
alias fwc='fox-word-count'
alias word-count='fox-word-count'
alias f-on='sudo systemctl start ollama && echo "🦊 Fox Brain is online."'
alias f-off='sudo systemctl stop ollama && echo "🦊 Fox Brain is offline."'

# ─── Functions ────────────────────────────────
give() {
  echo "Yeeting $1 to desktop.."
  rsync -avP "$1" Jennifer@100.113.148.120:~/
}

grab() {
  echo "Grabbing $1 from desktop..."
  rsync -avP Jennifer@100.113.148.120:~/"$1" .
}

pdf() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: pdf <file.pdf>"
    return 1
  fi

  local pdf_file="$1"

  if [[ ! -f "$pdf_file" ]]; then
    echo "pdf: no such file: $pdf_file"
    return 1
  fi

  pdftotext "$pdf_file" - | less -R
}

gpp() {
  if [[ -z "$1" ]]; then
    echo "Usage: gpp file.cpp"
    return 1
  fi

  local src="$1"
  local out="${src%.cpp}"
  local extra=()

  # Auto-link libraries the source actually includes.
  if grep -qE '#include *<(SDL2/|SDL\.h>)' "$src"; then
    extra+=(${=$(pkg-config --cflags --libs sdl2)})
  fi

  echo "Compiling your questionable code..."
  g++ -std=c++17 -Wall -Wextra -O2 "$src" -o "$out" "${extra[@]}"
}

# ─────────────────────────────────────────
# FoxML Utilities
# ─────────────────────────────────────────

# Border Telemetry Hooks
# Signals command start/finish to ~/.config/hypr/scripts/border_telemetry.sh
fox_preexec() { touch /tmp/fox_busy; }
fox_precmd() { [[ -f /tmp/fox_busy ]] && { rm -f /tmp/fox_busy; touch /tmp/fox_done; }; }
autoload -Uz add-zsh-hook
add-zsh-hook preexec fox_preexec
add-zsh-hook precmd fox_precmd

# System maintenance helper
fox-clean() {
    echo "🦊 Starting FoxML System Cleanup..."
    
    echo -e "\n[1/4] Cleaning pacman cache (keeping last 2 versions)..."
    sudo paccache -rk2
    
    echo -e "\n[2/4] Removing orphan packages..."
    local orphans=$(pacman -Qtdq)
    if [[ -n "$orphans" ]]; then
        sudo pacman -Rns $orphans
    else
        echo "No orphans to remove."
    fi
    
    echo -e "\n[3/4] Vacuuming system logs (older than 7 days)..."
    sudo journalctl --vacuum-time=7d
    
    echo -e "\n[4/4] Clearing old cliphist entries (keeping last 100)..."
    cliphist list | head -n -100 | cliphist decode | cliphist delete
    
    echo -e "\n✨ Cleanup complete! Stay earthy."
}

# fox-fingerprint lives at ~/.local/bin/fox-fingerprint (deployed from
# shared/bin) and is also reachable as `fox sec fingerprint`. No alias —
# one here would shadow that safe wrapper with a PAM-editing script. All
# PAM wiring (sudo/greetd) is done by fox-install modules, never a helper.
