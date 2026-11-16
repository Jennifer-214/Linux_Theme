#!/usr/bin/env python3
"""desk.nav's jump labels (s in the review's file list and the call graph, drawn by flash.nvim when it is installed)
and the keys beside them (s in a diff, gs for symdeps): its headless test, when nvim is installed."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim nav: skipped (no nvim)")
    sys.exit(0)
# Sealed from the running session: no tmux, Hyprland, Wayland, D-Bus or kitty address reaches the test, and its state,
# cache, runtime and tmux socket folders are its own (with TMUX unset, a bare `tmux` would still find the real server).
LIVE = ("TMUX", "TMUX_PANE", "NVIM", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK")
with tempfile.TemporaryDirectory(prefix="nvim-nav-") as tmp:
    env = {k: v for k, v in os.environ.items() if k not in LIVE}
    for name in ("XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMUX_TMPDIR"):
        env[name] = os.path.join(tmp, name.lower())
        os.makedirs(env[name], mode=0o700)
    run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_nav.lua")],
                         capture_output=True, text=True, timeout=120, env=env)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
