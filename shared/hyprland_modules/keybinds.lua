-- ╭──────────────────────────────────────────────────────────────────╮
-- │                         Keybinds                                 │
-- ╰──────────────────────────────────────────────────────────────────╯

-- ─────────────────────────────────────────
-- App Variables
-- ─────────────────────────────────────────
local terminal = "kitty tmux new-session"
local browser = "env -u MOZ_ENABLE_WAYLAND -u LIBVA_DRIVER_NAME -u GBM_BACKEND -u WLR_NO_HARDWARE_CURSORS firefox"
local fileManager = "yazi"
local menu = "~/.local/bin/fox-desktop-menu root"
local coding = "~/.local/bin/cursor"
local chat = "discord"

local mainMod = "ALT"

-- ─────────────────────────────────────────
-- Applications
-- ─────────────────────────────────────────
-- Terminal (kitty + tmux).
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal))
-- Firefox.
hl.bind(mainMod .. " + F", hl.dsp.exec_cmd(browser))
-- Cursor (code editor).
hl.bind(mainMod .. " + SHIFT + C", hl.dsp.exec_cmd(coding))
-- FoxML drawers — apps, connections, sound, comfort and system.
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd(menu))
-- Calendar beneath the clock banner (toggle).
hl.bind(mainMod .. " + C", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu calendar"))
-- Steam.
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exec_cmd("steam steam://open/main"))
-- Yazi file manager (toggle).
hl.bind(mainMod .. " + SHIFT + Y", hl.dsp.exec_cmd("~/.config/launchers/toggle/toggle_yazi.sh"))
-- btop system monitor (toggle).
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/launchers/toggle/toggle_btop.sh"))
-- Network / Wi-Fi menu.
hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu wifi"))
-- Bluetooth menu.
hl.bind(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu bluetooth"))
-- Audio output switcher.
hl.bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu audio-outputs"))
-- Color picker (hyprpicker).
hl.bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd("hyprpicker -a"))
-- Discord.
hl.bind(mainMod .. " + SHIFT + I", hl.dsp.exec_cmd(chat))
-- Screenshot (GUI editor).
hl.bind(mainMod .. " + SHIFT + O", hl.dsp.exec_cmd("~/.config/hypr/scripts/screenshot.sh"))
-- Screenshot scrapbook (saved captures).
hl.bind(mainMod .. " + CTRL + O", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu screenshots"))
-- Toggle displays off (DPMS).
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.exec_cmd("~/.config/hypr/scripts/toggle_dpms.sh"))
-- Toggle the desktop bar.
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd("fox-bar toggle"))
-- Cycle wallpaper.
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd("~/.config/hypr/scripts/rotate_wallpaper.sh --cycle"))
-- Clipboard history — text.
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu clipboard-text"))
-- Clipboard history — images.
hl.bind(mainMod .. " + SHIFT + V", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu clipboard-images"))
-- Panic kill — terminate runaway processes.
hl.bind(mainMod .. " + SHIFT + K", hl.dsp.exec_cmd("~/.config/hypr/scripts/panic.sh"))
-- Power menu.
hl.bind(mainMod .. " + SHIFT + X", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu power"))
-- Agents — each Claude session with its context hearts and state, then pending notes; Enter switches tmux to that pane.
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu agents"))
-- Path of Building (Flatpak) — build planner; `pob 2` for PoE 2.
hl.bind(mainMod .. " + CTRL + P", hl.dsp.exec_cmd("~/.local/bin/pob"))

-- ─────────────────────────────────────────
-- Media Keys
-- ─────────────────────────────────────────
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("~/.config/hypr/scripts/osd.sh volume up"), { repeating = true, locked = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("~/.config/hypr/scripts/osd.sh volume down"), { repeating = true, locked = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("~/.config/hypr/scripts/osd.sh volume mute"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("~/.config/hypr/scripts/osd.sh brightness up"), { locked = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("~/.config/hypr/scripts/osd.sh brightness down"), { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("playerctl stop"), { locked = true })

-- ─────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────
-- Toggle window group (tabbed stack). Moved off ALT+G — that's Ghost Mode.
hl.bind(mainMod .. " + T", hl.dsp.group.toggle())
hl.bind(mainMod .. " + bracketleft", hl.dsp.group.prev())
hl.bind(mainMod .. " + bracketright", hl.dsp.group.next())
hl.bind(mainMod .. " + P", hl.dsp.window.pin())
hl.bind(mainMod .. " + S", hl.dsp.layout("togglesplit"))
hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.window.close())
-- gen-keybinds: allow-dup
hl.bind(mainMod .. " + SHIFT + G", function()
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
    hl.dispatch(hl.dsp.window.center())
end)
-- Reload Hyprland.
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))

-- ─────────────────────────────────────────
-- Window Focus
-- ─────────────────────────────────────────
hl.bind(mainMod .. " + h", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + j", hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + k", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + l", hl.dsp.focus({ direction = "right" }))

-- cycle_next is built at keypress time: with three cycle_next binds made at load time,
-- upstream reports both binds stepping backwards (hyprwm/Hyprland discussion 14716).
hl.bind(mainMod .. " + SHIFT + Tab", function() hl.dispatch(hl.dsp.window.cycle_next({ next = false })) end)
-- Jump focus through only floating windows (skip tiled). Tiled-only inverse on $mod+CTRL+Tab.
-- (We can't double up $mainMod since $mainMod is ALT — ALT+ALT+Tab wouldn't fire.)
hl.bind(mainMod .. " + Tab", function() hl.dispatch(hl.dsp.window.cycle_next({ floating = true })) end)
hl.bind(mainMod .. " + CTRL + Tab", function() hl.dispatch(hl.dsp.window.cycle_next({ tiled = true })) end)
-- Searchable keybind cheatsheet — fuzzy-find any binding by description
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu cheatsheet"))

-- ─────────────────────────────────────────
-- Workspaces
-- ─────────────────────────────────────────
hl.bind(mainMod .. " + comma", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + period", hl.dsp.focus({ workspace = "e+1" }))

hl.bind(mainMod .. " + 1", hl.dsp.focus({ workspace = 1 }))
hl.bind(mainMod .. " + 2", hl.dsp.focus({ workspace = 2 }))
hl.bind(mainMod .. " + 3", hl.dsp.focus({ workspace = 3 }))
hl.bind(mainMod .. " + 4", hl.dsp.focus({ workspace = 4 }))
hl.bind(mainMod .. " + 5", hl.dsp.focus({ workspace = 5 }))
hl.bind(mainMod .. " + 6", hl.dsp.focus({ workspace = 6 }))
hl.bind(mainMod .. " + 7", hl.dsp.focus({ workspace = 7 }))
hl.bind(mainMod .. " + 8", hl.dsp.focus({ workspace = 8 }))
hl.bind(mainMod .. " + 9", hl.dsp.focus({ workspace = 9 }))

hl.bind(mainMod .. " + SHIFT + 1", hl.dsp.window.move({ workspace = 1 }))
hl.bind(mainMod .. " + SHIFT + 2", hl.dsp.window.move({ workspace = 2 }))
hl.bind(mainMod .. " + SHIFT + 3", hl.dsp.window.move({ workspace = 3 }))
hl.bind(mainMod .. " + SHIFT + 4", hl.dsp.window.move({ workspace = 4 }))
hl.bind(mainMod .. " + SHIFT + 5", hl.dsp.window.move({ workspace = 5 }))
hl.bind(mainMod .. " + SHIFT + 6", hl.dsp.window.move({ workspace = 6 }))
hl.bind(mainMod .. " + SHIFT + 7", hl.dsp.window.move({ workspace = 7 }))
hl.bind(mainMod .. " + SHIFT + 8", hl.dsp.window.move({ workspace = 8 }))
hl.bind(mainMod .. " + SHIFT + 9", hl.dsp.window.move({ workspace = 9 }))

-- ─────────────────────────────────────────
-- Mouse
-- ─────────────────────────────────────────
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- ─────────────────────────────────────────
-- Sandbox launcher
-- ─────────────────────────────────────────
-- Drawer page for one-shot sandboxed apps. Firejail wraps the
-- target with --private so its tmpfs $HOME evaporates on close. Quick
-- way to visit a sketchy URL or run an untrusted script without it
-- touching your real dotfiles.
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu sandbox"))

-- ─────────────────────────────────────────
-- Ghost Mode (boss key)
-- ─────────────────────────────────────────
-- Boss key — hide waybar, mute audio, opacify + blur everything. Same
-- keybind toggles back to normal. State persists across keypresses via a
-- runtime file.
hl.bind(mainMod .. " + G", hl.dsp.exec_cmd("~/.config/hypr/scripts/ghost-mode.sh"))

-- ─────────────────────────────────────────
-- Window drawer
-- ─────────────────────────────────────────
-- Active windows with the same navigation as the other drawers.
hl.bind(mainMod .. " + grave", hl.dsp.exec_cmd("~/.local/bin/fox-desktop-menu windows"))

-- ─────────────────────────────────────────
-- TTY switch (diagnostics)
-- ─────────────────────────────────────────
-- CTRL+ALT+F1..F6 switches to a kernel TTY while Hyprland is responsive.
-- Won't escape a wedged hyprlock — hyprlock holds the seat grab so neither
-- Hyprland nor the kernel sees these keys. For wedge recovery, enable
-- kernel.sysrq=1 in /etc/sysctl.d and use Alt+SysRq+r followed by Ctrl+Alt+F2.
--
-- chvt requires CAP_SYS_TTY_CONFIG. Either run with `sudo chvt` via a
-- NOPASSWD sudoers rule for the wheel user, or set chvt setuid root.
hl.bind("CTRL + ALT + F1", hl.dsp.exec_cmd("chvt 1"))
hl.bind("CTRL + ALT + F2", hl.dsp.exec_cmd("chvt 2"))
hl.bind("CTRL + ALT + F3", hl.dsp.exec_cmd("chvt 3"))
hl.bind("CTRL + ALT + F4", hl.dsp.exec_cmd("chvt 4"))
hl.bind("CTRL + ALT + F5", hl.dsp.exec_cmd("chvt 5"))
hl.bind("CTRL + ALT + F6", hl.dsp.exec_cmd("chvt 6"))

-- ─────────────────────────────────────────
-- Resize / move submap
-- ─────────────────────────────────────────
-- Resize / move mode. ALT+R enters: bare hjkl resize the focused window,
-- SHIFT+hjkl move it (moveactive — floating windows only, by pixels). binde
-- repeats on hold so you can glide. Escape or Return exits.
hl.bind(mainMod .. " + R", hl.dsp.submap("resize"))

hl.define_submap("resize", function()
    hl.bind("h", hl.dsp.window.resize({ x = -40, y = 0, relative = true }), { repeating = true })
    hl.bind("j", hl.dsp.window.resize({ x = 0, y = 40, relative = true }), { repeating = true })
    hl.bind("k", hl.dsp.window.resize({ x = 0, y = -40, relative = true }), { repeating = true })
    hl.bind("l", hl.dsp.window.resize({ x = 40, y = 0, relative = true }), { repeating = true })
    hl.bind("SHIFT + h", hl.dsp.window.move({ x = -40, y = 0, relative = true }), { repeating = true })
    hl.bind("SHIFT + j", hl.dsp.window.move({ x = 0, y = 40, relative = true }), { repeating = true })
    hl.bind("SHIFT + k", hl.dsp.window.move({ x = 0, y = -40, relative = true }), { repeating = true })
    hl.bind("SHIFT + l", hl.dsp.window.move({ x = 40, y = 0, relative = true }), { repeating = true })
    hl.bind("escape", hl.dsp.submap("reset"))
    hl.bind("return", hl.dsp.submap("reset"))
end)
