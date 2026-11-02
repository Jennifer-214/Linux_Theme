#!/usr/bin/env python3
"""Exercise drawer routing against fake desktop tools; no session or system action runs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "shared/bin/fox-desktop-menu"
WRAPPER = ROOT / "shared/hyprland_scripts/toggle_rofi.sh"
UPDATES = ROOT / "shared/hyprland_scripts/updates_menu.sh"

FAKE = r'''#!/usr/bin/python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if name == "quickshell":
    ready = pathlib.Path(os.environ["TEST_READY"])
    if "--daemonize" in args:
        if os.environ.get("TEST_LAUNCH_FAIL"): sys.exit(1)
        ready.touch()
    elif "status" in args:
        sys.exit(0 if ready.exists() and not os.environ.get("TEST_NEVER_READY") else 1)
    elif os.environ.get("TEST_ACTION_FAIL"):
        sys.exit(1)
elif name == "pkill":
    sys.exit(0 if os.environ.get("TEST_ROFI_OPEN") and args == ["-x", "rofi"] else 1)
elif name == "checkupdates":
    print("paper-pkg 1.0 -> 1.1")
elif name == "systemctl" and args and args[0] == "start" and os.environ.get("TEST_UNIT_FAIL"):
    sys.exit(1)
'''


class DrawerEntrypoints(unittest.TestCase):
    def setUp(self):
        # The machine may mount /tmp noexec; executable fixtures stay in the writable repo.
        self.tmp = tempfile.TemporaryDirectory(prefix=".fox-menu-test-", dir=ROOT / "tests")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.config = self.base / "config"
        drawer = self.config / "quickshell/foxml"
        drawer.mkdir(parents=True)
        for name in ("shell.qml", "Theme.qml", "menus.json"):
            (drawer / name).write_text("{}\n")
        scripts = self.config / "hypr/scripts"
        scripts.mkdir(parents=True)
        shutil.copy(ROOT / "shared/hyprland_scripts/_rofi_zone.sh", scripts)
        self.fake = self.bin / "fake-command"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        for name in ("quickshell", "fox-drawer", "pkill", "rofi", "sleep", "kitty", "notify-send", "checkupdates", "systemctl", "journalctl"):
            (self.bin / name).symlink_to(self.fake)
        for name in ("mkdir", "rm", "flock"):
            (self.bin / name).symlink_to(shutil.which(name))
        shutil.copy(LAUNCHER, self.bin / "fox-desktop-menu")
        self.calls_file = self.base / "calls.jsonl"
        self.ready = self.base / "ready"
        self.ready.touch()
        self.env = os.environ | {
            "HOME": str(self.base), "PATH": str(self.bin), "XDG_CONFIG_HOME": str(self.config),
            "XDG_RUNTIME_DIR": str(self.base), "XDG_STATE_HOME": str(self.base / "state"),
            "TEST_CALLS": str(self.calls_file), "TEST_READY": str(self.ready),
        }
        self.env.pop("FOXML_MENU_LEGACY", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, path, *args, **env):
        return subprocess.run(["/bin/bash", str(path), *map(str, args)], env=self.env | env,
                              capture_output=True, text=True, timeout=8)

    def calls(self, name=None):
        rows = [json.loads(line) for line in self.calls_file.read_text().splitlines()] if self.calls_file.exists() else []
        return [r for r in rows if name is None or r[0] == name]

    def test_ready_toggle_does_not_start_or_kill_anything(self):
        result = self.run_script(LAUNCHER, "sound")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["quickshell", "-c", "foxml", "ipc", "call", "drawer", "status"],
                                       ["quickshell", "-c", "foxml", "ipc", "call", "drawer", "toggle", "sound"]])

    def test_direct_shortcut_has_explicit_legacy_recovery(self):
        result = self.run_script(LAUNCHER, "apps", FOXML_MENU_LEGACY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["rofi", "-show", "drun"]])

    def test_start_is_hidden_and_cold_toggle_waits_for_its_own_instance(self):
        self.ready.unlink()
        result = self.run_script(LAUNCHER, "--start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["quickshell", "-c", "foxml", "--no-duplicate", "--daemonize"], self.calls())
        self.assertFalse(any("toggle" in row or "open" in row for row in self.calls()))

    def test_failed_readiness_has_a_bounded_exit(self):
        self.ready.unlink()
        result = self.run_script(LAUNCHER, "sound", TEST_NEVER_READY="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not become ready", result.stderr)
        self.assertEqual(len(self.calls("sleep")), 30)

    def test_close_never_starts_a_new_instance(self):
        self.ready.unlink()
        result = self.run_script(LAUNCHER, "--close")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["quickshell", "-c", "foxml", "ipc", "call", "drawer", "close"]])

    def test_incomplete_install_and_explicit_legacy_are_unavailable(self):
        result = self.run_script(LAUNCHER, "--available", FOXML_MENU_LEGACY="1")
        self.assertEqual(result.returncode, 1)
        (self.config / "quickshell/foxml/Theme.qml").unlink()
        self.assertEqual(self.run_script(LAUNCHER, "--available").returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_known_script_routes_before_any_rofi_kill(self):
        result = self.run_script(WRAPPER, self.config / "hypr/scripts/network.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1][-2:], ["toggle", "wifi"])
        self.assertEqual(self.calls("pkill"), [])

    def test_image_clipboard_and_application_search_have_distinct_pages(self):
        for command, args, page in [("clipmanager.sh", ["image"], "clipboard-images"),
                                    ("clipmanager.sh", ["text"], "clipboard-text"),
                                    ("rofi", ["-i", "-show", "drun"], "apps"),
                                    ("rofi", ["-show", "window"], "windows")]:
            with self.subTest(page=page):
                result = self.run_script(WRAPPER, command, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1][-2:], ["toggle", page])

    def test_legacy_mode_retains_rofi_arguments_and_positioning(self):
        result = self.run_script(WRAPPER, "rofi", "-show", "drun", "-filter", "jkl", FOXML_MENU_LEGACY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("quickshell"), [])
        call = self.calls("rofi")[0]
        self.assertEqual(call[-4:], ["-show", "drun", "-filter", "jkl"])
        self.assertEqual(call[1], "-theme-str")

    def test_unrecognized_rofi_modes_stay_rofi(self):
        result = self.run_script(WRAPPER, "rofi", "-show", "calc", "-modi", "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("quickshell"), [])
        self.assertEqual(self.calls("rofi")[0][-4:], ["-show", "calc", "-modi", "calc"])

    def test_failed_drawer_falls_back_to_rofi(self):
        result = self.run_script(WRAPPER, "rofi", "-show", "drun", TEST_ACTION_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("rofi")), 1)

    def test_update_click_routes_to_drawer_without_checking_or_applying(self):
        result = self.run_script(UPDATES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1][-2:], ["toggle", "updates"])
        self.assertEqual(self.calls("checkupdates"), [])
        self.assertEqual(self.calls("kitty"), [])

    def test_update_apply_terminal_bypasses_menu_and_keeps_refresh(self):
        result = self.run_script(UPDATES, "--apply-terminal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("quickshell"), [])
        self.assertEqual(self.calls("rofi"), [])
        self.assertEqual(len(self.calls("kitty")), 1)
        self.assertIn(["pkill", "-SIGRTMIN+1", "waybar"], self.calls())

    def test_silent_apply_without_informant_uses_terminal(self):
        result = self.run_script(UPDATES, "--apply-silent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("kitty")), 1)
        self.assertEqual(self.calls("systemctl"), [])

    def test_silent_apply_keeps_unit_failure_fallback(self):
        (self.bin / "informant").symlink_to(self.fake)
        result = self.run_script(UPDATES, "--apply-silent", TEST_UNIT_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["systemctl", "start", "foxml-apply-updates.service"], self.calls())
        self.assertEqual(len(self.calls("kitty")), 1)
        self.assertEqual(self.calls("rofi"), [])


if __name__ == "__main__":
    unittest.main()
