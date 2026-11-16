#!/usr/bin/env python3
"""desk.nav's jump labels (s in the review's file list and the call graph, drawn by flash.nvim when it is installed)
and the keys beside them (s in a diff, gs for symdeps): its headless test, when nvim is installed."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim nav: skipped (no nvim)")
    sys.exit(0)
# Sealed from the running session (tests/sealed_env.py): none of its addresses, and folders of its own; HOME and the
# data folder stay, as test_nav.lua draws the labels with the flash.nvim installed in ~/.local/share/nvim/lazy.
with sealed_env.sealed("nvim-nav-", keep_home=True) as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_nav.lua")], env, timeout=120)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
