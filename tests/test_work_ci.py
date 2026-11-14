"""The mandatory work checks cannot pass by skipping dependencies or using a changed SDK fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_claude_mod

ROOT=Path(__file__).resolve().parents[1]


class RequiredWorkChecks(unittest.TestCase):
    def test_missing_toolchain_fails_instead_of_skipping(self):
        with tempfile.TemporaryDirectory() as empty:
            result=subprocess.run([sys.executable,'-B',str(ROOT/'tests/run_work_checks.py'),'--preflight'],
                env=os.environ|{'PATH':empty},capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,2)
        self.assertIn('missing: make',result.stderr)
        self.assertIn('claude',result.stderr)
        self.assertNotIn('skipped',result.stdout)

    def test_generated_fixture_is_complete_and_matches_its_engine(self):
        folder,manifest=test_claude_mod.sdk_fixture()
        self.assertEqual(set(manifest['files']),{'claude-code/index.d.ts','claude-code-tools/index.d.ts','claude-code-mcp/index.d.ts','tsconfig.json'})
        self.assertIn(manifest['claude'],(folder/'claude-code/index.d.ts').read_text().split('\n',1)[0])

    def test_a_truncated_declaration_cannot_be_used_as_a_valid_sdk(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo=Path(temporary); folder=repo/'tests/fixtures/claude-sdk'
            shutil.copytree(ROOT/'tests/fixtures/claude-sdk',folder)
            (folder/'claude-code-tools/index.d.ts').write_text('export {}\n')
            with patch.object(test_claude_mod,'ROOT',repo):
                with self.assertRaisesRegex(ValueError,'SDK fixture changed'):
                    test_claude_mod.sdk_fixture()


if __name__=='__main__': unittest.main()
