"""The environment desk-work's tests give what they start: without the running session's addresses (tmux, Neovim,
Hyprland, Wayland, X, D-Bus, kitty) and with a tmux socket folder of the test's own. With TMUX unset, a bare `tmux`
still finds the default server in /tmp/tmux-UID, so TMUX_TMPDIR is set too. The caller sets HOME and the XDG folders."""
import os

LIVE = ("TMUX", "TMUX_PANE", "NVIM", "NVIM_LISTEN_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK", "XDG_CACHE_HOME", "XDG_DATA_HOME")


def sealed(base, folder):
    """`base` (os.environ) without the session's addresses, kitty's included, and a tmux socket folder in `folder`."""
    env = {k: v for k, v in base.items() if k not in LIVE and not k.startswith("KITTY_")}
    env["TMUX_TMPDIR"] = os.path.join(folder, "tmux")
    os.makedirs(env["TMUX_TMPDIR"], mode=0o700, exist_ok=True)
    return env
