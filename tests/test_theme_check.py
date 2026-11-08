"""fox theme check end to end: a fake home, the real repo and stand-in commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "src/fox-theme-check/fox-theme-check"
RENDER = ROOT / "src/fox-render/fox-render-fast"


@unittest.skipUnless(CHECK.exists() and RENDER.exists(), "build fox-theme-check and fox-render-fast first")
class ThemeCheck(unittest.TestCase):
    def setUp(self):
        # Beside the test, not in /tmp: stand-in commands must be executable, and /tmp may be noexec.
        self.tmp = Path(tempfile.mkdtemp(prefix=".fox-theme-check-tests-", dir=Path(__file__).parent))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.rendered = self.tmp / "rendered"
        subprocess.run([str(RENDER), str(ROOT / "themes/FoxML_Paper/palette.sh"), str(ROOT / "templates"), str(self.rendered)],
                       check=True, capture_output=True)

    def shim(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def deploy(self, src, dest, text=None):
        target = self.home / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text if text is not None else (self.rendered / src).read_text())

    def run_check(self, *args, extra_env=None):
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "FOXML_REPO": str(ROOT),
               "XDG_RUNTIME_DIR": str(self.tmp / "run")} | (extra_env or {})
        return subprocess.run([str(CHECK), "--theme", "FoxML_Paper", *args], env=env, text=True, capture_output=True, timeout=120)

    def test_drift_tells_a_changed_file_from_this_machines_own(self):
        self.deploy("kitty/kitty.conf", ".config/kitty/kitty.conf")
        self.deploy("tmux/.tmux.conf", ".tmux.conf", (self.rendered / "tmux/.tmux.conf").read_text().replace("set -g", "set -gq", 1))
        lock = (self.rendered / "hyprlock/hyprlock.conf").read_text().replace("    monitor =\n", "    monitor = eDP-1\n")
        self.deploy("hyprlock/hyprlock.conf", ".config/hypr/hyprlock.conf", lock)
        zshrc = (self.rendered / "zsh/.zshrc").read_text() + "\nexport MINE=1\n"
        self.deploy("zsh/.zshrc", ".zshrc", zshrc)
        out = self.run_check("--only", "D1", "--verbose")
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("differs: ~/.tmux.conf", out.stdout)
        self.assertNotIn("differs: ~/.config/kitty/kitty.conf", out.stdout, "an exact copy matches")
        self.assertNotIn("differs: ~/.config/hypr/hyprlock.conf", out.stdout, "a lock screen pinned to a panel is this machine's")
        self.assertNotIn("differs: ~/.zshrc", out.stdout)
        self.assertIn("1 match with lines of your own added", out.stdout, "your own line keeps .zshrc yours")
        self.assertIn("missing: ", out.stdout, "files the fake home never got are listed")
        self.assertFalse(list(Path(tempfile.gettempdir()).glob(f"fox-theme-check-{os.getpid()}*")), "nothing left behind")

    def test_services_hyprland_and_exit_codes(self):
        self.shim("systemctl", 'case "$3" in fox-pulse.service) [ "$2" = is-enabled ] && echo enabled || echo active ;;'
                               ' foxml-focus-pulse.service) [ "$2" = is-active ] && echo active || echo enabled ;;'
                               ' *) echo inactive ;; esac')
        out = self.run_check("--only", "D9")
        self.assertIn("foxml-focus-pulse.service still runs beside fox-pulse", out.stdout)
        self.assertEqual(out.returncode, 1, "a warning")
        self.shim("systemctl", 'case "$3" in fox-pulse.service) [ "$2" = is-enabled ] && echo enabled || echo active ;; *) echo inactive ;; esac')
        self.assertEqual(self.run_check("--only", "D9").returncode, 0)

        self.shim("hyprctl", 'echo "config error in rules.conf line 3"')
        out = self.run_check("--only", "D2", extra_env={"HYPRLAND_INSTANCE_SIGNATURE": "test"})
        self.assertIn("rules.conf line 3", out.stdout)
        self.assertEqual(out.returncode, 3, "a broken Hyprland config is a high failure")
        self.shim("hyprctl", "echo 'no errors'")
        self.assertEqual(self.run_check("--only", "D2", extra_env={"HYPRLAND_INSTANCE_SIGNATURE": "test"}).returncode, 0)
        self.assertIn("not in a Hyprland session", self.run_check("--only", "D2", "--verbose").stdout)

    def test_the_drawer_and_bar_are_asked_for_real(self):
        menus = self.home / ".config/quickshell/foxml/menus.json"
        menus.parent.mkdir(parents=True)
        menus.write_text(json.dumps({"groups": [{"id": "comfort", "items": [{"id": "x", "kind": "page", "page": "slow"}]}]}))
        drawer = self.home / ".local/bin/fox-drawer"
        drawer.parent.mkdir(parents=True)
        drawer.write_text('#!/bin/sh\n[ "$2" = slow ] && echo \'{"ok":false,"message":"broken"}\' && exit 1\necho \'{"items":[]}\'\n')
        drawer.chmod(0o755)
        out = self.run_check("--only", "D4")
        self.assertIn("slow (broken)", out.stdout)
        self.assertEqual(out.returncode, 1)
        bar = self.home / ".config/waybar/config"
        bar.parent.mkdir(parents=True)
        bar.write_text('// a comment waybar allows\n{"custom/good":{"exec":"echo \'{\\"text\\":\\"x\\"}\'","return-type":"json"},'
                       '"custom/bad":{"exec":"echo nope","return-type":"json"},"custom/gone":{"exec":"exit 4"}}')
        out = self.run_check("--only", "D5")
        self.assertIn("custom/bad (not JSON)", out.stdout)
        self.assertIn("custom/gone (exit 4)", out.stdout)
        self.assertNotIn("custom/good", out.stdout)

    def test_gtk_firefox_cursor_and_the_lock_panel(self):
        self.shim("gsettings", 'case "$3" in color-scheme) echo "\'prefer-dark\'" ;; cursor-theme) echo "\'foxml-paper-cursors\'" ;; esac')
        out = self.run_check("--only", "D10")
        self.assertIn("the theme is light but color-scheme is prefer-dark", out.stdout)
        self.assertEqual(out.returncode, 1)
        self.shim("gsettings", 'case "$3" in color-scheme) echo "\'default\'" ;; cursor-theme) echo "\'foxml-paper-cursors\'" ;; esac')
        self.assertEqual(self.run_check("--only", "D10").returncode, 0)

        out = self.run_check("--only", "D12")
        self.assertIn("foxml-paper-cursors is not installed", out.stdout)
        (self.home / ".local/share/icons/foxml-paper-cursors/cursors").mkdir(parents=True)
        self.assertEqual(self.run_check("--only", "D12").returncode, 0)

        ff = self.home / ".config/mozilla/firefox"
        (ff / "abc.default-release").mkdir(parents=True)
        (ff / "profiles.ini").write_text("[Install4F96D1932A9F858E]\nDefault=abc.default-release\nLocked=1\n")
        prefs = ('user_pref("ui.textHighlightBackground", "#e2a4ba");\nuser_pref("ui.textHighlightForeground", "#202024");\n'
                 'user_pref("ui.textSelectAttentionBackground", "#e2a4ba");\n')
        (ff / "abc.default-release/user.js").write_text(prefs)
        out = self.run_check("--only", "D11")
        self.assertIn("ui.textSelectAttentionForeground", out.stdout)
        (ff / "abc.default-release/user.js").write_text(prefs + 'user_pref("ui.textSelectAttentionForeground", "#202024");\n')
        self.assertEqual(self.run_check("--only", "D11").returncode, 0)

        lock = self.home / ".config/hypr/hyprlock.conf"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("label {\n    monitor = eDP-1\n}\n")
        session = {"HYPRLAND_INSTANCE_SIGNATURE": "test"}
        out = self.run_check("--only", "D13", extra_env=session)
        self.assertIn("fox-lock-panel is not installed", out.stdout)
        moved = self.tmp / "moved.conf"
        moved.write_text("label {\n    monitor = DP-2\n}\n")
        chooser = self.home / ".local/bin/fox-lock-panel"
        chooser.parent.mkdir(parents=True, exist_ok=True)
        chooser.write_text(f"#!/bin/sh\necho {moved}\n")
        out = self.run_check("--only", "D13", "--verbose", extra_env=session)
        self.assertIn("locking now would put it on DP-2", out.stdout)
        self.assertEqual(out.returncode, 0)


if __name__ == "__main__":
    unittest.main()
