-- FoxML Theme Hub — main Hyprland config (Hyprland 0.57+ reads only Lua)
-- Loads every module in ~/.config/hypr/modules/ in order; Hyprland puts this
-- file's directory first on package.path, so "modules.keybinds" resolves to
-- ~/.config/hypr/modules/keybinds.lua. nvidia.lua is written by the nvidia
-- module (or as a comment-only placeholder), monitors.lua by the monitors step.
-- To override or add personal bindings/settings, append them below the loop.

local modules = {
    "app_shortcuts",
    "autostart",
    "environment",
    "general",
    "input",
    "keybinds",
    "monitors",
    "rules",
    "scratchpads",
    "theme",
    "workspace_layout",
    "nvidia",
}

for _, name in ipairs(modules) do
    require("modules." .. name)
end

-- This machine's own settings (the drawer's Displays page writes the pointer size here). Optional,
-- and loaded last: a mistake in it shows as Hyprland's config error after everything else applied.
pcall(require, "modules.local")
