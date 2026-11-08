#!/usr/bin/env bash
# agent_notify.sh — themed notify-send + JSONL queue append for AI agent hooks.
# Invoked by Claude Code hooks. Reads hook payload JSON on stdin.
#
# Usage:
#   agent_notify.sh <source> <event>
#     <source>: claude
#     <event>:  stop | subagent | notification | asking | seen | toolran | started | compact | compacted | failed | ended
#               (seen: you replied in this pane, so its note is cleared — no popup; toolran: a tool ran,
#                so a "needs you" was answered and counts as seen;
#                started … ended only record what the session is doing, for the drawer)
#
# Theme: hex colors are sourced from ~/.config/hypr/modules/border_colors.sh
# (rendered by render.sh from the active palette), so a palette swap takes
# effect on the next hook fire — no need to re-run install.sh.

# Hooks must never surface a non-zero exit (Claude Code marks the turn with a
# red "stop hook error" banner if they do, even though the failure is harmless
# from the user's perspective). Trap any unexpected error and exit 0 with the
# real reason logged to a sidecar so we can debug without polluting the TUI.
#
# Runtime dir: prefer XDG_RUNTIME_DIR (systemd creates it 0700 per-user).
# Fall back to /tmp/foxml-$USER with explicit 0700 perms so AI payloads
# — which may contain code snippets, file paths, prompt content — don't
# end up world-readable on systems without XDG_RUNTIME_DIR.
if [[ -d "${XDG_RUNTIME_DIR:-}" ]]; then
    FOXML_RUNTIME_DIR="$XDG_RUNTIME_DIR"
else
    FOXML_RUNTIME_DIR="/tmp/foxml-$USER"
    mkdir -p "$FOXML_RUNTIME_DIR" 2>/dev/null
    chmod 700 "$FOXML_RUNTIME_DIR" 2>/dev/null
fi
LOG_FILE="$FOXML_RUNTIME_DIR/foxml-agent-notify.log"
# Lock down log perms even when in XDG_RUNTIME_DIR — defense in depth in
# case the dir mode ever drifts. umask handles the create-time perms.
( umask 077; : >> "$LOG_FILE" )
trap 'echo "[$(date -Iseconds)] $0 ${LINENO} ${BASH_COMMAND}" >> "$LOG_FILE" 2>/dev/null; exit 0' ERR

src="${1:-claude}"
event="${2:-stop}"

# Read hook payload (Claude passes JSON on stdin). Bounded read
# so this never wedges if a hook fires without piping anything.
input=""
if [[ ! -t 0 ]]; then
    input="$(timeout 0.2 cat 2>/dev/null || true)"
fi

# After each tool Claude runs (PostToolUse): a session marked "needs you" was answered, so it counts as
# seen again. Every tool call lands here, so anything else leaves at once, before any jq.
if [[ "$event" == "toolran" ]]; then
    [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,80})\" ]] || exit 0
    grep -q '"state":"needs"' "$FOXML_RUNTIME_DIR/foxml-claude/${BASH_REMATCH[1]}.state" 2>/dev/null || exit 0
    event="seen"
fi

# Theme palette (rendered hex strings, no leading '#').
if [[ -r "$HOME/.config/hypr/modules/border_colors.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.config/hypr/modules/border_colors.sh"
fi
C_PRIMARY="${C_PRIMARY:-c4956e}"
C_SECONDARY="${C_SECONDARY:-b8967a}"
C_ACCENT="${C_ACCENT:-8a9a7a}"
C_RED="${C_RED:-b05555}"
C_OK="${C_OK:-7aab88}"
C_WARN="${C_WARN:-c4b48a}"

# Pull a usable message + cwd out of whatever shape the payload is in.
msg=""
cwd=""
tool_name=""
if [[ -n "$input" ]] && command -v jq >/dev/null 2>&1; then
    msg="$(printf '%s' "$input" | jq -r '
        .message //
        .subagent.description //
        .description //
        empty
    ' 2>/dev/null)" || msg=""
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
    tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || tool_name=""
    session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)" || session_id=""
    trigger="$(printf '%s' "$input" | jq -r '.trigger // .error // .source // empty' 2>/dev/null)" || trigger=""
    session_name="$(printf '%s' "$input" | jq -r '.session_title // empty | gsub("[[:cntrl:]]"; " ") | .[0:80]' 2>/dev/null)" || session_name=""
fi

# Idle pings — Claude Code fires Notification hooks for
# real permission prompts ("Claude needs your permission to use Bash") AND
# for after-N-seconds "waiting for your input" idle reminders. The idle
# variant is noise during multi-pane work — same critical urgency as a
# real prompt, but no action is required. Drop them at the source so they
# don't notify or land in the rofi triage queue.
if [[ "$event" == "notification" ]]; then
    msg_lower="${msg,,}"
    case "$msg_lower" in
        *"waiting for your input"*|*"waiting for input"*|*"waiting for user input"*)
            exit 0
            ;;
    esac
