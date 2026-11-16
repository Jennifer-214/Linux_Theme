#!/usr/bin/env python3
"""Shift+Enter (a notebook's "run the cell, go to the next") in kitty, inside tmux and outside it. VM test 2026-11-16
(F13): inside tmux Neovim got a plain Enter. kitty's legacy keys send Shift+Enter as 0x0d, the same as Enter, and tmux
asks a terminal for modified keys only in xterm's way, which kitty ignores; so kitty.conf maps Shift+Enter to its CSI u
form, which tmux passes on to programs that ask for modified keys, and zsh binds that form as Enter.

A pty stands in for kitty: it answers the queries kitty answers, follows the key protocol and cursor mode a program
sets, and for Shift+Enter sends what the rendered kitty.conf maps (0x0d when nothing is mapped). tmux is a private
server running the rendered .tmux.conf; Neovim runs the desk-jupyter block of the rendered init.lua on a notebook buffer.
Sealed: bwrap gives the test its own /tmp, runtime folder and process list, the tmux server is its own (-S), and no
TMUX, NVIM, Hyprland, Wayland or D-Bus address reaches it."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
BLOCK_LUA = ROOT / "tests/jupyter_block.lua"

# (Only where bwrap may make namespaces: a CI container may not, and then the -S socket is the guard.)
if (shutil.which("bwrap") and not os.environ.get("FOXML_TMUX_TEST_SEALED")
        and subprocess.run(["bwrap", "--dev-bind", "/", "/", "--unshare-pid", "--proc", "/proc", "true"],
                           capture_output=True).returncode == 0):
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["FOXML_TMUX_TEST_SEALED"] = "1"
    os.execvp("bwrap", ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--tmpfs", runtime, "--unshare-pid",
                        "--as-pid-1", "--die-with-parent", "--proc", "/proc", sys.executable, "-B", *sys.argv])

LIVE = ("TMUX", "TMUX_PANE", "NVIM", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK")

# Neovim: the desk-jupyter block on a notebook buffer, the cursor on prose above a code cell. Shift+Enter there goes
# to the cell (row 11); a plain Enter goes one row down (row 9).
DRIVER = r"""
vim.g.mapleader = " "
local function say(line) local f = assert(io.open(vim.env.DESK_LOG, "a")); f:write(line, "\n"); f:close() end
local J = dofile(vim.env.DESK_BLOCK)(vim.env.DESK_INIT)
local api = vim.api
local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/work.ipynb")
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "jupyter:", "  kernelspec:", "    language: python",
  "    name: python3", "---", "", "Some prose", "", "```python", "x = 1", "```" })
vim.bo[buf].filetype = "markdown"
api.nvim_win_set_cursor(0, { 8, 0 })
api.nvim_create_autocmd("CursorMoved", { callback = function() say("row " .. api.nvim_win_get_cursor(0)[1]) end })
api.nvim_create_autocmd("UIEnter", { once = true, callback = function()
  vim.defer_fn(function() say("ready " .. (vim.fn.maparg("<S-CR>", "n", false, true).desc or "unmapped")) end, 300)
end })
"""


def kitty_mapping(conf):
    """(modes, bytes) of the rendered kitty.conf's Shift+Enter send_text mapping, else None."""
    found = re.search(r"^map\s+shift\+enter\s+send_text\s+(\S+)\s+(.+?)\s*$", conf, re.M)
    if not found:
        return None
    text = found.group(2).replace("\\e", "\\x1b").encode().decode("unicode_escape").encode("latin-1")
    return set(found.group(1).split(",")), text


