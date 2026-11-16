#!/usr/bin/env python3
"""desk.planmarks (the plan's references, marked in the files): its headless test, when nvim is installed, sealed from
the session (tests/sealed_env.py)."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim plan marks: skipped (no nvim)")
    sys.exit(0)
with sealed_env.sealed("nvim-planmarks-") as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_planmarks.lua")], env, timeout=60)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
sys.exit(run.returncode)
