#!/usr/bin/env python3
"""desk.planmarks (the plan's references, marked in the files): its headless test, when nvim is installed."""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim plan marks: skipped (no nvim)")
    sys.exit(0)
run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_planmarks.lua")],
                     capture_output=True, text=True, timeout=60)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
