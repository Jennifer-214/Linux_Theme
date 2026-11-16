#!/usr/bin/env python3
"""desk.map (the project map: its syntax reader, its pages at each zoom, the view with a fake desk-work, its keys as
rows of the action registry): its headless test, when nvim is installed. A language whose treesitter parser is missing
is skipped and named. Neovim runs with private state, cache, config and runtime folders and no tmux, Neovim or
Hyprland of hers in reach; the data folder stays, for the installed parsers."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim project map: skipped (no nvim)")
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix="desk-map-") as home:
    runtime = Path(home) / "runtime"
    runtime.mkdir(mode=0o700)
    env = {k: v for k, v in os.environ.items()
           if k not in ("TMUX", "TMUX_PANE", "NVIM", "NVIM_LISTEN_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY")}
    env.update(XDG_STATE_HOME=home, XDG_CACHE_HOME=home, XDG_CONFIG_HOME=home, XDG_RUNTIME_DIR=str(runtime))
    run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_map.lua")],
                         capture_output=True, text=True, timeout=180, env=env)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
