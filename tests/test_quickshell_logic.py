#!/usr/bin/env python3
"""The Quickshell logic files' own tests (drawer, calendar), when node is installed. Before this they ran only when
run_changed.py saw the .mjs itself change, so a duplicate retro glyph (Today and Work health both ■) went unseen."""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if shutil.which("node") is None:
    print("    quickshell logic: skipped (no node)")
    sys.exit(0)
failed = False
for name in ("drawer-logic-test.mjs", "calendar-logic-test.mjs"):
    run = subprocess.run(["node", str(ROOT / "tests" / name)], capture_output=True, text=True, timeout=120)
    print(f"    {name}: " + ("ok" if run.returncode == 0 else "FAILED\n" + (run.stdout + run.stderr)[-3000:]))
    failed = failed or run.returncode != 0
sys.exit(1 if failed else 0)
