-- Minimal Hyprland config for the greetd greeter (Hyprland 0.57+ reads only Lua)
-- Runs regreet inside Hyprland instead of cage — no TTY flash

-- select-monitor.sh prunes external outputs when a laptop panel is present,
-- so regreet lands on the built-in display regardless of monitor names. On
-- desktops it's a no-op. Installed alongside this config by the greetd module.
-- GTK_THEME=Adwaita:dark: GTK4 renders its first frames BEFORE regreet's
-- settings/custom CSS apply — with light Adwaita base that's the white
-- flash at boot. The env var takes effect at process start, so even the
-- pre-CSS frames come up dark.
-- Once regreet exits (a login started) the greeter session closes itself: the
-- Lua dispatch on 0.57, then the legacy form for older releases (whichever one
-- the running Hyprland doesn't understand fails harmlessly).
hl.on("hyprland.start", function()
    hl.exec_cmd("/etc/greetd/select-monitor.sh; sleep 0.3 && GTK_THEME=Adwaita:dark regreet; "
        .. "hyprctl dispatch 'hl.dsp.exit()'; hyprctl dispatch exit")
end)

-- ─── Monitor ────────────────────────────────────
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

hl.config({
    -- ─── Input ──────────────────────────────────────
    input = {
        kb_layout = "us",
    },

    -- ─── Appearance (minimal — regreet handles its own styling) ──
    general = {
        gaps_in = 0,
        gaps_out = 0,
        border_size = 0,
    },
    decoration = {
        blur = { enabled = false },
        shadow = { enabled = false },
    },
    animations = {
        enabled = false,
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        -- greetd starts Hyprland directly, not through the start-hyprland watchdog;
        -- without this, 0.57 paints a red warning banner over the login screen.
        disable_watchdog_warning = true,
        -- Theme-dark compositor canvas from the first modeset — the other
        -- half of the boot white-flash fix (regreet.css window bg only
        -- applies once regreet's custom CSS loads).
        background_color = "rgba(1a1214ff)",
    },
})
