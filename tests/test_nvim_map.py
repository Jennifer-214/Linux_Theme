#!/usr/bin/env python3
"""desk.map (the project map: its syntax reader, its pages at each zoom, the view with a fake desk-work): its
headless test, when nvim is installed. A language whose treesitter parser is missing is skipped and named."""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim project map: skipped (no nvim)")
    sys.exit(0)
run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_map.lua")],
                     capture_output=True, text=True, timeout=180)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
