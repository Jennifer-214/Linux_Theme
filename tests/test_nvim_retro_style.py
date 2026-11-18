#!/usr/bin/env python3
"""Every desk view drawn in retro-amber uses only Big Blue Term's characters (code page 437) and keeps its headings in
capitals: shared/nvim_lua/tests/test_retro_style.lua, headless, when nvim is installed."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim retro style: skipped (no nvim)")
    sys.exit(0)
with sealed_env.sealed("nvim-retro-style-") as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_retro_style.lua")], env, timeout=120)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
