#!/usr/bin/env python3
"""Neovim's working directory (VM test 2026-11-16, F16): opening src/desk-common/shell.cpp moved it to src/desk-common as
clangd attached (project.nvim took clangd's root, the nearest Makefile), and :restart then opened
src/desk-common/src/desk-common/shell.cpp, which does not exist.

- project.nvim, set up with the rendered spec's options from lazy.nvim's clone of it here (DESK_PROJECT_NVIM names
  another): a file in a folder with its own Makefile, under a language server rooted there, leaves the working directory
  at the git checkout.
- :restart (in a terminal Neovim; it needs one) after a :cd opens the file named at the start, once: the desk-restart
  block of the rendered init.lua, through :restart and then :restart!.
Neovim gets its own state, cache, config, data and runtime folders and none of the session's addresses."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
PROJECT = Path(os.environ.get("DESK_PROJECT_NVIM") or Path.home() / ".local/share/nvim/lazy/project.nvim")
LIVE = ("TMUX", "TMUX_PANE", "NVIM", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK")

# project.nvim as the rendered spec sets it up, then a file opened under a language server rooted at its folder.
PROJECT_LUA = r"""
local source = table.concat(vim.fn.readfile(vim.env.DESK_INIT), "\n")
local at = assert(source:find('"coffebar/project.nvim"', 1, true), "no project.nvim spec")
local spec = assert(loadstring("return " .. source:match("%b{}", source:sub(1, at):match(".*(){"))))()
vim.opt.rtp:prepend(vim.env.DESK_PLUGIN)
require("project_nvim").setup(spec.opts)
local function server(dispatchers)   -- clangd's part here: it starts, and its root is the file's folder
  local closing, id = false, 0
  return {
    request = function(method, _, callback)
      id = id + 1
      callback(nil, method == "initialize" and { capabilities = {} } or vim.NIL)
      return true, id
    end,
    notify = function(method) if method == "exit" then dispatchers.on_exit(0, 15) end return true end,
    is_closing = function() return closing end,
    terminate = function() closing = true end,
  }
