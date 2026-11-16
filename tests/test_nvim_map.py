#!/usr/bin/env python3
"""desk.map (the project map: its syntax reader, its pages at each zoom, the view with a fake desk-work, its keys as
rows of the action registry): its headless test, when nvim is installed. A language whose treesitter parser is missing
is skipped and named. Neovim runs sealed from the session (tests/sealed_env.py): private state, cache, config and
runtime folders, none of the session's addresses; HOME and the data folder stay, for the installed parsers."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim project map: skipped (no nvim)")
    sys.exit(0)
with sealed_env.sealed("desk-map-", keep_home=True) as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_map.lua")], env, timeout=180)
print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
# A Neovim that quits before its summary line (a prompt meeting the end of its input) did not pass.
if run.returncode == 0 and "test_map:" not in run.stdout + run.stderr:
    print("    test_map: ended before its summary")
    sys.exit(1)
sys.exit(run.returncode)
