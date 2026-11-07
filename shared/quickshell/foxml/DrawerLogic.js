.pragma library

function drawerPlacement(screenWidth, windowWidth, anchor, connected) {
    if (!anchor) return {left:Math.max(0, screenWidth-windowWidth-20), top:connected ? 0 : 63};
    var left = Math.max(11, Math.min(screenWidth-windowWidth-11, anchor.x+anchor.width/2-windowWidth/2));
    return {left:left, top:connected ? 0 : Math.max(7, Math.floor(anchor.y)-9)};
}

function isNight(date) {
    var hour = date.getHours();
    return hour >= 22 || hour < 5;
}

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
        lock: "▢", suspend: "☾", reboot: "↻", poweroff: "⏻", logout: "↪", "app-launch": "⌘",
        apps: "⌘", vault: "⚿", passwords: "⚿" };
    return icons[icon] || icons[item.id] || (item.kind === "page" ? "›" : "·");
}

function paperIcon(item) {
    if (!item) return "";
    var presets = {
        desk:["desk","✎"], sound:["sound","♫"], connections:["connections","⌁"],
        comfort:["comfort","☾"], system:["system","⚙"], apps:["apps","⌘"],
        projects:["notebook","▤"], bookmarks:["bookmark","◇"], library:["library","▤"],
        downloads:["mail","✉"], screenshots:["picture","▧"], windows:["window","▣"],
        "clipboard-text":["clipboard","⌇"], "clipboard-images":["picture","▧"],
        wallpapers:["picture","❀"], themes:["palette","◐"],
        "wallpaper-next":["refresh","↝"], "wallpaper-sync":["palette","◇"],
        "color-picker":["pencil","✎"], agents:["mail","✉"],
        volume:["sound","♪"], "volume-mute":["sound","♩"], "audio-outputs":["sound","◉"],
        "mic-mute":["microphone","○"], "media-play-pause":["play","▷"],
        "media-previous":["previous","‹"], "media-next":["next","›"],
        wifi:["wifi","⌁"], bluetooth:["bluetooth","⋈"],
        brightness:["comfort","☼"], nightlight:["moon","☾"], dnd:["mail","✉"], idle:["clock","◷"],
        updates:["refresh","↻"], "power-profile":["battery","◈"],
        vault:["passwords","⚿"], passwords:["passwords","⚿"], tools:["notebook","▤"],
        cheatsheet:["notebook","✎"], sandbox:["window","▢"], security:["shield","◇"],
        cleanup:["pencil","✎"], lock:["lock","▢"], power:["power","⏻"],
        suspend:["moon","suspend"], reboot:["refresh","reboot"],
        poweroff:["power","poweroff"], logout:["logout","logout"]
    };
    var semantic = {message:"mail", window:"window", volume:"sound", image:"picture", palette:"palette",
        search:"search", download:"mail", info:"notebook", package:"package", key:"passwords",
        wifi:"wifi", bluetooth:"bluetooth", clipboard:"clipboard"};
    var id = String(item.id || ""), preset = presets[id], icon = String(item.icon || ""), name = "";
    // Application identity and user artwork keep their own icons.
    if (id === "app-launch") return "";
    // An explicit custom glyph or icon name belongs to the user's menu.
    if (preset) {
        if (icon && icon !== preset[1] && icon !== symbol({id:id}) && icon !== id) return "";
        name = preset[0];
    } else name = semantic[icon] || (icon === "✉" ? "mail" : "");
    if (!name) return "";
    return "paper-icon-" + name + ".svg";
}

function emptyIllustration(page, searching, failed) {
    if (failed) return "";
    var names = {downloads:"tray",bookmarks:"notebook","clipboard-text":"scraps","clipboard-images":"scraps"};
    return !searching && names[page] ? "paper-empty-" + names[page] + ".svg" : "paper-cat.png";
}

function pageFlourish(page, searching) {
    return searching ? "" : page === "root" ? "swash" : page === "bookmarks" ? "circle" : "underline";
}

function connectionState(item) {
    if (!item || ["wifi-connect", "bluetooth-connect", "audio-output", "theme-set"].indexOf(item.id) < 0
        || item.enabled === false || typeof item.checked !== "boolean") return null;
    return item.checked;
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

function statusLabel(item) {
    return item.presentation === "media" && (item.mediaState === "Paused" || item.mediaState === "Stopped") ? item.mediaState.toLowerCase() : "";
}

function detailText(item, stateTag) {
    var detail = String(item.disabledReason || item.detail || "");
    if (stateTag && statusLabel(item)) {
        if (detail === item.mediaState) detail = "";
        else if (detail.endsWith(" · " + item.mediaState)) detail = detail.slice(0, -item.mediaState.length - 3);
    }
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
    if (!item) return "h goes back · / searches · Esc goes back";
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
        var prefix = clause.match(/^((?:Enter|Esc|[hjkltebrfc↑↓\/])(?:(?: \/ | or )(?:Enter|Esc|[hjkltebrfc↑↓\/]))?)(?= |$)/);
        if (!prefix) { parts.push({text: clause, key: false}); return; }
        prefix[1].split(/(Enter|Esc|[hjkltebrfc↑↓])/).forEach(function(text) {
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
        downloads: ["nothing in the post.", "your latest downloads will land here.\npress / to filter, or h to go back."],
        "clipboard-text": ["a place for little thoughts.", "copy some text to keep it close.\nh goes back to the previous page."],
        "clipboard-images": ["a place for little pictures.", "copy an image to keep it close.\nh goes back to the previous page."]
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
