"""Waybar can render without Quickshell and preserves an existing drawer marker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WaybarStartupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="foxml-bar-startup-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bar = self.home / ".config/waybar"
        self.bar.mkdir(parents=True)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        # Keep this a headless render: no live compositor tools or desktop processes.
        for name in ("bash", "sed", "awk", "tr", "mktemp", "ln", "rm"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (self.bin / name).symlink_to(executable)
        (self.bar / "style.css.tmpl").write_text('@import "drawer-state.css";\n* { font-size: __FONT_BASE__pt; }\n')
        (self.bar / "config.tmpl").write_text('{"height":__HEIGHT__,"margin":"__MARGIN_BAR__"}\n')

    def render(self, **overrides):
        env = os.environ | {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config"), "PATH": str(self.bin)} | overrides
        subprocess.run(["/bin/bash", str(ROOT / "shared/hyprland_scripts/start_waybar.sh"), "--render-only"],
                       env=env, capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(json.loads((self.bar / "config").read_text())["height"], 34)
        self.assertIn("font-size: 10pt", (self.bar / "style.css").read_text())
        self.assertEqual(list(self.bar.glob(".drawer-state.*")), [])

    def test_initializes_missing_state_without_a_drawer_installation(self):
        self.render()
        self.assertEqual((self.bar / "drawer-state.css").read_bytes(), b"")

    def test_existing_drawer_marker_survives_repeated_rendering(self):
        marker = "#custom-logo { box-shadow: inset 0 -1px @peach; }\n"
        path = self.bar / "drawer-state.css"
        path.write_text(marker)
        self.render()
        self.render()
        self.assertEqual(path.read_text(), marker)

    def test_dangling_user_symlink_is_left_untouched(self):
        target = self.home / "unavailable.css"
        path = self.bar / "drawer-state.css"
        path.symlink_to(target)
        self.render()
        self.assertTrue(path.is_symlink())
        self.assertFalse(target.exists())

    def start_with_frontend(self, succeeds, render_only=False):
        fixture = tempfile.TemporaryDirectory(prefix=".bar-frontend-", dir=ROOT / "tests")
        self.addCleanup(fixture.cleanup)
        calls = self.home / "frontend-calls"
        stubs = {
            "desk-bar": 'printf "quickshell:%s\\n" "$*" >> "$BAR_CALLS"; exit "$BAR_RESULT"',
            "waybar": 'printf "waybar\\n" >> "$BAR_CALLS"',
            "pgrep": 'exit 1',
            "pkill": 'printf "stop-waybar\\n" >> "$BAR_CALLS"',
        }
        for name, body in stubs.items():
            program = Path(fixture.name) / name
            program.write_text("#!/bin/bash\n" + body + "\n")
            program.chmod(0o755)
            (self.bin / name).symlink_to(program)
        env = os.environ | {"XDG_CONFIG_HOME": str(self.home / ".config"), "PATH": str(self.bin),
                            "BAR_CALLS": str(calls), "BAR_RESULT": "0" if succeeds else "1"}
        args = ["/bin/bash", str(ROOT / "shared/hyprland_scripts/start_waybar.sh")]
        if render_only:
            args.append("--render-only")
        subprocess.run(args, env=env, capture_output=True, text=True, check=True, timeout=10)
        return calls.read_text().splitlines() if calls.exists() else []

    def test_quickshell_is_ready_before_old_bar_stops(self):
        self.assertEqual(self.start_with_frontend(True), ["quickshell:start", "stop-waybar"])

    def test_failed_quickshell_preserves_waybar_fallback(self):
        self.assertEqual(self.start_with_frontend(False), ["quickshell:start", "waybar"])

    def test_render_only_never_starts_either_frontend(self):
        self.assertEqual(self.start_with_frontend(True, render_only=True), [])

    def cursor_calls(self, theme=None, legacy=False):
        fixture = tempfile.TemporaryDirectory(prefix=".cursor-startup-", dir=ROOT / "tests")
        self.addCleanup(fixture.cleanup)
        hyprctl = Path(fixture.name) / "hyprctl"
        hyprctl.write_text('''#!/usr/bin/python3
import json, os, sys
with open(os.environ['CURSOR_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
print('[]' if sys.argv[1:2] == ['monitors'] else ('eval is only supported with the lua config manager' if os.environ.get('CURSOR_TEST_LEGACY') == '1' and sys.argv[1:2] == ['eval'] else 'ok'))
''')
        hyprctl.chmod(0o755)
        (self.bin / "hyprctl").symlink_to(hyprctl)
        (self.bin / "desk-hl").symlink_to(ROOT / "shared/bin/desk-hl")
        if theme is not None:
            gtk = self.home / ".config/gtk-3.0"
            gtk.mkdir()
            (gtk / "settings.ini").write_text('[Settings]\ngtk-cursor-theme-name=' + theme + '\n')
        calls = self.home / "cursor-calls"
        self.render(HYPRLAND_INSTANCE_SIGNATURE="fixture", XCURSOR_THEME="previous-theme", CURSOR_CALLS=str(calls), CURSOR_TEST_LEGACY="1" if legacy else "0")
        return [json.loads(line) for line in calls.read_text().splitlines()]

    def test_rendered_cursor_theme_overrides_stale_launcher_environment(self):
        calls = self.cursor_calls("catppuccin-mocha-pink-cursors")
        self.assertIn(["setcursor", "catppuccin-mocha-pink-cursors", "30"], calls)
        update = next(row[1] for row in calls if row[0] == "eval" and "hl.env" in row[1])
        self.assertIn("hl.env('HYPRCURSOR_THEME', 'catppuccin-mocha-pink-cursors')", update)
        self.assertIn("hl.env('XCURSOR_THEME', 'catppuccin-mocha-pink-cursors')", update)

    def test_cursor_environment_uses_legacy_parser_before_lua_upgrade(self):
        calls = self.cursor_calls("catppuccin-latte-pink-cursors", legacy=True)
        update = next(row[1] for row in calls if row[0] == "--batch")
        self.assertIn("keyword env HYPRCURSOR_THEME,catppuccin-latte-pink-cursors", update)
        self.assertIn("keyword env XCURSOR_THEME,catppuccin-latte-pink-cursors", update)
        self.assertIn("keyword env HYPRCURSOR_SIZE,30", update)

    def test_cursor_theme_falls_back_to_environment_without_rendered_settings(self):
        self.assertIn(["setcursor", "previous-theme", "30"], self.cursor_calls())

    def test_cursor_setting_is_data_and_invalid_value_uses_fallback(self):
        self.assertIn(["setcursor", "previous-theme", "30"], self.cursor_calls("$(touch should-not-exist)"))
        self.assertFalse((ROOT / "should-not-exist").exists())

    def test_session_exports_cursor_to_both_activation_environments(self):
        import socket
        with tempfile.TemporaryDirectory(prefix='.cursor-env-', dir=ROOT/'tests') as directory:
            base=Path(directory);bins=base/'bin';bins.mkdir()
            gtk=base/'config/gtk-3.0';gtk.mkdir(parents=True)
            (gtk/'settings.ini').write_text('[Settings]\ngtk-cursor-theme-name=catppuccin-mocha-pink-cursors\n')
            runtime=base/'runtime';runtime.mkdir()
            calls=base/'calls'
            stub='''#!/usr/bin/python3
import json,os,sys
with open(os.environ['CURSOR_ENV_CALLS'],'a') as stream:
    stream.write(json.dumps([sys.argv[0].split('/')[-1],sys.argv[1:],{key:os.environ.get(key) for key in ['XCURSOR_THEME','HYPRCURSOR_THEME','XCURSOR_SIZE']}])+'\\n')
'''
            for name in ['systemctl','dbus-update-activation-environment']:
                path=bins/name;path.write_text(stub);path.chmod(0o755)
            (bins/'awk').symlink_to(shutil.which('awk'))
            with socket.socket(socket.AF_UNIX) as bus:
                bus.bind(str(runtime/'bus'))
                env=os.environ|{'PATH':str(bins),'XDG_CONFIG_HOME':str(base/'config'),'XDG_RUNTIME_DIR':str(runtime),
                    'XCURSOR_THEME':'stale-white','HYPRCURSOR_THEME':'stale-white','XCURSOR_SIZE':'24','CURSOR_ENV_CALLS':str(calls)}
                subprocess.run(['/bin/bash',str(ROOT/'shared/hyprland_scripts/env-init.sh')],env=env,check=True,capture_output=True,text=True)
            rows=[json.loads(line)for line in calls.read_text().splitlines()]
            self.assertIn(['--user','try-restart','fox-pulse.service'],[row[1]for row in rows])
            exports=[row for row in rows if 'try-restart' not in row[1]]
            self.assertEqual([row[0]for row in exports],['systemctl','dbus-update-activation-environment'])
            for _,args,env in exports:
                self.assertIn('XCURSOR_THEME',args)
                self.assertEqual(env['XCURSOR_THEME'],'catppuccin-mocha-pink-cursors')
                self.assertEqual(env['HYPRCURSOR_THEME'],env['XCURSOR_THEME'])


if __name__ == "__main__":
    unittest.main()
