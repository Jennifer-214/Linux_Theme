#!/usr/bin/env python3
"""fox sec health doesn't pass when nothing was checked (installer batch 3a, audit "known item"): a filter that matches no
check exits 1 with a message, where it used to exit 0 like an all-green run. Runs the in-tree binary with filters that
match nothing, so no check ever executes. Skips (passes) when the binary isn't built."""
import pathlib, subprocess, sys

BIN = pathlib.Path(__file__).resolve().parent.parent / "src/fox-sec-health/fox-sec-health"
if not BIN.exists():
    print("health zero checks: skipped (fox-sec-health not built)"); sys.exit(0)
fails = []
# every check filtered out by an option → exit 1 + the message (no check executes)
for args in (["--only", "ZZ-NO-SUCH-CHECK", "--quiet"], ["--only", "ZZ-NO-SUCH-CHECK"], ["--only", "A", "--exclude", "A"],
             ["--only", "A2", "--no-slow"]):   # A2 is the slow check: --no-slow leaves nothing
    r = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=60)
    if r.returncode != 1 or "no checks ran" not in r.stderr:
        fails.append(f"{' '.join(args)}: exit {r.returncode}, stderr {r.stderr.strip()[:80]!r}")
# a real check ran (A1 reads the running kernel's module tree — read-only) → never the "no checks" message
r = subprocess.run([str(BIN), "--only", "A1", "--no-slow", "--quiet"], capture_output=True, text=True, timeout=60)
if "no checks ran" in r.stderr:
    fails.append("a run where A1 executed was reported as 'no checks ran'")
for f in fails:
    print("FAIL", f)
print("health zero checks:", "OK" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
