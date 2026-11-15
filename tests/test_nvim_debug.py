#!/usr/bin/env python3
"""desk.debug (C/C++ debugging through the system gdb): its headless test, when nvim is installed. The Lua test checks
the program finder on its own scratch project; this adds a real gdb session when a compiler, gdb and nvim-dap are
here. The program is built under the cache folder, not /tmp: /tmp is noexec here and gdb has to run it."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if shutil.which("nvim") is None:
    print("    nvim debugger: skipped (no nvim)")
    sys.exit(0)

SOURCE = "#include <stdio.h>\nint main(void) {\n    int x = 41;\n    x = x + 1;\n    printf(\"%d\\n\", x);\n    return 0;\n}\n"

cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=cache, prefix="desk-debug-test-") as scratch:
    env = dict(os.environ)
    dap = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "nvim/lazy/nvim-dap"
    compiler = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if dap.is_dir():
        env["DEBUG_TEST_DAP"] = str(dap)
        source, program = Path(scratch) / "main.c", Path(scratch) / "app"
        source.write_text(SOURCE)
        if compiler and shutil.which("gdb") and subprocess.run([compiler, "-g", "-O0", "-o", str(program), str(source)]).returncode == 0:
            env.update(DEBUG_TEST_PROGRAM=str(program), DEBUG_TEST_SOURCE=str(source))
    run = subprocess.run(["nvim", "--headless", "--clean", "-l", str(REPO / "shared/nvim_lua/tests/test_debug.lua")],
                         capture_output=True, text=True, timeout=90, env=env)
    print("    " + (run.stdout + run.stderr).strip().replace("\n", "\n    "))
    sys.exit(run.returncode)
