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

// A row's height in the item list (compact: the landing page's favorites).
function rowHeight(item, compact) {
    if (!item) return 0;
    if (item.kind === "heading") return 30;
    if (item.presentation === "project" || item.presentation === "library" || item.presentation === "download") return 94;
    if (item.kind === "slider") return 91;
    if (item.image || (item.presentation === "media" && Boolean(item.artwork))) return 80;
    return compact || item.presentation === "shortcut" ? 54 : 72;
}

// Paper headings are written by hand: lowercase with a full stop. Acronyms (API, USB) and names
// with capitals inside them (Linux_Theme) stay as they are; "Wi-Fi" becomes "wi-fi".
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

// The row the cursor was on, after a refresh. Rows can share an identity (every job in one pane jumps to it), so the
// match nearest its old place wins; when the row is gone, its neighbour does, not the top of the page.
function restoreIndex(items, key, near) {
    var best = -1;
    items.forEach(function(item, at) {
        if (identity(item) !== key) return;
        if (best < 0 || (near !== undefined && Math.abs(at - near) < Math.abs(best - near))) best = at;
    });
    if (best >= 0 && items[best].enabled !== false) return best;
    if (near !== undefined && near >= 0 && items.length) {
        var start = Math.min(near, items.length - 1);
        for (var step = 0; step < items.length; step++) {
            if (start + step < items.length && items[start + step].enabled !== false) return start + step;
            if (start - step >= 0 && items[start - step].enabled !== false) return start - step;
        }
    }
    return Math.max(0, nextIndex(items, -1, 1));
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
    calendar:"◰", "earlier-notes":"↶", apps:"⌘", projects:"▤", "api-tasks":"☰", worktrees:"▥", jobs:"◷", "test-results":"✓", reviews:"◎", attention:"◆", "work-history":"≡", "work-digest":"✱", "work-health":"⚕",
    "next-steps":"↳", failures:"!", bookmarks:"◇", library:"⌸", downloads:"↧", screenshots:"▧", garden:"❦",
    models:"⬡", windows:"▣", "clipboard-text":"⌇", "clipboard-images":"⧉", wallpapers:"❀", themes:"◐",
    "wallpaper-next":"↝", "color-picker":"⌖", agents:"✉",
    volume:"♪", "volume-mute":"♩", "audio-outputs":"◉", "mic-mute":"○", "media-play-pause":"▷",
    "media-previous":"‹", "media-next":"›", wifi:"⌁", bluetooth:"⋈",
    brightness:"☼", nightlight:"☾", crt:"≣", dnd:"⊘", idle:"⊙",
    updates:"↻", displays:"▭", storage:"▦", backups:"↺", startup:"⏵", programs:"⊞", terminals:"⧈", "power-profile":"◈",
    vault:"⚿", passwords:"⚿", tools:"❯", "api-credits":"◔", cheatsheet:"⌨", sandbox:"▢", security:"⛨",
    cleanup:"✧", lock:"⊡", power:"⏼", suspend:"⏾", reboot:"⟳", poweroff:"⏻", logout:"↪"
};

