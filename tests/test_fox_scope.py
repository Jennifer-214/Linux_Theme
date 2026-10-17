#!/usr/bin/env python3
"""tests/test_fox_scope.py — run the fox-scope pi extension under node against a scratch folder tree.

fox-scope is TypeScript with only a type import from pi, so plain node ≥ 22 runs it (--experimental-strip-types)
without pi installed. Skips (passes) when node is missing or too old, per testing discipline.
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
tmp = Path(tempfile.mkdtemp(prefix="fox-scope-test-", dir=base))
try:
    shutil.copy(ROOT / "shared/pi/extensions/fox-scope.ts", tmp / "fox-scope.ts")
    home = tmp / "home"
    home.mkdir()
    env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(home / ".pi/agent"))
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-scope-test.mjs"), str(tmp / "fox-scope.ts"), str(home)],
                       capture_output=True, text=True, env=env)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-1500:] + r.stderr[-800:] if r.returncode else "    fox-scope: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
