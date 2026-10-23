#!/usr/bin/env python3
"""The early drift stop runs before anything can change the machine (installer batch 3a, 2026-10-23): in the
installer's main file the drift_stops_before_install block must come before the sudo warmup and before the module
dispatch loop's m.fn(ctx). If a refactor moves it after either, a -y run with live edits could again stop half-way,
after root modules ran."""
import pathlib, sys

src = (pathlib.Path(__file__).resolve().parent.parent / "src" / "desk-install" / "desk-install.cpp").read_text()
stop = src.find("drift_stops_before_install(")
warm = src.find("sh::sudo_warmup_interactive()")
dispatch = src.find("m.fn(ctx);")
fails = []
if stop < 0:
    fails.append("the early drift stop is missing from the installer's main file")
if warm < 0:
    fails.append("the sudo warmup call is not found: the check can no longer see it")
elif not (0 <= stop < warm):
    fails.append("the early drift stop comes after the sudo warmup")
if dispatch < 0:
    fails.append("the module dispatch call is not found: the check can no longer see it")
elif not (0 <= stop < dispatch):
    fails.append("the early drift stop comes after the module dispatch")
for f in fails:
    print("FAIL", f)
print("drift stop order:", "OK" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
