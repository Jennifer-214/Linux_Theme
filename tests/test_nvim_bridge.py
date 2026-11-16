#!/usr/bin/env python3
"""desk.bridge (shared/nvim_lua/desk/bridge.lua: the messages other programs send a running Neovim, and what they may
open there): its headless test, when nvim is installed. The editor runs sealed from the session (tests/sealed_env.py):
a disposable home and runtime folder, none of the session's addresses; the test itself connects to no socket
(src/desk-work/tests/test_work.py sends the same messages over one)."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim bridge: skipped (no nvim)")
    sys.exit(0)
with sealed_env.sealed("desk-bridge-") as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_bridge.lua")], env, timeout=120)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
