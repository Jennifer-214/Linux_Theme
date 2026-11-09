.pragma library

function drawerPlacement(screenWidth, windowWidth, anchor, connected) {
    if (!anchor) return {left:Math.max(0, screenWidth-windowWidth-20), top:connected ? 0 : 63};
    var left = Math.max(11, Math.min(screenWidth-windowWidth-11, anchor.x+anchor.width/2-windowWidth/2));
    return {left:left, top:connected ? 0 : Math.max(7, Math.floor(anchor.y)-9)};
}

function greeting(date, name) {
    var hour = date.getHours(), who = name ? ", " + name : "";
    if (isNight(date)) return "still up?";
    return (hour < 12 ? "good morning" : hour < 17 ? "good afternoon" : "good evening") + who;
}

// The Today sheet's little tags: waiting agents first, then the group summaries and what only Today knows.
// Each opens what it describes: a page, or the agent's own terminal.
function todayTags(today, groups) {
    today = today || {};
    var summary = function(id) {
        var group = (groups || []).filter(function(row) { return row.id === id; })[0];
        return group && group.summary ? String(group.summary) : "";
    };
    var tags = [];
    var add = function(text, target) { if (text) tags.push(Object.assign({text: text}, target)); };
    (Array.isArray(today.waiting) ? today.waiting : []).forEach(function(agent) {
        if (!agent || !agent.argument) return;
        var count = Number(agent.count || 1), project = agent.project || "an agent";
        add("◇ " + (count > 1 ? count + " in " + project + (agent.asking ? ", one needs you" : " are waiting")
                              : project + (agent.asking ? " needs you" : " is waiting")),
            {action: "agent-jump", argument: String(agent.argument)});
    });
    var working = Number(today.claudeWorking || 0);
    add(working ? "✎ " + working + " working" : "", {page: "agents"});
    var running = Number(today.jobsRunning || 0), finished = Number(today.jobsFinished || 0);
    add(running || finished ? "◷ " + running + " jobs running · " + finished + " finished" : "", {page: "jobs"});
    var reviews = Number(today.changesToReview || 0);
    add(reviews ? reviews + (reviews === 1 ? " change to look over ✿" : " changes to look over ✿") : "", {page: "reviews"});
    var failed = Number(today.jobsFailed || 0);
    add(failed ? "! " + failed + (failed === 1 ? " failed job" : " failed jobs") : "", {page: "failures"});
    add(today.nextStep ? "◇ next: " + today.nextStep : "", {page: "next-steps"});
    var notes = Number(today.notes || 0);
    add(today.battery ? today.battery + (/^(charging|full|not charging)$/.test(today.batteryState || "") ? " · plugged in" : "") : "", {page: "power"});
    add(summary("connections"), {page: "wifi"});
    add(summary("sound"), {page: "audio-outputs"});
    add(summary("system"), {page: "updates"});
    add(notes ? notes + (notes === 1 ? " agent note" : " agent notes") : "", {page: "agents"});
    return tags;
}

// Commits written today, across the project cards; quiet until there is one.
function sinceLine(count) {
    count = Number(count || 0);
    return count ? "✎ " + count + (count === 1 ? " commit" : " commits") + " since this morning" : "";
}

// Claude plan usage, as the backend words it; quiet when the plan reports none.
// "2h 10m today": the time Claude spent working today, quiet below a minute.
function claudeTime(minutes) {
    var total = Math.floor(Number(minutes) || 0);
    if (total < 1) return "";
    var hours = Math.floor(total / 60), rest = total % 60;
    return (hours ? hours + "h" + (rest ? " " + rest + "m" : "") : rest + "m") + " today";
}

function claudeLine(usage, minutes) {
    var parts = [claudeTime(minutes), usage || ""].filter(function(part) { return part.length > 0; });
    return parts.length ? "Claude · " + parts.join(" · ") : "";
}

function heartLine(count) {
    return count ? "· " + count + (count === 1 ? " day" : " days") + " active this month" : "No commits this month";
}

// The commit garden. Counts run one per day from `start` (a Sunday, "YYYY-MM-DD") to today.
var gardenMonthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
var gardenWeekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

function gardenDate(start, index) {
    var parts = String(start || "").split("-").map(Number);
    return new Date(parts[0], (parts[1] || 1) - 1, (parts[2] || 1) + Number(index || 0), 12);
}

// Like GitHub's graph: the quarters of your own non-empty days set the shades, so a quiet year still blooms.
function gardenThresholds(counts) {
    var busy = (counts || []).filter(function(count) { return count > 0; }).sort(function(a, b) { return a - b; });
    if (!busy.length) return [0, 0, 0];
    var at = function(share) { return busy[Math.floor((busy.length - 1) * share)]; };
    return [at(.25), at(.5), at(.75)];
}

