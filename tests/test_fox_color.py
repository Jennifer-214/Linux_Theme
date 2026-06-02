#!/usr/bin/env python3
"""Unit test for shared/bin/fox-color — the OKLCH selection-color derivation.

Run directly (`python3 tests/test_fox_color.py`) or via `make test` (the test-scripts target).
Exit 0 = pass, 1 = fail. Dependency-free.
"""
import importlib.machinery
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fc = importlib.machinery.SourceFileLoader("fc", str(ROOT / "shared/bin/fox-color")).load_module()

fails = []
def check(name, cond):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


# 1 · roundtrip identity — validates the sRGB↔OKLab matrices (must be exact to ±1/255)
for c in ["000000", "ffffff", "d4985a", "8a9a7a", "2ea3f2", "e8a4b8", "7fbbb3", "1a1214"]:
    rt = fc.oklch_to_hex(*fc.hex_to_oklch(c))
    drift = max(abs(int(rt[i:i + 2], 16) - int(c[i:i + 2], 16)) for i in (0, 2, 4))
    check(f"roundtrip {c} -> {rt} (drift {drift})", drift <= 1)

# 2 · golden derivations — lock the shipped theme selection colors (a retune must update these)
for accent, expect in [("d4985a", "372411"), ("2ea3f2", "072b45"), ("e8a4b8", "372228")]:
    got = fc.derive_selection(accent)
    check(f"derive_selection({accent}) == {expect} (got {got})", got == expect)

# 3 · invariants — the derived selection is DARK, MUTED, and on the accent's HUE, for any accent
for accent in ["d4985a", "2ea3f2", "e8a4b8", "8a9a7a", "ff0000", "00ff00", "0000ff"]:
    Ls, Cs, Hs = fc.hex_to_oklch(fc.derive_selection(accent))
    La, Ca, Ha = fc.hex_to_oklch(accent)
    check(f"{accent}: selection dark (L={Ls:.2f} < 0.40)", Ls < 0.40)
    check(f"{accent}: selection muted (C={Cs:.3f} < accent {Ca:.3f})", Cs < Ca + 1e-9)
    hue_delta = abs(((math.degrees(Hs) - math.degrees(Ha) + 180) % 360) - 180)
    check(f"{accent}: selection on-hue (Δ={hue_delta:.0f}° < 8°)", hue_delta < 8)

# 4 · output is always a valid 6-digit hex, even for out-of-gamut inputs
for accent in ["000000", "ffffff", "ff00ff", "00ffff"]:
    sel = fc.derive_selection(accent)
    check(f"derive({accent}) -> valid hex {sel}", len(sel) == 6 and all(ch in "0123456789abcdef" for ch in sel))

print(f"\nfox-color: {'ALL PASS' if not fails else str(len(fails)) + ' FAILED'}")
sys.exit(1 if fails else 0)
