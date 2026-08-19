#!/usr/bin/env bash
# fox-monitor-watch — react to monitor hot-swap (dock/undock).
#
# Listens on Hyprland's socket2 for monitoradded / monitorremoved events.
# On change:
#   1. Re-derive MONITOR_RESOLUTIONS, PORTRAIT_OUTPUTS, SECONDARY_OUTPUTS
#      from `hyprctl monitors -j`. PRIMARY is preserved from the existing
#      sidecar — the user's choice from configure_monitors is sticky.
#   2. Update ~/.config/foxml/monitor-layout.conf in place.
#   3. Re-run _generate_per_monitor_wallpapers, _personalize_hyprlock,
#      _personalize_workspace_rules from mappings.sh.
#   4. Fire rotate_wallpaper.sh so awww applies the matching variants.
#
# Hot-swap events fire in bursts (4-6 within ~1s on dock connect). A 2s
# debounce window coalesces them into one re-render.
#
# Idempotent — repeated firing with no actual change is a cheap no-op.

set -u

SIDECAR="$HOME/.config/foxml/monitor-layout.conf"
SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
DEBOUNCE_SECONDS=2

# FOXML_DIR resolution. Order:
#   1. Explicit env override (FOXML_DIR=…)
#   2. Cached path from a prior install at ~/.config/foxml/install.conf
#   3. Walk up from the running script's symlink-resolved location
#      (handles `~/.config/hypr/scripts/` install AND repo-local invocation)
#   4. Common conventional locations as a last resort
# Hardcoding $HOME/code/Linux_Theme would silently break for any user
# who clones elsewhere — this script is the multi-monitor hot-swap
# nerve so a wrong path means the dock event drops on the floor.
_resolve_foxml_dir() {
    [[ -n "${FOXML_DIR:-}" ]] && return 0

    # install.sh writes script_dir=… to ~/.local/share/foxml/.installed-version
    # on every successful install — that's the authoritative location.
    local marker="$HOME/.local/share/foxml/.installed-version"
    if [[ -f "$marker" ]]; then
        local cached
        cached=$(awk -F= '/^script_dir=/{gsub(/"/, "", $2); print $2; exit}' "$marker")
        if [[ -n "$cached" && -f "$cached/mappings.sh" ]]; then
            FOXML_DIR="$cached"; return 0
        fi
    fi

    local self
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    local dir="$(dirname "$self")"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/mappings.sh" && -f "$dir/install.sh" ]]; then
            FOXML_DIR="$dir"; return 0
        fi
        dir="$(dirname "$dir")"
    done

    for candidate in "$HOME/code/Linux_Theme" "$HOME/code/FoxML_Workstation" "$HOME/Linux_Theme" "$HOME/FoxML_Workstation" "$HOME/.local/share/FoxML_Workstation"; do
        if [[ -f "$candidate/mappings.sh" ]]; then
            FOXML_DIR="$candidate"; return 0
        fi
    done
    return 1
}
_resolve_foxml_dir || FOXML_DIR="${FOXML_DIR:-/nonexistent}"

if [[ ! -S "$SOCKET" ]]; then
    echo "fox-monitor-watch: no Hyprland socket at $SOCKET" >&2
    exit 1
fi
command -v socat   >/dev/null 2>&1 || { echo "fox-monitor-watch: socat required"      >&2; exit 1; }
command -v hyprctl >/dev/null 2>&1 || { echo "fox-monitor-watch: hyprctl required"    >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "fox-monitor-watch: jq required"         >&2; exit 1; }
if [[ ! -f "$FOXML_DIR/mappings.sh" ]]; then
    echo "fox-monitor-watch: mappings.sh not found at $FOXML_DIR — set FOXML_DIR" >&2
    exit 1
fi

