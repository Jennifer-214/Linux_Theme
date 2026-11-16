#!/usr/bin/env python3
"""desk.actions (the one list of actions: the keys, which-key's words, the home menu, the pop-out's door): its headless
test, when nvim is installed."""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim actions: skipped (no nvim)")
    sys.exit(0)
run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_actions.lua")],
                     capture_output=True, text=True, timeout=120)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
