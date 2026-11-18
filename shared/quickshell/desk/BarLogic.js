.pragma library

function plain(value) {
    return String(value || "").replace(/<[^>]*>/g, "").replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, "&");
}

function modules(config, side) { return Array.isArray(config["modules-" + side]) ? config["modules-" + side] : []; }
function children(config, name) { return name.indexOf("group/") === 0 ? (config[name] || {}).modules || [] : [name]; }
function enabled(config) {
    var result = [];
    function visit(name, seen) {
        if (seen.indexOf(name) >= 0) return;
        if (name.indexOf("group/") === 0) children(config, name).forEach(function(child) { visit(child, seen.concat([name])); });
        else if (result.indexOf(name) < 0) result.push(name);
    }
    ["left", "center", "right"].forEach(function(side) { modules(config, side).forEach(function(name) { visit(name, []); }); });
    return result;
}
function pollers(primary, secondary) {
    var result = [];
    [primary, secondary].forEach(function(config) {
        enabled(config).forEach(function(name) {
            var spec = config[name] || {};
            if (name.indexOf("custom/") !== 0 || !spec.exec || result.some(function(row) { return row.name === name; })) return;
            result.push({name: name, spec: spec});
        });
    });
    return result;
}
function sample(output, spec) {
    var value = spec["return-type"] === "json" ? JSON.parse(output.trim()) : {text: output.trim()};
    if (!value || typeof value !== "object") throw new Error("Helper returned no module data");
    var result = {text: plain(value.text), tooltip: plain(value.tooltip || value.alt || value.text),
        classes: Array.isArray(value.class) ? value.class : String(value.class || "").split(/\s+/)};
    if (typeof value.percentage === "number" && isFinite(value.percentage))
        result.percentage = Math.max(0, Math.min(100, value.percentage));
    // Workspaces holding a Claude that waits on you (desk-drawer claude-bar): the tabs wear a small pin.
    if (Array.isArray(value.pins))
        result.pins = value.pins.filter(function(id) { return Number.isInteger(id) && id > 0 && id < 100; }).slice(0, 10);
    return result;
}
function format(text, values) {
    return String(text || "").replace(/\{([A-Za-z]+)(?::([^}]+))?\}/g, function(all, key, style) {
        if (values[key] === undefined) return all;
        var decimals = style && style.match(/\.(\d+)f/);
        return typeof values[key] === "number" && decimals ? values[key].toFixed(Number(decimals[1])) : String(values[key]);
    });
}
function memory(output, spec) {
    var fields = {};
    output.split("\n").forEach(function(line) { var match = line.match(/^(\w+):\s+(\d+)/); if (match) fields[match[1]] = Number(match[2]); });
    if (!fields.MemTotal || fields.MemAvailable === undefined) throw new Error("Memory state unavailable");
    var values = {used: (fields.MemTotal - fields.MemAvailable) / 1048576, total: fields.MemTotal / 1048576,
        percentage: Math.round(100 * (fields.MemTotal - fields.MemAvailable) / fields.MemTotal),
        swapUsed: ((fields.SwapTotal || 0) - (fields.SwapFree || 0)) / 1048576, swapTotal: (fields.SwapTotal || 0) / 1048576};
    var states = spec.states || {};
    return {text: format(spec.format || "󰍛 {used:0.1f}/{total:0.0f}g", values),
        tooltip: format(spec["tooltip-format"] || "RAM: {percentage}%", values),
        classes: values.percentage >= (states.critical || 90) ? ["critical"] : values.percentage >= (states.warning || 75) ? ["warning"] : []};
}
function primary(layout) {
    var match = String(layout).match(/^PRIMARY\s*=\s*"([^"\n]*)"\s*$/m);
    return match ? match[1] : "";
}
function windowIcon(app, spec) {
    var rules = spec["window-rewrite"] || {}, icon = spec["window-rewrite-default"] || "󰘔";
    Object.keys(rules).some(function(pattern) {
        var match = pattern.match(/^class<(.+)>$/);
        if (!match) return false;
        try { if (new RegExp("^(?:" + match[1] + ")$", "i").test(app)) { icon = rules[pattern]; return true; } } catch (_) {}
        return false;
    });
    return icon;
}

