"""The Claude Code paper mod: renders for every palette, and Claude Code's own validator and test kit accept it."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import hashlib

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT/'src/desk-render/desk-render-fast'
MOD = ROOT/'shared/claude/mods/foxml-paper'


def sdk_fixture():
    folder = ROOT/'tests/fixtures/claude-sdk'
    manifest = json.loads((folder/'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or hashlib.sha256((folder/relative).read_bytes()).hexdigest() != expected:
            raise ValueError('The generated Claude SDK fixture changed: '+name)
    header = (folder/'claude-code/index.d.ts').read_text().split('\n',1)[0]
    if not re.search(r'\b'+re.escape(manifest['claude'])+r'\b', header):
        raise ValueError('The SDK fixture and engine pin do not agree')
    return folder, manifest


class PaperMod(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not RENDER.exists():
            if os.environ.get('FOXML_REQUIRE_MOD_CHECKS') == '1':
                raise AssertionError('build desk-render-fast first')
            raise unittest.SkipTest('build desk-render-fast first')

    def need(self, available, reason):
        if not available:
            if os.environ.get('FOXML_REQUIRE_MOD_CHECKS') == '1':
                self.fail(reason)
            self.skipTest(reason)

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

    def test_claude_code_validates_and_tests_it(self):
        self.need(shutil.which('claude'), 'Claude Code not installed')
        mod = self.stage('FoxML_Paper')
        valid = subprocess.run(['claude', 'plugin', 'validate', str(mod)], capture_output=True, text=True, timeout=120)
        self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
        tested = subprocess.run(['claude', 'plugin', 'test', str(mod)], capture_output=True, text=True, timeout=300, cwd=mod.parent)
        self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)
        self.assertIn(' 0 fail', tested.stdout + tested.stderr)

    # An exported SDK can live anywhere; release checks must never pass by skipping a missing SDK.
    def engine_types(self, version):
        config = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home()/'.claude'))).expanduser()
        if os.environ.get('CLAUDE_TYPES_DIR'):
            candidates = [Path(os.path.expandvars(os.environ['CLAUDE_TYPES_DIR'])).expanduser()]
        else:
            candidates = [config/'mods/foxml-paper/.claude-plugin/types']
            plugins = os.environ.get('CLAUDE_CODE_PLUGIN_DIRS', '')
            try:
                settings = json.loads((config/'settings.json').read_text())
                plugins += ':' + settings.get('env', {}).get('CLAUDE_CODE_PLUGIN_DIRS', '')
            except (OSError, ValueError, TypeError, AttributeError):
                pass
            candidates += [Path(os.path.expandvars(p)).expanduser()/'.claude-plugin/types'
                           for p in plugins.split(':') if p]
            candidates += sorted((config/'mods').glob('*/.claude-plugin/types'))
        for candidate in dict.fromkeys(candidates):
            try:
                header = (candidate/'claude-code/index.d.ts').read_text().split('\n', 1)[0]
                if (candidate/'tsconfig.json').is_file() and re.search(r'\b' + re.escape(version) + r'\b', header):
                    return candidate
            except OSError:
                continue
        if not os.environ.get('CLAUDE_TYPES_DIR'):
            fixture, manifest = sdk_fixture()
            if version == manifest['claude']:
                return fixture
        self.need(False, 'No matching Claude Code SDK found. Set CLAUDE_TYPES_DIR to engine-generated '
                         '.claude-plugin/types for version ' + version + '.')

    def test_the_mod_and_its_tests_type_check(self):
        self.need(shutil.which('tsc'), 'install TypeScript (tsc) for the Claude mod checks')
        self.need(shutil.which('claude'), 'Claude Code is needed to verify the SDK version')
        engine = subprocess.run(['claude', '--version'], capture_output=True, text=True, timeout=30)
        version = re.search(r'\d+\.\d+\.\d+', engine.stdout)
        self.assertTrue(engine.returncode == 0 and version, 'Could not read the Claude Code version.')
        types = self.engine_types(version[0])
        mod = self.stage('FoxML_Paper')
        shutil.copytree(types, mod/'.claude-plugin/types')
        # A running engine can regenerate its SDK while the check is staging it.
        header = (mod/'.claude-plugin/types/claude-code/index.d.ts').read_text().split('\n', 1)[0]
        self.assertRegex(header, r'\b' + re.escape(version[0]) + r'\b', 'The SDK changed while staging; rerun the check.')
        (mod/'tsconfig.json').write_text('{ "extends": "./.claude-plugin/types/tsconfig.json", "include": ["hooks", "tests", "types"] }\n')
        checked = subprocess.run(['tsc', '-p', str(mod), '--noEmit'], capture_output=True, text=True, timeout=300)
        self.assertEqual(checked.returncode, 0, checked.stdout[-4000:] + checked.stderr[-1000:])


if __name__ == '__main__':
    unittest.main()
