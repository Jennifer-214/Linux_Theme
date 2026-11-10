#!/usr/bin/env python3
"""tmux-title: the terminal title says the project, the branch and what runs there — never just the shell."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "shared/bin/tmux-title"


def title(path, cmd, home=None):
    env = dict(os.environ, HOME=home or os.environ.get("HOME", "/"))
    return subprocess.run(["bash", str(SCRIPT), str(path), cmd], capture_output=True, text=True, env=env, timeout=10).stdout


class TmuxTitle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "My_Project"
        (self.repo / "src").mkdir(parents=True)
        git = lambda *a: subprocess.run(["git", "-C", str(self.repo), *a], capture_output=True, check=True)
        git("init", "-q", "-b", "feature/a-rather-long-branch-name-for-tests")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x")

    def tearDown(self):
        self.tmp.cleanup()

    def test_project_branch_and_program(self):
        self.assertEqual(title(self.repo / "src", "nvim"), "My_Project · feature/a-rather-long-branc… · nvim")

    def test_a_shell_is_not_named(self):
        self.assertEqual(title(self.repo, "zsh"), "My_Project · feature/a-rather-long-branc…")

    def test_outside_a_repo_the_folder_and_home(self):
        plain = Path(self.tmp.name) / "notes"
        plain.mkdir()
        self.assertEqual(title(plain, "bash"), "notes")
        self.assertEqual(title(plain, "btop", home=str(plain)), "~ · btop")


if __name__ == "__main__":
    unittest.main()