function compactOutput(width, height, name, primaryName) {
    return !!(primaryName && name !== primaryName) || width < 1280 || height > width;
}
function fullscreenWorkspace(workspace) {
    return !!(workspace && workspace.hasFullscreen && workspace.toplevels.values.some(function(window) {
        return (window.lastIpcObject || {}).fullscreen === 2;
    }));
}
function outputConfig(primaryConfig, secondaryConfig, compact) {
    if (!compact) return primaryConfig;
    if (Array.isArray(secondaryConfig["modules-left"])) return secondaryConfig;
    var config = Object.assign({}, primaryConfig);
    config["modules-left"] = modules(primaryConfig, "left").filter(function(name) {
        return name === "group/launcher" || name === "hyprland/workspaces" || name === "custom/logo" || name === "custom/ai_status";
    });
    config["modules-center"] = [];
    config["modules-right"] = enabled(primaryConfig).indexOf("custom/clock") >= 0 ? ["custom/clock"] : [];
    return config;
}
function findItem(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    var items = item.children || [];
    for (var i = 0; i < items.length; i++) {
        var found = findItem(items[i], name);
        if (found) return found;
    }
    return null;
}

// ── The retro bar (Theme.style "retro") ──────────────────────────────────────────────────────────────────────────
// A DOS status line: each module a short capital code and its value ("CPU 16% 40°C"), in Big Blue Term's own
// characters, so no glyph has to be guessed. One table holds the code, the tooltip's first line (what the code
// means) and how the helper's text becomes the value. A module not listed keeps its text, its symbols swapped.
var retroMarks = {"✓":"√", "⚠":"!", "🚨":"!", "◇":"♦", "◆":"♦", "…":"...", "—":"-", "–":"-", "\uFE0E":"", "\uFE0F":"",
    "☀":"sunny", "⛅":"partly cloudy", "☁":"cloudy", "🌫":"fog", "⛈":"storm", "🌩":"storm", "🌧":"rain", "🌦":"rain",
    "❄":"snow", "🌨":"snow"};
