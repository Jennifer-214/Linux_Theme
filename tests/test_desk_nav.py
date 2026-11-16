"""ALT+h/j/k/l (shared/bin/desk-nav with shared/nvim_lua/desk/nav.lua): Neovim's split that way, else tmux's pane,
else the desktop's focus. Sealed: bwrap gives the test its own /tmp, runtime folder and process list; the tmux server
is a private one (-S); hyprctl and desk-hl are stubs on PATH that record what they are asked. The user's Hyprland,
tmux and Neovims are never reached (see tests/test_tmux_name_session.py for why it is sealed)."""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import sealed_env

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "shared/bin/desk-nav"
LUA = ROOT / "shared/nvim_lua"

# (Only where bwrap may make namespaces: a CI container may not, and then the stubs and the -S socket are the guard.)
if (shutil.which("bwrap") and not os.environ.get("FOXML_TMUX_TEST_SEALED")
        and subprocess.run(["bwrap", "--dev-bind", "/", "/", "--unshare-pid", "--proc", "/proc", "true"],
                           capture_output=True).returncode == 0):
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["FOXML_TMUX_TEST_SEALED"] = "1"
    # The test is pid 1 of its own process list: whatever it leaves running dies with it.
    os.execvp("bwrap", ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/tmp", "--tmpfs", runtime, "--unshare-pid",
                        "--as-pid-1", "--die-with-parent", "--proc", "/proc", sys.executable, "-B", *sys.argv])

STUB = """#!/bin/sh
printf '%s %s\\n' "${0##*/}" "$*" >> "$NAV_LOG"
[ "${0##*/} $1" = "hyprctl activewindow" ] && cat "$NAV_WINDOW"
exit 0
"""
NVIM_SETUP = "lua package.path = '{lua}/?.lua;' .. package.path; require('desk.nav').setup()"


@unittest.skipUnless(all(shutil.which(t) for t in ("tmux", "nvim", "jq", "script", "pgrep", "timeout")),
                     "needs tmux, nvim, jq, script, pgrep and timeout")