class Kitty:
    """A pty standing in for kitty around one program."""
    # The queries kitty answers, answered in the order they come (a program asks for the key protocol, then sends the
    # device attributes query; an answer to the first before the second is what says the protocol is there).
    QUERIES = re.compile(rb"\x1b\[>0?q|\x1b\[>c|\x1b\[0?c|\x1b\[\?u|\x1b\]11;\?(?:\x07|\x1b\\)")

    def __init__(self, argv, env, mapping):
        self.mapping, self.out, self.answered = mapping, b"", 0
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=terminal,
                                     close_fds=True)
        os.close(slave)

    def close(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.proc.wait(10)
        os.close(self.master)

    def flags(self):
        """The kitty key protocol flags the program has set (push, pop, set), as kitty keeps them."""
        stack = [0]
        for kind, a, b in re.findall(rb"\x1b\[([<>=])(\d*)(?:;(\d*))?u", self.out):
            if kind == b">":
                stack.append(int(a or 0))
            elif kind == b"<":
                del stack[max(1, len(stack) - int(a or 1)):]
            else:
                value, how = int(a or 0), int(b or 1)
                stack[-1] = value if how == 1 else (stack[-1] | value if how == 2 else stack[-1] & ~value)
        return stack[-1]

    def mode(self):
        """kitty's keyboard mode name for send_text: kitty, application or normal."""
        if self.flags():
            return "kitty"
        modes = re.findall(rb"\x1b\[\?1([hl])", self.out)
        return "application" if modes and modes[-1] == b"h" else "normal"

    def shift_enter(self):
        modes, text = self.mapping or (set(), b"")
        if modes & {self.mode(), "all"}:
            return text
        return b"\x1b[13;2u" if self.mode() == "kitty" else b"\r"

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if not ready:
                continue
            try:
                self.out += os.read(self.master, 65536)
            except OSError:
                return
            last = self.answered
            for query in self.QUERIES.finditer(self.out, self.answered):
                asked, last = query.group(), query.end()
                if asked.endswith(b"q"):
                    os.write(self.master, b"\x1bP>|kitty(0.50.0)\x1b\\")
                elif asked == b"\x1b[>c":
                    os.write(self.master, b"\x1b[>1;4000;50c")
                elif asked.endswith(b"c"):
                    os.write(self.master, b"\x1b[?62;c")
                elif asked == b"\x1b[?u":
                    os.write(self.master, b"\x1b[?%du" % self.flags())
                else:
                    os.write(self.master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            # a query cut off at the end of this read is answered once the rest of it has come
            self.answered = max(last, len(self.out) - 16)

    def press(self, keys):
        os.write(self.master, keys)


@unittest.skipUnless(all(shutil.which(t) for t in ("tmux", "nvim", "zsh")) and RENDER.exists(),
                     "requires tmux, nvim, zsh and desk-render-fast (make)")
class ShiftEnter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="shift-enter-")
        base = Path(cls.temp.name)
        for name in ("kitty", "tmux", "nvim", "zsh"):
            subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates" / name),
                            str(base / "render" / name)], check=True, capture_output=True, timeout=60)
        cls.render = base / "render"
        cls.mapping = kitty_mapping((cls.render / "kitty/kitty.conf").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="shift-enter-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        sockets = self.work / "sock"
        sockets.mkdir(mode=0o700)
        self.socket = sockets / "s"
        self.log = self.work / "log"
        self.env = {k: v for k, v in os.environ.items() if k not in LIVE}
        self.env.update(HOME=str(self.work), TMUX_TMPDIR=str(sockets), TERM="xterm-kitty",
                        XDG_CONFIG_HOME=str(self.work / "config"), XDG_DATA_HOME=str(self.work / "data"),
                        XDG_STATE_HOME=str(self.work / "state"), XDG_CACHE_HOME=str(self.work / "cache"),
                        XDG_RUNTIME_DIR=str(self.work / "run"), NVIM_LOG_FILE=str(self.work / "nvim.log"),
                        DESK_LOG=str(self.log), DESK_BLOCK=str(BLOCK_LUA), DESK_INIT=str(self.render / "nvim/init.lua"))
        (self.work / "run").mkdir(mode=0o700)
        (self.work / "driver.lua").write_text(DRIVER)

    def lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def until(self, kitty, check, seconds=15):
        end = time.time() + seconds
        while time.time() < end:
            kitty.pump(0.1)
            if check():
                return True
        return False

    def shift_enter_in_neovim(self, argv):
        kitty = Kitty(argv, self.env, self.mapping)
        self.addCleanup(kitty.close)
        self.assertTrue(self.until(kitty, lambda: any(l.startswith("ready") for l in self.lines())),
                        "Neovim never drew: " + repr(kitty.out[-400:]))
        self.assertIn("ready Run the cell, go to the next", self.lines(), "Shift+Enter is not mapped in the notebook")
        kitty.pump(0.5)
        sent = kitty.shift_enter()
        kitty.press(sent)
        self.until(kitty, lambda: any(l.startswith("row") for l in self.lines()), 5)
        return kitty.mode(), sent, [l for l in self.lines() if l.startswith("row")]

    def test_inside_tmux_shift_enter_runs_the_cell(self):
        def stop_server():
            if self.socket.is_socket():
                subprocess.run(["tmux", "-S", str(self.socket), "kill-server"], capture_output=True, env=self.env)
        self.addCleanup(stop_server)
        mode, sent, rows = self.shift_enter_in_neovim(
            ["tmux", "-S", str(self.socket), "-f", str(self.render / "tmux/.tmux.conf"), "new-session", "-x", "100",
             "-y", "30", "nvim", "-u", str(self.work / "driver.lua"), "-i", "NONE", "-n"])
        self.assertNotEqual(mode, "kitty", "tmux turned on kitty's key protocol (it misreads kitty's Esc then)")
        self.assertEqual(rows[:1], ["row 11"], f"kitty sent {sent!r} for Shift+Enter; Neovim in tmux moved {rows}")

    def test_outside_tmux_shift_enter_runs_the_cell(self):
        # the pop-out: Neovim turns on kitty's key protocol, and kitty's own encoding reaches it
        mode, sent, rows = self.shift_enter_in_neovim(["nvim", "-u", str(self.work / "driver.lua"), "-i", "NONE",
                                                       "-n"])
        self.assertEqual(mode, "kitty", "Neovim did not turn on kitty's key protocol")
        self.assertEqual(rows[:1], ["row 11"], f"kitty sent {sent!r} for Shift+Enter; Neovim moved {rows}")

    def test_at_a_zsh_prompt_shift_enter_is_enter(self):
        # The vi mode the .zshrc's oh-my-zsh plugin sets, and the .zshrc's own lines for kitty's Shift+Enter.
        binds = [line for line in (self.render / "zsh/.zshrc").read_text().splitlines() if "13;2u" in line]
        zdot = self.work / "zdot"
        zdot.mkdir()
        (zdot / ".zshrc").write_text("bindkey -v\nKEYTIMEOUT=1\n" + "\n".join(binds) + "\nPS1='P> '\n")
        kitty = Kitty(["zsh", "-d", "-i"], self.env | {"ZDOTDIR": str(zdot)}, self.mapping)
        self.addCleanup(kitty.close)
        self.assertTrue(self.until(kitty, lambda: b"P> " in kitty.out), "zsh never drew its prompt")
        kitty.press(b"echo one")
        kitty.pump(0.3)
        sent = kitty.shift_enter()
        kitty.press(sent)
        self.until(kitty, lambda: re.search(rb"\r\none\r\n", kitty.out) is not None, 5)
        self.assertRegex(kitty.out, rb"\r\none\r\n", f"zsh did not take {sent!r} as Enter: {kitty.out[-300:]!r}")
        self.assertNotIn(b"command not found", kitty.out)


if __name__ == "__main__":
    unittest.main()
