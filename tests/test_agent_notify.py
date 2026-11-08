#!/usr/bin/env python3
"""tests/test_agent_notify.py — the agent hook keeps one note per pane and clears it when you reply.

agent_notify.sh runs from Claude's Stop / SubagentStop / Notification hooks and, as `seen`, from UserPromptSubmit.
A UserPromptSubmit hook's stdout is handed to the agent as context, so `seen` must print nothing.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/hyprland_scripts/agent_notify.sh"


@unittest.skipUnless(shutil.which("jq") and shutil.which("flock"), "jq and flock are needed")
class AgentNotifyTest(unittest.TestCase):
    def setUp(self):
        # /tmp is noexec on FoxML; the fake tmux and notify-send live beside the test.
        self.tmp = Path(tempfile.mkdtemp(prefix=".foxml-agent-notify-", dir=Path(__file__).parent))
        self.run_dir = self.tmp / "run"
        self.bin = self.tmp / "bin"
        self.run_dir.mkdir(mode=0o700)
        self.bin.mkdir()
        (self.bin / "notify-send").write_text("#!/bin/sh\nexit 0\n")
        # display-message -t <pane> names that pane's own target
        (self.bin / "tmux").write_text('#!/bin/sh\ncase "$*" in *"-t %7"*) echo s:1.2 ;; *"-t %8"*) echo s:1.3 ;; esac\n')
        for name in ("notify-send", "tmux"):
            (self.bin / name).chmod(0o755)
        self.queue = self.run_dir / "foxml-agent-queue.jsonl"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hook(self, event, pane="%7"):
        env = os.environ | {"PATH": f"{self.bin}:{os.environ['PATH']}", "XDG_RUNTIME_DIR": str(self.run_dir),
                            "TMUX": "/tmp/fake,1,0", "TMUX_PANE": pane, "HOME": str(self.tmp)}
        return subprocess.run(["bash", str(SCRIPT), "claude", event], input='{"cwd":"/x/paper","message":"m"}',
                              env=env, text=True, capture_output=True, timeout=10)

    def notes(self):
        return [json.loads(line) for line in self.queue.read_text().splitlines()]

    def test_one_note_per_pane_and_seen_clears_it(self):
        stale = {"event": "stop", "tmux": "z:9.9", "pane": "%99", "epoch": int(time.time()) - 13 * 3600}
        legacy = {"event": "stop", "tmux": "s:1.2", "ts": "2026-11-07T08:00:00-06:00"}
        other = {"event": "stop", "tmux": "s:4.4", "ts": "2026-11-07T08:00:00-06:00"}
        self.queue.write_text("\n".join(json.dumps(n) for n in (stale, legacy, other)) + "\nnot json\n")
        for event in ("stop", "subagent", "stop"):
            self.assertEqual(self.hook(event).returncode, 0)
        self.hook("stop", pane="%8")
        notes = self.notes()
        self.assertEqual([(n["tmux"], n.get("pane")) for n in notes], [("s:4.4", None), ("s:1.2", "%7"), ("s:1.3", "%8")],
                         "stale, unreadable and replaced notes gone; each pane keeps its newest")
        self.assertEqual(notes[1]["project"], "paper")
        self.assertIsInstance(notes[1]["epoch"], int)
        self.assertEqual(self.queue.stat().st_mode & 0o777, 0o600)

        seen = self.hook("seen")
        self.assertEqual((seen.returncode, seen.stdout), (0, ""), "seen says nothing: its stdout would reach the agent")
        self.assertEqual([n["tmux"] for n in self.notes()], ["s:4.4", "s:1.3"], "replying clears only this pane's note")

    def state_hook(self, event, payload):
        env = os.environ | {"PATH": f"{self.bin}:{os.environ['PATH']}", "XDG_RUNTIME_DIR": str(self.run_dir),
                            "TMUX": "/tmp/fake,1,0", "TMUX_PANE": "%7", "HOME": str(self.tmp)}
        return subprocess.run(["bash", str(SCRIPT), "claude", event], input=json.dumps({"cwd": "/x/paper", **payload}),
                              env=env, text=True, capture_output=True, timeout=10)

    def test_each_session_says_what_it_is_doing(self):
        sessions = self.run_dir / "foxml-claude"
        state = lambda: json.loads((sessions / "abc-1.state").read_text())
        seen = self.state_hook("seen", {"session_id": "abc-1"})
        self.assertEqual((seen.returncode, seen.stdout), (0, ""), "still silent while recording")
        self.assertEqual((state()["state"], state()["pane"], state()["cwd"]), ("working", "%7", "/x/paper"))
        self.assertEqual(sessions.stat().st_mode & 0o777, 0o700)
        self.assertEqual((sessions / "abc-1.state").stat().st_mode & 0o777, 0o600)
        for event, payload, expected in (("stop", {}, "waiting"), ("notification", {"message": "Claude needs your permission to use Bash"}, "needs"),
                                         ("compact", {"trigger": "auto"}, "compacting"), ("compacted", {"trigger": "auto"}, "working"),
                                         ("compacted", {"trigger": "manual"}, "waiting"), ("failed", {"error": "rate_limit"}, "error")):
            self.assertEqual(self.state_hook(event, {"session_id": "abc-1", **payload}).returncode, 0)
            self.assertEqual(state()["state"], expected, event)
        self.assertEqual(state()["detail"], "rate_limit")
        lines_before = len(self.notes())
        self.state_hook("compact", {"session_id": "abc-1"})
        self.assertEqual(len(self.notes()), lines_before, "compacting leaves no note and no popup")
        idle = self.state_hook("notification", {"session_id": "abc-1", "message": "Claude is waiting for your input"})
        self.assertEqual((idle.returncode, state()["state"]), (0, "compacting"), "an idle reminder changes nothing")
        (sessions / "abc-1.json").write_text("{}")
        self.state_hook("ended", {"session_id": "abc-1", "reason": "prompt_input_exit"})
        self.assertEqual([p.name for p in sessions.iterdir() if not p.name.startswith("tally-")], [], "an ended session leaves nothing behind")
        self.state_hook("seen", {"session_id": "../escape"})
        self.assertFalse((self.run_dir / "escape.state").exists(), "a session id is never a path")

    def test_starts_fresh_pages_and_the_days_tally(self):
        sessions = self.run_dir / "foxml-claude"
        state = lambda: json.loads((sessions / "t-1.state").read_text())
        sessions.mkdir(mode=0o700)
        (sessions / "tally-2020-01-01").write_text("old 1 2\n")
        started = self.state_hook("started", {"session_id": "t-1", "source": "startup"})
        self.assertEqual((started.returncode, started.stdout), (0, ""), "SessionStart output would reach the agent")
        self.assertEqual(state()["state"], "waiting", "a new session counts at once")
        self.assertFalse((sessions / "tally-2020-01-01").exists(), "yesterday's tally goes")
        self.state_hook("seen", {"session_id": "t-1"})
        self.state_hook("started", {"session_id": "t-1", "source": "compact"})
        self.assertEqual(state()["state"], "working", "a restart after a compaction is left to the compacted event")
        self.state_hook("compacted", {"session_id": "t-1", "trigger": "auto"})
        self.assertEqual((state()["state"], state()["detail"]), ("working", "fresh"))
        self.state_hook("ended", {"session_id": "t-1"})
        tally = [line.split() for line in next(sessions.glob("tally-*")).read_text().splitlines()]
        self.assertEqual([row[1] for row in tally], ["waiting", "working", "working", "ended"])
        self.assertTrue(all(row[0] == "t-1" and row[2].isdigit() for row in tally))
        self.assertEqual(next(sessions.glob("tally-*")).stat().st_mode & 0o777, 0o600)

    def test_the_session_title_is_kept(self):
        state = lambda: json.loads((self.run_dir / "foxml-claude" / "abc-2.state").read_text())
        self.state_hook("seen", {"session_id": "abc-2"})
        self.assertNotIn("title", state(), "no title until Claude Code gives one")
        self.state_hook("seen", {"session_id": "abc-2", "session_title": "Greeter\nrecolour"})
        self.assertEqual(state()["title"], "Greeter recolour")
        self.state_hook("stop", {"session_id": "abc-2"})
        self.assertEqual((state()["state"], state()["title"]), ("waiting", "Greeter recolour"), "an event without one keeps it")
        self.state_hook("seen", {"session_id": "abc-2", "session_title": "x" * 200})
        self.assertEqual(len(state()["title"]), 80)

    def test_seen_outside_tmux_changes_nothing(self):
        self.queue.write_text(json.dumps({"event": "stop", "tmux": "s:1.2"}) + "\n")
        env = os.environ | {"PATH": f"{self.bin}:{os.environ['PATH']}", "XDG_RUNTIME_DIR": str(self.run_dir), "HOME": str(self.tmp)}
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        out = subprocess.run(["bash", str(SCRIPT), "claude", "seen"], input="{}", env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual((out.returncode, out.stdout), (0, ""))
        self.assertEqual(len(self.notes()), 1)


if __name__ == "__main__":
    unittest.main()
