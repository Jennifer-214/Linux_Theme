#!/usr/bin/env python3
"""Verify migrated selections using fake pickers; never launch desktop actions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['PICKER_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\n')
if name == 'fox-picker':
    pathlib.Path(os.environ['PICKER_INPUT']).write_text(sys.stdin.read())
    if os.environ.get('PICKER_APPEND'):
        with open(pathlib.Path(os.environ['XDG_RUNTIME_DIR'])/'foxml-agent-queue.jsonl', 'a') as stream:
            stream.write(os.environ['PICKER_APPEND'] + '\n')
    if os.environ.get('PICKER_CANCEL'): sys.exit(1)
    print(os.environ.get('PICKER_REPLY', '0'))
elif name == 'wl-copy':
    pathlib.Path(os.environ['PICKER_CLIPBOARD']).write_text(sys.stdin.read())
elif name == 'fox-llm-run':
    if sys.argv[1:] == ['--model']: print('local:fixture')
    else: print('fixture response')
elif name == 'rofi':
    sys.exit(99)
'''


class PaperPickers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.paper-picker-', dir=ROOT/'tests')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home/'bin'
        self.bin.mkdir()
        fake = self.bin/'fake'
        fake.write_text(FAKE)
        fake.chmod(0o755)
        for name in ('fox-picker','fox-desktop-menu','rofi','setsid','kitty','firejail','notify-send','tmux','wl-copy','fox-llm-run','systemctl'):
            (self.bin/name).symlink_to(fake)
        for name in ('bash','awk','sed','jq','flock','mktemp','mv','find','basename','rm','sort','file','grep'):
            real = shutil.which(name)
            if real: (self.bin/name).symlink_to(real)
        scripts = self.home/'.config/hypr/scripts'
        scripts.mkdir(parents=True)
        self.env = os.environ | {'HOME':str(self.home), 'XDG_RUNTIME_DIR':str(self.home), 'PATH':str(self.bin),
                                'PICKER_CALLS':str(self.home/'calls'), 'PICKER_INPUT':str(self.home/'input'),
                                'PICKER_CLIPBOARD':str(self.home/'clipboard'), 'TMUX':'fixture'}

    def run_tool(self, name, *args, **env):
        path = ROOT/'shared'/('hyprland_scripts' if name.endswith('.sh') else 'bin')/name
        result = subprocess.run(['/bin/bash',str(path),*args], env=self.env|env, text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        calls = [json.loads(row) for row in (self.home/'calls').read_text().splitlines()]
        self.assertFalse(any(row[0]=='rofi' for row in calls))
        return calls

    def test_shortcut_reference_copies_exact_key_with_spaces(self):
        docs = self.home/'.local/share/foxml'
        docs.mkdir(parents=True)
        (docs/'KEYBINDS.md').write_text('## Hyprland\n| `Super + Shift + Return` | Open terminal |\n| `Alt + h` | Move left |\n')
        self.run_tool('fox-cheatsheet','hyprland',PICKER_REPLY='0')
        self.assertEqual((self.home/'clipboard').read_text(),'Super + Shift + Return')
        self.assertIn('Open terminal',(self.home/'input').read_text())

    def test_sandbox_cancel_does_not_launch_and_direct_mode_preserves_argv(self):
        calls = self.run_tool('fox-sandbox',PICKER_CANCEL='1')
        self.assertFalse(any(row[0]=='setsid' for row in calls))
        calls = self.run_tool('fox-sandbox','literal-command','one argument','$(data)')
        self.assertIn(['setsid','-f','firejail','--private','--quiet','literal-command','one argument','$(data)'],calls)

    def test_ai_prompt_cancel_never_runs_inference(self):
        calls = self.run_tool('fox-ai-quick',PICKER_CANCEL='1')
        self.assertEqual([row for row in calls if row[0]=='fox-llm-run'],[['fox-llm-run','--model']])
        self.assertTrue(any('--prompt' in row for row in calls if row[0]=='fox-picker'))

    def test_wallpaper_picker_keeps_rotation_option(self):
        wallpaper = self.home/'.wallpapers'
        wallpaper.mkdir()
        (wallpaper/'a literal $(paper).png').write_bytes(b'fixture')
        self.run_tool('fox-wallpaper','--menu',PICKER_CANCEL='1')
        rows = (self.home/'input').read_text()
        self.assertIn('Rotation',rows)
        self.assertIn('a literal $(paper).png',rows)

    def test_legacy_agent_entrypoint_opens_the_native_agent_drawer(self):
        calls=self.run_tool('agent_rofi.sh')
        self.assertIn(['fox-desktop-menu','agents'],calls)
        self.assertFalse(any(row[0] in ('fox-picker','tmux') for row in calls))

    def test_password_copy_preserves_pass_arguments_and_sensitive_hint(self):
        fake_pass = self.bin/'pass'
        fake_pass.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$PICKER_INPUT"\nprintf "fixture" | wl-copy\n')
        fake_pass.chmod(0o755)
        calls = self.run_tool('fox-password-copy','a literal $(entry)')
        self.assertIn(['wl-copy','--sensitive'],calls)
        self.assertEqual((self.home/'input').read_text().splitlines(),['show','--clip=1','--','a literal $(entry)'])

    def test_command_entrypoint_opens_tools_without_launching_commands(self):
        # Stage the real wrapper beside the fake desktop launcher: the wrapper
        # deliberately resolves its sibling instead of a command on PATH.
        wrapper = self.bin/'fox-menu'
        shutil.copy(ROOT/'shared/bin/fox-menu', wrapper)
        result = subprocess.run(['/bin/bash', str(wrapper)], env=self.env,
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(row) for row in (self.home/'calls').read_text().splitlines()]
        self.assertEqual(calls, [['fox-desktop-menu', '--open', 'tools']])
        self.assertFalse((self.home/'input').exists(), 'opening tools must not invoke a picker or command')


if __name__ == '__main__':
    unittest.main()
