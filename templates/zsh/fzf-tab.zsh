# fzf-tab — fuzzy, preview-driven completion menu.
#
# Sourced from .zshrc AFTER compinit + fzf, BEFORE zsh-autosuggestions /
# zsh-syntax-highlighting (they wrap ZLE widgets; fzf-tab must wrap first).
# Colors INHERIT the palette-tokenized FZF_DEFAULT_OPTS, so this file carries
# no hardcoded hex ([I-07]) and recolors on a theme swap for free.

zstyle ':fzf-tab:*' use-fzf-default-opts yes
# FZF_DEFAULT_OPTS hides the preview by default (:hidden); the whole point of
# fzf-tab is the preview, so un-hide it here.
zstyle ':fzf-tab:*' fzf-flags --preview-window=right:55%:wrap

# Floating warm popup in tmux (matches the warm transparent-popup aesthetic).
# Inline alternative ("still in the terminal"): comment out the next line.
zstyle ':fzf-tab:*' fzf-command ftb-tmux-popup
zstyle ':fzf-tab:*' popup-min-size 50 8

# Reuse the ◆ marker from the rest of the UI; descend dirs with /, switch groups with [ ].
zstyle ':fzf-tab:*' prefix '◆ '
zstyle ':fzf-tab:*' continuous-trigger '/'
zstyle ':fzf-tab:*' switch-group '[' ']'

# ── Previews ──
# cd / directories → eza listing (icons, dirs first), matching the rest of the theme.
zstyle ':fzf-tab:complete:cd:*' fzf-preview \
  'eza -1a --color=always --icons --group-directories-first -- "$realpath"'
# everything else → bat for files, eza for dirs.
zstyle ':fzf-tab:complete:*:*' fzf-preview \
  '[[ -d "$realpath" ]] && eza -1a --color=always --icons -- "$realpath" \
   || bat --color=always --style=numbers --line-range=:300 -- "$realpath" 2>/dev/null \
   || echo "$realpath"'
# git refs → recent log of the ref under the cursor.
zstyle ':fzf-tab:complete:git-(checkout|switch|show|diff|rebase|merge):*' fzf-preview \
  'git log --oneline --color=always -20 "$word" 2>/dev/null || git log --oneline --color=always -20 2>/dev/null'
