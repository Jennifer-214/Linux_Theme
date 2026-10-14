#!/usr/bin/env python3
"""tests/test_fox_guard.py — run the fox-guard pi extension's rule table under node.

fox-guard is TypeScript; node ≥ 22 runs it directly with --experimental-strip-types.
Skips (passes) when node is missing or too old, per testing discipline.

fox-guard asks pi's OWN tools where a call lands (`import * as piApi from "@mariozechner/pi-coding-agent"` — pi's
loader maps that name to the running pi): under plain node the guard is handed the INSTALLED pi under that name, through
a node_modules link beside a copy of it, and the rows whose answer depends on the pi read its own resolver
(FOX_GUARD_PI_ROOT). Skips when pi is not installed.
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
pi = shutil.which("pi")
if not pi:
    print("    skip: pi not installed")
    sys.exit(0)
pkg = Path(pi).resolve().parent
while not (pkg / "package.json").exists() and pkg != pkg.parent:
    pkg = pkg.parent
# Not /tmp: the noexec_tmp module mounts it noexec
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="fox-guard-test-", dir=base))
try:
    (tmp / "node_modules/@mariozechner").mkdir(parents=True)
    (tmp / "node_modules/@mariozechner/pi-coding-agent").symlink_to(pkg)
    shutil.copy(ROOT / "shared/pi/extensions/fox-guard.ts", tmp / "fox-guard.ts")
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-guard-test.mjs"), str(tmp / "fox-guard.ts")],
                       capture_output=True, text=True, env=dict(os.environ, FOX_GUARD_PI_ROOT=str(pkg)))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-1200:] + r.stderr[-600:] if r.returncode else "    fox-guard: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
