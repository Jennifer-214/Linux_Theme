#!/usr/bin/env python3
"""tests/test_fox_guard.py — run the fox-guard pi extension's rule table under node.

fox-guard is TypeScript; node ≥ 22 runs it directly with --experimental-strip-types.
Skips (passes) when node is missing or too old, per testing discipline.
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

node = shutil.which("node")
if not node:
    print("    skip: node not installed")
    sys.exit(0)
major = int(subprocess.run([node, "--version"], capture_output=True, text=True).stdout.lstrip("v").split(".")[0])
if major < 22:
    print(f"    skip: node {major} has no --experimental-strip-types")
    sys.exit(0)
r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                    str(ROOT / "tests/fox-guard-test.mjs"),
                    str(ROOT / "shared/pi/extensions/fox-guard.ts")],
                   capture_output=True, text=True)
print(r.stdout[-400:] if r.returncode else "    fox-guard: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
