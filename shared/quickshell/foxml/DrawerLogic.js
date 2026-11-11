.pragma library

function drawerPlacement(screenWidth, windowWidth, anchor, connected) {
    if (!anchor) return {left:Math.max(0, screenWidth-windowWidth-20), top:connected ? 0 : 63};
    var left = Math.max(11, Math.min(screenWidth-windowWidth-11, anchor.x+anchor.width/2-windowWidth/2));
    return {left:left, top:connected ? 0 : Math.max(7, Math.floor(anchor.y)-9)};
}

// The sheet's height below the bar: the calendar and a written prompt stay small; the drawer itself
// grows with the screen so the landing page has room for its favorites, without covering a laptop.
// A tall portrait screen may use up to half its height, so it shows more rows than a laptop does.
function drawerBody(layout, screenHeight) {
    if (layout === "calendar") return 590;  // the month, then up to three "coming up" lines
    if (layout === "prompt") return 310;
    var height = Number(screenHeight || 0);
    return Math.max(624, Math.min(Math.max(940, Math.round(height * .5)), Math.round(height * .78)));
}

// A section heading inside a tab: Paper writes it small and lowercase ("upkeep"), the other themes in spaced capitals.
function sectionHeading(label, paper) {
    label = String(label || "");
    if (!paper) return label.toUpperCase();
    return /^[A-Z]{2,}$/.test(label) ? label : label.toLowerCase();
}

// How many rows a page holds; its section headings are not rows.
function rowCount(items) {
    return (items || []).filter(function(item) { return item.kind !== "heading"; }).length;
}

// The heading just above a row, when there is one, so moving up shows it along with the row.
function headingAbove(items, index) {
    return index > 0 && items[index - 1] && items[index - 1].kind === "heading" ? index - 1 : index;
}

// The sheet's height: what the page needs (fit, 0 = unknown), never shorter than the laptop-sized sheet and never
// taller than the screen allows. On a laptop that is the usual sheet; on a tall portrait screen a short page stops
// where its content does instead of leaving a stretch of empty paper.
function fitHeight(full, fit, floor) {
    if (!(fit > 0)) return full;
    return Math.min(full, Math.max(Math.min(floor, full), fit));
}

