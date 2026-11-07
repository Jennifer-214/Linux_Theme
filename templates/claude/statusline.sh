#!/usr/bin/env bash
# Claude Code status line, in the palette: model · context hearts · plan usage · branch · plan gate.
# Each run also leaves a small snapshot of the session for the bar pill and the drawer's Agents page,
# in $XDG_RUNTIME_DIR/foxml-claude/<session>.json (the hooks keep <session>.state beside it).
input="$(cat)"
command -v jq >/dev/null 2>&1 || { printf 'Claude\n'; exit 0; }
printf -v now '%(%s)T' -1

{ IFS= read -r fields; IFS= read -r snapshot; } < <(jq -r --arg pane "${TMUX_PANE:-}" --argjson now "$now" '
    def pct: if type == "number" then floor else null end;
    def limit(w): (.rate_limits[w] // {}) | {used: (.used_percentage | pct), resets: (.resets_at // null)};
    . as $in
    | {session: (.session_id // ""), name: (.session_name // ""), model: (.model.display_name // "Claude"),
       context: (.context_window.used_percentage | pct), five: limit("five_hour"), week: limit("seven_day"),
       cwd: (.workspace.current_dir // .cwd // ""), project: (.workspace.project_dir // ""), pane: $pane, epoch: $now}
    | ([.model, (.context // ""), (.five.used // ""), (.five.resets // ""), (.week.used // ""), (.week.resets // ""),
        .cwd, .project, .session] | map(tostring) | join("\u001f")),
      tojson' <<<"$input" 2>/dev/null)
IFS=$'\x1f' read -r model ctx five five_reset week week_reset dir project sid <<<"$fields"
model="${model:-Claude}"

if [[ -d "${XDG_RUNTIME_DIR:-}" && "$sid" =~ ^[A-Za-z0-9_-]{1,80}$ && -n "$snapshot" ]]; then
    out="$XDG_RUNTIME_DIR/foxml-claude"
    if ( umask 077; mkdir -p "$out" ); then
        tmp="$out/.$sid.json.$$"
        ( umask 077; printf '%s\n' "$snapshot" > "$tmp" ) && mv -f "$tmp" "$out/$sid.json"
    fi
fi

rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
INK="$(rgb {{FG_R}} {{FG_G}} {{FG_B}})"
DIM="$(rgb {{FG_DIM_R}} {{FG_DIM_G}} {{FG_DIM_B}})"
FAINT="$(rgb {{COMMENT_R}} {{COMMENT_G}} {{COMMENT_B}})"
HEART="$(rgb {{GARDEN_3_R}} {{GARDEN_3_G}} {{GARDEN_3_B}})"
BERRY="$(rgb {{GARDEN_4_R}} {{GARDEN_4_G}} {{GARDEN_4_B}})"
ACCENT="$(rgb {{WAYBAR_WS_ACTIVE_R}} {{WAYBAR_WS_ACTIVE_G}} {{WAYBAR_WS_ACTIVE_B}})"
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Each part is kept twice: coloured, and plain to measure the width.
parts=() plain=()
add() { parts+=("$1"); plain+=("$2"); }

add "$INK$model$RESET" "$model"

if [[ "$ctx" =~ ^[0-9]+$ ]]; then
    filled=$(( (ctx * 5 + 50) / 100 )); (( filled > 5 )) && filled=5
    colour="$HEART"; (( ctx >= 80 )) && colour="$BERRY"
    hearts="" bare=""
    for (( i = 0; i < 5; i++ )); do
        if (( i < filled )); then hearts+="$colour♥"; else hearts+="$FAINT♡"; fi
        bare+="♥"
    done
    add "$hearts $DIM$ctx%$RESET" "$bare $ctx%"
fi

# Plan usage turns berry from 80%, and then says when it resets.
usage() {
    local label="$1" used="$2" resets="$3" format="$4" when=""
    [[ "$used" =~ ^[0-9]+$ ]] || return 0
    if (( used >= 80 )); then
        [[ "$resets" =~ ^[0-9]+$ ]] && when="$(date -d "@$resets" "$format" 2>/dev/null)" && when=" (resets ${when,,})"
        add "$BERRY$BOLD$label $used%$when$RESET" "$label $used%$when"
    else
        add "$DIM$label $used%$RESET" "$label $used%"
    fi
}
usage "5h" "$five" "$five_reset" "+%-l%P"
usage "week" "$week" "$week_reset" "+%a"

if [[ -d "$dir" ]]; then
    branch="$(git --no-optional-locks -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)"
    [[ -n "$branch" ]] && add "$FAINT⎇ $branch$RESET" "⎇ $branch"
fi

# The plan-before-code gate, where a repo keeps one: open once this session's plan was approved.
if [[ -n "$sid" && -r "$project/.claude/.plan-approved" ]] && grep -q "^$sid " "$project/.claude/.plan-approved" 2>/dev/null; then
    add "${ACCENT}gate open$RESET" "gate open"
fi

# Narrow panes drop the branch first, then the week, then the five hours; the model and hearts stay.
width="${COLUMNS:-200}"
fits() {
    local total=0 i
    for i in "${!plain[@]}"; do [[ -n "${plain[$i]}" ]] && total=$(( total + ${#plain[$i]} + 3 )); done
    (( total <= width ))
}
for drop in "⎇ " "week " "5h "; do
    fits && break
    for i in "${!plain[@]}"; do
        [[ "${plain[$i]}" == "$drop"* ]] && { parts[$i]=""; plain[$i]=""; }
    done
done

line="" sep="$FAINT · $RESET"
for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    line+="${line:+$sep}$part"
done
printf '%s\n' "$line"
