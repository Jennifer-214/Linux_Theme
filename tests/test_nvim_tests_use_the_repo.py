"""Neovim-driven tests must exercise this repo's Lua, never the copy installed under ~/.config/nvim.

Neovim looks for a module in its runtime path before package.path, so a test started with `-u NONE` quietly loads
the installed foxml/*.lua when there is one (two suites did, until 2026-11-13). `--clean` leaves the user's
directories out of the runtime path; this holds every test to it, and proves it with a decoy install.
"""
from pathlib import Path
import re
import shutil
import tempfile
import unittest

import sealed_env

ROOT = Path(__file__).resolve().parents[1]


class NvimTestsUseTheRepo(unittest.TestCase):
    def test_no_test_starts_neovim_on_the_user_s_runtime_path(self):
        bad = []
        for path in sorted(ROOT.glob('tests/test_*.py')) + sorted(ROOT.glob('src/*/tests/test_*.py')):
            if path.name == Path(__file__).name:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"""['"]nvim['"]""", line) and re.search(r"""['"]-u['"],\s*['"]NONE['"]""", line):
                    bad.append(f'{path.relative_to(ROOT)}:{number}')
        self.assertEqual(bad, [], 'start Neovim with --clean, not -u NONE')

    @unittest.skipUnless(shutil.which('nvim'), 'needs Neovim')
    def test_a_decoy_install_is_never_loaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            decoy = Path(tmp) / 'config/nvim/lua/desk'
            decoy.mkdir(parents=True)
            for module in (ROOT / 'shared/nvim_lua/desk').glob('*.lua'):
                (decoy / module.name).write_text("error('the installed copy was loaded: " + module.name + "')\n")
            # Sealed from the session (tests/sealed_env.py), the decoy as the config folder.
            env = sealed_env.environment(tmp, XDG_CONFIG_HOME=Path(tmp) / 'config')
            self.addCleanup(sealed_env.stop, env)
            for test in sorted((ROOT / 'shared/nvim_lua/tests').glob('test_*.lua')):
                run = sealed_env.run(['nvim', '--headless', '--clean', '-l', str(test)], env, 120, sandboxes=(ROOT / 'tests', '[pr][ov]??????'))
                self.assertEqual(run.returncode, 0, f'{test.name}: ' + (run.stdout + run.stderr)[-600:])
                self.assertNotIn('installed copy', run.stdout + run.stderr, test.name)


if __name__ == '__main__':
    unittest.main()
