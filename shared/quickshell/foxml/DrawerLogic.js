.pragma library

function identity(item) {
    return item ? JSON.stringify([String(item.id || ""), String(item.argument === undefined ? "" : item.argument)]) : "";
}

function restoreIndex(items, key) {
    var found = items.findIndex(function(item) { return identity(item) === key; });
    return found >= 0 && items[found].enabled !== false ? found : Math.max(0, nextIndex(items, -1, 1));
}

function nextIndex(items, current, delta) {
    if (!items.length) return -1;
    for (var step = 1; step <= items.length; step++) {
        var at = ((current + delta * step) % items.length + items.length) % items.length;
        if (items[at].enabled !== false) return at;
    }
    return -1;
}

function actionArguments(item, value, confirmed) {
    var args = ["run", String(item.action || item.id)];
    if (value !== undefined) args.push(String(value));
    else if (item.argument !== undefined) args.push(String(item.argument));
    if (confirmed) args.push("--confirm");
    return args;
}

function symbol(item) {
    var icon = String(item.icon || "");
    if (icon && !/^[\x00-\x7f]+$/.test(icon)) return icon;
    var icons = { desk: "✎", sound: "♫", connections: "⌁", comfort: "☾", system: "⚙",
        wifi: "⌁", bluetooth: "⋈", window: "▣", volume: "♪", image: "▧", palette: "◐",
        search: "⌕", download: "↧", info: "·", package: "□", message: "✉",
        lock: "▢", suspend: "☾", reboot: "↻", poweroff: "⏻", logout: "↪", "app-launch": "⌘" };
    return icons[icon] || icons[item.id] || (item.kind === "page" ? "›" : "·");
}

function iconName(item) {
    var icon = String(item.icon || "");
    return /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(icon) ? icon : "";
}

function valueText(item, editing, draft) {
    if (item.kind === "slider") return String(editing ? draft : Math.round(Number(item.value || 0))) + "%";
    if (item.kind === "toggle") return item.checked || item.active ? "on" : "off";
    if (item.kind === "page") return "›";
    return "↵";
}

function barStyle(opened, page, group) {
    var css = "/* Generated drawer state; no user settings. */\n";
    if (!opened) return css;
    var selectors = ["#custom-logo"];
    if (page === "updates") selectors.push("#custom-updates");
    else if (page === "power") selectors.push("#power-profiles-daemon");
    else if (group === "sound" || page === "sound" || page === "audio-outputs") selectors.push("#custom-battery", "#custom-media");
    else if (group === "connections" || page === "connections" || page === "wifi" || page === "bluetooth") selectors.push("#custom-net_speed");
    else if (group === "comfort" || page === "comfort") selectors.push("#power-profiles-daemon", "#idle_inhibitor");
    else if (group === "system" || page === "system") selectors.push("#custom-system_health");
    return css + selectors.join(", ") + " { box-shadow: inset 0 -1px @peach; }\n";
}

function footerHint(state, item) {
    if (state.confirming) return "h / l choose · Enter confirms · Esc cancels";
    if (state.busy) return "working… · Esc goes back";
    if (state.prompt) return "type normally · Enter sends · Esc closes";
    if (state.searching) return "type to find · ↑ / ↓ choose · Enter selects · Esc goes back";
    if (state.picker) return "j / k move · Enter / l chooses · / searches · h / Esc closes";
    if (state.editing) return "h / l adjusts · Enter or Esc finishes";
    if (state.focus === "groups") return "j / k move · Enter / l opens a drawer · / searches · Esc closes";
    if (!item) return "h goes back · / searches · Esc closes";
    if (item.enabled === false) return "control unavailable · h goes back · / searches";
    if (item.presentation === "project") return "Enter opens editor · t terminal · b bookmark · h goes back";
    if (item.presentation === "library") return "Enter opens / mounts · e ejects · / filters · h goes back";
    if (item.presentation === "download") return "Enter opens · r opens folder · / filters · h goes back";
    if (item.kind === "toggle") return "Enter / l toggles on or off · j / k move · h goes back";
    if (item.kind === "slider") return "Enter / l starts adjustment · j / k move · h goes back";
    if (item.kind === "page") return "Enter / l opens · j / k move · / searches · h goes back";
    if (item.id === "agent-jump") return "Enter / l goes to agent · j / k move · h goes back";
    return "Enter / l runs · j / k move · / searches · h goes back";
}
