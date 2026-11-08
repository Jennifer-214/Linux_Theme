"""The tmux pane footer marks a Claude session that needs you (♡) or is working (✿)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "shared/bin/tmux-pane-info"


class PaneFooter(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sessions = Path(self.tmp.name) / "foxml-claude"
        self.sessions.mkdir()

    def footer(self, command, pane):
        env = os.environ | {"XDG_RUNTIME_DIR": self.tmp.name, "FOX_TMUX_SEP": "•"}
        return subprocess.run(["bash", str(SCRIPT), self.tmp.name, command, pane], env=env, text=True,
                              capture_output=True, timeout=10).stdout

    def put(self, name, state, pane):
        (self.sessions / f"{name}.state").write_text(json.dumps({"state": state, "pane": pane, "epoch": 1}))

    def test_marks_follow_the_session_in_that_pane(self):
        self.put("a", "needs", "%7")
        self.put("b", "working", "%8")
        self.put("c", "waiting", "%9")
        self.assertTrue(self.footer("claude", "%7").startswith(" ♡  "))
        self.assertTrue(self.footer("claude", "%8").startswith(" ✿  "))
        self.assertFalse(self.footer("claude", "%9").startswith((" ♡", " ✿")), "waiting is quiet")
        self.assertFalse(self.footer("zsh", "%7").startswith(" ♡"), "back at a shell: the session is gone")
        self.assertFalse(self.footer("claude", "%70").startswith(" ♡"), "%7 is not %70")
        self.assertFalse(self.footer("claude", "%7;rm").startswith(" ♡"), "only a pane id is looked up")
        self.assertFalse(self.footer("claude", "").startswith(" ♡"), "no pane id, no mark")


if __name__ == "__main__":
    unittest.main()


RENDER = SCRIPT.parents[2] / "src/fox-render/fox-render-fast"


@unittest.skipUnless(RENDER.exists() and __import__("shutil").which("tmux"), "fox-render-fast and tmux needed")
class PaneDividers(unittest.TestCase):
    def test_every_theme_renders_a_tmux_config_that_parses(self):
        root = SCRIPT.parents[2]
        for palette in sorted((root / "themes").glob("*/palette.sh")):
            with self.subTest(theme=palette.parent.name), tempfile.TemporaryDirectory() as tmp:
                subprocess.run([str(RENDER), str(palette), str(root / "templates/tmux"), tmp], check=True, capture_output=True)
                conf = Path(tmp) / ".tmux.conf"
                text = conf.read_text()
                self.assertNotIn("{{", text)
                socket = f"fox-test-{os.getpid()}-{palette.parent.name}"
                # a throwaway server: the real one is never touched
                out = subprocess.run(["tmux", "-L", socket, "-f", "/dev/null", "new-session", "-d", ";",
                                      "source-file", "-n", str(conf), ";", "kill-server"], capture_output=True, text=True, timeout=10)
                self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_paper_draws_a_double_pencil_line_with_a_pink_active_pane(self):
        root = SCRIPT.parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([str(RENDER), str(root / "themes/FoxML_Paper/palette.sh"), str(root / "templates/tmux"), tmp],
                           check=True, capture_output=True)
            text = (Path(tmp) / ".tmux.conf").read_text()
        self.assertIn("set -g pane-border-lines double", text)
        self.assertIn('set -g pane-border-style "fg=#a39d96,bg=default"', text)
        self.assertIn('set -g pane-active-border-style "fg=#c67596,bg=default"', text)
