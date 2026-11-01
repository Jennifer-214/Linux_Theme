-- ─── Workspace Layout ─────────────────────────
-- Note: workspace 1 default-monitor binding lives in rules.lua so it can use
-- the monitor name set in monitors.lua. Don't duplicate it here.
-- Note: kitty + tmux startup is handled by autostart.lua — don't re-add it here
-- or you'll get two terminals on login.


hl.window_rule({
    name = "spotify-music-scratchpad",
    match = { class = "^(Spotify)$" },
    float = true,
    size = "1800 1000",
    center = true,
    workspace = "special:music silent",
})
