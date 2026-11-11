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