// The retro style (Theme.style) is set in Big Blue Term, a DOS code page 437 font with Nerd Font icons:
// every glyph below is one that font has, so none falls back to another font's drawing.
var retroGlyphs = {
    today:"■", desk:"⌂", workbench:"\u{F1322}", sound:"♫", connections:"↔", comfort:"≈", system:"\u{F0493}",
    calendar:"\u{F00ED}", "earlier-notes":"§", apps:"\u{F003B}", projects:"\u{F024B}", "api-tasks":"☰",
    worktrees:"\u{F062C}", jobs:"\u{F0150}", "test-results":"√", reviews:"\u{F0208}", attention:"♦",
    "work-history":"≡", "work-digest":"Σ", "work-health":"■", "next-steps":"»", failures:"!", bookmarks:"▼",
    library:"\u{F00BA}", downloads:"↓", screenshots:"\u{F0100}", garden:"♣", models:"\u{F06A9}", windows:"◘",
    "clipboard-text":"¶", "clipboard-images":"\u{F02E9}", wallpapers:"▒", themes:"\u{F03D8}", "wallpaper-next":"→",
    "color-picker":"\u{F020A}", agents:"☺", volume:"♪", "volume-mute":"\u{F0581}", "audio-outputs":"◙",
    "mic-mute":"○", "media-play-pause":"►", "media-previous":"◄◄", "media-next":"►►", wifi:"\u{F05A9}",
    bluetooth:"\u{F00AF}", brightness:"☼", nightlight:"\u{F0594}", crt:"░", dnd:"\u{F009B}", idle:"\u{F0176}",
    updates:"↑", displays:"▬", storage:"▓", backups:"↨", startup:"▲", programs:"\u{F061A}",
    terminals:"\u{F018D}", "power-profile":"\u{F140B}", vault:"\u{F0306}", passwords:"\u{F0306}", tools:"❯",
    "api-credits":"$", cheatsheet:"\u{F030C}", sandbox:"\u{F01A7}", security:"\u{F0498}", cleanup:"*",
    lock:"\u{F033E}", power:"⏼", suspend:"⏾", reboot:"\u{F0709}", poweroff:"⏻", logout:"\u{F0343}"
};
// Marks written into the drawer's own words that the font lacks, as a DOS screen would write them.
var retroChars = {
    "✿":"»", "◇":"♦", "◆":"♦", "…":"...", "⋯":"...", "☐":"[ ]", "✎":"\u{F03EB}", "↵":"◄┘", "›":"►", "‹":"◄",
    "×":"x", "✓":"√", "✗":"x", "—":"-", "–":"-", "⌕":"\u{F0349}", "□":"\u{F03D6}", "⌫":"←", "⏏":"▲", "♡":"♦"
};
var style = "";
// Each Paper glyph, as the retro glyph of the same item, for text a backend or menu wrote with the Paper ones.
var retroOf = {};
for (var paperKey in retroGlyphs)
    if (glyphs[paperKey] !== retroGlyphs[paperKey] && !retroOf[glyphs[paperKey]]) retroOf[glyphs[paperKey]] = retroGlyphs[paperKey];
function useStyle(name) {
    style = String(name || "");
    if (style === "retro") for (var key in retroGlyphs) glyphs[key] = retroGlyphs[key];
    return true;
}
// The retro words and marks; callers ask for them only in the retro style (bindings may run before useStyle).
function retroText(text) {
    text = String(text === undefined || text === null ? "" : text);
    return Array.from(text).map(function(ch) { return retroChars[ch] || retroOf[ch] || ch; }).join("");
}

// [drawing, then glyphs and icon names that menus used for the item before].
var paperPresets = {
    today:["today","✿"], desk:["desk","✎"], workbench:["terminal","terminal"], calendar:["today","today"],
    "earlier-notes":["bell","message"], sound:["sound","♫"], connections:["connections","⌁"],
    comfort:["comfort","☾"], system:["system","⚙"], apps:["apps","⌘"],
    projects:["notebook","▤"], bookmarks:["bookmark","◇"], library:["library","▥","▤"],
    worktrees:["notebook","▥"], jobs:["clock","◷"], "test-results":["notebook","✓"],
    reviews:["note","✿"], attention:["note","!"], "work-history":["note","note"], "work-digest":["note","note"], "work-health":["system","⚙"], "work-health-controls":["system","system"], "work-backups":["refresh","folder"], "next-steps":["next","◇"], failures:["note","!"],
    models:["package","◈"], "api-credits":["notebook","◇"], "api-tasks":["mail","✎"], displays:["window","▭"], storage:["library","▦"], backups:["refresh","↺"], startup:["play","⏵"], programs:["cpu","⊞"], terminals:["terminal","⧈"],
    downloads:["tray","↧","✉"], screenshots:["picture","▧"], windows:["window","▣"], garden:["garden","❦"],
    "clipboard-text":["clipboard","⌇"], "clipboard-images":["clipboard","▧"],
    wallpapers:["picture","❀"], themes:["palette","◐"],
    "wallpaper-next":["refresh","↝"],
    "color-picker":["dropper","✎"], agents:["note","✉"],
    volume:["sound","♪"], "volume-mute":["sound","♩"], "audio-outputs":["sound","◉"],
    "mic-mute":["microphone","○"], "media-play-pause":["play","▷"],
    "media-previous":["previous","‹"], "media-next":["next","›"],
    wifi:["wifi","⌁"], bluetooth:["bluetooth","⋈"],
    brightness:["comfort","☼"], nightlight:["moon","☾"], crt:["window","≣"], dnd:["bell","⊘","✉"], idle:["clock","◷"],
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
    return !icon || icon === own || /^[\x00-\x7f]+$/.test(icon) || (preset && preset.indexOf(icon) > 0)
        || (retroOf[icon] === own) ? own : "";
}

