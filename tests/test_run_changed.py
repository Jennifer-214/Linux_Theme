"""make test-fast chooses the tests that name what changed."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('run_changed', ROOT / 'tests/run_changed.py')
run_changed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_changed)


class RunChanged(unittest.TestCase):
    TESTS = {
        'tests/test_nvim_review.py': "ROOT / 'shared/nvim_lua' ... foxml/review.lua",
        'tests/test_claude_mod.py': "MOD = ROOT/'shared/claude/mods/foxml-paper'",
        'src/desk-work/tests/test_work.py': "BIN = ROOT / 'src/desk-work/desk-work'",
        'tests/test_tmux_title.py': "SCRIPT = ROOT / 'shared/bin/tmux-title'",
    }

    def test_a_changed_file_brings_the_tests_that_name_it_or_its_tool(self):
        choose = run_changed.choose
        self.assertEqual(choose(['shared/nvim_lua/foxml/review.lua'], self.TESTS), ['tests/test_nvim_review.py'])
        self.assertEqual(choose(['shared/claude/mods/foxml-paper/hooks/register.tsx'], self.TESTS), ['tests/test_claude_mod.py'])
        self.assertEqual(choose(['src/desk-work/main.cpp'], self.TESTS), ['src/desk-work/tests/test_work.py'])
        self.assertEqual(choose(['shared/bin/tmux-title'], self.TESTS), ['tests/test_tmux_title.py'])
        self.assertEqual(choose(['tests/test_tmux_title.py'], self.TESTS), ['tests/test_tmux_title.py'], 'a changed test runs itself')
        self.assertEqual(choose(['README.md'], self.TESTS), [], 'nothing names it: say so, do not guess')

    def test_common_folder_names_choose_nothing(self):
        self.assertNotIn('hooks', run_changed.handles('shared/claude/mods/foxml-paper/hooks/work.ts'))
        self.assertIn('foxml-paper', run_changed.handles('shared/claude/mods/foxml-paper/hooks/work.ts'))
        self.assertIn('desk-drawer', run_changed.handles('src/desk-drawer/main.cpp'))

    def test_the_makefile_offers_it(self):
        self.assertIn('test-fast:', (ROOT / 'Makefile').read_text())


if __name__ == '__main__':
    unittest.main()
