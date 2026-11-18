#!/usr/bin/env python3
"""tests/test_pi_guard.py — run the desk-guard pi extension's rule table under node.

desk-guard is TypeScript; node ≥ 22 runs it directly with --experimental-strip-types.
Skips (passes) when node is missing or too old, per testing discipline.

desk-guard asks pi's OWN tools where a call lands (`import * as piApi from "@mariozechner/pi-coding-agent"` — pi's
loader maps that name to the running pi): under plain node the guard is handed the INSTALLED pi under that name, through
a node_modules link beside a copy of it, and the rows whose answer depends on the pi read its own resolver
(FOX_GUARD_PI_ROOT). Skips when pi is not installed.
"""
import json
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


def real_pi():
    """The installed pi's package: the first `pi` on PATH inside a package named …/pi-coding-agent. The theme's own
    launcher (shared/bin/pi, first on PATH once installed) is in none — it finds pi the same way (its realPi)."""
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        cand = Path(folder or ".") / "pi"
        if not cand.is_file():
            continue
        for pkg in cand.resolve().parents:
            try:
                if json.loads((pkg / "package.json").read_text()).get("name", "").endswith("/pi-coding-agent"):
                    return pkg
            except (OSError, ValueError, AttributeError):
                continue
    return None


pkg = real_pi()
if not pkg:
    print("    skip: pi not installed")
    sys.exit(0)
# Not /tmp: the noexec_tmp module mounts it noexec
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="desk-guard-test-", dir=base))
try:
    (tmp / "node_modules/@mariozechner").mkdir(parents=True)
    (tmp / "node_modules/@mariozechner/pi-coding-agent").symlink_to(pkg)
    shutil.copy(ROOT / "shared/pi/extensions/desk-guard.ts", tmp / "desk-guard.ts")
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/desk-guard-test.mjs"), str(tmp / "desk-guard.ts")],
                       capture_output=True, text=True, env=dict(os.environ, FOX_GUARD_PI_ROOT=str(pkg)))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-1200:] + r.stderr[-600:] if r.returncode else "    desk-guard: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