function symbol(item) {
    var icon = String(item.icon || ""), own = ownGlyph(String(item.id || ""), icon);
    if (own) return own;
    if (style === "retro") return retroText(paperSymbol(item, icon));
    return paperSymbol(item, icon);
}

function paperSymbol(item, icon) {
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
        jobs: ["no jobs yet.", "commands you run in a terminal\nwill gather here."],
        "test-results": ["no test runs yet.", "your test runs\nwill leave their results here."],
        reviews: ["no changes waiting.", "new commits to look over\nwill wait for you here."],
        attention: ["nothing needs you here.", "failed checks and changes ready to read\nwill gather here."],
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

// ── Retro: the drawer as a DOS screen, one line per row in whole character cells. ──

// A string's width in character cells (a Nerd icon is one cell but two UTF-16 units).
function cells(text) { return Array.from(String(text || "")).length; }
function clip(text, width) {
    var chars = Array.from(String(text || ""));
    if (chars.length <= width) return chars.join("");
    return width <= 3 ? chars.slice(0, Math.max(0, width)).join("") : chars.slice(0, width - 3).join("") + "...";
}

// "Volume ............ 47%": the label, dot leaders, then the value against the right edge.
function leaderLine(label, value, width) {
    value = String(value || "");
    var room = Math.max(0, width - cells(value) - (value ? 1 : 0));
    label = clip(label, room);
    if (!value) return label;
    var gap = width - cells(label) - cells(value);
    if (gap < 1) return label + " " + value;
    return label + (gap >= 4 && label ? " " + ".".repeat(gap - 2) + " " : " ".repeat(gap)) + value;
}

function retroBar(percent, width) {
    var size = Math.max(1, width || 10), value = Math.max(0, Math.min(100, Number(percent) || 0));
    var filled = Math.round(value * size / 100);
    return "[" + "█".repeat(filled) + "░".repeat(size - filled) + "]";
}

// A row's keys as a DOS manual writes them: "alt ⇧ n" is Alt+Shift+N.
function retroKeys(keys) {
    var names = {alt:"Alt", ctrl:"Ctrl", control:"Ctrl", super:"Super", meta:"Super", shift:"Shift", "⇧":"Shift",
        enter:"Enter", return:"Enter", esc:"Esc", escape:"Esc", tab:"Tab", space:"Space", "↵":"Enter"};
    return String(keys || "").trim().split(/\s+/).filter(function(key) { return key.length > 0; }).map(function(key) {
        var lower = key.toLowerCase();
        if (names[lower]) return names[lower];
        return key.length === 1 ? key.toUpperCase() : retroText(key.charAt(0).toUpperCase() + key.slice(1));
    }).join("+");
}

// The value column of a retro row: [X] for a toggle, a bar for a slider, ► for a page, ◄┘ for an action.
function retroValue(item, editing, draft) {
    if (!item) return "";
    if (hasStops(item)) return "[" + valueText(item, editing, draft) + "]";
    if (item.kind === "slider") {
        var level = editing ? draft : Math.round(Number(item.value || 0));
        return retroBar(level, 12) + " " + String(level).padStart(3, " ") + "%";
    }
    if (item.kind === "toggle") return item.checked || item.active ? "[X]" : "[ ]";
    var linked = connectionState(item);
    if (linked !== null) return linked ? "(•)" : "( )";
    if (item.presentation === "claude" && item.context !== undefined && contextHearts(item.context) >= 0)
        return retroBar(item.context, 5) + " " + Math.round(Number(item.context)) + "%";
    if (item.presentation === "media" && item.mediaState) return String(item.mediaState).toUpperCase();
    if (item.presentation === "library") return item.mounted ? "MOUNTED" : "<DRIVE>";
    if (item.presentation === "download") return String(item.stamp || "NEW").toUpperCase();
    if (item.presentation === "project") return (item.bookmarked ? "♦ " : "") + "<DIR>";
    if (item.kind === "page") return "►";
    return item.enabled === false ? "" : "◄┘";
}

// "C:\DESK\SOUND\AUDIO_OU>": the trail as a DOS path, each name cut to eight characters.
function retroPath(crumbs, searching) {
    var parts = (crumbs || []).map(function(crumb) {
        return String(crumb.label || "").toUpperCase().replace(/[^A-Z0-9]+/g, "_").replace(/^_+/, "").slice(0, 8).replace(/_+$/, "");
    }).filter(function(part, index) { return part.length > 0 && !(index === 0 && part === "DESK"); });
    return "C:\\DESK" + parts.map(function(part) { return "\\" + part; }).join("") + ">" + (searching ? "FIND " : "");
}

function retroTitle(title) {
    return retroText(String(title || "").replace(/[.…]+$/, "")).toUpperCase();
}

// The bottom status line: the keys that work right now, as a DOS program lists them.
function retroHints(mode, presentation) {
    var hints = {
        groups: "j/k Move  ◄┘ Open  / Find  1-9 Jump  ? Help  q Close",
        items: "j/k Move  ◄┘ Open  h Back  / Find  ? Help  q Close",
        search: "Ctrl+j/k Move  ◄┘ Open  Esc List",
        results: "j/k Move  ◄┘ Open  / Type  h Back  q Close",
        prompt: "◄┘ Done  Esc Cancel",
        picker: "j/k Move  ◄┘ Choose  / Filter  Esc Cancel",
        editing: "h/l Adjust  ◄┘ Done  Esc Back",
        confirm: "h/l Choose  ◄┘ Select  Esc Cancel",
        calendar: "h/l Month  t Today  g Garden  c Courses  Esc Close",
        garden: "hjkl Move  t Today  h Back  q Close",
        scrapbook: "hjkl Move  ◄┘ Open  c Copy  h Back  q Close",
        tags: "h/l Move  ◄┘ Open  j Down  Tab Groups  q Close"
    };
    var extra = {project: "b Ribbon  w Trees  t Term  ", library: "e Eject  ", download: "r Folder  "};
    var line = hints[mode] || hints.items;
    return mode === "items" && extra[presentation] ? extra[presentation] + line : line;
}

// The cute lowercase words, as a DOS screen would say them.
var retroWords = {
    "today.": "TODAY", "find anything": "FIND", "write here…": "Type here...", "drawer keys": "DRAWER KEYS",
    "apps, projects, settings, recent things…": "Search apps, projects, settings...", "find on this page…": "Find on this page...",
    "all set.": "OK.", "a little order, restored.": "READY.", "a few favorites.": "FAVORITES",
    "stay here": "CANCEL", "one moment before you go.\nthis action needs your confirmation.": "This action needs confirmation.\nContinue?",
    "a little song.": "NOW PLAYING", "a little light.": "BRIGHTNESS", "a little quiet.": "MUTED",
    "a little loud.": "VOLUME", "a little sound.": "VOLUME", "nothing is playing.": "No media.",
    "a little permission.": "PERMISSION REQUIRED", "calendar": "CALENDAR"
};
function retroWord(text) {
    text = String(text || "");
    return retroWords.hasOwnProperty(text) ? retroWords[text] : retroText(text);
}

// The menu's own descriptions, plainer; anything not listed keeps the backend's words.
var retroDetails = {
    apps: "Run a program", windows: "Switch to an open window", calendar: "Month view and due dates",
    "clipboard-text": "Clipboard history", "clipboard-images": "Saved images", screenshots: "Screen captures",
    downloads: "Recent downloads", "color-picker": "Read a colour from the screen", library: "Removable drives",
    bookmarks: "Bookmarked projects", terminals: "tmux sessions", projects: "Projects in ~/code",
    worktrees: "Branches and work folders", garden: "Commits per day, one year", attention: "Failures, requests, unread changes",
    agents: "Messages from agents", jobs: "Builds, tests and downloads", "test-results": "Test runs and failures",
    failures: "Job errors and failed services", reviews: "Commits not yet read", "next-steps": "Pinned next steps",
    models: "Local models", "volume-mute": "Mute output", "audio-outputs": "Output device", "mic-mute": "Mute input",
    "media-play-pause": "Current media", brightness: "Backlight level", nightlight: "Warmer colours",
    idle: "Keep screens on", crt: "Scanlines over the whole screen", dnd: "Hold notifications", "earlier-notes": "Notification history",
    wallpapers: "Background image", themes: "Colour themes", "wallpaper-next": "Next background",
    updates: "Pending updates", storage: "Disk usage", backups: "Files kept before replacing",
    cleanup: "Clean caches in a terminal", programs: "Running processes", startup: "Session autostart",
    power: "Suspend, restart, shut down, log out", lock: "Lock the screen", security: "Security dashboard",
    vault: "pass store", sandbox: "Disposable app sandbox", tools: "Desk commands", cheatsheet: "Keyboard shortcuts"
};
// A row's own retro name where the menu's words would not read as a DOS setting; others keep the menu's label.
var retroLabels = { crt: "CRT SCANLINES" };
function retroLabel(item) {
    if (!item) return "";
    return retroText(retroLabels[String(item.id || "")] || item.label || "");
}
function retroDetail(item) {
    if (!item) return "";
    var own = String(item.disabledReason || "") ? "" : retroDetails[String(item.id || "")];
    return retroText(own || detailText(item, false));
}

function retroEmptyState(page, searching, failed) {
    if (failed) return {title: "General failure reading drawer", detail: "Abort, Retry, Ignore?  h Back"};
    if (searching) return {title: "File not found", detail: "Esc Back"};
    var note = emptyState(page, false, false);
    var detail = note.detail.split("\n").map(function(line) { return line.charAt(0).toUpperCase() + line.slice(1); }).join("\n");
    return {title: "0 File(s)", detail: retroText(detail)};
}

// A file as DOS's DIR lists it: "LITTLE~1 PNG    11-05-26   2:30p".
function dosEntry(label, index, modified) {
    var name = String(label || "").split("/").pop();
    var dot = name.lastIndexOf(".");
    var base = (dot > 0 ? name.slice(0, dot) : name).toUpperCase().replace(/[^A-Z0-9]/g, "");
    var ext = (dot > 0 ? name.slice(dot + 1) : "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 3);
    if (base.length > 8) base = base.slice(0, 6) + "~" + String(Math.min(9, Number(index || 0) + 1));
    var stamp = String(modified || "").match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/);
    var when = "";
    if (stamp) {
        var hour = Number(stamp[4]);
        when = stamp[2] + "-" + stamp[3] + "-" + stamp[1].slice(2) + "  "
            + String(hour % 12 || 12).padStart(2, " ") + ":" + stamp[5] + (hour < 12 ? "a" : "p");
    }
    return (base || "NONAME").padEnd(8, " ") + " " + ext.padEnd(3, " ") + "    " + when;
}
