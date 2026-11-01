#!/usr/bin/env bash
# agent_rofi.sh — centered rofi triage list of pending AI agent notifications.
# Reads the JSONL queue written by agent_notify.sh, renders themed entries,
# hjkl navigation. Selecting an entry tmux-routes to the originating pane and
# removes the entry from the queue. The first item clears the whole queue.
#
# Permission prompts are still answered inside the agent's TUI — this is a
# "where is it?" router, not a remote-control panel.

set -u

ROFI_ZONE="${ROFI_ZONE:-center}"
# shellcheck source=/dev/null
source ~/.config/hypr/scripts/_rofi_zone.sh

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

queue_dir="${XDG_RUNTIME_DIR:-/tmp}"
queue_file="$queue_dir/foxml-agent-queue.jsonl"

if [[ ! -s "$queue_file" ]]; then
    rofi -e "No pending agent notifications" \
        -theme-str "$ROFI_POS_THEME"
    exit 0
fi

mapfile -t lines < "$queue_file"
total=${#lines[@]}

pango_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

entries=()
indices=()  # parallel: file line number (1-based) for each menu row; 0 = clear-all

entries+=("<span foreground=\"#${C_RED}\"></span>  Clear all (${total})")
indices+=("0")

if ! command -v fox-agent-parse >/dev/null 2>&1; then
    # Fallback to jq if C++ parser not built/installed yet
    mapfile -t parsed_lines < <(jq -R -r 'try (fromjson | [.source // "", .event // "", .project // "?", .tmux // "", .message // ""] | @tsv) catch ""' "$queue_file" 2>/dev/null)
else
    mapfile -t parsed_lines < <(fox-agent-parse "$queue_file" 2>/dev/null)
fi

for (( raw=total-1; raw>=0; raw-- )); do
    line="${lines[$raw]}"
    [[ -z "$line" ]] && continue

    IFS=$'\t' read -r src event project target msg <<< "${parsed_lines[$raw]:-}"

    project_e="$project"
    msg_e="$msg"
    target_e="$target"

    case "$src" in
        claude)   src_color="$C_PRIMARY";   src_label="Claude"   ;;
        gemini)   src_color="$C_ACCENT";    src_label="Gemini"   ;;
        opencode) src_color="$C_WARN";      src_label="OpenCode" ;;
        *)        src_color="$C_SECONDARY"; src_label="${src:-?}" ;;
    esac

    case "$event" in
        notification) ev_color="$C_RED";  ev_glyph="" ;;
        subagent)     ev_color="$C_WARN"; ev_glyph="" ;;
        stop|*)       ev_color="$C_OK";   ev_glyph="" ;;
    esac

    label="<span foreground=\"#${ev_color}\">${ev_glyph}</span>  <span foreground=\"#${src_color}\"><b>${src_label}</b></span> · ${project_e}"
    if [[ -n "$target_e" ]]; then
        label="${label}  <span foreground=\"#${C_SECONDARY}\" font_size=\"smaller\">[${target_e}]</span>"
    fi
    if [[ -n "$msg_e" ]]; then
        label="${label} — ${msg_e}"
    fi

    entries+=("$label")
    indices+=("$((raw + 1))")
done

chosen="$(printf '%s\n' "${entries[@]}" | \
    rofi -dmenu -i -no-custom -markup-rows -p "Agents" \
        -kb-row-up "k,Up" \
        -kb-row-down "j,Down" \
        -kb-accept-entry "l,Return" \
        -kb-cancel "Escape,h" \
        -theme-str "$ROFI_POS_THEME inputbar {enabled: false;} window {width: 50%;} listview {lines: 12;}" \
        -format 'i')"

[[ -z "$chosen" ]] && exit 0

idx="$chosen"
file_line="${indices[$idx]}"

if [[ "$file_line" == "0" ]]; then
    : > "$queue_file"
    exit 0
fi

chosen_line="${lines[$((file_line - 1))]}"
target="$(printf '%s' "$chosen_line" | jq -r '.tmux // ""' 2>/dev/null)"
cwd="$(printf '%s' "$chosen_line" | jq -r '.cwd // ""' 2>/dev/null)"

(
    flock -n 9 || flock 9
    sed -i "${file_line}d" "$queue_file"
) 9>"${queue_file}.lock"

# Route to the originating tmux pane.
if [[ -n "$target" ]] && command -v tmux >/dev/null 2>&1; then
    sess="${target%%:*}"
    rest="${target#*:}"
    win="${rest%%.*}"
    pane="${rest#*.}"

    if tmux has-session -t "$sess" 2>/dev/null; then
        tmux select-window -t "${sess}:${win}" 2>/dev/null || true
        tmux select-pane -t "${sess}:${win}.${pane}" 2>/dev/null || true

        if [[ -n "${TMUX:-}" ]]; then
            tmux switch-client -t "${sess}:${win}.${pane}" 2>/dev/null || true
        else
            # Outside tmux (Hyprland keybind): switch only the most recently 
            # active client to avoid hijacking every open terminal.
            target_tty=$(tmux list-clients -F '#{client_activity} #{client_tty}' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2)
            if [[ -n "$target_tty" ]]; then
                tmux switch-client -c "$target_tty" -t "${sess}:${win}.${pane}" 2>/dev/null
            fi

            if command -v hyprctl >/dev/null 2>&1; then
                fox-hl dispatch "hl.dsp.focus({ window = 'class:kitty' })" "focuswindow kitty" >/dev/null 2>&1 || true
            fi
        fi
    fi
elif [[ -n "$cwd" ]]; then
    notify-send -a "Agent" "Agent triage" "Working dir: $cwd" || true
fi

exit 0
