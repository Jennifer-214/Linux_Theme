"""Real Git repositories and supervised processes; all state stays in disposable homes."""
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parents[1] / "fox-work"


class Work(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.repo = self.dir / "project with spaces"
        self.repo.mkdir()
        self.env = dict(os.environ, HOME=str(self.dir / "home"), XDG_STATE_HOME=str(self.dir / "state"),
                        XDG_CONFIG_HOME=str(self.dir / "config"), XDG_RUNTIME_DIR=str(self.dir / "runtime"),
                        TMUX_PANE="%123", FOXML_WORK_NOTIFY="0", PYTHONDONTWRITEBYTECODE="1")
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "sample.cpp").write_text("int original = 1;\n")
        (self.repo / ".gitignore").write_text("build/\n*.log\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, capture_output=True,
                              text=True, check=True).stdout.strip()

    def invoke(self, *args, code=0):
        p = subprocess.run([str(BIN), *map(str, args)], cwd=self.repo, env=self.env, capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return p.stdout

    def data(self, *args):
        return json.loads(self.invoke(*args))

    def execute(self, script, code=0):
        return self.invoke("run", "--session", "test-session", "--", sys.executable, "-c", script, code=code)

    def latest(self):
        return self.data("jobs")[0]

    def test_streams_exit_status_counts_and_locations(self):
        text = "sample.cpp:1:3: assertion failed\n128 passed, 2 failed\n"
        self.execute(f"import sys; print({text!r}); print('stderr kept', file=sys.stderr); sys.exit(7)", code=7)
        j = self.latest()
        self.assertEqual((j["state"], j["exit"], j["session"], j["pane"]), ("failed", 7, "test-session", "%123"))
        self.assertEqual((j["tests"]["passed"], j["tests"]["failed"]), (128, 2))
        failure = j["tests"]["failures"][0]
        self.assertEqual((failure["filename"], failure["lnum"], failure["col"]), (str(self.repo / "sample.cpp"), 1, 3))
        self.assertIn("stderr kept", Path(j["log"]).read_text())
        self.assertEqual(Path(j["log"]).stat().st_mode & 0o777, 0o600)

    def test_dirty_baseline_compares_tested_content_and_turns_stale(self):
        script = "from pathlib import Path; import sys; s=Path('sample.cpp').read_text(); print('2 passed' if 'broken' not in s else '1 passed, 1 failed'); sys.exit('broken' in s)"
        (self.repo / "sample.cpp").write_text("int dirty_but_good = 2;\n")
        self.execute(script)
        green = self.latest()
        self.assertTrue(green["baselineEligible"])
        (self.repo / "sample.cpp").write_text("int broken = 3;\n")
        self.execute(script, code=1)
        failed = self.latest()
        self.assertEqual(failed["baseline"], green["id"])
        patch = self.invoke("compare", "--id", failed["id"])
        self.assertIn("-int dirty_but_good = 2;", patch)
        self.assertIn("+int broken = 3;", patch)
        self.assertFalse(self.data("notebook")["tests"]["stale"])
        (self.repo / "sample.cpp").write_text("int fixed = 4;\n")
        self.assertTrue(self.data("notebook")["tests"]["stale"])

    def test_new_untracked_source_invalidates_result(self):
        self.execute("print('2 passed')")
        self.assertFalse(self.data("notebook")["tests"]["stale"])
        (self.repo / "new_test.py").write_text("assert True\n")
        self.assertTrue(self.data("notebook")["tests"]["stale"])

    def test_freshness_counts_modified_added_and_deleted_files_by_content(self):
        (self.repo / "deleted.py").write_text("print('old')\n")
        self.execute("print('128 passed')")
        self.assertEqual(self.data("notebook")["tests"]["changedFiles"], [])
        (self.repo / "sample.cpp").write_text("int updated = 2;\n")
        (self.repo / "deleted.py").unlink()
        (self.repo / "new.py").write_text("print('new')\n")
        test = self.data("notebook")["tests"]
        self.assertTrue(test["stale"])
        self.assertEqual(test["changedFiles"], ["deleted.py", "new.py", "sample.cpp"])
        self.assertEqual(self.data("tests", "--id", test["id"])["changedFiles"], test["changedFiles"])

    def test_changed_during_run_is_not_a_green_baseline(self):
        self.execute("from pathlib import Path; Path('sample.cpp').write_text('changed\\n'); print('2 passed')")
        self.assertTrue(self.latest()["changedDuringRun"])
        self.assertFalse(self.latest()["baselineEligible"])

    def test_unknown_test_output_does_not_invent_counts(self):
        self.execute("print('nothing to count')")
        self.assertIsNone(self.latest()["tests"]["passed"])
        self.assertFalse(self.latest()["baselineEligible"])

    def test_gtest_ctest_and_unittest_summaries(self):
        for log, expected in [("[  PASSED  ] 18 tests.\n[  FAILED  ] 2 tests.", (18, 2)),
                              ("80% tests passed, 2 tests failed out of 10", (8, 2)),
                              ("Ran 7 tests in 0.1s\n\nOK", (7, 0))]:
            self.execute(f"print({log!r})")
            t = self.latest()["tests"]
            self.assertEqual((t["passed"], t["failed"]), expected)

    def test_ignored_outputs_and_secrets_are_not_snapshotted(self):
        (self.repo / "build").mkdir()
        (self.repo / "build/generated.cpp").write_text("ignored\n")
        (self.repo / "secrets.cfg").write_text("private\n")
        (self.repo / ".env").write_text("private\n")
        self.execute("print('1 passed')")
        manifest = self.latest()["snapshot"]["files"]
        self.assertEqual(set(manifest), {"sample.cpp"})

    def test_private_repo_has_no_source_copies_or_green_claim(self):
        config = Path(self.env["XDG_CONFIG_HOME"]) / "foxml"
        config.mkdir(parents=True)
        (config / "claude-private-repos").write_text(str(self.repo) + "\n")
        self.execute("print('1 passed')")
        self.assertFalse(self.latest()["snapshot"]["complete"])
        self.assertFalse(self.latest()["baselineEligible"])
        self.assertEqual(self.latest()["snapshot"]["files"], {})
        self.assertIsNone(self.data("notebook")["tests"]["changedFiles"])

    def test_attention_failure_clears_after_same_command_succeeds(self):
        script = "from pathlib import Path; import sys; sys.exit(Path('broken').exists())"
        (self.repo / "broken").touch()
        self.execute(script, code=1)
        self.assertEqual(len(self.data("notebook")["failures"]), 1)
        (self.repo / "broken").unlink()
        self.execute(script)
        self.assertEqual(self.data("notebook")["failures"], [])

    def test_a_call_recorded_from_outside_reads_like_one_fox_work_ran(self):
        p = subprocess.run([str(BIN), "begin", "--root", self.repo, "--session", "s", "--pid", "parent",
                            "--command", "make test", "--title", "Run the tests"], cwd=self.repo, env=self.env,
                           capture_output=True, text=True, timeout=30)
        run = p.stdout.strip()
        self.assertRegex(run, r"^[0-9a-f]{32}$", p.stderr)
        self.assertEqual(self.latest()["pid"], os.getpid(), "the job lives as long as whoever started it")
        subprocess.run([str(BIN), "finish", "--id", run, "--exit", "2", "--output", "-"], input="128 passed, 2 failed\n",
                       cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30, check=True)
        j = self.latest()
        self.assertEqual((j["state"], j["title"], j["observed"]), ("failed", "Run the tests", False))
        self.assertEqual((j["tests"]["passed"], j["tests"]["failed"]), (128, 2))

    def test_a_title_names_the_job_and_the_failure_count_is_what_still_fails_today(self):
        script = "from pathlib import Path; import sys; sys.exit(Path('broken').exists())"
        (self.repo / "broken").touch()
        self.invoke("run", "--session", "s", "--title", "Check the sample\nbuild", "--", sys.executable, "-c", script, code=1)
        self.assertNotIn("title", self.latest(), "a title must be one line")
        self.invoke("run", "--session", "s", "--title", "  Check the sample  ", "--", sys.executable, "-c", script, code=1)
        self.assertEqual(self.latest()["title"], "Check the sample")
        self.assertIn("sys.exit", self.latest()["command"], "the command itself is kept")
        self.assertEqual(self.data("overview", "--root", self.repo)["failed"], 1, "one command, failing twice, is one failure")
        (self.repo / "broken").unlink()
        self.execute(script)
        self.assertEqual(self.data("overview", "--root", self.repo)["failed"], 0, "fixed once it passes again")
        (self.repo / "broken").touch()
        self.execute("import sys; sys.exit(3)", code=3)
        self.assertEqual(len(self.data("notebook")["failures"]), 1)
        for run in Path(self.env["XDG_STATE_HOME"]).rglob("run.json"):
            j = json.loads(run.read_text()); j["ended"] -= 2 * 24 * 3600; run.write_text(json.dumps(j))
        self.assertEqual(self.data("notebook")["failures"], [], "yesterday's failures leave the notebook")
        self.assertEqual(self.data("overview", "--root", self.repo)["failed"], 0)

    def test_active_plan_and_step_are_persistent_and_scoped_to_session(self):
        plan = self.repo / "plan with spaces.md"
        plan.write_text("# A plan\n")
        self.assertTrue(self.data("plan-pin", "--session", "one", "--file", plan, "--step", "implement file selection")["ok"])
        self.assertEqual(self.data("plan", "--session", "one")["step"], "implement file selection")
        self.assertIsNone(self.data("plan", "--session", "two"))
        self.assertFalse(json.loads(self.invoke("plan-pin", "--session", "one", "--file", "missing.md", code=1))["ok"])
        self.assertEqual(self.data("plan", "--session", "one")["file"], str(plan))
        self.assertTrue(self.data("plan-pin", "--session", "one", "--file", "")["ok"])
        self.assertIsNone(self.data("plan", "--session", "one"))

    def test_file_actions_preserve_literal_arguments_and_reject_paths_outside_checkout(self):
        with tempfile.TemporaryDirectory(prefix='.fox-work-editor-', dir=Path(__file__).parent) as temp:
            fake = Path(temp)
            calls = self.dir / 'editor.json'
            kitty = fake / 'kitty'
            kitty.write_text('#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["WORK_CALLS"]).write_text(json.dumps(sys.argv))\n')
            kitty.chmod(0o755)
            self.env.update(PATH=str(fake) + os.pathsep + self.env['PATH'], WORK_CALLS=str(calls))
            path = self.repo / "a ' quote ; literal.cpp"
            path.write_text("int x;\n")
            self.invoke('open', '--root', self.repo, '--action', 'file-diff', '--file', path.name, '--session', 'abc')
            argv = json.loads(calls.read_text())
            self.assertEqual(argv[-3:], ['foxml-work:file-diff', str(path), 'abc'])
            self.assertEqual(argv[argv.index('--directory') + 1], str(self.repo))
            outside = self.dir / 'outside.cpp'
            outside.write_text('outside\n')
            (self.repo / 'escape.cpp').symlink_to(outside)
            self.invoke('open', '--root', self.repo, '--action', 'file', '--file', outside, code=2)
            self.invoke('open', '--root', self.repo, '--action', 'file', '--file', 'escape.cpp', code=2)

    def test_running_background_job_outlives_its_caller_and_is_visible(self):
        p = subprocess.Popen([str(BIN), "run", "--session", "abc", "--", sys.executable, "-c",
                              "import time; print('started', flush=True); time.sleep(1); print('1 passed')"],
                             cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        self.assertEqual(p.stdout.readline().strip(), "started")
        self.assertEqual(self.latest()["state"], "running")
        self.assertEqual(self.data("overview")["running"], 1)
        self.assertTrue(self.data("activities")["abc"]["active"])
        p.communicate(timeout=5)
        self.assertEqual(self.latest()["state"], "passed")
        self.assertEqual(self.data("overview")["running"], 0)

    def test_interrupted_and_reused_pid_are_never_passes(self):
        p = subprocess.Popen([str(BIN), "run", "--", sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(30)"],
                             cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        self.assertEqual(p.stdout.readline().strip(), "ready")
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=5)
        self.assertEqual(p.returncode, 143)
        self.assertEqual(self.latest()["state"], "interrupted")
        record = Path(self.latest()["log"]).parent / "run.json"
        j = json.loads(record.read_text())
        j.update(state="running", pid=os.getpid(), process="wrong-boot:1")
        record.write_text(json.dumps(j))
        self.assertEqual(self.latest()["state"], "interrupted")

    def test_long_log_is_bounded_and_cannot_be_a_green_baseline(self):
        self.execute("print('x' * (5 * 1024 * 1024)); print('1 passed')")
        j = self.latest()
        self.assertTrue(j["truncated"])
        self.assertLessEqual(Path(j["log"]).stat().st_size, 4 * 1024 * 1024)
        self.assertFalse(j["baselineEligible"])

    def test_tasks_are_atomic_concurrent_and_reopenable(self):
        def add(i): return self.invoke("task-add", "--text", f"step {i}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(add, range(16)))
        tasks = self.data("tasks")
        self.assertEqual(len(tasks), 16)
        self.assertEqual(len({t["id"] for t in tasks}), 16)
        key = tasks[0]["id"]
        self.data("task-toggle", "--id", key)
        self.assertTrue(self.data("tasks")[0]["done"])
        self.assertEqual(len(self.data("overview")["tasks"]), 15)
        self.data("task-toggle", "--id", key)
        self.assertFalse(self.data("tasks")[0]["done"])

    def test_corrupt_tasks_are_preserved(self):
        self.data("task-add", "--text", "a task")
        file = next((Path(self.env["XDG_STATE_HOME"]) / "foxml/work/projects").glob("*/tasks.json"))
        file.write_text("broken")
        self.invoke("task-add", "--text", "another", code=1)
        self.assertEqual(file.read_text(), "broken")

    def test_review_tray_only_claude_commits_and_tracks_inspection(self):
        self.git("commit", "--allow-empty", "-qm", "Claude change\n\nClaude-Session: https://claude.ai/code/session_example")
        sha = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "human change")
        self.assertEqual([r["sha"] for r in self.data("reviews")], [sha])
        self.data("reviewed", "--sha", sha)
        self.assertEqual(self.data("reviews"), [])
        self.assertTrue(self.data("reviews", "--all", "yes")[0]["reviewed"])

    def test_worktree_paths_with_spaces_are_not_shell_commands(self):
        other = self.dir / "other tree ; literal"
        self.git("worktree", "add", "-qb", "feature/work", str(other))
        rows = self.data("worktrees")
        self.assertEqual({r["path"] for r in rows}, {str(self.repo), str(other)})
        self.assertEqual(next(r for r in rows if r["path"] == str(other))["branch"], "feature/work")

    def test_snapshot_does_not_follow_symlinks_outside_project(self):
        target = self.dir / "outside.cpp"
        target.write_text("do not copy\n")
        (self.repo / "linked.cpp").symlink_to(target)
        self.execute("print('1 passed')")
        self.assertNotIn("linked.cpp", self.latest()["snapshot"]["files"])
        self.assertFalse(self.latest()["snapshot"]["complete"])

    def test_user_service_failure_notifies_once_until_it_recovers(self):
        # Executable fixtures live beside the test; /tmp can be mounted noexec.
        with tempfile.TemporaryDirectory(prefix='.fox-work-notify-',dir=Path(__file__).parent) as temp:
            fake = Path(temp)
            calls, units = self.dir / 'calls.jsonl', self.dir / 'units.txt'
            units.write_text('example.service loaded failed failed Example\n')
            code = ('#!'+sys.executable+'\nimport json,os,sys\nfrom pathlib import Path\n'
                    'with open(os.environ["WORK_CALLS"],"a") as f: f.write(json.dumps(sys.argv)+"\\n")\n'
                    'if Path(sys.argv[0]).name=="systemctl": print(Path(os.environ["WORK_UNITS"]).read_text())\n')
            for name in ('systemctl','setsid','notify-send'):
                p = fake / name
                p.write_text(code)
                p.chmod(0o755)
            self.env.update(PATH=str(fake)+os.pathsep+self.env['PATH'],WORK_CALLS=str(calls),WORK_UNITS=str(units),FOXML_WORK_NOTIFY='1')
            self.data('notify-services')
            self.data('notify-services')
            rows = [json.loads(line) for line in calls.read_text().splitlines()]
            notices = [r for r in rows if Path(r[0]).name=='setsid']
            self.assertEqual(len(notices),1)
            self.assertEqual(notices[0][-4:],['User service failed','service','ask-service','service'])
            self.assertIn('--expire-time=0',notices[0][4])
            self.assertIn('--category=foxml.work',notices[0][4])
            self.assertIn('--action=default=',notices[0][4])
            self.assertNotIn("--action=jump",notices[0][4])
            units.write_text('')
            self.data('notify-services')
            units.write_text('example.service loaded failed failed Example\n')
            self.data('notify-services')
            rows = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len([r for r in rows if Path(r[0]).name=='setsid']),2)


if __name__ == "__main__":
    unittest.main()
