#!/usr/bin/env python3
"""noice.nvim and Neovim 0.12's :restart (VM test 2026-11-16, F11). :restart sends every attached UI a `restart` event;
noice's get_handler splits each event name at its "_" and raised on that one. Delivered while an exit hook ran the event
loop (Neovim's own LSP shutdown, desk.review's share wait), the error made Neovim stop at an invisible "Press any key"
and skip every exit hook after the waiting one. The rendered noice spec guards get_handler.

With lazy.nvim's clones of noice.nvim and nui.nvim here (DESK_NOICE_NVIM and DESK_NUI_NVIM name others), each read at
the commit the lock pins (git archive), and the rendered spec run as lazy.nvim runs it:
- get_handler("restart") is nil, with no error, and msg_show keeps its handler;
- in a terminal Neovim (:restart needs one) with an exit hook that waits and one after it, :restart runs both hooks and
  the new Neovim starts, with no key pressed.
Neovim gets its own state, cache, config, data and runtime folders and none of the session's addresses."""
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tarfile
import tempfile
import termios
import time
import unittest

import sealed_env

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
LOCK = json.loads((ROOT / "shared/nvim_lazy-lock.json").read_text())
LAZY = Path.home() / ".local/share/nvim/lazy"
CLONES = {"noice.nvim": Path(os.environ.get("DESK_NOICE_NVIM") or LAZY / "noice.nvim"),
          "nui.nvim": Path(os.environ.get("DESK_NUI_NVIM") or LAZY / "nui.nvim")}

# The rendered noice spec with what it reads of init.lua (the drawing style, the border, Paper), on the runtime path the
# pinned noice and nui, and the spec run as lazy.nvim runs it: its config, else setup with its opts.
LOAD = r"""
local source = table.concat(vim.fn.readfile(vim.env.DESK_INIT), "\n")
local at = assert(source:find('"folke/noice.nvim"', 1, true), "no noice spec")
local spec = assert(loadstring(table.concat({
  assert(source:match('(local DeskStyle = "[^"]*")'), "no DeskStyle"),
  assert(source:match("%-%- >>> desk%-border\n(.-)\n%-%- <<< desk%-border"), "no desk-border block"),
  assert(source:match("(local Paper = %b{})"), "no Paper"),
  "return " .. source:match("%b{}", source:sub(1, at):match(".*(){")),
}, "\n")))()
vim.opt.rtp:prepend(vim.env.DESK_NUI)
vim.opt.rtp:prepend(vim.env.DESK_NOICE)
if spec.config then spec.config(nil, spec.opts) else require("noice").setup(spec.opts) end
"""

CHECK = LOAD + r"""
vim.wait(500, function() return require("noice.ui")._attached end, 20)
local ui = require("noice.ui")
local ok, handler = pcall(ui.get_handler, "restart")
local shown = ui.get_handler("msg_show", "echo")
io.stdout:write(vim.json.encode({ attached = ui._attached, ok = ok, restart = ok and handler == nil or tostring(handler),
  msg_show = type(shown) }) .. "\n")
"""

# The repro's shape: an exit hook that runs the event loop (as Neovim's LSP exit handler does while a server shuts
# down), then one more; a line per start and per exit.
RESTART = LOAD + r"""
local function say(line) local f = assert(io.open(vim.env.DESK_LOG, "a")); f:write(line, "\n"); f:close() end
vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() vim.wait(300, function() return false end) end })
vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() say("left " .. vim.v.exitreason) end })
vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  vim.defer_fn(function() say("started " .. vim.v.startreason) end, 500)
end })
"""


@unittest.skipUnless(shutil.which("nvim") and shutil.which("git") and RENDER.exists(),
                     "requires nvim, git and desk-render-fast (make)")
class NoiceRestart(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="nvim-noice-"))
        self.addCleanup(shutil.rmtree, self.base, True)
        for name, clone in CLONES.items():
            commit = LOCK[name]["commit"]
            got = subprocess.run(["git", "--no-optional-locks", "-C", str(clone), "archive", "--format=tar", commit],
                                 capture_output=True)
            if got.returncode != 0:
                self.skipTest(f"requires lazy.nvim's clone of {name} holding {commit[:7]} ({clone}; :Lazy restore)")
            with tarfile.open(fileobj=io.BytesIO(got.stdout)) as tar:
                tar.extractall(self.base / name, filter="data")
        subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates/nvim"),
                        str(self.base / "render")], check=True, capture_output=True, timeout=60)
        # Sealed (tests/sealed_env.py); at the end every Neovim it started is stopped, a :restart's new server too (it
        # runs outside the terminal Neovim's process group), before the folder goes.
        self.env = sealed_env.environment(self.base, DESK_INIT=self.base / "render/init.lua", DESK_NOICE=self.base / "noice.nvim",
                                          DESK_NUI=self.base / "nui.nvim", DESK_LOG=self.base / "log")
        self.addCleanup(sealed_env.stop, self.env)

    def test_the_restart_event_has_no_handler_and_no_error(self):
        (self.base / "check.lua").write_text(CHECK)
        ran = subprocess.run(["nvim", "--headless", "--clean", "-l", str(self.base / "check.lua")], capture_output=True,
                             text=True, timeout=60, env=self.env)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        seen = json.loads(ran.stdout.strip().splitlines()[-1])
        self.assertTrue(seen["attached"], "noice never attached")
        self.assertEqual((seen["ok"], seen["restart"]), (True, True), f"get_handler('restart') gave {seen['restart']}")
        self.assertEqual(seen["msg_show"], "function", "msg_show lost its handler")

    def test_restart_runs_every_exit_hook_and_starts_without_a_key(self):
        (self.base / "driver.lua").write_text(RESTART)
        log = self.base / "log"
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        nvim = subprocess.Popen(["nvim", "-u", str(self.base / "driver.lua"), "-i", "NONE", "-n"], cwd=self.base,
                                stdin=slave, stdout=slave, stderr=slave, env=self.env | {"TERM": "xterm-256color"},
                                preexec_fn=terminal, close_fds=True)
        os.close(slave)
        self.addCleanup(os.close, master)

        def stop():
            try:
                os.killpg(nvim.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            nvim.wait(10)
        self.addCleanup(stop)

        def lines():
            return log.read_text().splitlines() if log.exists() else []

        def until(line, seconds):
            end = time.time() + seconds
            while time.time() < end and line not in lines():
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        drawn = os.read(master, 65536)
                    except OSError:
                        break
                    if b"\x1b[c" in drawn or b"\x1b[0c" in drawn:     # a terminal's answers, so it starts at once
                        os.write(master, b"\x1b[?62;c")
                    if b"\x1b]11;?" in drawn:
                        os.write(master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            return line in lines()

        self.assertTrue(until("started normal", 15), "Neovim never started")
        os.write(master, b":restart\r")
        self.assertTrue(until("started restart", 10) and "left restart" in lines(),
                        f":restart stopped with no key pressed (exit hooks after the waiting one ran: "
                        f"{'left restart' in lines()}): {lines()}")


if __name__ == "__main__":
    unittest.main()
