-- ─── Workspace Layout ─────────────────────────
-- Note: workspace 1 default-monitor binding lives in rules.lua so it can use
-- the monitor name set in monitors.lua. Don't duplicate it here.
-- Note: kitty + tmux startup is handled by autostart.lua — don't re-add it here
-- or you'll get two terminals on login.


hl.window_rule({
    name = "spotify-music-scratchpad",
    match = { class = "^(Spotify)$" },
    float = true,
    size = { "monitor_w*0.9", "monitor_h*0.3+monitor_w*0.35" }, -- 90% of the screen width (see scratchpads.lua)
    center = true,
    workspace = "special:music silent",
})
