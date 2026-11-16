#!/usr/bin/env python3
"""desk.nav's jump labels (s in the review's file list and the call graph, drawn by flash.nvim when it is installed)
and the keys beside them (s in a diff, gs for symdeps): its headless test, when nvim is installed."""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim nav: skipped (no nvim)")
    sys.exit(0)
run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_nav.lua")],
                     capture_output=True, text=True, timeout=120)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
