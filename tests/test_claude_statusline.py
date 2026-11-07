#!/usr/bin/env python3
"""tests/test_claude_statusline.py — the palette's Claude Code status line, rendered for every theme.

Claude Code pipes the session's JSON to `bash ~/.claude/statusline.sh`; the first line printed is the status line.
Each run also leaves a snapshot for the bar pill and the drawer in $XDG_RUNTIME_DIR/foxml-claude/<session>.json.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
RENDER = ROOT / "src/fox-render/fox-render-fast"
ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


@unittest.skipUnless(shutil.which("jq") and RENDER.exists(), "jq and a built fox-render-fast are needed")
class StatusLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="foxml-statusline-"))
        self.runtime = self.tmp / "run"
        self.runtime.mkdir(mode=0o700)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def render(self, theme):
        out = self.tmp / theme
        subprocess.run([str(RENDER), str(ROOT / "themes" / theme / "palette.sh"), str(ROOT / "templates/claude"), str(out)],
                       check=True, capture_output=True)
        return out / "statusline.sh"

    def line(self, script, payload, columns=200, pane="%3"):
        env = os.environ | {"XDG_RUNTIME_DIR": str(self.runtime), "COLUMNS": str(columns), "TMUX_PANE": pane}
        out = subprocess.run(["bash", str(script)], input=json.dumps(payload), env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stderr, "")
        return out.stdout

    def test_every_theme_renders_a_working_line(self):
        themes = sorted(p.parent.name for p in (ROOT / "themes").glob("*/palette.sh"))
        self.assertEqual(len(themes), 6)
        for theme in themes:
            with self.subTest(theme=theme):
                script = self.render(theme)
                body = script.read_text()
                self.assertNotIn("{{", body, "every palette token resolved")
                self.assertEqual(subprocess.run(["bash", "-n", str(script)]).returncode, 0)
                shown = self.line(script, {"model": {"display_name": "Opus 5.5"}, "context_window": {"used_percentage": 41}})
                self.assertIn("\x1b[38;2;", shown, "truecolour from the palette")
                self.assertEqual(ESCAPE.sub("", shown), "Opus 5.5 · ♥♥♡♡♡ 41%\n")

    def test_usage_branch_gate_snapshot_and_narrow_panes(self):
        script = self.render("FoxML_Paper")
        project = self.tmp / "repo"
        subprocess.run(["git", "init", "-q", "-b", "garden", str(project)], check=True)
        (project / ".claude").mkdir()
        (project / ".claude/.plan-approved").write_text("other-session 2026-11-07\nabc-123 2026-11-07T12:00:00\n")
        soon = int(time.time()) + 3600
        payload = {"session_id": "abc-123", "model": {"display_name": "Opus 5.5"}, "context_window": {"used_percentage": 88.6},
                   "rate_limits": {"five_hour": {"used_percentage": 22, "resets_at": soon},
                                   "seven_day": {"used_percentage": 83.4, "resets_at": soon}},
                   "workspace": {"current_dir": str(project), "project_dir": str(project)}}
        shown = self.line(script, payload)
        day = time.strftime("%a", time.localtime(soon)).lower()
        self.assertEqual(ESCAPE.sub("", shown), f"Opus 5.5 · ♥♥♥♥♡ 88% · 5h 22% · week 83% (resets {day}) · ⎇ garden · gate open\n")
        self.assertIn("\x1b[38;2;162;79;115m\x1b[1mweek 83%", shown, "berry and bold from 80%")
        snapshot = json.loads((self.runtime / "foxml-claude/abc-123.json").read_text())
        self.assertEqual((snapshot["context"], snapshot["five"]["used"], snapshot["week"]["used"], snapshot["pane"]), (88, 22, 83, "%3"))
        self.assertEqual((self.runtime / "foxml-claude").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.runtime / "foxml-claude/abc-123.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(ESCAPE.sub("", self.line(script, payload, columns=50)), "Opus 5.5 · ♥♥♥♥♡ 88% · 5h 22% · gate open\n",
                         "a narrow pane drops the branch, then the week")
        other = payload | {"session_id": "not-approved"}
        self.assertNotIn("gate open", self.line(script, other))

    def test_odd_input_still_prints_a_line_and_writes_nowhere_strange(self):
        script = self.render("FoxML_Paper")
        self.assertEqual(ESCAPE.sub("", self.line(script, {})), "Claude\n")
        out = subprocess.run(["bash", str(script)], input="not json", env=os.environ | {"XDG_RUNTIME_DIR": str(self.runtime)},
                             text=True, capture_output=True, timeout=10)
        self.assertEqual((out.returncode, ESCAPE.sub("", out.stdout)), (0, "Claude\n"))
        self.line(script, {"session_id": "../../escape", "model": {"display_name": "Opus"}})
        self.assertFalse((self.tmp / "escape.json").exists())
        self.assertEqual(list((self.runtime / "foxml-claude").glob("*")) if (self.runtime / "foxml-claude").exists() else [], [])


if __name__ == "__main__":
    unittest.main()
