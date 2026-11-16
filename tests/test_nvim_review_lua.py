#!/usr/bin/env python3
"""desk.review's calls and callers (what a change calls, compared per function; who calls what it changed; read without
holding the editor up) and its list as the pop-out draws it: shared/nvim_lua/tests/test_review.lua, headless, when nvim
and git are installed. The language server and the project map are fakes in the test."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None or shutil.which("git") is None:
    print("    nvim review (Lua): skipped (needs nvim and git)")
    sys.exit(0)
# Sealed from the running session: no tmux, Hyprland, Wayland, D-Bus or kitty address reaches the test, and its state,
# cache, runtime, log and tmux socket folders are its own. The Lua seals itself again (PATH holds git only).
LIVE = ("TMUX", "TMUX_PANE", "NVIM", "NVIM_LISTEN_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK")
with tempfile.TemporaryDirectory(prefix="nvim-review-lua-") as tmp:
    env = {k: v for k, v in os.environ.items() if k not in LIVE}
    for name in ("XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMUX_TMPDIR"):
        env[name] = os.path.join(tmp, name.lower())
        os.makedirs(env[name], mode=0o700)
    env["NVIM_LOG_FILE"] = os.path.join(tmp, "nvim.log")
    run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_review.lua")],
                         capture_output=True, text=True, timeout=240, env=env)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
# A Neovim that quits before its summary line (an error, a prompt meeting the end of its input) did not pass.
if run.returncode == 0 and "test_review:" not in run.stdout + run.stderr:
    print("    test_review: ended before its summary")
    sys.exit(1)
sys.exit(run.returncode)
