#!/usr/bin/env python3
"""The CI check that no Soloist API key is committed (.github/scripts/no-soloist-key.sh).

Builds throwaway repos: a key added and then removed still fails (it is in the history), so does one on another branch
or only in the working tree; the report names the commit and file but never prints the key. The keys here are made at
run time, so this file holds none.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / ".github/scripts/no-soloist-key.sh"
KEY = "spak" + "_" + "Q7x" * 11  # 33 characters after the prefix, like a real one
ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}


class NoSoloistKey(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.commit("README", "a Soloist service, no key here: soloist setup-api-key\n", "start")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, env=ENV, check=True, capture_output=True)

    def commit(self, name, text, message):
        (self.repo / name).write_text(text)
        self.git("add", name)
        self.git("commit", "-q", "-m", message)

    def check(self):
        return subprocess.run(["bash", str(CHECK)], cwd=self.repo, env=ENV, capture_output=True, text=True)

    def test_clean_history_passes(self):
        run = self.check()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_a_removed_key_still_fails_without_printing_it(self):
        self.commit("start.sh", f"soloist -n box --api-key {KEY}\n", "run soloist")
        self.commit("start.sh", "soloist -n box\n", "key out")
        run = self.check()
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("run soloist: start.sh", run.stdout)
        self.assertNotIn(KEY[5:], run.stdout + run.stderr)

    def test_a_key_on_another_branch_fails(self):
        self.git("checkout", "-q", "-b", "side")
        self.commit("notes", KEY + "\n", "side notes")
        self.git("checkout", "-q", "main")
        self.assertEqual(self.check().returncode, 1)

    def test_a_key_only_in_the_working_tree_fails(self):
        (self.repo / "README").write_text(KEY + "\n")
        run = self.check()
        self.assertEqual(run.returncode, 1)
        self.assertIn("working tree: README", run.stdout)
        self.assertNotIn(KEY[5:], run.stdout)

    def test_short_lookalikes_pass(self):
        self.commit("doc", "keys look like spak_… and spak_abc\n", "doc")
        self.assertEqual(self.check().returncode, 0)

    def test_this_repo_has_none(self):
        # The real git settings: a CI container marks the checkout safe.directory there.
        run = subprocess.run(["bash", str(CHECK)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
