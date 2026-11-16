"""ALT+N (shared/bin/desk-notice-act): the newest notice on screen does what a click does, and nothing happens when
none is showing. makoctl is a stub on PATH that records what it is asked; the real notification daemon is never
reached."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "shared/bin/desk-notice-act"
STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_LOG"
case "$1" in
  mode) printf '%s\\n' $STUB_MODES ;;
  list) cat "$STUB_LIST" ;;
esac
"""


def notice(id, actions, app="FoxML"):
    return {"id": id, "app_name": app, "app_icon": None, "category": "desk.work", "desktop_entry": None,
            "summary": f"notice {id}", "body": None, "urgency": "normal", "actions": actions}


@unittest.skipUnless(shutil.which("jq"), "needs jq")
class NoticeAct(unittest.TestCase):
    def setUp(self):
        # /tmp may be noexec: the stub lives under tests/. PATH is only this folder, so the real makoctl in /usr/bin,
        # which would act on the notices on the desktop, can never be the one found.
        self.dir = Path(tempfile.mkdtemp(dir=ROOT / "tests", prefix="notice-act-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.bin, self.bare = self.dir / "bin", self.dir / "bare"
        for folder in (self.bin, self.bare):
            folder.mkdir()
            for tool in ("jq", "grep", "cat", "sh"):
                (folder / tool).symlink_to(shutil.which(tool))
        stub = self.bin / "makoctl"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.log, self.list = self.dir / "calls", self.dir / "list.json"

    def run_act(self, notices, modes="default", stub=True):
        self.list.write_text(json.dumps(notices))
        self.log.write_text("")
        env = {"PATH": str(self.bin if stub else self.bare), "STUB_LOG": str(self.log), "STUB_LIST": str(self.list),
               "STUB_MODES": modes, "HOME": str(self.dir)}
        ran = subprocess.run([shutil.which("bash"), str(SCRIPT)], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual((ran.returncode, ran.stdout, ran.stderr), (0, "", ""), "always quiet, always 0")
        return [line for line in self.log.read_text().splitlines() if line]

    def test_the_newest_notice_with_a_default_action_is_clicked(self):
        calls = self.run_act([notice(5, {"default": "Open result", "log": "Open log"}),
                              notice(12, {}, app="fox-osd"),              # the volume stroke: no action
                              notice(9, {"default": "Go to session"}),
                              notice(11, {"log": "Open log"})])           # no default
        self.assertEqual(calls, ["mode", "list -j", "invoke -n 9 default", "dismiss -n 9"])

    def test_nothing_showing_does_nothing(self):
        self.assertEqual(self.run_act([]), ["mode", "list -j"])
        self.assertEqual(self.run_act([notice(3, {}), notice(4, {"log": "Open log"})]), ["mode", "list -j"],
                         "notices with no default action are not acted on")

    def test_do_not_disturb_hides_them_all(self):
        self.assertEqual(self.run_act([notice(7, {"default": "Open"})], modes="default do-not-disturb"), ["mode"])

    def test_without_makoctl_it_says_nothing(self):
        self.assertEqual(self.run_act([notice(7, {"default": "Open"})], stub=False), [])

    def test_alt_n_runs_it_in_both_twins(self):
        lua = (ROOT / "shared/hyprland_modules/keybinds.lua").read_text()
        conf = (ROOT / "shared/hyprland_modules/keybinds.conf").read_text()
        self.assertIn('hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("~/.local/bin/desk-notice-act"))', lua)
        self.assertIn("bind = $mainMod,       N,      exec, ~/.local/bin/desk-notice-act", conf)
        self.assertTrue(os.access(SCRIPT, os.X_OK), "the bind runs the script directly")


if __name__ == "__main__":
    unittest.main()
