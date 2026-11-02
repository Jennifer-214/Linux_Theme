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
