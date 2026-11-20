#!/usr/bin/env python3
"""desk.tags (the tag-comment colours in C and C++): its headless test, when nvim is installed."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim tags: skipped (no nvim)")
    sys.exit(0)
# Sealed from the running session (tests/sealed_env.py): none of its addresses, and folders of its own.
with sealed_env.sealed("nvim-tags-") as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_tags.lua")], env, timeout=60)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
