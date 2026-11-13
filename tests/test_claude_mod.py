"""The Claude Code paper mod: renders for every palette, and Claude Code's own validator and test kit accept it."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT/'src/desk-render/desk-render-fast'
MOD = ROOT/'shared/claude/mods/foxml-paper'


@unittest.skipUnless(RENDER.exists(), 'build desk-render-fast first')
class PaperMod(unittest.TestCase):
    def stage(self, theme):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        subprocess.run([str(RENDER), str(ROOT/'themes'/theme/'palette.sh'), str(ROOT/'templates/claude'), str(tmp/'r')],
                       check=True, capture_output=True)
        mod = tmp/'foxml-paper'
        shutil.copytree(MOD, mod)
        shutil.copy(tmp/'r/mods/foxml-paper/hooks/theme.ts', mod/'hooks/theme.ts')
        return mod

    def test_every_palette_fills_the_mod_theme(self):
        for palette in sorted((ROOT/'themes').glob('*/palette.sh')):
            theme = (self.stage(palette.parent.name)/'hooks/theme.ts').read_text()
            self.assertNotIn('{{', theme, palette.parent.name)
            self.assertRegex(theme, r"ink: '#[0-9a-f]{6}'", palette.parent.name)

    def test_the_code_holds_no_template_tokens(self):
        # The code is copied as it is; only theme.ts is rendered, so JSX's {{ }} never meets the renderer.
        self.assertFalse((ROOT/'templates/claude/mods/foxml-paper/hooks/register.tsx').exists())

    @unittest.skipUnless(shutil.which('claude'), 'Claude Code not installed')
    def test_claude_code_validates_and_tests_it(self):
        mod = self.stage('FoxML_Paper')
        valid = subprocess.run(['claude', 'plugin', 'validate', str(mod)], capture_output=True, text=True, timeout=120)
        self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
        tested = subprocess.run(['claude', 'plugin', 'test', str(mod)], capture_output=True, text=True, timeout=300, cwd=mod.parent)
        self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)
        self.assertIn(' 0 fail', tested.stdout + tested.stderr)

    # The engine writes its type files beside a mod it has loaded; they are not in this repo, so this runs where the
    # mod is installed and a TypeScript compiler exists, and is skipped elsewhere.
    TYPES = Path.home()/'.claude/mods/foxml-paper/.claude-plugin/types'

    @unittest.skipUnless(shutil.which('tsc') and (TYPES/'tsconfig.json').exists(), 'needs tsc and the installed mod\'s engine types')
    def test_the_mod_and_its_tests_type_check(self):
        mod = self.stage('FoxML_Paper')
        shutil.copytree(self.TYPES, mod/'.claude-plugin/types')
        (mod/'tsconfig.json').write_text('{ "extends": "./.claude-plugin/types/tsconfig.json", "include": ["hooks", "tests", "types"] }\n')
        checked = subprocess.run(['tsc', '-p', str(mod), '--noEmit'], capture_output=True, text=True, timeout=300)
        self.assertEqual(checked.returncode, 0, checked.stdout[-4000:] + checked.stderr[-1000:])


if __name__ == '__main__':
    unittest.main()
