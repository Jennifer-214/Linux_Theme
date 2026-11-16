#!/usr/bin/env python3
"""desk.map (the project map: its syntax reader, its pages at each zoom, the view with a fake desk-work, its keys as
rows of the action registry): its headless test, when nvim is installed. A language whose treesitter parser is missing
is skipped and named, except in the required CI run (tests/required.py), where it fails like a missing nvim. Neovim
runs sealed from the session (tests/sealed_env.py): private state, cache, config and runtime folders, none of the
session's addresses; HOME and the data folder stay, for the installed parsers (site/parser under Neovim's data
folder, where CI puts its python and cpp parsers too)."""
import shutil
import sys
from pathlib import Path

from required import REQUIRED
import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim project map: " + ("FAILED: requires nvim, in the required run" if REQUIRED else "skipped (requires nvim)"))
    sys.exit(1 if REQUIRED else 0)
with sealed_env.sealed("desk-map-", keep_home=True) as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_map.lua")], env, timeout=180)
said = run.stdout + run.stderr
print("    " + said.strip().replace("\n", "\n    "))
# A Neovim that quits before its summary line (a prompt meeting the end of its input) did not pass.
if run.returncode == 0 and "test_map:" not in said:
    print("    test_map: ended before its summary")
    sys.exit(1)
if run.returncode == 0 and REQUIRED and "(skipped: " in said:
    print("    test_map: FAILED: requires the treesitter parsers it skipped, in the required run")
    sys.exit(1)
sys.exit(run.returncode)