function gardenLevel(count, thresholds) {
    if (!(count > 0)) return 0;
    return count <= thresholds[0] ? 1 : count <= thresholds[1] ? 2 : count <= thresholds[2] ? 3 : 4;
}

// The three busiest days wear a heart; a tie goes to the more recent day.
function gardenHearts(counts) {
    return (counts || []).map(function(count, index) { return {count: count, index: index}; })
        .filter(function(day) { return day.count > 0; })
        .sort(function(a, b) { return b.count - a.count || b.index - a.index; })
        .slice(0, 3).map(function(day) { return day.index; });
}

function gardenNumber(value) {
    return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function gardenSummary(start, counts) {
    counts = counts || [];
    var total = 0, longest = 0, run = 0, busiest = -1;
    counts.forEach(function(count, index) {
        total += count;
        run = count > 0 ? run + 1 : 0;
        longest = Math.max(longest, run);
        if (count > 0 && (busiest < 0 || count >= counts[busiest])) busiest = index;
    });
    if (!total) return "the garden is waiting for its first commit";
    var day = gardenDate(start, busiest);
    return "· " + gardenNumber(total) + (total === 1 ? " commit" : " commits") + " this year · longest streak " + longest
        + (longest === 1 ? " day" : " days") + " · busiest " + gardenMonthNames[day.getMonth()] + " " + day.getDate()
        + " (" + counts[busiest] + ")";
}

function gardenReadout(start, counts, index, todayIndex) {
    if (!counts || index < 0 || index >= counts.length) return "";
    var day = gardenDate(start, index), count = counts[index];
    var name = index === todayIndex ? "today" : gardenWeekdays[day.getDay()] + ", " + gardenMonthNames[day.getMonth()] + " " + day.getDate();
    return name + " · " + (count ? count + (count === 1 ? " commit" : " commits") : "no commits");
}

// Month names above the weeks where a new month begins, between weeks `from` and `to` (exclusive).
function gardenMonths(start, from, to) {
    var labels = [], last = -1;
    for (var week = from; week < to; week++) {
        var month = gardenDate(start, week * 7).getMonth();
        var firstWeek = week === from;
        if (month !== last && (firstWeek || gardenDate(start, week * 7).getDate() <= 7)) labels.push({week: week - from, text: gardenMonthNames[month]});
        last = month;
    }
    return labels;
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
    var icons = { today: "✿", desk: "✎", sound: "♫", connections: "⌁", comfort: "☾", system: "⚙",
        wifi: "⌁", bluetooth: "⋈", window: "▣", volume: "♪", image: "▧", palette: "◐",
        search: "⌕", download: "↧", info: "·", package: "□", message: "✉",
        lock: "▢", suspend: "☾", reboot: "↻", poweroff: "⏻", logout: "↪", "app-launch": "⌘",
        apps: "⌘", vault: "⚿", passwords: "⚿",
        folder: "▭", cpu: "◈", trash: "⌫", shield: "⛨", refresh: "↺", gear: "⚙" };
    return icons[icon] || icons[item.id] || (item.kind === "page" ? "›" : "·");
}

function paperIcon(item) {
    if (!item) return "";
    var presets = {
        today:["today","✿"], desk:["desk","✎"], sound:["sound","♫"], connections:["connections","⌁"],
        comfort:["comfort","☾"], system:["system","⚙"], apps:["apps","⌘"],
        projects:["notebook","▤"], bookmarks:["bookmark","◇"], library:["library","▥","▤"],
        worktrees:["notebook","▥"], jobs:["clock","◷"], "test-results":["notebook","✓"],
        reviews:["note","✿"], "next-steps":["bookmark","◇"], failures:["note","!"],
        models:["notebook","◈"], "api-credits":["notebook","◇"], "api-tasks":["mail","✎"], displays:["window","▭"], storage:["library","▦"], backups:["refresh","↺"], startup:["play","⏵"],
        downloads:["tray","↧","✉"], screenshots:["picture","▧"], windows:["window","▣"], garden:["garden","❦"],
        "clipboard-text":["clipboard","⌇"], "clipboard-images":["picture","▧"],
        wallpapers:["picture","❀"], themes:["palette","◐"],
        "wallpaper-next":["refresh","↝"], "wallpaper-sync":["palette","◑","◇"],
        "color-picker":["dropper","✎"], agents:["note","✉"],
        volume:["sound","♪"], "volume-mute":["sound","♩"], "audio-outputs":["sound","◉"],
        "mic-mute":["microphone","○"], "media-play-pause":["play","▷"],
        "media-previous":["previous","‹"], "media-next":["next","›"],
        wifi:["wifi","⌁"], bluetooth:["bluetooth","⋈"],
        brightness:["comfort","☼"], nightlight:["moon","☾"], dnd:["bell","⊘","✉"], idle:["clock","◷"],
        updates:["refresh","↻"], "power-profile":["battery","◈"],
        vault:["passwords","⚿"], passwords:["passwords","⚿"], tools:["terminal","❯","▤"],
        cheatsheet:["keys","⌨","✎"], sandbox:["sandbox","▢"], security:["shield","⛨","◇"],
        cleanup:["broom","✧","✎"], lock:["lock","⊡","▢"], power:["power","⏻"],
        suspend:["moon","suspend"], reboot:["refresh","reboot"],
        poweroff:["power","poweroff"], logout:["logout","logout"]
    };
    var semantic = {message:"mail", window:"window", volume:"sound", image:"picture", palette:"palette",
        search:"search", download:"mail", info:"notebook", package:"package", key:"passwords",
        wifi:"wifi", bluetooth:"bluetooth", clipboard:"clipboard", gear:"system", system:"system", cpu:"system",
        refresh:"refresh", today:"today", folder:"library", trash:"broom", apps:"apps", terminal:"terminal", next:"next",
        comfort:"comfort", shield:"shield"};
    var id = String(item.id || ""), preset = presets[id], icon = String(item.icon || ""), name = "";
    // Application identity and user artwork keep their own icons.
    if (id === "app-launch") return "";
    // An explicit custom glyph or icon name belongs to the user's menu.
    if (preset) {
        if (icon && icon !== preset[1] && icon !== preset[2] && icon !== symbol({id:id}) && icon !== id) return "";
        name = preset[0];
    } else name = semantic[icon] || (icon === "✉" ? "mail" : "");
    if (!name) return "";
    return "paper-icon-" + name + ".svg";
}

function emptyIllustration(page, searching, failed) {
    if (failed) return "";
    var names = {downloads:"tray",bookmarks:"notebook","clipboard-text":"scraps","clipboard-images":"scraps"};
    return !searching && names[page] ? "paper-empty-" + names[page] + ".svg" : "paper-sprig.png";
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
    if (item.presentation === "claude") return String(item.claudeState || "");
    return item.presentation === "media" && (item.mediaState === "Paused" || item.mediaState === "Stopped") ? item.mediaState.toLowerCase() : "";
}

// Five meter segments for a session's context: how many are filled.
function contextHearts(percent) {
    var value = Number(percent);
    return isFinite(value) && value >= 0 ? Math.min(5, Math.round(value / 20)) : -1;
}

function detailText(item, stateTag) {
    var detail = String(item.disabledReason || item.detail || "");
    // Without the paper tag a session's state still has to be said somewhere.
    if (!stateTag && item.presentation === "claude" && item.claudeState) detail = item.claudeState + (detail ? " · " + detail : "");
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
    if (state.focus === "tags") return "Enter opens · h / l choose · j goes to favorites · Esc goes back";
    if (!item) return "h goes back · / searches · Esc goes back";
    if (item.enabled === false) return (item.disabledReason || item.detail || "control unavailable") + " · h goes back · / searches";
    if (item.presentation === "project") return "Enter editor · t terminal · w worktrees · n next steps · b bookmark";
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
            if (text) parts.push({text: text, key: /^(Enter|Esc|[hjkltebrfc↑↓\/])$/.test(text)});
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
        agents: ["all quiet at the desk.", "your agents will leave a note here\nwhen they need you."],
        passwords: ["the key drawer is empty.", "add something with pass\nand it will appear here."],
        projects: ["no index cards yet.", "folders with a project inside ~/code\nget a little card here."],
        wallpapers: ["no pictures in the frame.", "add some to ~/.wallpapers\nand they will hang here."],
        windows: ["a clear desk.", "open windows will gather here."],
        screenshots: ["no little moments yet.", "press + new to take one."],
        library: ["the shelves are quiet.", "plug in a removable drive\nand its library card will appear here."],
        bookmarks: ["save your place.", "press b on a project card\nto leave a little ribbon here."],
        downloads: ["nothing in the post.", "your latest downloads will land here.\npress / to filter, or h to go back."],
        "clipboard-text": ["a place for little thoughts.", "copy some text to keep it close.\nh goes back to the previous page."],
        "clipboard-images": ["a place for little pictures.", "copy an image to keep it close.\nh goes back to the previous page."]
    };
    var lines = pages[page] || ["nothing here yet.", "h goes back to the previous page."];
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
