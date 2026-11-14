"""make test-fast chooses the tests that name what changed."""
import importlib.util
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('run_changed', ROOT / 'tests/run_changed.py')
run_changed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_changed)


class RunChanged(unittest.TestCase):
    TESTS = {
        'tests/test_nvim_review.py': "ROOT / 'shared/nvim_lua' ... foxml/review.lua",
        'tests/test_claude_mod.py': "MOD = ROOT/'shared/claude/mods/desk-notebook'",
        'src/desk-work/tests/test_work.py': "BIN = ROOT / 'src/desk-work/desk-work'",
        'tests/test_tmux_title.py': "SCRIPT = ROOT / 'shared/bin/tmux-title'",
    }

    def test_a_changed_file_brings_the_tests_that_name_it_or_its_tool(self):
        choose = run_changed.choose
        self.assertEqual(choose(['shared/nvim_lua/desk/review.lua'], self.TESTS), ['tests/test_nvim_review.py'])
        self.assertEqual(choose(['shared/claude/mods/desk-notebook/hooks/register.tsx'], self.TESTS), ['tests/test_claude_mod.py'])
        self.assertEqual(choose(['src/desk-work/main.cpp'], self.TESTS), ['src/desk-work/tests/test_work.py'])
        self.assertEqual(choose(['shared/bin/tmux-title'], self.TESTS), ['tests/test_tmux_title.py'])
        self.assertEqual(choose(['tests/test_tmux_title.py'], self.TESTS), ['tests/test_tmux_title.py'], 'a changed test runs itself')
        self.assertEqual(choose(['README.md'], self.TESTS), [], 'nothing names it: say so, do not guess')

    def test_common_folder_names_choose_nothing(self):
        self.assertNotIn('hooks', run_changed.handles('shared/claude/mods/desk-notebook/hooks/work.ts'))
        self.assertIn('desk-notebook', run_changed.handles('shared/claude/mods/desk-notebook/hooks/work.ts'))
        self.assertIn('desk-drawer', run_changed.handles('src/desk-drawer/main.cpp'))

    def test_the_makefile_offers_it(self):
        self.assertIn('test-fast:', (ROOT / 'Makefile').read_text())


class ChangedCheckout(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        override = patch.object(run_changed, 'ROOT', self.root)
        override.start()
        self.addCleanup(override.stop)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args],
                                       cwd=self.root, text=True)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_names_survive_and_the_first_commit_has_no_parent(self):
        name = 'a file\nwith spaces.cpp'
        self.write(name, 'old')
        self.commit()
        self.assertEqual(run_changed.changed_files(), [name])
        self.assertEqual(run_changed.changed_files('HEAD'), [])
        self.write(name, 'new')
        self.write('untracked space.txt', 'new')
        self.assertEqual(run_changed.changed_files(), [name, 'untracked space.txt'])

    def test_an_unborn_checkout_and_invalid_revisions(self):
        self.write('new file', 'new')
        self.git('add', '.')
        self.assertEqual(run_changed.changed_files(), ['new file'])
        self.commit()
        with self.assertRaises(RuntimeError):
            run_changed.changed_files('does-not-exist')
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(run_changed.main(['--since', 'does-not-exist', '--list']), 2)
            with self.assertRaises(SystemExit) as error:
                run_changed.main(['--since'])
        self.assertEqual(error.exception.code, 2)

    def test_native_tests_and_shared_library_dependents_are_run_and_fail_the_run(self):
        self.write('Makefile', 'all:\n\t@true\n')
        self.write('src/library/Makefile', 'all:\n\t@true\ntest:\n\t@true\n')
        self.write('src/consumer/Makefile', 'LIB = ../library/liblibrary.a\nall:\n\t@true\ntest:\n\t@exit 7\n')
        self.write('src/library/header.hpp', '// old')
        self.commit()
        self.write('src/library/header.hpp', '// new')
        self.assertEqual(run_changed.native_targets(['src/library/header.hpp']), ['src/consumer', 'src/library'])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(run_changed.main([]), 1)
        self.assertIn('FAILED  src/consumer test', output.getvalue())

    def test_a_moving_tree_is_inconclusive_even_when_every_test_passed(self):
        self.write('Makefile', 'all:\n\t@true\n')
        self.write('src/tool/Makefile', 'test:\n\t@true\n')
        self.commit()
        with patch.object(run_changed, 'fingerprint', side_effect=['before', 'after']), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(run_changed.main([]), 3)


if __name__ == '__main__':
    unittest.main()