fi

[[ -z "$cwd" ]] && cwd="$PWD"
project="$(basename "$cwd" 2>/dev/null)"
[[ -z "$project" ]] && project="?"

# tmux target — populated when the hook is invoked from inside a tmux pane,
# which is the common case (claude runs in a tmux pane). Format S:W.P.
# $TMUX_PANE names the hook's own pane; a bare display-message would name
# whichever pane the client has active, which is often a different one.
tmux_target=""
tmux_pane=""
if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    tmux_pane="$TMUX_PANE"
    tmux_target="$(tmux display-message -p -t "$tmux_pane" '#S:#I.#P' 2>/dev/null || true)"
fi

# The triage queue (JSONL), shared with the drawer under the same flock.
queue_file="$FOXML_RUNTIME_DIR/foxml-agent-queue.jsonl"
# A pane's newest note replaces its older ones, and notes older than twelve hours go.
# Rewrites the queue without them; unreadable lines are dropped, never fatal.
# Callers hold the lock.
prune_queue() {
    [[ -s "$queue_file" ]] && command -v jq >/dev/null 2>&1 || return 0
    local cutoff tmp
    cutoff=$(( $(date +%s) - 12 * 3600 ))
    tmp="$(umask 077; mktemp "${queue_file}.XXXXXX")" || return 0
    if jq -cR --arg pane "$tmux_pane" --arg target "$tmux_target" --argjson cutoff "$cutoff" '
        fromjson? | select(type == "object")
        | select(((.epoch // $cutoff) >= $cutoff)
                 and (if $pane != "" and (.pane // "") == $pane then false
                      elif $target != "" and (.pane // "") == "" and (.tmux // "") == $target then false
                      else true end))' "$queue_file" > "$tmp" 2>>"$LOG_FILE"; then
        mv -f "$tmp" "$queue_file"
    else
        rm -f "$tmp"
    fi
}

# What each Claude session is doing, for the bar pill and the drawer: one small
# file per session beside the status line's own snapshot. Ended sessions leave none.
session_dir="$FOXML_RUNTIME_DIR/foxml-claude"
record_state() {
    [[ "$src" == "claude" && "$session_id" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    ( umask 077; mkdir -p "$session_dir" ) || return 0
    local file="$session_dir/$session_id.state" tmp name="${session_name:-}"
    # Not every event carries the title Claude Code gave the session; keep the last one.
    [[ -z "$name" && -r "$file" ]] && name="$(jq -r '.title // empty' "$file" 2>/dev/null)"
    tmp="$(umask 077; mktemp "$file.XXXXXX")" || return 0
    local epoch; epoch="$(date +%s)"
    if jq -cn --arg state "$1" --arg detail "${2:-}" --arg pane "$tmux_pane" --arg cwd "$cwd" \
            --arg title "$name" --argjson epoch "$epoch" \
            '{state:$state, detail:$detail, pane:$pane, cwd:$cwd, epoch:$epoch}
             + (if $title == "" then {} else {title:$title} end)' > "$tmp" 2>>"$LOG_FILE"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
    # Today's tally: one line per change, so the drawer can add up the time spent working.
    ( umask 077; printf '%s %s %s\n' "$session_id" "$1" "$epoch" >> "$session_dir/tally-$(date +%F)" ) 2>/dev/null
}
case "$event" in
    seen)         record_state working ;;
    # A new session counts at once; one restarted by a compaction is the compacted event's to say.
    started)
        [[ "$trigger" == "compact" ]] && exit 0
        record_state waiting
        find "$session_dir" -maxdepth 1 -name 'tally-*' ! -name "tally-$(date +%F)" -delete 2>/dev/null
        exit 0 ;;
    stop)         record_state waiting ;;
    notification) record_state needs ;;
    # The permission dialog just opened (PermissionRequest): mark it at once, quietly. The popup and the note
    # still come with the Notification hook, after its delay, if the dialog is still waiting by then.
    asking)       record_state needs; exit 0 ;;
    compact)      record_state compacting; exit 0 ;;
    # "fresh": the context was just tidied, so the status line sparkles for a moment.
    compacted)    if [[ "$trigger" == "manual" ]]; then record_state waiting fresh; else record_state working fresh; fi; exit 0 ;;
    failed)       record_state error "$trigger"; exit 0 ;;
    ended)
        [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || exit 0
        rm -f "$session_dir/$session_id.state" "$session_dir/$session_id.json"
        [[ -d "$session_dir" ]] && ( umask 077; printf '%s ended %s\n' "$session_id" "$(date +%s)" >> "$session_dir/tally-$(date +%F)" ) 2>/dev/null
        exit 0 ;;
esac

# You answered this pane: its note is done. Says nothing on stdout, because a
# UserPromptSubmit hook's output is handed to the agent as context.
if [[ "$event" == "seen" ]]; then
    [[ -n "$tmux_pane" || -n "$tmux_target" ]] || exit 0
    (
        flock -w 2 9 || exit 0
        prune_queue
    ) 9>"${queue_file}.lock"
    exit 0
fi

case "$src" in
    claude)   src_label="Claude";   src_color="$C_PRIMARY" ;;
    opencode) src_label="OpenCode"; src_color="$C_WARN"    ;;
    *)        src_label="$src";     src_color="$C_PRIMARY" ;;
