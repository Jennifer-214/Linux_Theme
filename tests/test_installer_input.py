"""The entry wrapper refuses missing input before any build, update or install; fixtures never run the installer."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class InstallerInput(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='input-fixture-', dir=ROOT/'tests')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.core = self.base/'src/desk-install/core'
        self.core.mkdir(parents=True)
        for name in ['input_preflight.sh', 'input_options.def']:
            shutil.copy(ROOT/'src/desk-install/core'/name, self.core/name)
        shutil.copy(ROOT/'install.sh', self.base/'install.sh')
        self.bin = self.base/'bin'; self.bin.mkdir()
        for name in ['make', 'sudo', 'git', 'df']:
            script = self.bin/name
            script.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$INPUT_FIXTURE_CALLS"\nexit 93\n')
            script.chmod(0o755)
        self.env = os.environ | {'PATH': str(self.bin)+':'+os.environ['PATH'], 'INPUT_FIXTURE_CALLS': str(self.base/'calls')}

    def test_noninteractive_entry_refuses_before_any_side_effect(self):
        for flags in [[], ['--render'], ['--only', 'symlinks'], ['--preset', 'workstation']]:
            result = subprocess.run(['bash', str(self.base/'install.sh'), *flags], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, env=self.env)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('requires a terminal', result.stderr)
            self.assertFalse((self.base/'calls').exists(), 'a build, update or system command ran before input was checked')

    def test_inspection_only_builds_in_the_repository(self):
        script = self.bin/'make'
        script.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$INPUT_FIXTURE_CALLS"\nexit 0\n')
        binary = self.base/'src/desk-install/desk-install'
        binary.write_text('#!/bin/bash\nprintf "inspected %s\\n" "$*"\n'); binary.chmod(0o755)
        for flag in ['--help', '--version', '--dry-run', '--wizard-demo']:
            result = subprocess.run(['bash', str(self.base/'install.sh'), flag], capture_output=True, text=True, env=self.env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('inspected '+flag, result.stdout)
        calls = (self.base/'calls').read_text()
        self.assertNotIn(' install', calls)
        self.assertNotIn('sudo', calls)
        self.assertNotIn('git', calls)

    def test_explicit_unattended_choice_and_option_boundary(self):
        command = 'SCRIPT_DIR="$1"; FOX_INSTALL_BIN="$1/src/desk-install/desk-install"; shift; source "$SCRIPT_DIR/src/desk-install/core/input_preflight.sh"; echo accepted'
        for flags, expected in [(['--yes'], 0), (['-y'], 0), (['--', '--yes'], 1), (['--preset', '--yes'], 1), ([], 1)]:
            result = subprocess.run(['bash', '-c', command, 'fixture', str(self.base), *flags], capture_output=True, text=True, env=self.env)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

if __name__ == '__main__': unittest.main()
