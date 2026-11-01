-- ╭──────────────────────────────────────────────────────────────────╮
-- │                        Environment                               │
-- ╰──────────────────────────────────────────────────────────────────╯

-- Wayland Session
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Cursor — XCURSOR_PATH includes ~/.local/share/icons because that's where
-- the catppuccin_cursor module drops the theme (XDG user dir, no sudo needed).
-- XCURSOR_THEME comes from the palette, in theme.lua.
-- XCURSOR_SIZE here is the pre-Hyprland fallback; start_waybar.sh overrides
-- it via `hyprctl setcursor` + `setenv` based on detected monitor scale.
hl.env("XCURSOR_SIZE", "24")
hl.env("XCURSOR_PATH", os.getenv("HOME") .. "/.local/share/icons:" .. os.getenv("HOME") .. "/.icons:/usr/share/icons:/usr/share/pixmaps")

-- Wayland
hl.env("MOZ_ENABLE_WAYLAND", "1")
-- env = WLR_NO_HARDWARE_CURSORS, 1

-- Apps
hl.env("NIXOS_OZONE_WL", "1")
hl.env("SPOTIFY_USE_WAYLAND", "1")

-- Qt Theming
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")

-- SSH agent — gnome-keyring-daemon (started in autostart.lua) provides the
-- socket; SSH_ASKPASS_REQUIRE=prefer forces the GUI dialog even with a TTY.
hl.env("SSH_AUTH_SOCK", os.getenv("XDG_RUNTIME_DIR") .. "/keyring/ssh")
hl.env("SSH_ASKPASS", "/usr/lib/seahorse/ssh-askpass")
hl.env("SSH_ASKPASS_REQUIRE", "prefer")