// (Split and join, not Array.from: QML's engine splits a string into UTF-16 units, which breaks up an emoji.)
function retroText(text) {
    var out = String(text || "");
    Object.keys(retroMarks).forEach(function(mark) { out = out.split(mark).join(retroMarks[mark]); });
    return out;
}
// The helper's words without its Nerd Font icons (the private-use areas), spaces collapsed.
function retroWords(text) {
    return String(text || "").replace(/[\uE000-\uF8FF]|[\uDB80-\uDBFF][\uDC00-\uDFFF]/g, "").replace(/\s+/g, " ").trim();
}
// 40° is 40°C; "207g/920g" names its unit once, on the total; gigabytes are G.
function retroUnits(text) {
    return String(text).replace(/(\d)°(?![CF])/g, "$1°C").replace(/(\d)g\/(\d)/gi, "$1/$2").toUpperCase();
}
function hasClass(sample, name) { return (sample.classes || []).indexOf(name) >= 0; }
var retroModules = {
    "custom/logo": {about: "MENU: the desk drawer"},
    "custom/ai_status": {code: "LLM", about: "LLM: the local model (IDLE: not loaded; used/total: GB of video memory)",
        value: function(sample) {
            return retroWords(sample.text).replace(/⚠\s*/, "").replace(/(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)g$/i, function(all, used, total) {
                return used + "/" + Math.round(Number(total)) + "G";
            }).toUpperCase();
        }},
    "custom/claude": {code: "CLAUDE", about: "CLAUDE: Claude Code sessions (RUN: working, WAIT: waiting for you, ERR: stopped)",
        value: function(sample) {
            var text = String(sample.text || ""), parts = /all done/.test(text) ? ["DONE"] : [];
            [["✎", "RUN"], ["◇", "WAIT"], ["!", "ERR"]].forEach(function(mark) {
                var count = text.match(new RegExp(mark[0] + "\\s*(\\d+)"));
                if (count) parts.push(count[1] + " " + mark[1]);
            });
            return parts.length ? parts.join(" ") : retroWords(retroText(text)).toUpperCase();
        }},
    "custom/api_credits": {code: "API", about: "API: API credits left this month",
        value: function(sample) {
            return retroWords(sample.text).replace(/^API\b/, "").replace(/[~·]/g, "").replace(/\$(\d[\d,]*)\.\d+/, "$$$1")
                .replace(/\s+/g, " ").trim().toUpperCase();
        }},
    // The problems while there are any, else the protections running; the tooltip lists both.
    "custom/foxml_sentry": {code: "SEC", about: "SEC: security (WARN or CRIT: problems; OK: protections running)",
        value: function(sample) {
            var counts = retroWords(sample.text).match(/\d+/g) || [];
            if (!counts.length) return "";
            return counts.length < 2 ? counts[0] + " OK" : counts[0] + (hasClass(sample, "critical") ? " CRIT" : " WARN");
        }},
    "custom/system_health": {code: "STRESS", about: "STRESS: the machine is under heavy load",
        value: function(sample) { return retroUnits(retroWords(sample.text)); }},
    "power-profiles-daemon": {code: "PWR", about: "PWR: power profile (TURBO: performance, BAL: balanced, SAVE: power saver)",
        value: function(sample) { return {performance: "TURBO", balanced: "BAL", "power-saver": "SAVE"}[(sample.classes || [])[0]] || "N/A"; }},
    "custom/battery": {code: "BAT", about: "BAT: battery (AC: on mains power, CHG: charging, W: watts in or out)",
        value: function(sample) {
            var text = String(sample.text || ""), level = text.match(/(\d+)%/), watts = text.match(/[+-]\d+W/);
            if (!level) return retroWords(retroText(text)).toUpperCase();
            var mains = text.indexOf("✓") >= 0 || text.indexOf("\u{F06A5}") >= 0 || hasClass(sample, "plugged") || hasClass(sample, "plugged-drain");
            return level[1] + "%" + (mains ? " AC" : "") + (watts ? " " + watts[0] : text.indexOf("ϟ") >= 0 ? " CHG" : "");
        }},
    "idle_inhibitor": {code: "AWAKE", about: "AWAKE: keep the screens on while idle", quiet: true,
        value: function(sample, state) { return state.idle ? "ON" : ""; }},
    "custom/net_speed": {code: "NET", about: "NET: network per second (↓ in, ↑ out; K: KB, M: MB)",
        value: function(sample) { return retroWords(sample.text).replace(/([↓↑])\s*/g, "$1").replace(/\s*([KM])B\/s/g, "$1").toUpperCase(); }},
    "custom/cpu": {code: "CPU", about: "CPU: processor load and temperature",
        value: function(sample) { return retroUnits(retroWords(sample.text)); }},
    "custom/gpu": {code: "GPU", about: "GPU: graphics card load and temperature (ON: awake, IDLE: asleep)",
        value: function(sample) { return retroUnits(retroWords(sample.text).replace(/⚠\s*/, "")); }},
    "memory": {code: "MEM", about: "MEM: memory in use / installed, in GB",
        value: function(sample) { return retroUnits(retroWords(sample.text)); }},
    "custom/disk": {code: "DSK", about: "DSK: disk space used / size of /, in GB",
        value: function(sample) { return retroUnits(retroWords(sample.text)); }},
    "custom/updates": {code: "UPD", about: "UPD: package updates waiting", quiet: true,
        value: function(sample) { var n = retroWords(String(sample.text || "").replace(/↻/g, "")); return /^0*$/.test(n.trim()) ? "" : n; }},
    "custom/clock": {value: function(sample) { return String(sample.text || "").trim().toUpperCase(); }}
};
// A module's sample as the retro bar shows it. A helper that printed nothing hides its module, as waybar does.
function retroSample(name, sample, state) {
    var row = retroModules[name] || {}, raw = sample || {};
    var tooltip = retroText(raw.tooltip || "");
    var out = {text: "", tooltip: row.about ? row.about + (tooltip ? "\n" + tooltip : "") : tooltip, classes: raw.classes || []};
    if (raw.silent || (!String(raw.text || "").trim() && name !== "idle_inhibitor")) return out;
    if (raw.failed) out.text = (row.code || retroWords(raw.text)) + " ERR";
    else if (!row.value) out.text = retroWords(retroText(raw.text));
    else {
        var value = row.value(raw, state || {});
        // A quiet one says nothing while there is nothing to say (no updates; the screens free to sleep).
        if (row.quiet && !value) return out;
        out.text = row.code ? row.code + (value ? " " + value : "") : value;
    }
    if (raw.percentage !== undefined) out.percentage = raw.percentage;
    if (raw.pins) out.pins = raw.pins;
    return out;
}
// Reverse video means it needs you: an alert, a session asking for you or just finished, a charger that is not
// charging, a large or long-unsynced update backlog. Critical ones blink.
var retroNeedsYou = ["critical", "error", "warning", "stopped", "asking", "done", "plugged-drain", "high"];
function retroAlert(classes) {
    return (classes || []).some(function(name) { return retroNeedsYou.indexOf(name) >= 0; });
}
function retroBlinks(classes) {
    return (classes || []).some(function(name) { return name === "critical" || name === "error"; });
}
// Three zones, left to right: where you are (the workspaces), your work (agents, the local model, API credits) as
// one group in the middle, then the machine. A layout that already uses the middle stays as it is.
var retroWork = ["custom/ai_status", "custom/claude", "custom/api_credits"];
// Not on the retro bar (her ask, 2026-11-16: less dense): the local model, API credits (the drawer has a page), the power
// profile, and the network, memory and disk readings. CPU and GPU stay: their load and temperature at a glance.
var retroHidden = ["custom/ai_status", "custom/api_credits", "power-profiles-daemon", "custom/net_speed", "memory", "custom/disk"];
function withoutHidden(config) {
    var out = Object.assign({}, config);
    ["left", "center", "right"].forEach(function(side) {
        out["modules-" + side] = modules(config, side).filter(function(name) { return retroHidden.indexOf(name) < 0; });
    });
    Object.keys(config).forEach(function(key) {
        if (key.indexOf("group/") === 0 && config[key] && Array.isArray(config[key].modules))
            out[key] = Object.assign({}, config[key], {modules: config[key].modules.filter(function(name) { return retroHidden.indexOf(name) < 0; })});
    });
    return out;
}
// What the bar reads and polls: on the retro bar, nothing it does not show (a hidden module's helper, cat /proc/meminfo
// every 5 s, powerprofilesctl every 10 s, ran for no one; Codex's review, 2026-11-18).
function shown(config, flat) { return flat ? withoutHidden(config) : config; }
function retroZones(config) {
    config = withoutHidden(config);
    if (modules(config, "center").length) return config;
    var zoned = Object.assign({}, config), work = [];
    ["left", "right"].forEach(function(side) {
        zoned["modules-" + side] = modules(config, side).filter(function(name) {
            if (retroWork.indexOf(name) < 0) return true;
            work.push(name);
            return false;
        });
    });
    if (!work.length) return config;
    zoned["modules-center"] = ["group/retro-work"];
    zoned["group/retro-work"] = {modules: work};
    return zoned;
}
