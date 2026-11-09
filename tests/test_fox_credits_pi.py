#!/usr/bin/env python3
"""tests/test_fox_credits_pi.py — run the fox-credits pi extension under node with a fake pi and fake fox-credits.

The extension has only a type import from pi, so plain node ≥ 22 runs it. Skips (passes) when node is missing or old.
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
# Not /tmp: it is mounted noexec here, and the fake fox-credits has to run.
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="fox-credits-pi-test-", dir=base))
try:
    audit = tmp / "calls.txt"
    fake = tmp / "fox-credits"
    fake.write_text('#!/bin/sh\necho "$*" >> "$TEST_AUDIT"\n'
                    'if [ "$1" = status ]; then echo \'{"short": "API ~$199.99 left"}\'; fi\n')
    fake.chmod(0o755)
    shutil.copy(ROOT / "shared/pi/extensions/fox-credits.ts", tmp / "fox-credits.ts")
    env = dict(os.environ, FOX_CREDITS_BIN=str(fake), TEST_AUDIT=str(audit))
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-credits-pi-test.mjs"), str(tmp / "fox-credits.ts")],
                       capture_output=True, text=True, env=env, timeout=60)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout + r.stderr)
sys.exit(r.returncode)
