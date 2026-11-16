#!/usr/bin/env python3
"""desk.review's calls and callers (what a change calls, compared per function; who calls what it changed; read without
holding the editor up) and its list as the pop-out draws it: shared/nvim_lua/tests/test_review.lua, headless, when nvim
and git are installed. The language server and the project map are fakes in the test."""
import shutil
import sys
from pathlib import Path

import sealed_env

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None or shutil.which("git") is None:
    print("    nvim review (Lua): skipped (needs nvim and git)")
    sys.exit(0)
# Sealed from the running session (tests/sealed_env.py): none of its addresses, and folders of its own, HOME too (the
# test reads nothing installed: the Lua and C parsers come with Neovim). The Lua seals itself again: PATH holds git only.
with sealed_env.sealed("nvim-review-lua-") as (env, _):
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_review.lua")], env, timeout=240)
said = run.stdout + run.stderr
print("    " + said.strip().replace("\n", "\n    "))
# A Neovim that quits before its summary line (an error, a prompt meeting the end of its input) did not pass.
if run.returncode == 0 and "test_review:" not in said:
    print("    test_review: ended before its summary")
    sys.exit(1)
sys.exit(run.returncode)
