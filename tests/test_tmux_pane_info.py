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
