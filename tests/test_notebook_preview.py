"""A partial or failed notebook run must not produce a successful preview."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('preview', ROOT / 'tests/notebook_preview.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class NotebookPreview(unittest.TestCase):
    def run_preview(self, args, result):
        with patch.object(preview.shutil, 'which', return_value='claude'), \
             patch.object(preview, 'RENDER', ROOT / 'Makefile'), \
             patch.object(preview, 'scenes', return_value=result), \
             contextlib.redirect_stdout(io.StringIO()) as stdout, \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            code = preview.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_scenes_from_a_failing_test_run_are_not_reported_as_success(self):
        result = ([{'name': 'partial', 'tree': 'sample'}], subprocess.CompletedProcess([], 1, '', '1 fail'))
        code, stdout, stderr = self.run_preview([], result)
        self.assertEqual(code, 1)
        self.assertEqual(stdout, '')
        self.assertIn('tests failed', stderr)

    def test_a_scene_filter_must_match_and_a_valid_preview_shows_its_text(self):
        result = ([{'name': 'front page', 'tree': 'sample'}], subprocess.CompletedProcess([], 0, '', ''))
        self.assertEqual(self.run_preview(['--scene', 'missing'], result)[0], 2)
        code, stdout, _ = self.run_preview(['--plain', '--scene', 'front'], result)
        self.assertEqual(code, 0)
        self.assertIn('sample', stdout)


if __name__ == '__main__':
    unittest.main()