end
vim.cmd.edit(vim.fn.fnameescape(vim.env.DESK_FILE))
vim.bo.filetype = "cpp"
vim.lsp.start({ name = "clangd", cmd = server, root_dir = vim.fs.dirname(vim.env.DESK_FILE), filetypes = { "cpp" } })
vim.wait(3000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end, 20)
vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0 })
vim.wait(200)
io.stdout:write(vim.json.encode({ cwd = vim.uv.cwd(), clients = #vim.lsp.get_clients({ bufnr = 0 }) }) .. "\n")
"""

# The desk-restart block, then a line per start: why it started, the working directory, every named buffer.
RESTART_LOG = r"""
vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  vim.defer_fn(function()
    local names = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then names[#names + 1] = name end
    end
    local f = assert(io.open(vim.env.DESK_LOG, "a"))
    f:write(vim.json.encode({ reason = vim.v.startreason, cwd = vim.uv.cwd(), bufs = names }), "\n")
    f:close()
  end, 300)
end })
"""


def rendered_init(base):
    out = base / "render"
    subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates/nvim"), str(out)],
                   check=True, capture_output=True, timeout=60)
    return out / "init.lua"


def sealed_env(base, **more):
    run = Path(tempfile.mkdtemp(prefix="nc-"))   # short: a socket path has at most 107 bytes
    env = {k: v for k, v in os.environ.items() if k not in LIVE}
    env.update(HOME=str(base), XDG_STATE_HOME=str(base), XDG_CACHE_HOME=str(base), XDG_CONFIG_HOME=str(base),
               XDG_DATA_HOME=str(base), XDG_RUNTIME_DIR=str(run), NVIM_LOG_FILE=str(base / "nvim.log"), **more)
    return env, run


@unittest.skipUnless(shutil.which("nvim") and shutil.which("git") and RENDER.exists(),
                     "requires nvim, git and desk-render-fast (make)")
class WorkingDirectory(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="nvim-cwd-"))
        self.addCleanup(shutil.rmtree, self.base, True)

    def test_a_language_server_root_or_a_makefile_does_not_move_it_off_the_checkout(self):
        if not (PROJECT / "lua/project_nvim").is_dir():
            self.skipTest(f"requires lazy.nvim's clone of project.nvim ({PROJECT})")
        repo = self.base / "repo"
        tool = repo / "src/tool"
        tool.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (tool / "Makefile").write_text("all:\n")
        (tool / "shell.cpp").write_text("int main() { return 0; }\n")
        (self.base / "project.lua").write_text(PROJECT_LUA)
        env, run = sealed_env(self.base, DESK_INIT=str(rendered_init(self.base)), DESK_PLUGIN=str(PROJECT),
                              DESK_FILE=str(tool / "shell.cpp"))
        self.addCleanup(shutil.rmtree, run, True)
        ran = subprocess.run(["nvim", "--headless", "--clean", "-l", str(self.base / "project.lua")], cwd=repo,
                             capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        seen = json.loads(ran.stdout.strip().splitlines()[-1])
        self.assertEqual(seen["clients"], 1, "the language server never attached")
        self.assertEqual(os.path.realpath(seen["cwd"]), os.path.realpath(repo),
                         "the working directory left the checkout for the tool folder")

    def test_restart_after_a_cd_opens_the_file_named_at_the_start(self):
        init = rendered_init(self.base)
        block = init.read_text().split("-- >>> desk-restart\n", 1)[1].split("\n-- <<< desk-restart", 1)[0]
        (self.base / "driver.lua").write_text(block + "\n" + RESTART_LOG)
        start = self.base / "start"
        (start / "sub").mkdir(parents=True)
        (start / "sub/file.txt").write_text("hello\n")
        log = self.base / "log"
        env, run = sealed_env(self.base, TERM="xterm-256color", DESK_LOG=str(log))
        self.addCleanup(shutil.rmtree, run, True)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        nvim = subprocess.Popen(["nvim", "-u", str(self.base / "driver.lua"), "-i", "NONE", "-n", "sub/file.txt"],
                                cwd=start, stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=terminal,
                                close_fds=True)
        os.close(slave)
        self.addCleanup(os.close, master)

        def stop():
            try:
                os.killpg(nvim.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            nvim.wait(10)
        self.addCleanup(stop)

        def starts():
            return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

        def until(count, seconds=15):
            end = time.time() + seconds
            while time.time() < end and len(starts()) < count:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        drawn = os.read(master, 65536)
                    except OSError:
                        break
                    if b"\x1b[c" in drawn or b"\x1b[0c" in drawn:     # a terminal's answers, so it starts at once
                        os.write(master, b"\x1b[?62;c")
                    if b"\x1b]11;?" in drawn:
                        os.write(master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            return len(starts()) >= count

        self.assertTrue(until(1), "Neovim never started")
        os.write(master, b":cd sub\r")
        time.sleep(0.3)
        os.write(master, b":restart\r")
        self.assertTrue(until(2), ":restart never started a new Neovim")
        os.write(master, b":restart!\r")
        self.assertTrue(until(3), ":restart! never started a new Neovim")
        want = os.path.realpath(start / "sub/file.txt")
        for seen in starts()[1:]:
            with self.subTest(reason=seen["reason"]):
                self.assertTrue(seen["reason"].startswith("restart"), seen)
                self.assertEqual([os.path.realpath(name) for name in seen["bufs"]], [want],
                                 f"after :cd sub, {seen['reason']} opened {seen['bufs']}")
                self.assertEqual(os.path.realpath(seen["cwd"]), os.path.realpath(start / "sub"),
                                 "the working directory she had was not kept")


if __name__ == "__main__":
    unittest.main()