# Re-derive sidecar fields from current hyprctl state. Effective WxH
# accounts for transform (1/3 = 90°/270° → swap). PRIMARY is preserved
# from the existing sidecar so the user's pick from configure_monitors
# isn't clobbered by hot-swap.
rederive_sidecar() {
    local primary=""
    if [[ -f "$SIDECAR" ]]; then
        primary=$(awk -F'"' '/^PRIMARY=/{print $2; exit}' "$SIDECAR")
    fi

    local monitors_json
    monitors_json=$(hyprctl monitors -j 2>/dev/null) || return 1
    [[ -z "$monitors_json" || "$monitors_json" == "[]" ]] && return 1

    # If the recorded PRIMARY is no longer present (e.g. external died and
    # external was the primary), fall back to whatever Hyprland reports
    # first. Keeps the sidecar self-consistent rather than referencing a
    # ghost monitor.
    if [[ -z "$primary" ]] || ! echo "$monitors_json" | jq -e --arg p "$primary" '.[] | select(.name==$p)' >/dev/null; then
        primary=$(echo "$monitors_json" | jq -r '.[0].name')
    fi

    local resolutions portrait secondary
    resolutions=$(echo "$monitors_json" | jq -r '
        .[] |
        if (.transform == 1 or .transform == 3)
        then "\(.name):\(.height)x\(.width)"
        else "\(.name):\(.width)x\(.height)"
        end' | tr '\n' ' ' | sed 's/ *$//')
    portrait=$(echo "$monitors_json" | jq -r '
        .[] | select(.transform == 1 or .transform == 3) | .name
    ' | tr '\n' ' ' | sed 's/ *$//')
    secondary=$(echo "$monitors_json" | jq -r --arg p "$primary" '
        .[] | select(.name != $p) | .name
    ' | tr '\n' ' ' | sed 's/ *$//')

    mkdir -p "$(dirname "$SIDECAR")"
    {
        echo "# Auto-generated by fox-monitor-watch (hot-swap)"
        echo "PRIMARY=\"${primary}\""
        echo "PORTRAIT_OUTPUTS=\"${portrait}\""
        echo "SECONDARY_OUTPUTS=\"${secondary}\""
        echo "MONITOR_RESOLUTIONS=\"${resolutions}\""
    } > "$SIDECAR"
}

apply_changes() {
    # Source mappings.sh fresh each time so any installer-side updates
    # to the personalize helpers are picked up without restarting the
    # listener.
    # shellcheck disable=SC1090
    source "$FOXML_DIR/mappings.sh" 2>/dev/null || return 1

    rederive_sidecar || return 1
    _generate_per_monitor_wallpapers || true
    _personalize_hyprlock            || true
    _personalize_workspace_rules     || true
    if [[ -x "$HOME/.config/hypr/scripts/rotate_wallpaper.sh" ]]; then
        # --static re-applies the persisted .current wallpaper (respecting the
        # user's pick) instead of the time-of-day slot. Without it, a monitor
        # event or the login startup_reconcile would bucket-rotate and stomp
        # .current back to the clock slot.
        "$HOME/.config/hypr/scripts/rotate_wallpaper.sh" --static || true
    fi

    # Regenerate the waybar config for the new monitor set. start_waybar
    # re-reads the sidecar we just re-derived, re-runs the per-monitor merge,
    # and relaunches the bar. Without this a hot-plugged monitor keeps the
    # bar layout from login — the secondary inherits the full primary bar
    # instead of the minimal date+workspaces+model one. setsid detaches the
    # new waybar from this debounce subshell so the next monitor event (which
    # kills the pending apply) can't take the bar down with it.
    if [[ -x "$HOME/.config/hypr/scripts/start_waybar.sh" ]]; then
        setsid "$HOME/.config/hypr/scripts/start_waybar.sh" >/dev/null 2>&1 &
    fi
}

# Coalesce burst events into one re-render. read -t blocks waiting for
# the next event; after the first event fires, we keep draining the
# socket for DEBOUNCE_SECONDS, then apply once.
last_apply_pid=""
debounce_dispatch() {
    # Kill any pending apply — the new event supersedes it.
    if [[ -n "$last_apply_pid" ]] && kill -0 "$last_apply_pid" 2>/dev/null; then
        kill "$last_apply_pid" 2>/dev/null || true
    fi
    (
        sleep "$DEBOUNCE_SECONDS"
        apply_changes
    ) &
    last_apply_pid=$!
}

# Startup reconcile — the watch loop below only fires on hot-plug events, so a
# monitor present at LOGIN (the common docked case) never reaches apply_changes
# and never lands in the sidecar. Compare the live monitor set to the sidecar's
# recorded set; if they differ (or the sidecar is missing), run one
# apply_changes before listening. Guarded so a correct sidecar is a no-op (no
# race with the login wallpaper/waybar setup).
startup_reconcile() {
    local live recorded
    live=$(hyprctl monitors -j 2>/dev/null \
        | jq -r '[.[].name] | sort | join(",")' 2>/dev/null) || return 0
    [[ -z "$live" ]] && return 0
    recorded=""
    if [[ -f "$SIDECAR" ]]; then
        recorded=$(awk -F'"' '/^MONITOR_RESOLUTIONS=/{print $2}' "$SIDECAR" 2>/dev/null \
            | tr ' ' '\n' | sed 's/:.*//' | grep -v '^$' | sort | paste -sd, -)
    fi
    [[ "$live" == "$recorded" ]] && return 0
    apply_changes || true
}
startup_reconcile

# socat streams socket2 events line-by-line (event>>payload). We care
# about monitor enumeration changes only — workspace/focus/etc. firehose
# past silently.
# -u = unidirectional. Same systemd-stdin-EOF bug as fox-workspace-color-watch.
socat -u UNIX-CONNECT:"$SOCKET" - 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        monitoradded*|monitorremoved*|monitoraddedv2*)
            debounce_dispatch
            ;;
    esac
done
