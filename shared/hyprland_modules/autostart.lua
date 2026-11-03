-- ╭──────────────────────────────────────────────────────────────────╮
-- │                         Autostart                                │
-- ╰──────────────────────────────────────────────────────────────────╯

-- ─────────────────────────────────────────
-- Core Services
-- ─────────────────────────────────────────
hl.on("hyprland.start", function()
    hl.exec_cmd("~/.config/hypr/scripts/env-init.sh")
    hl.exec_cmd("~/.config/hypr/scripts/startup.sh")
    -- Audio: pipewire (modern Arch default) starts via systemd-user; no exec-once needed.
    -- If you're on classic pulseaudio, uncomment the next line.
    -- exec-once = pulseaudio --start
    -- Apply the static wallpaper at boot. Rotation is OFF by default — opt in with
    -- `fox-wallpaper --rotate on` if you want time-of-day cycling. The script still
    -- handles starting awww-daemon and waiting for its socket.
    hl.exec_cmd("~/.config/hypr/scripts/rotate_wallpaper.sh --static")
    -- Hot-swap watcher is the fox-pulse daemon (fox-pulse.service), managed via
    -- systemd user unit rather than exec-once. On a monitor event it runs
    -- `fox-monitor reconcile`. The systemd path survives SIGHUP and auto-
    -- restarts on failure; exec-once backgrounded scripts were exiting silently
    -- when Hyprland's spawn parent terminated. (Supersedes fox-monitor-watch.)

    -- First-launch tour — shows the keybind cheatsheet on the first Hyprland
    -- session after install. Self-gated by ~/.local/share/foxml/.first-launch-shown,
    -- so this is silent on every session after the first.
    hl.exec_cmd("~/.config/hypr/scripts/first-launch-tour.sh")
    -- hypridle is launched (and its config swapped on AC/battery transitions) by
    -- the power-state-watcher.service systemd user unit, not directly here.

    -- ─────────────────────────────────────────
    -- Authentication
    -- ─────────────────────────────────────────
    hl.exec_cmd("/usr/bin/gnome-keyring-daemon --start --components=pkcs11,secrets,ssh,gpg")
    -- Polkit auth agent for graphical privilege prompts (GNOME Disks, blueman,
    -- fprintd verify, etc.). Without an agent, polkit denies any action that
    -- needs user authentication — surfaces as silent failures in GUI apps and
    -- "Authorization denied" entries in the system journal.
    hl.exec_cmd("systemctl --user start hyprpolkitagent")

    -- ─────────────────────────────────────────
    -- Clipboard History
    -- ─────────────────────────────────────────
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")

    -- ─────────────────────────────────────────
    -- Night light — start neutral; the drawer toggles Hyprsunset over IPC.
    -- ─────────────────────────────────────────
    hl.exec_cmd("hyprsunset --identity")

    -- ─────────────────────────────────────────
    -- Initial Apps
    -- ─────────────────────────────────────────
    hl.exec_cmd("kitty --title Terminal1 tmux new-session")
end)