class DeskNav(unittest.TestCase):
    def setUp(self):
        # /tmp may be noexec: the stubs live under tests/. Sockets need a short path (107 bytes at most), and the
        # sealed /tmp is the test's own.
        self.work = Path(tempfile.mkdtemp(dir=ROOT / "tests", prefix="desk-nav-"))
        self.short = Path(tempfile.mkdtemp(prefix="nav-"))
        self.addCleanup(shutil.rmtree, self.work, True)    # last
        self.addCleanup(shutil.rmtree, self.short, True)
        stubs, self.run_dir, sockets = self.work / "bin", self.short / "run", self.short / "sock"
        for folder in (stubs, self.run_dir, sockets):
            folder.mkdir(mode=0o700)
        for name in ("hyprctl", "desk-hl"):
            (stubs / name).write_text(STUB)
            (stubs / name).chmod(0o755)
        self.socket = sockets / f"tmux-{os.getuid()}" / "default"
        self.socket.parent.mkdir(mode=0o700)
        self.log, self.window = self.work / "calls", self.work / "window.json"
        # Sealed (tests/sealed_env.py) where bwrap is missing too: none of the session's addresses.
        self.env = sealed_env.environment(self.short, TMUX_TMPDIR=sockets, HOME=self.work, XDG_RUNTIME_DIR=self.run_dir,
                                          XDG_STATE_HOME=self.work / "state", XDG_CONFIG_HOME=self.work / "config",
                                          XDG_DATA_HOME=self.work / "data", XDG_CACHE_HOME=self.work / "cache",
                                          PATH=f"{stubs}{os.pathsep}{os.environ['PATH']}", NAV_LOG=self.log, NAV_WINDOW=self.window)
        self.addCleanup(sealed_env.stop, self.env)
        self.procs = []
        self.addCleanup(self.stop)                          # first

    def stop(self):
        for proc in self.procs:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(10)
        if self.socket.is_socket() and self.short in self.socket.resolve().parents:
            subprocess.run(["tmux", "-S", str(self.socket), "kill-server"], capture_output=True, env=self.env)

    def tmux(self, *args):
        return subprocess.run(["tmux", "-S", str(self.socket), *args], env=self.env, capture_output=True, text=True,
                              timeout=10).stdout.strip()

    def spawn(self, argv):
        proc = subprocess.Popen(argv, env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        self.procs.append(proc)
        return proc

    def until(self, check, what):
        for _ in range(200):
            if check():
                return
            time.sleep(0.025)
        self.fail(what)

    def nvim_args(self, server=None):
        listen = ["--listen", str(server)] if server else []
        return ["nvim", "--headless", "--clean", *listen, "-c", NVIM_SETUP.format(lua=LUA), "-c", "vsplit | wincmd l"]

    def ask(self, server, expr):
        return subprocess.run(["nvim", "--server", str(server), "--remote-expr", expr], env=self.env, capture_output=True,
                              text=True, timeout=10).stdout.strip()

    def nav(self, key, window_class="kitty", pid=None, timeout=20):
        self.window.write_text(json.dumps({"class": window_class, "pid": pid if pid is not None else self.client.pid}))
        self.log.write_text("")
        ran = subprocess.run(["bash", str(SCRIPT), key], env=self.env, capture_output=True, text=True, timeout=timeout)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        return [line for line in self.log.read_text().splitlines() if not line.startswith("hyprctl activewindow")]

    def active(self):
        return self.tmux("display", "-p", "-t", "s:", "#{pane_id}")

    def desktop(self, direction, legacy):
        return [f'desk-hl dispatch hl.dsp.focus({{ direction = "{direction}" }}) movefocus {legacy}']

    def terminal(self):
        """A terminal window: a tmux client (its window's process is script's) on a window of two panes, a shell
        on the left and Neovim with two splits on the right, its cursor in the right split."""
        self.server = self.run_dir / "pane.sock"
        self.tmux("-f", "/dev/null", "new-session", "-d", "-s", "s", "-x", "120", "-y", "30", "sleep 600")
        self.tmux("split-window", "-h", "-t", "s:", *self.nvim_args(self.server))   # several arguments: run without a shell
        self.left, self.right = self.tmux("list-panes", "-t", "s:", "-F", "#{pane_id}").split()
        self.until(lambda: self.tmux("show-options", "-p", "-t", self.right, "-qv", "@desk-nvim") == str(self.server),
                   "Neovim never named its socket on its pane")
        self.client = self.spawn(["script", "-qfc", f"tmux -S {self.socket} attach -t s", "/dev/null"])
        self.until(lambda: self.tmux("list-clients", "-F", "#{client_pid}"), "the client never attached")
        self.assertEqual(self.ask(self.server, "winnr()"), "2")

    def test_neovim_then_tmux_then_the_desktop(self):
        self.terminal()
        self.assertEqual(self.nav("h"), [], "Neovim had a split that way")
        self.assertEqual((self.ask(self.server, "winnr()"), self.active()), ("1", self.right))
        self.assertEqual(self.nav("h"), [], "tmux had a pane that way")
        self.assertEqual(self.active(), self.left)
        self.assertEqual(self.nav("h"), self.desktop("left", "l"), "at the left edge of everything: the desktop")
        self.assertEqual(self.active(), self.left)
        self.assertEqual(self.nav("l"), [])
        self.assertEqual((self.active(), self.ask(self.server, "winnr()")), (self.right, "1"), "into the Neovim pane, as it was")
        self.assertEqual(self.nav("l"), [])
        self.assertEqual(self.ask(self.server, "winnr()"), "2", "then Neovim's split that way")
        self.assertEqual(self.nav("l"), self.desktop("right", "r"))
        self.assertEqual(self.nav("j"), self.desktop("down", "d"), "no split below, no pane below")
        self.assertEqual(self.nav("k"), self.desktop("up", "u"))

    def test_a_float_and_a_zoomed_pane_hand_the_key_on(self):
        self.terminal()
        # A picker or menu in Neovim: no split beside a float, so tmux moves.
        self.ask(self.server, "luaeval('vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, "
                              "{ relative = \"editor\", row = 1, col = 1, width = 10, height = 2 }) and 1')")
        self.assertEqual(self.nav("h"), [])
        self.assertEqual(self.active(), self.left)
        self.tmux("select-pane", "-t", self.right)
        self.ask(self.server, "execute('only')")
        self.tmux("resize-pane", "-Z", "-t", self.right)
        self.assertEqual(self.nav("h"), self.desktop("left", "l"), "a zoomed pane fills its window: an edge")
        self.assertEqual((self.active(), self.tmux("display", "-p", "-t", "s:", "#{window_zoomed_flag}")), (self.right, "1"))

    def test_other_windows_go_straight_to_the_desktop(self):
        self.terminal()
        other = self.spawn(["sleep", "600"])
        self.assertEqual(self.nav("h", "firefox", other.pid), self.desktop("left", "l"))
        self.assertEqual((self.active(), self.ask(self.server, "winnr()")), (self.right, "2"), "the terminal was left alone")
        self.window.write_text("{}")
        self.log.write_text("")
        subprocess.run(["bash", str(SCRIPT), "k"], env=self.env, capture_output=True, timeout=20)
        self.assertIn(self.desktop("up", "u")[0], self.log.read_text(), "no window focused: the desktop")

    def test_neovim_in_a_window_of_its_own_the_pop_out(self):
        listening = self.run_dir / "popout.sock"
        for server in (listening, None):
            with self.subTest(socket="--listen" if server else "the default"):
                window = self.spawn(["sh", "-c", shlex.join(self.nvim_args(server)) + "; :"])   # the window's process, Neovim its child
                found = server
                if not server:
                    self.until(lambda: list(self.run_dir.glob("nvim.*.0")), "Neovim never made its default socket")
                    found = next(self.run_dir.glob("nvim.*.0"))
                else:
                    self.until(lambda: listening.is_socket(), "Neovim never listened")
                self.until(lambda: self.ask(found, "winnr()") == "2", "Neovim never split")
                self.assertEqual(self.nav("h", "desk-popout", window.pid), [])
                self.assertEqual(self.ask(found, "winnr()"), "1", "the pop-out's Neovim moved")
                self.assertEqual(self.nav("h", "desk-popout", window.pid), self.desktop("left", "l"))
                os.killpg(window.pid, signal.SIGKILL)
                window.wait(10)
                for left in self.run_dir.glob("nvim.*.0"):
                    left.unlink()

    def test_a_neovim_that_does_not_answer_hands_the_key_on(self):
        # Stopped (or stuck), Neovim's socket still takes the question, and the answer never comes.
        listening = self.run_dir / "popout.sock"
        window = self.spawn(["sh", "-c", shlex.join(self.nvim_args(listening)) + "; :"])
        self.until(lambda: listening.is_socket(), "Neovim never listened")
        self.until(lambda: self.ask(listening, "winnr()") == "2", "Neovim never split")
        os.killpg(window.pid, signal.SIGSTOP)
        self.assertEqual(self.nav("h", "desk-popout", window.pid, timeout=5), self.desktop("left", "l"))

    def test_usage(self):
        ran = subprocess.run(["bash", str(SCRIPT), "x"], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(ran.returncode, 2)


class Binds(unittest.TestCase):
    def test_alt_hjkl_run_it_in_both_twins(self):
        lua = (ROOT / "shared/hyprland_modules/keybinds.lua").read_text()
        conf = (ROOT / "shared/hyprland_modules/keybinds.conf").read_text()
        for key in "hjkl":
            self.assertIn(f'hl.bind(mainMod .. " + {key}", hl.dsp.exec_cmd("~/.local/bin/desk-nav {key}"))', lua)
            self.assertIn(f"bind = $mainMod, {key}, exec, ~/.local/bin/desk-nav {key}", conf)
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_neovim_maps_no_alt_direction_key_for_it(self):
        # The keys never reach Neovim under Hyprland; its own Alt maps (move a line, j and k) are left as they are.
        nav = (LUA / "desk/nav.lua").read_text()
        self.assertNotIn("keymap", nav)
        self.assertIn('pcall(function() require("desk.nav").setup() end)', (ROOT / "templates/nvim/init.lua").read_text())


if __name__ == "__main__":
    unittest.main()
