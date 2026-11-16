#!/usr/bin/env python3
"""desk.bridge (shared/nvim_lua/desk/bridge.lua: the messages other programs send a running Neovim, and what they may
open there): its headless test, when nvim is installed. The editor runs in a disposable home and runtime folder; the
test itself connects to no socket (src/desk-work/tests/test_work.py sends the same messages over one)."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim bridge: skipped (no nvim)")
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix="desk-bridge-") as temp:
    base = Path(temp)
    (base / "runtime").mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(base / "home"), XDG_RUNTIME_DIR=str(base / "runtime"), XDG_STATE_HOME=str(base / "state"),
               XDG_CONFIG_HOME=str(base / "config"), XDG_CACHE_HOME=str(base / "cache"), NVIM_LOG_FILE=str(base / "nvim.log"))
    run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_bridge.lua")],
                         capture_output=True, text=True, timeout=120, env=env)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
