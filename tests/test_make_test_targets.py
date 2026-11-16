#!/usr/bin/env python3
"""`make test` runs each src/<tool> test target: a tool without one says "no tests"; one whose test target cannot run (a
missing prerequisite, a broken Makefile) fails the run instead of passing as "no tests". The real root Makefile, over a
throwaway src/ tree."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = {
    "good": "all:\n\t@true\ntest:\n\t@echo ran-the-tests\n",
    "none": "all:\n\t@true\n",
    "broken": "all:\n\t@true\ntest: tests/missing_test\n\t@./tests/missing_test\n",
    "malformed": "all:\n\t@true\ntest:\n    echo indented-with-spaces\n",
}


@unittest.skipUnless(shutil.which("make"), "make is not installed")
class TestTargets(unittest.TestCase):
    def setUp(self):
        self.tree = Path(tempfile.mkdtemp(prefix="make-test-targets-"))
        self.addCleanup(shutil.rmtree, self.tree, True)
        shutil.copy(ROOT / "Makefile", self.tree / "Makefile")
        for name, makefile in TOOLS.items():
            (self.tree / "src" / name).mkdir(parents=True)
            (self.tree / "src" / name / "Makefile").write_text(makefile)

    def make(self, target):
        # Its own environment: none of a calling make's flags (MAKEFLAGS would carry -n or -k in).
        return subprocess.run(["make", "--no-print-directory", "-C", str(self.tree), target], capture_output=True,
                              text=True, timeout=60, env={"PATH": "/usr/bin:/bin", "HOME": str(self.tree), "LC_ALL": "C"})

    def test_a_test_target_runs(self):
        run = self.make("test-good")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("ran-the-tests", run.stdout)

    def test_no_test_target_says_so_and_passes(self):
        run = self.make("test-none")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("src/none: no tests", run.stdout)

    def test_a_test_target_that_cannot_run_fails(self):
        for name in ("broken", "malformed"):
            with self.subTest(name):
                run = self.make(f"test-{name}")
                self.assertNotEqual(run.returncode, 0, f"src/{name}'s broken test target passed:\n{run.stdout}")
                self.assertNotIn("no tests", run.stdout, "a broken test target is not 'no tests'")


if __name__ == "__main__":
    unittest.main()