esac

case "$event" in
    notification)
        urgency="critical"
        title="$src_label needs input · $project"
        body_text="${msg:-Awaiting your decision}"
        body_color="$C_RED"
        ;;
    subagent)
        urgency="normal"
        title="$src_label subagent · $project"
        body_text="${msg:-Subagent finished}"
        body_color="$C_WARN"
        ;;
    stop|*)
        urgency="low"
        title="$src_label · $project"
        body_text="${msg:-Turn complete — ready for next message}"
        body_color="$src_color"
        ;;
esac

# Pango-escape user-controlled strings before splicing into markup.
pango_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
esc_body="$(pango_escape "$body_text")"
esc_target="$(pango_escape "$tmux_target")"

body="<span foreground=\"#${body_color}\">${esc_body}</span>"
if [[ -n "$tmux_target" ]]; then
    body="${body}
<span foreground=\"#${C_SECONDARY}\" font_size=\"smaller\">tmux: ${esc_target}</span>"
fi

# Notification: -a sets app-name (mako/dunst route on this). Stderr is
# swallowed so a transient D-Bus issue (e.g. agent started outside the
# graphical session) doesn't paint a hook error in the TUI; details land
# in $LOG_FILE if you need them.
if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "$src_label" -u "$urgency" -i dialog-information \
        "$title" "$body" 2>>"$LOG_FILE" || true
fi

# Blocking events (the agent is waiting on a decision) get an extra BEL
# to the controlling terminal. Kitty translates BEL into an xdg_activation
# request when window_alert_on_bell=yes, which Hyprland surfaces as the
# .urgent class on the workspace — waybar lights it red+bold so the user
# can find the waiting pane from any workspace. Audio bell is disabled in
# kitty.conf so this is silent. stop/subagent events are not "blocking"
# in the same sense, so they get the popup only.
if [[ "$event" == "notification" ]]; then
    printf '\a' > /dev/tty 2>/dev/null || true
fi

# Append to the triage queue (JSONL). flock serializes concurrent appends
# from multiple panes. Uses the same FOXML_RUNTIME_DIR computed above so
# the queue file isn't world-readable on /tmp-fallback systems.
( umask 077; : >> "$queue_file" )

if command -v jq >/dev/null 2>&1; then
    entry="$(jq -cn \
        --arg ts "$(date -Iseconds)" \
        --argjson epoch "$(date +%s)" \
        --arg pane "$tmux_pane" \
        --arg src "$src" \
        --arg event "$event" \
        --arg project "$project" \
        --arg cwd "$cwd" \
        --arg target "$tmux_target" \
        --arg msg "$body_text" \
        --arg urgency "$urgency" \
        '{ts:$ts, epoch:$epoch, source:$src, event:$event, project:$project, cwd:$cwd, tmux:$target, pane:$pane, message:$msg, urgency:$urgency}' \
        2>/dev/null)" || entry=""
    if [[ -n "$entry" ]]; then
        (
            flock -n 9 || flock 9
            prune_queue
            printf '%s\n' "$entry" >> "$queue_file"
        ) 9>"${queue_file}.lock"
    fi
fi

exit 0
