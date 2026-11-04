# ─── Git workflow ────────────────────────────
# Complements omz git plugin (simple aliases like gst, ga, gd, gco, gp)
# These are multi-step workflow functions.

# The named format comes from the palette-rendered Git include.
alias gpaper='git log --graph --all --pretty=paper'

# Push current branch — auto-sets upstream on first push
gpush() {
  local branch=$(git branch --show-current 2>/dev/null)
  if [[ -z "$branch" ]]; then
    echo "gpush: not on a branch"
    return 1
  fi
  if git config "branch.$branch.remote" &>/dev/null; then
    git push "$@"
  else
    echo "First push — setting upstream → origin/$branch"
    git push -u origin "$branch" "$@"
  fi
}

# Create + switch to a new branch
gnew() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo -n "Branch name: "
    read name
    [[ -z "$name" ]] && return 1
  fi
  git switch -c "$name"
}

# Stage everything + commit in one shot
gsave() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: gsave <message>"
    return 1
  fi
  git add -A && git commit -m "$*"
}

# Quick WIP checkpoint with timestamp
gquick() {
  git add -A && git commit -m "wip: $(date +'%b %d %H:%M')"
}

# Undo last commit, keep changes staged
gundo() {
  echo "Undoing: $(git log -1 --oneline)"
  git reset --soft HEAD~1
}

# Amend staged changes into last commit (keeps message)
gamend() {
  git add -A && git commit --amend --no-edit
}

# fzf branch switcher — sorted by most recent
unalias gbr 2>/dev/null
gbr() {
  local branch=$(git branch --sort=-committerdate \
    --format='%(refname:short)  %(color:dim)%(committerdate:relative)%(color:reset)' \
    --color=always \
    | fzf --ansi --height=40% --border --prompt="branch > " \
    | awk '{print $1}')
  [[ -n "$branch" ]] && git switch "$branch"
}

# Show recent branches at a glance
grecent() {
  git branch --sort=-committerdate \
    --format='%(color:yellow)%(refname:short)%(color:reset)  %(committerdate:relative)' \
    --color=always | head -15
}

# Rebase current branch on latest main
gsync() {
  local main=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  [[ -z "$main" ]] && main="main"
  git fetch origin "$main" && git rebase "origin/$main"
}

# Delete local branches that are merged into main
unalias gclean 2>/dev/null
gclean() {
  local merged=$(git branch --merged main 2>/dev/null | grep -vE '^\*|^\s*main$')
  if [[ -z "$merged" ]]; then
    echo "Nothing to clean"
    return 0
  fi
  echo "$merged"
  echo -n "Delete these? [y/N] "
  read yn
  [[ "$yn" =~ ^[Yy]$ ]] && echo "$merged" | xargs git branch -d
}

# Named stash (no args = list stashes)
gstash() {
  if [[ $# -eq 0 ]]; then
    git stash list
  else
    git stash push -m "$*"
  fi
}

# Pop a stash with fzf
gpop() {
  local entry=$(git stash list | fzf --height=40% --border --prompt="stash > " | cut -d: -f1)
  [[ -n "$entry" ]] && git stash pop "$entry"
}

# Show what you've done today
gtoday() {
  git log --oneline --since="midnight" --author="$(git config user.name)"
}

# Diff what's staged (complements gd = git diff for unstaged)
unalias gds 2>/dev/null
gds() {
  git diff --staged "$@"
}
