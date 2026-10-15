#!/usr/bin/env python3
"""tests/test_fox_notify.py — run the fox-notify pi extension under node with a fake pi (tests/fox-notify-test.mjs).

fox-notify is TypeScript with only a type import from pi, so plain node ≥ 22 runs it (--experimental-strip-types)
without pi installed. Skips (passes) when node is missing or too old, per testing discipline. Nothing is sent: the
fake pi records each notify-send argv instead of running it.
"""
import os
import shutil
import subprocess
import sys
import tempfile
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
# Not /tmp: the noexec_tmp module mounts it noexec
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="fox-notify-test-", dir=base))
try:
    shutil.copy(ROOT / "shared/pi/extensions/fox-notify.ts", tmp / "fox-notify.ts")
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-notify-test.mjs"), str(tmp / "fox-notify.ts")],
                       capture_output=True, text=True, timeout=60)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-1500:] + r.stderr[-800:] if r.returncode else "    fox-notify: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