// Paper headings are written by hand: lowercase with a full stop. Acronyms (API, USB) and names
// with capitals inside them (FoxML) stay as they are; "Wi-Fi" becomes "wi-fi".
function pageHeading(title, paper) {
    title = String(title || "");
    if (!paper || !title) return title;
    // A model number ("B277K") and the single capital after it stay as written: "acer B277K L."
    var model = /[A-Za-z][0-9]|[0-9][A-Za-z]/.test(title);
    var written = title.replace(/[A-Za-z0-9][A-Za-z0-9']*(?:-[A-Za-z0-9][A-Za-z0-9']*)*/g, function(word) {
        if (/[0-9]/.test(word) || (model && /^[A-Z]$/.test(word))) return word;
        var simple = word.split("-").every(function(part) { return /^[A-Z]?[a-z']*$/.test(part); });
        return simple ? word.toLowerCase() : word;
    });
    return /[.!?…:]$/.test(written) ? written : written + ".";
}

function greeting(date, name) {
    var hour = date.getHours(), who = name ? ", " + name : "";
    if (isNight(date)) return "still up?";
    return (hour < 12 ? "good morning" : hour < 17 ? "good afternoon" : "good evening") + who;
}

// The Today sheet's little tags: waiting agents first, then the group summaries and what only Today knows.
// Each opens what it describes: a page, or the agent's own terminal. Every tag wears its page's glyph.
// `hearts` is the month's active days (-1 until read); the garden tag closes the row.
function todayTags(today, groups, hearts) {
    today = today || {};
    var summary = function(id) {
        var group = (groups || []).filter(function(row) { return row.id === id; })[0];
        return group && group.summary ? String(group.summary) : "";
    };
    var tags = [];
    var add = function(text, target) { if (text) tags.push(Object.assign({text: text}, target)); };
    // Due soon, from the course calendars: first, since a deadline outranks everything else here.
    (Array.isArray(today.dueSoon) ? today.dueSoon : []).forEach(function(due) {
        if (!due || !due.title) return;
        add("✎ " + due.title + (due.course ? " · " + due.course : "") + " · due " + (due.when || "soon"), {page: "calendar"});
    });
    // The morning slip: last night's /goodnight note for each project, its next step first.
    (Array.isArray(today.lastNight) ? today.lastNight : []).forEach(function(note) {
        if (!note || !note.name) return;
        add("☾ last night · " + note.name + (note.next ? (note.hasNext ? " · next: " : " · ") + note.next : ""),
            {action: "goodnight-open", argument: String(note.name)});
    });
    (Array.isArray(today.waiting) ? today.waiting : []).forEach(function(agent) {
        if (!agent || !agent.argument) return;
        var count = Number(agent.count || 1), project = agent.project || "an agent";
        add(glyphs.agents + " " + (count > 1 ? count + " in " + project + (agent.asking ? ", one needs you" : " are waiting")
                              : project + (agent.asking ? " needs you" : " is waiting")),
            {action: "agent-jump", argument: String(agent.argument)});
    });
    var working = Number(today.claudeWorking || 0), live = Number(today.claudeSessions || 0);
    add(working ? "⋯ " + (live > working ? working + " of " + live : working) + " working" : "", {page: "agents"});
    var running = Number(today.jobsRunning || 0), finished = Number(today.jobsFinished || 0);
    var job = today.runningJob;
    add(job && job.name ? glyphs.jobs + " " + job.name + " · " + job.left + (running > 1 ? " · " + running + " running" : "")
        : running ? glyphs.jobs + " " + running + (running === 1 ? " job running" : " jobs running") + (finished ? " · " + finished + " finished" : "")
        : finished ? glyphs.jobs + " " + finished + (finished === 1 ? " job finished" : " jobs finished") : "", {page: "jobs"});
    var reviews = Number(today.changesToReview || 0);
    add(reviews ? glyphs.reviews + " " + reviews + (reviews === 1 ? " change to look over" : " changes to look over") : "", {page: "reviews"});
    var failed = Number(today.jobsFailed || 0);
    add(failed ? "! " + failed + (failed === 1 ? " failed job" : " failed jobs") : "", {page: "failures"});
    add(today.nextStep ? glyphs["next-steps"] + " next: " + today.nextStep : "", {page: "next-steps"});
    var notes = Number(today.notes || 0);
    add(today.battery ? today.battery + (/^(charging|full|not charging)$/.test(today.batteryState || "") ? " · plugged in" : "") : "", {page: "power"});
    var marked = function(glyph, text) { return text ? glyph + " " + text : ""; };
    add(marked(glyphs.wifi, summary("connections")), {page: "wifi"});
    add(marked(glyphs.volume, summary("sound")), {page: "audio-outputs"});
    add(marked(glyphs.updates, summary("system")), {page: "updates"});
    add(notes ? glyphs.agents + " " + notes + (notes === 1 ? " agent note" : " agent notes") : "", {page: "agents"});
    if (hearts !== undefined && hearts !== null) add(gardenTag(hearts), {page: "garden"});
    return tags;
}

// The month's hearts, as the tag that opens the whole year of them.
function gardenTag(hearts) {
    var count = Number(hearts);
    if (!(count >= 0)) return glyphs.garden + " the garden";
    return glyphs.garden + " " + (count ? count + (count === 1 ? " day" : " days") + " active this month" : "no commits this month");
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
    // A stop slider names what it sets as well as the value: "DP-2=125".
    if (value !== undefined && hasStops(item) && item.argument !== undefined) args.push(String(item.argument) + "=" + String(value));
    else if (value !== undefined) args.push(String(value));
    else if (item.argument !== undefined) args.push(String(item.argument));
    if (confirmed) args.push("--confirm");
    return args;
}

// One glyph per item. A menu still carrying an item's earlier glyph (listed after its drawing in
// paperPresets) is shown the item's own one; a glyph the user chose stays theirs.
var glyphs = {
    today:"✿", desk:"✎", workbench:"⚒", sound:"♫", connections:"⇄", comfort:"☁", system:"⚙",
    calendar:"◰", "earlier-notes":"↶", apps:"⌘", projects:"▤", "api-tasks":"☰", worktrees:"▥", jobs:"◷", "test-results":"✓", reviews:"◎",
    "next-steps":"↳", failures:"!", bookmarks:"◇", library:"⌸", downloads:"↧", screenshots:"▧", garden:"❦",
    models:"⬡", windows:"▣", "clipboard-text":"⌇", "clipboard-images":"⧉", wallpapers:"❀", themes:"◐",
    "wallpaper-next":"↝", "wallpaper-sync":"◑", "color-picker":"⌖", agents:"✉",
    volume:"♪", "volume-mute":"♩", "audio-outputs":"◉", "mic-mute":"○", "media-play-pause":"▷",
    "media-previous":"‹", "media-next":"›", wifi:"⌁", bluetooth:"⋈",
    brightness:"☼", nightlight:"☾", dnd:"⊘", idle:"⊙",
    updates:"↻", displays:"▭", storage:"▦", backups:"↺", startup:"⏵", programs:"⊞", terminals:"⧈", "power-profile":"◈",
    vault:"⚿", passwords:"⚿", tools:"❯", "api-credits":"◔", cheatsheet:"⌨", sandbox:"▢", security:"⛨",
    cleanup:"✧", lock:"⊡", power:"⏼", suspend:"⏾", reboot:"⟳", poweroff:"⏻", logout:"↪"
};

// [drawing, then glyphs and icon names that menus used for the item before].
var paperPresets = {
    today:["today","✿"], desk:["desk","✎"], workbench:["terminal","terminal"], calendar:["today","today"],
    "earlier-notes":["bell","message"], sound:["sound","♫"], connections:["connections","⌁"],
    comfort:["comfort","☾"], system:["system","⚙"], apps:["apps","⌘"],
    projects:["notebook","▤"], bookmarks:["bookmark","◇"], library:["library","▥","▤"],
    worktrees:["notebook","▥"], jobs:["clock","◷"], "test-results":["notebook","✓"],
    reviews:["note","✿"], "next-steps":["next","◇"], failures:["note","!"],
    models:["package","◈"], "api-credits":["notebook","◇"], "api-tasks":["mail","✎"], displays:["window","▭"], storage:["library","▦"], backups:["refresh","↺"], startup:["play","⏵"], programs:["cpu","⊞"], terminals:["terminal","⧈"],
    downloads:["tray","↧","✉"], screenshots:["picture","▧"], windows:["window","▣"], garden:["garden","❦"],
    "clipboard-text":["clipboard","⌇"], "clipboard-images":["clipboard","▧"],
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
    suspend:["moon","suspend","☾"], reboot:["refresh","reboot","↻"],
    poweroff:["power","poweroff"], logout:["logout","logout"]
};

function ownGlyph(id, icon) {
    var own = glyphs[id], preset = paperPresets[id];
    if (!own) return "";
    return !icon || icon === own || /^[\x00-\x7f]+$/.test(icon) || (preset && preset.indexOf(icon) > 0) ? own : "";
}

function symbol(item) {
    var icon = String(item.icon || ""), own = ownGlyph(String(item.id || ""), icon);
    if (own) return own;
    if (icon && !/^[\x00-\x7f]+$/.test(icon)) return icon;
    var icons = { today: "✿", desk: "✎", sound: "♫", connections: "⇄", comfort: "☁", system: "⚙", wifi: "⌁", bluetooth: "⋈", window: "▣", volume: "♪", image: "▧", palette: "◐",
        search: "⌕", download: "↧", info: "·", package: "□", message: "✉",
        lock: "⊡", suspend: "⏾", reboot: "⟳", poweroff: "⏻", logout: "↪", "app-launch": "⌘",
        apps: "⌘", vault: "⚿", passwords: "⚿",
        folder: "▭", cpu: "◈", trash: "⌫", shield: "⛨", refresh: "↺", gear: "⚙" };
    return icons[icon] || (item.kind === "page" ? "›" : "·");
}

function paperIcon(item) {
    if (!item) return "";
    var semantic = {message:"mail", window:"window", volume:"sound", image:"picture", palette:"palette",
        search:"search", download:"mail", info:"notebook", package:"package", key:"passwords",
        wifi:"wifi", bluetooth:"bluetooth", clipboard:"clipboard", gear:"system", system:"system", cpu:"system",
        refresh:"refresh", today:"today", folder:"library", trash:"broom", apps:"apps", terminal:"terminal", next:"next",
        comfort:"comfort", shield:"shield", clock:"clock", note:"note", notebook:"notebook"};
    var id = String(item.id || ""), preset = paperPresets[id], icon = String(item.icon || ""), name = "";
    // Application identity and user artwork keep their own icons.
    if (id === "app-launch") return "";
    // An explicit custom glyph or icon name belongs to the user's menu.
    if (preset) {
        if (icon && preset.indexOf(icon) < 0 && icon !== glyphs[id] && icon !== id) return "";
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

// Pages that show one thing chosen on the page before: a project's worktrees, one screen.
function scopedPage(page) {
    return page === "worktrees" || page === "display" || page === "display-modes" || page === "cheatsheet-keys";
}

// A slider whose values are a few fixed stops, each with its own label and words.
function hasStops(item) {
    // The drawer hands rows over as Qt values, where a list is not an Array; a length is enough.
    return Boolean(item) && item.kind === "slider" && Boolean(item.stops) && Number(item.stops.length) > 0;
}

function sliderPosition(item, editing, draft) {
    if (!hasStops(item)) return editing ? draft : Number(item.value || 0);
    var count = item.stops.length;
    var at = editing ? draft : Number(item.stop || 0);
    return count > 1 ? at * 100 / (count - 1) : 100;
}

function stopDetail(item, draft) {
    var stop = item.stops[Math.max(0, Math.min(item.stops.length - 1, draft))];
    return (draft === Number(item.stop || 0) ? "now · " : "Enter for ") + String(stop.label) + (stop.detail ? " · " + stop.detail : "");
}

function valueText(item, editing, draft) {
    if (hasStops(item)) return String(item.stops[Math.max(0, Math.min(item.stops.length - 1, editing ? draft : Number(item.stop || 0)))].label);
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

// `?` opens the shortcut reference at the drawer's own section.
var drawerKeysQuery = "quickshell drawers";





// An empty page says whether that is good news, or how to fill it, naming the real key.
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
        screenshots: ["no little moments yet.", "alt ⇧ o takes one, or press + new."],
        library: ["the shelves are quiet.", "plug in a removable drive\nand its library card will appear here."],
        bookmarks: ["save your place.", "press b on a project card\nto leave a little ribbon here."],
        downloads: ["nothing in the post.", "your latest downloads will land here.\npress / to filter, or h to go back."],
        "clipboard-text": ["a place for little thoughts.", "copy some text to keep it close.\nh goes back to the previous page."],
        "clipboard-images": ["a place for little pictures.", "copy an image to keep it close.\nh goes back to the previous page."],
        updates: ["all up to date.", "nothing is waiting to install.\nh goes back to the previous page."],
        failures: ["nothing has failed today.", "a job that stops with an error\nwill leave a note here."],
        jobs: ["nothing has failed today.", "commands you run in a terminal\nwill gather here."],
        "test-results": ["nothing has failed today.", "your test runs\nwill leave their results here."],
        reviews: ["no changes waiting.", "new commits to look over\nwill wait for you here."],
        "next-steps": ["no next steps pinned.", "pin a next step from the notebook,\nor press n on a project card."],
        worktrees: ["just the one tree.", "worktrees you add to a project\nwill be mapped here."]
    };
    var lines = pages[page] || ["nothing here yet.", "h goes back to the previous page."];
    return {title: lines[0], detail: lines[1]};
}

function breadcrumbs(page, group, trail, groups, title, seen) {
    if (page === "root" || page === "picker") return [];
    var labels = {};
    Object.keys(seen || {}).forEach(function(id) { labels[id] = seen[id]; });
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
