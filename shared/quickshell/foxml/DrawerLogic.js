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

function confirmationLabel(item) {
    if (!item) return "Confirm";
    var labels = { "drive-eject": "Eject drive", "agent-clear": "Clear notes" };
    return labels[item.action || item.id] || item.label || "Confirm";
}

function focusDetail(item) {
    if (!item) return "";
    var path = String(item.argument || "");
    return item.presentation && path.charAt(0) === "/" ? path : "";
}

function tooltipText(item) {
    if (!item) return "";
    var parts = [item.label || "", detailText(item), focusDetail(item), item.modifiedAt || ""];
    return parts.filter(function(part, index) { return part && parts.indexOf(part) === index; }).join("\n");
}

function detailText(item) {
    var detail = String(item.disabledReason || item.detail || "");
    var normalized = detail.trim().toLowerCase();
    if (normalized === String(item.label || "").trim().toLowerCase()) return "";
    if ((item.kind === "slider" || item.kind === "toggle") && normalized === valueText(item, false, 0)) return "";
    return detail;
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
    if (item.enabled === false) return (item.disabledReason || item.detail || "control unavailable") + " · h goes back · / searches";
    if (item.presentation === "project") return "Enter opens editor · t terminal · b bookmark · h goes back";
    if (item.presentation === "library") return "Enter opens / mounts · e ejects · / filters · h goes back";
    if (item.presentation === "download") return "Enter opens · r opens folder · / filters · h goes back";
    if (item.kind === "toggle") return "Enter / l toggles on or off · j / k move · h goes back";
    if (item.kind === "slider") return "Enter / l starts adjustment · j / k move · h goes back";
    if (item.kind === "page") return "Enter / l opens · j / k move · / searches · h goes back";
    if (item.id === "agent-jump") return "Enter / l goes to agent · j / k move · h goes back";
    return "Enter / l runs · j / k move · / searches · h goes back";
}

function hintParts(hint) {
    var parts = [];
    String(hint).split(" · ").forEach(function(clause, index) {
        if (index) parts.push({text: " · ", key: false});
        var prefix = clause.match(/^((?:Enter|Esc|[hjkltebrf↑↓\/])(?:(?: \/ | or )(?:Enter|Esc|[hjkltebrf↑↓\/]))?)(?= |$)/);
        if (!prefix) { parts.push({text: clause, key: false}); return; }
        prefix[1].split(/(Enter|Esc|[hjkltebrf↑↓])/).forEach(function(text) {
            if (text) parts.push({text: text, key: /^(Enter|Esc|[hjkltebrf↑↓\/])$/.test(text)});
        });
        if (clause.length > prefix[1].length) parts.push({text: clause.slice(prefix[1].length), key: false});
    });
    return parts;
}

function emptyState(page, searching, failed) {
    if (failed) return {title: "this page needs a moment.", detail: "check the note below, or h to go back."};
    if (searching) return {title: "no matching notes.", detail: "try another search, or Esc to go back."};
    var pages = {
        root: ["everything in its little place.", "choose a group on the left\nor press / to find any action."],
        library: ["the shelves are quiet.", "plug in a removable drive\nand its library card will appear here."],
        bookmarks: ["save your place.", "press b on a project card\nto leave a little ribbon here."],
        downloads: ["nothing in the post.", "your latest downloads will land here.\npress / to filter, or h to go back."]
    };
    var lines = pages[page] || ["nothing here", "h goes back to the previous page."];
    return {title: lines[0], detail: lines[1]};
}

function breadcrumbs(page, group, trail, groups, title) {
    if (page === "root" || page === "picker") return [];
    var labels = {};
    (groups || []).forEach(function(section) {
        labels[section.page || section.id] = section.label;
        (section.items || []).forEach(function(item) {
            if (item.kind === "page") labels[item.page || item.id] = item.label;
        });
    });
    var pages = [];
    [group].concat(trail || []).concat([page]).forEach(function(id) {
        if (id && id !== "root" && pages[pages.length - 1] !== id) pages.push(id);
    });
    return pages.map(function(id, index) {
        var current = index === pages.length - 1;
        return { label: labels[id] || (current && title) || id.replace(/-/g, " "), current: current };
    });
}
