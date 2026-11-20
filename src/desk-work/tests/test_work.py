"""Real Git repositories and supervised processes; all state stays in disposable homes."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import select
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

BIN = Path(__file__).resolve().parents[1] / "desk-work"
NVIM_LUA = Path(__file__).resolve().parents[3] / "shared/nvim_lua"
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tests"))
import sealed_env  # noqa: E402


class Work(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.repo = self.dir / "project with spaces"
        self.repo.mkdir()
        self.env = self.environment()
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "sample.cpp").write_text("int original = 1;\n")
        (self.repo / ".gitignore").write_text("build/\n*.log\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def environment(self):
        """Sealed from the session (tests/sealed_env.py): no tmux of hers (desk-work agents lists tmux's panes), and no
        display, bus or kitty for an editor or a kitty a test forgot to stub; the pane desk-work records is the test's."""
        env = sealed_env.environment(self.dir, HOME=self.dir / "home", XDG_STATE_HOME=self.dir / "state",
                                     XDG_CONFIG_HOME=self.dir / "config", XDG_RUNTIME_DIR=self.dir / "runtime",
                                     TMUX_PANE="%123", FOXML_WORK_NOTIFY="0", PYTHONDONTWRITEBYTECODE="1")
        self.addCleanup(sealed_env.stop, env)
        return env

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
        """The newest run, with its source snapshot (kept beside the record, in snapshot.json)."""
        run = self.data("jobs")[0]
        folder = Path(self.env["XDG_STATE_HOME"]) / "foxml/work/runs" / run["id"]
        for name in ("snapshot.json", "run.json"):
            saved = json.loads((folder / name).read_text()) if (folder / name).exists() else {}
            if name == "snapshot.json" and saved:
                run["snapshot"] = saved; break
            if "snapshot" in saved:
                run["snapshot"] = saved["snapshot"]; break
        return run

    def test_history_digest_and_cross_agent_identity_use_one_store(self):
        self.data('review-request', '--file', 'sample.cpp', '--name', 'pi session', '--sid', 'peer', '--text', 'Please adjust')
        (self.repo/'sample.cpp').write_text('int edited = 2;\n')
        for agent in ['claude', 'pi']:
            self.assertTrue(self.data('agent-update', '--agent', agent, '--session', 'same-id', '--pid', os.getpid(),
                                     '--state', 'working', '--file', 'sample.cpp', '--title', agent)['ok'])
        overlaps = self.data('overlaps', '--file', 'sample.cpp', '--agent', 'claude', '--session', 'same-id')
        self.assertEqual([(row['agent'], row['key']) for row in overlaps], [('pi', 'pi:same-id')])
        self.execute("print('2 passed')")
        events = self.data('timeline')
        self.assertEqual([event['seq'] for event in events], sorted([event['seq'] for event in events], reverse=True))
        self.assertTrue({'request', 'edit', 'job'} <= {event['kind'] for event in events})
        for event in events:
            resolved = self.data('resolve', '--action', 'event', '--id', event['id'])
            self.assertEqual(resolved['action'], event['action'])
        digest = self.data('digest', '--consumer', 'notebook')
        self.assertIn('1 request ready', digest['summary'])
        through = digest['through']
        self.execute("print('3 passed')")
        self.data('digest', '--consumer', 'notebook', '--through', through)
        self.assertEqual(len(self.data('digest', '--consumer', 'notebook')['events']), 2, 'acknowledgement must not clear later arrivals')
        self.assertGreater(self.data('digest', '--consumer', 'nvim')['total'], 2, 'consumer cursors have independent places')

    def test_snoozing_is_shared_and_content_changes_bring_an_item_back(self):
        self.data('review-request', '--file', 'sample.cpp', '--name', 'peer', '--sid', 'peer', '--text', 'Adjust')
        (self.repo/'sample.cpp').write_text('int changed = 2;\n')
        item = self.data('attention')[0]
        self.assertTrue(self.data('snooze', '--id', item['id'], '--until-change', 'yes')['ok'])
        self.assertEqual(self.data('attention'), [])
        self.assertEqual(self.data('notebook')['attention'], [])
        self.assertEqual(self.data('overview')['attention'], [])
        self.assertIn('snoozed', self.data('attention', '--include-snoozed', 'yes')[0])
        self.assertEqual(self.data('review-requests')[0]['state'], 'ready', 'snoozing must not settle the underlying request')
        (self.repo/'sample.cpp').write_text('int changed_again = 3;\n')
        self.assertEqual(self.data('attention')[0]['id'], item['id'])

    def test_live_sessions_survive_silence_and_heartbeats_preserve_input_state(self):
        self.data('agent-update', '--agent', 'pi', '--session', 'long', '--pid', os.getpid(), '--state', 'needs')
        record = next((Path(self.env['XDG_STATE_HOME'])/'foxml/work/projects').glob('*/agents/*.json'))
        value = json.loads(record.read_text()); value['at'] -= 13*3600; value['seenAt'] = value['at']; record.write_text(json.dumps(value))
        self.assertTrue(self.data('agents')[0]['delayed'])
        revision = self.data('revision')['revision']
        self.assertTrue(self.data('agent-heartbeat', '--agent', 'pi', '--session', 'long', '--pid', os.getpid())['ok'])
        self.assertEqual(self.data('revision')['revision'], revision, 'a heartbeat is not a change every watcher refreshes on')
        current = self.data('agents')[0]
        self.assertEqual(current['state'], 'needs')
        self.assertEqual(current['at'], value['at'])
        self.assertFalse(current['delayed'])

    def test_suggested_tests_explain_inference_and_never_run_until_asked(self):
        (self.repo/'test_sample.py').write_text("print('1 passed')\n")
        self.invoke('run', '--', sys.executable, 'test_sample.py')
        original_count = len(self.data('jobs'))
        suggestions = self.data('suggest-tests', '--file', 'sample.cpp')
        self.assertIn('inferred', suggestions[0]['reason'])
        self.assertEqual(len(self.data('jobs')), original_count)
        self.invoke('run-suggested', '--id', suggestions[0]['id'])
        self.assertEqual(len(self.data('jobs')), original_count + 1)

    def test_loaded_versions_are_not_inferred_from_installed_files(self):
        directory = Path(self.env['XDG_STATE_HOME'])/'foxml/work/integrations'
        directory.mkdir(parents=True)
        record={'transaction':'100-1','clients': {'notebook': 'new-build'}, 'files': [], 'source': []}
        (directory/'current.json').write_text(json.dumps(record))
        (directory/'transactions/100-1').mkdir(parents=True)
        (directory/'transactions/100-1/manifest.json').write_text(json.dumps(record))
        self.assertEqual(self.data('integration-status', '--client', 'notebook', '--loaded', 'old-build')['status'], 'reload-pending')
        self.assertEqual(self.data('integration-status', '--client', 'notebook', '--loaded', 'new-build')['status'], 'current')
        self.assertEqual(self.data('integration-status', '--client', 'notebook')['status'], 'unverified')

    def test_health_reports_refresh_failure_without_erasing_the_last_success_or_publishing_a_change(self):
        directory = Path(self.env['XDG_STATE_HOME'])/'foxml/work/integrations'
        directory.mkdir(parents=True)
        record={'transaction':'100-1','clients': {'nvim': 'build'}, 'files': [], 'source': []}
        (directory/'current.json').write_text(json.dumps(record))
        (directory/'transactions/100-1').mkdir(parents=True)
        (directory/'transactions/100-1/manifest.json').write_text(json.dumps(record))
        self.data('signal')
        revision = self.data('revision')['revision']
        earlier = int(time.time())-40
        self.data('client-report','--client','nvim','--build','build','--pid',os.getpid(),'--root',self.repo,
                  '--stream','connected','--refresh-at',earlier,'--event-at',earlier)
        self.data('client-report','--client','nvim','--build','build','--pid',os.getpid(),'--root',self.repo,
                  '--stream','retrying','--retry-at',int(time.time())+10,'--error','Refresh timed out')
        health=self.data('health'); client=health['clients'][0]
        self.assertEqual(client['refreshAt'],earlier)
        self.assertEqual(client['loadedStatus'],'current')
        self.assertEqual(client['refreshState'],'failed')
        self.assertEqual(client['root'],str(self.repo))
        self.assertTrue(any('reconnecting' in line for line in health['alerts']))
        self.assertEqual(self.data('revision')['revision'],revision,'telemetry must not cause a refresh loop')
        self.data('client-report','--client','nvim','--build','build','--pid',os.getpid(),'--root',self.repo,
                  '--stream','connected','--refresh-at',int(time.time()),'--retry-at','0','--error','')
        self.assertEqual(self.data('health')['alerts'],[])

    def test_health_detects_a_dead_owned_watcher_and_an_interrupted_first_update(self):
        self.data('client-report','--client','nvim','--build','build','--pid',os.getpid(),'--root',self.repo,'--stream','connected')
        record=next((Path(self.env['XDG_STATE_HOME'])/'foxml/work/clients').glob('*.json'))
        value=json.loads(record.read_text()); value.update(watchPid=999999999,watchProcess='dead')
        record.write_text(json.dumps(value))
        self.assertEqual(self.data('health')['clients'][0]['stream'],'retrying')
        folder=Path(self.env['XDG_STATE_HOME'])/'foxml/work/integrations/transactions/100-1'
        folder.mkdir(parents=True)
        (folder/'manifest.json').write_text(json.dumps({'phase':'applying','transaction':'100-1','pid':0,'process':'dead','createdAt':100,'files':[]}))
        health=self.data('health')
        self.assertEqual(health['status'],'interrupted')
        self.assertEqual(health['pending'][0]['transaction'],'100-1')
        self.assertTrue(health['pending'][0]['interrupted'])
        self.assertIn('Interrupted update',[row['label'] for row in health['checks']])

    def test_suggested_rerun_keeps_the_original_working_directory(self):
        folder = self.repo/'subdirectory'; folder.mkdir()
        (folder/'test_sample.py').write_text("from pathlib import Path\nPath('ran.marker').write_text(str(Path.cwd()))\nprint('1 passed')\n")
        first = subprocess.run([str(BIN),'run','--root',str(self.repo),'--',sys.executable,'test_sample.py'],
                               cwd=folder,env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(first.returncode,0,first.stderr)
        self.assertEqual(self.latest()['cwd'],str(folder))
        (folder/'ran.marker').unlink()
        suggestion = self.data('suggest-tests','--file','sample.cpp')[0]
        self.assertEqual(suggestion['cwd'],str(folder))
        self.invoke('run-suggested','--id',suggestion['id'])
        self.assertEqual((folder/'ran.marker').read_text(),str(folder))
        self.assertFalse((self.repo/'ran.marker').exists())

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

    def test_an_incomplete_snapshot_alone_does_not_make_a_run_stale(self):
        # Review of 2026-11-17, G2: a checkout whose snapshot is never complete (here one in claude-private-repos) read
        # every pass as stale, and as changed while it ran. As the review tree reads a run, git's tree ids decide: a run
        # begun on a clean tree is current while no source file differs from that tree; one begun on a dirty tree
        # cannot be told (desk-work's word: unverified).
        config = Path(self.env["XDG_CONFIG_HOME"]) / "foxml"
        config.mkdir(parents=True)
        (config / "claude-private-repos").write_text(str(self.repo) + "\n")
        def fresh():
            run = self.data("tests", "--root", self.repo)
            return run["freshness"], run["stale"]
        self.execute("print('1 passed')")
        run = self.data("tests", "--root", self.repo)
        self.assertEqual((run["state"], run["freshness"], run["stale"], run.get("changedDuringRun", False), run["changedFiles"]),
                         ("passed", "same", False, False, None), "a clean tree, nothing changed since or during the run")
        self.assertFalse(self.data("notebook")["tests"]["stale"], "the notebook reads it the same")
        overview = self.data("overview", "--root", self.repo, "--fresh", "yes")["jobs"][0]
        self.assertEqual((overview["freshness"], overview["stale"]), ("same", False), "so does the drawer's overview")
        (self.repo / "build.log").write_text("ignored\n")
        (self.repo / "notes.md").write_text("not source\n")
        self.assertEqual(fresh(), ("same", False), "an ignored file and a file that is not source")
        self.git("add", "notes.md")
        self.git("commit", "-qm", "notes")
        self.assertEqual(fresh(), ("same", False), "a commit since that changes no source file")
        (self.repo / "sample.cpp").write_text("int edited = 2;\n")
        self.assertEqual(fresh(), ("stale", True), "a source file edited since")
        self.git("commit", "-qam", "edit")
        self.assertEqual(fresh(), ("stale", True), "… and committed")
        self.execute("from pathlib import Path; Path('sample.cpp').write_text('int during = 3;\\n'); print('2 passed')")
        self.assertTrue(self.latest()["changedDuringRun"], "a source file changed while it ran is still seen")
        self.execute("print('3 passed')")
        self.assertEqual(fresh(), ("unverified", True), "begun on a dirty tree: it cannot be told, and is not called stale")
        self.assertNotIn("changedDuringRun", self.latest(), "… nor changed while it ran")

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

    def test_a_failure_clears_when_a_newer_run_passes_the_same_tests_however_it_was_written(self):
        failures = lambda: [f["command"] for f in self.data("notebook")["failures"]]
        self.record("cd here; python3 -B tests/test_a.py", 1)
        self.record("python3 -B tests/test_b.py", 0)
        self.assertEqual(len(failures()), 1, "a passing run of another test does not clear it")
        self.record("python3 -I -B tests/test_a.py 2>&1 | tail -3", 1)
        self.assertEqual(self.data("overview", "--root", self.repo)["failed"], 1, "the same test failing twice, written two ways, is one failure")
        self.record("python3 -B tests/test_b.py; python3 -B tests/test_a.py", 0)
        self.assertEqual(failures(), [], "a newer run that passed the same test clears it")

        # What a command only mentions (a heredoc that writes a test) is not what it ran.
        self.record("cat > tests/test_c.py <<'EOF'\nimport tests.test_d\nEOF\npython3 -B tests/test_e.py", 1)
        self.record("python3 -B tests/test_e.py", 0)
        self.assertEqual(failures(), [], "the test it ran passed; the files its heredoc names are not tests it ran")

        # A test binary under a folder, cleared by that folder's suite written with a glob.
        (self.repo / "sub/tests").mkdir(parents=True)
        (self.repo / "sub/tests/test_ring").write_text("")
        self.record("make -C sub tests/test_ring; ./sub/tests/test_ring", 2)
        self.assertEqual(len(failures()), 1)
        self.record("make -s -C s*b test 2>&1 | tail -1", 0)
        self.assertEqual(failures(), [], "make -C D test covers the tests under D, globs read as the folder they match")

        # A command that names no test keeps the old rule: only the same command, passing, settles it.
        self.record("make -C sub all", 1)
        self.record("python3 -B tests/test_a.py", 0)
        self.assertEqual(failures(), ["make -C sub all"])
        record = next(Path(self.env["XDG_STATE_HOME"]).rglob("run.json"))
        old = json.loads(record.read_text())
        old.update(command="grep -n x tests/test_a.py", kind="tests", state="failed", observed=False); record.write_text(json.dumps(old))
        self.assertNotIn("grep -n x tests/test_a.py", failures(), "a call that only mentions a test file ran no test")

    def test_runs_older_than_a_month_are_cleared_when_a_new_one_starts(self):
        self.record("python3 -B tests/test_old.py", 0)
        old = next(Path(self.env["XDG_STATE_HOME"]).rglob("run.json"))
        stamp = old.stat().st_mtime - 31 * 24 * 3600
        os.utime(old, (stamp, stamp))
        self.record("python3 -B tests/test_new.py", 0)
        self.assertFalse(old.parent.exists(), "a run from last month is gone")
        self.assertEqual(len(self.data("jobs")), 1)
        self.assertTrue((Path(self.env["XDG_STATE_HOME"]) / "foxml/work/runs" / self.latest()["id"] / "snapshot.json").exists(),
                        "a new run keeps its snapshot beside the record")

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

    def test_plan_counts_markdown_checkboxes_outside_code_fences(self):
        plan = self.repo / "plan.md"
        plan.write_text("# A plan\n- [x] one\n  - [X] nested two\n* [ ] three\n1. [ ] four\n```\n- [x] example, not a step\n```\n- [] not a box\n")
        self.data("plan-pin", "--session", "one", "--file", plan)
        j = self.data("plan", "--session", "one")
        self.assertEqual((j["done"], j["total"]), (2, 4))
        plan.write_text("# No boxes here\n- just a list\n")
        self.assertEqual(self.data("plan", "--session", "one")["total"], 0)

    def record(self, command, code, output="", root=None, took=None):
        """A Claude Bash call recorded from outside, as the mod does it; took rewrites its duration."""
        run = self.invoke("begin", "--root", root or self.repo, "--session", "s", "--pid", "parent", "--command", command).strip()
        if code is None:
            return run, None
        p = subprocess.run([str(BIN), "finish", "--id", run, "--exit", str(code), "--output", "-"], input=output,
                           cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30, check=True)
        if took is not None:
            record = next(Path(self.env["XDG_STATE_HOME"]).rglob(run + "/run.json"))
            j = json.loads(record.read_text()); j["started"] = j["ended"] - took; record.write_text(json.dumps(j))
        return run, json.loads(p.stdout)

    def test_running_job_estimate_is_the_last_pass_of_the_same_command_here(self):
        self.record("make test", 0, "3 passed\n", took=42)
        self.record("make test", 2, "1 failed\n", took=5)
        running, _ = self.record("make test", None)
        rows = {r["id"]: r for r in self.data("jobs")}
        self.assertEqual(rows[running]["estimate"], 42, "a failure in between is no estimate")
        self.assertNotIn("estimate", next(r for r in self.data("jobs") if r["state"] != "running"))
        self.assertEqual(self.data("notebook")["jobs"][0]["estimate"], 42)
        self.assertEqual(next(r for r in self.data("overview")["jobs"] if r["id"] == running)["estimate"], 42)
        other, _ = self.record("make test VERBOSE=1", None)
        self.assertNotIn("estimate", {r["id"]: r for r in self.data("jobs")}[other], "only the exact command counts")
        elsewhere = self.dir / "elsewhere"; elsewhere.mkdir()
        away, _ = self.record("make test", None, root=elsewhere)
        self.assertNotIn("estimate", {r["id"]: r for r in self.data("jobs")}[away], "only the same checkout counts")
        self.record("make test", 0, "3 passed\n", took=30)
        self.assertEqual({r["id"]: r for r in self.data("jobs")}[running]["estimate"], 30, "the newest pass wins")

    def test_finish_reports_how_many_runs_failed_in_a_row_before(self):
        _, first = self.record("make test", 2, "1 failed\n")
        self.assertEqual(first["failedBefore"], 0)
        self.record("make build", 2, "")
        self.record("make test", 130, "")
        _, second = self.record("make test", 2, "1 failed\n")
        self.assertEqual(second["failedBefore"], 1, "a stop neither counts nor breaks the run of failures")
        _, green = self.record("make test", 0, "4 passed\n")
        self.assertEqual((green["state"], green["testRun"], green["failedBefore"]), ("passed", True, 2))
        self.assertEqual(next(r for r in self.data("jobs") if r["state"] == "passed")["failedBefore"], 2)
        self.record("make test", 2, "1 failed\n")
        _, flaky = self.record("make test", 0, "4 passed\n")
        self.assertEqual(flaky["failedBefore"], 1, "one flaky failure is not a streak")

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
            self.assertEqual(argv[-3:], ['desk-work:file-diff', str(path), 'abc'])
            self.assertEqual(argv[argv.index('--directory') + 1], str(self.repo))
            outside = self.dir / 'outside.cpp'
            outside.write_text('outside\n')
            (self.repo / 'escape.cpp').symlink_to(outside)
            self.invoke('open', '--root', self.repo, '--action', 'file', '--file', outside, code=2)
            self.invoke('open', '--root', self.repo, '--action', 'file', '--file', 'escape.cpp', code=2)
            # The call graph: the file checked the same way, its line only ever a number.
            self.invoke('open', '--root', self.repo, '--action', 'callgraph', '--file', path.name, '--index', '12')
            self.assertEqual(json.loads(calls.read_text())[-3:], ['desk-work:callgraph', str(path), '12'])
            for line in ('', '0', '12; x', '-3'):
                self.invoke('open', '--root', self.repo, '--action', 'callgraph', '--file', path.name, '--index', line, code=2)
            self.invoke('open', '--root', self.repo, '--action', 'callgraph', '--file', 'escape.cpp', '--index', '1', code=2)
            # A file named from a folder of the checkout is that folder's (the notebook's plan: it opened the top's
            # MASTER.md, a blank buffer, 2026-11-16); a name only the top has still opens there.
            plans = self.repo / 'plans' / 'v5'
            plans.mkdir(parents=True)
            (plans / 'MASTER.md').write_text('# A plan\n')
            self.invoke('open', '--root', plans, '--action', 'file', '--file', 'MASTER.md')
            self.assertEqual(json.loads(calls.read_text())[-3:-1], ['desk-work:file', str(plans / 'MASTER.md')])
            self.invoke('open', '--root', plans, '--action', 'file', '--file', path.name)
            self.assertEqual(json.loads(calls.read_text())[-3:-1], ['desk-work:file', str(path)])
            self.invoke('open', '--root', plans, '--action', 'file', '--file', '../../../outside.cpp', code=2)

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
        for _ in range(2): self.data("task-toggle", "--id", key, "--done", "yes")
        self.assertTrue(self.data("tasks")[0]["done"], "mark done sets done: a second press cannot reopen the step")

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

    def test_review_progress_is_shared_and_a_changed_file_reopens_with_its_history(self):
        import hashlib
        (self.repo / "queue.cpp").write_text("one\n"); (self.repo / "worker.cpp").write_text("w\n")
        sig = lambda s: hashlib.sha256(s.encode()).hexdigest()
        content = hashlib.sha256(b"one\n").hexdigest()
        mark = lambda *a: self.data("review-mark", "--key", "working", *a)
        self.assertTrue(mark("--file", "queue.cpp", "--signature", sig("a"), "--content", content, "--total", "3")["ok"])
        self.assertTrue(mark("--file", "worker.cpp", "--signature", sig("b"))["ok"])
        got = self.data("review-progress")["working"]
        self.assertEqual((got["checked"], got["changed"], got["total"], got["completed"]), (2, 0, 3, False))
        (self.repo / "queue.cpp").write_text("two\n")                      # edited after it was checked
        got = self.data("review-progress")["working"]
        self.assertEqual(got["files"]["queue.cpp"]["state"], "changed")
        self.assertEqual((got["checked"], got["changed"]), (1, 1), "a check with no recorded content (a commit's file) still holds")
        mark("--file", "queue.cpp", "--signature", sig("c"), "--content", hashlib.sha256(b"two\n").hexdigest())
        store = json.loads(next((self.dir / "state").rglob("review-marks.json")).read_text())
        self.assertEqual(store["working"]["files"]["queue.cpp"]["before"]["signature"], sig("a"), "the earlier check is kept as history")
        mark("--file", "third.cpp", "--signature", sig("d")); mark("--done", "yes")
        self.assertTrue(self.data("review-progress", "--key", "working")["working"]["completed"])
        mark("--file", "third.cpp", "--signature", "")                      # unchecked again
        self.assertFalse(self.data("review-progress")["working"]["completed"])
        for bad in (["--key", "../x", "--file", "a", "--signature", sig("a")], ["--key", "k", "--file", "../etc/passwd", "--signature", sig("a")],
                    ["--key", "k", "--file", "/abs", "--signature", sig("a")], ["--key", "k", "--file", "a", "--signature", "nothex"]):
            self.assertFalse(json.loads(self.invoke("review-mark", *bad, code=1))["ok"], bad)
        self.git("commit", "--allow-empty", "-qm", "Claude change\n\nClaude-Session: https://claude.ai/code/session_example")
        sha = self.git("rev-parse", "HEAD")
        self.data("review-mark", "--key", sha, "--file", "queue.cpp", "--signature", sig("e"), "--total", "4")
        row = self.data("reviews")[0]
        self.assertEqual((row["sha"], row["checked"], row["total"]), (sha, 1, 4), "the tray row carries 1 of 4")

    def test_review_tree_groups_claude_commits_by_plan_oldest_first_with_progress(self):
        import hashlib
        def commit(subject, when):
            env = dict(self.env, GIT_COMMITTER_DATE=when, GIT_AUTHOR_DATE=when)
            subprocess.run(["git", "-C", str(self.repo), "commit", "--allow-empty", "-qm",
                            subject + "\n\nClaude-Session: https://claude.ai/code/session_x"], env=env, check=True)
            return self.git("rev-parse", "HEAD")
        first = commit("Split the queue header", "2026-11-10T10:00:00")
        second = commit("Workers take the new queue", "2026-11-10T11:00:00")
        loose = commit("A stray fix", "2026-11-11T09:00:00")
        for sha, step in ((first, "step 1"), (second, "step 2")):
            self.assertTrue(self.data("commit-plan", "--sha", sha, "--file", "/plans/queue.md", "--title", "Queue refactor", "--step", step)["ok"])
        self.data("review-mark", "--key", first, "--file", "queue.hpp", "--signature", hashlib.sha256(b"a").hexdigest(), "--total", "2")
        tree = self.data("review-tree")
        self.assertEqual([t["title"] for t in tree][0], "Queue refactor")
        self.assertRegex(tree[1]["title"], r" · Wed Nov 11$", "no plan: the branch and the day")
        plan = tree[0]
        self.assertEqual([c["sha"] for c in plan["commits"]], [first, second], "oldest first")
        self.assertEqual((plan["checked"], plan["total"], plan["plan"], plan["commits"][1]["step"]), (1, 2, "/plans/queue.md", "step 2"))
        self.data("reviewed", "--sha", first)
        self.assertEqual([c["sha"] for c in self.data("review-tree")[0]["commits"]], [second], "a finished commit leaves the pending tree")
        self.assertEqual(len(self.data("review-tree", "--all", "yes")[0]["commits"]), 2)
        self.assertFalse(json.loads(self.invoke("commit-plan", "--sha", "nothex", "--title", "x", code=1))["ok"])

    def test_checking_every_file_of_a_commit_takes_it_off_the_to_review_count(self):
        import hashlib
        sig = lambda text: hashlib.sha256(text.encode()).hexdigest()
        self.git("commit", "--allow-empty", "-qm", "Two files\n\nClaude-Session: https://claude.ai/code/session_x")
        sha = self.git("rev-parse", "HEAD")
        pending = lambda: [r["sha"] for r in self.data("reviews")]
        self.assertEqual(pending(), [sha])
        self.data("review-mark", "--key", sha, "--file", "a.cpp", "--signature", sig("a"), "--total", "2")
        self.assertEqual(pending(), [sha], "one of two files checked: still to review")
        self.data("review-mark", "--key", sha, "--file", "b.cpp", "--signature", sig("b"), "--total", "2")
        self.assertEqual(pending(), [], "every file checked: no longer counted")
        self.assertTrue(self.data("reviews", "--all", "yes")[0]["reviewed"])
        # Without a recorded file count, one checked file never counts as the whole commit.
        self.git("commit", "--allow-empty", "-qm", "Unknown size\n\nClaude-Session: https://claude.ai/code/session_x")
        other = self.git("rev-parse", "HEAD")
        self.data("review-mark", "--key", other, "--file", "c.cpp", "--signature", sig("c"))
        self.assertEqual(pending(), [other])

    def test_a_finished_review_is_stamped_on_the_commit_and_the_stamp_alone_counts(self):
        self.git("commit", "--allow-empty", "-qm", "Claude change\n\nClaude-Session: https://claude.ai/code/session_example")
        sha = self.git("rev-parse", "HEAD")
        head_before = self.git("rev-parse", "HEAD")
        self.assertTrue(self.data("reviewed", "--sha", sha)["ok"])
        note = self.git("notes", "--ref", "reviews", "show", sha)
        self.assertIn("Reviewed-by: Test", note)
        self.assertRegex(note, r"Reviewed-on: \d{4}-\d\d-\d\d")
        self.assertEqual(self.git("rev-parse", "HEAD"), head_before, "history is not rewritten")
        # A fresh machine: the local record is gone, the note came with the repository.
        for record in (self.dir / "state").rglob("reviewed.json"): record.unlink()
        for cache in (self.dir / "state").rglob("reviews-cache*.json"): cache.unlink()
        self.assertEqual(self.data("reviews"), [], "the stamp alone marks it reviewed")
        self.assertTrue(self.data("reviews", "--all", "yes")[0]["reviewed"])
        # Switched off: no note is written.
        self.git("commit", "--allow-empty", "-qm", "Another\n\nClaude-Session: https://claude.ai/code/session_example")
        other = self.git("rev-parse", "HEAD")
        self.env["DESK_REVIEW_NOTES"] = "0"
        self.assertTrue(self.data("reviewed", "--sha", other)["ok"])
        listed = self.git("notes", "--ref", "reviews", "list")
        self.assertNotIn(other, listed)

    def test_push_check_counts_unreviewed_claude_commits_going_out_and_names_the_red_zone(self):
        remote = self.dir / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        self.git("commit", "--allow-empty", "-qm", "base")
        self.git("remote", "add", "origin", str(remote))
        branch = self.git("symbolic-ref", "--short", "HEAD")
        self.git("push", "-q", "-u", "origin", branch)
        self.assertEqual(self.data("push-check")["line"], "", "nothing to push says nothing")
        def claude(name, text):
            (self.repo / name).write_text(text)
            self.git("add", name)
            self.git("commit", "-qm", f"Change {name}\n\nClaude-Session: https://claude.ai/code/session_example")
            return self.git("rev-parse", "HEAD")
        plain = claude("notes.txt", "hello\n")
        risky = claude("setup.sh", "#!/bin/sh\nsudo install pam.conf /etc/pam.d/sudo\n")
        self.git("commit", "--allow-empty", "-qm", "mine, no session")
        got = self.data("push-check")
        self.assertEqual((got["unpushed"], got["unreviewed"]), (3, 2), "only Claude's commits count")
        self.assertEqual(got["line"], "2 Claude commits not reviewed · 1 touches the red zone (/etc/pam.d)")
        self.data("reviewed", "--sha", risky)
        self.assertEqual(self.data("push-check")["line"], "1 Claude commit not reviewed")
        self.data("reviewed", "--sha", plain)
        self.assertEqual(self.data("push-check")["line"], "", "all reviewed: quiet")

    def test_the_tree_says_tests_passed_at_a_commit_only_when_they_ran_on_exactly_it(self):
        def claude(subject):
            self.git("add", "-A")
            self.git("commit", "--allow-empty", "-qm", subject + "\n\nClaude-Session: https://claude.ai/code/session_x")
            return self.git("rev-parse", "HEAD")
        first = claude("One")
        self.execute("print('3 passed')")                      # clean tree, on `first`
        second = claude("Two")
        (self.repo / "sample.cpp").write_text("int edited = 2;\n")
        self.execute("print('3 passed')")                      # a dirty tree: says nothing about `second`
        self.git("checkout", "-q", "--", "sample.cpp")
        third = claude("Three")
        self.execute("print('1 failed'); raise SystemExit(1)", code=1)
        tests = {c["sha"]: c.get("tests") for t in self.data("review-tree") for c in t["commits"]}
        self.assertEqual((tests[first], tests[second], tests[third]), ("passed", None, "failed"))

    def test_an_untracked_test_script_does_not_speak_for_the_commit(self):
        def claude(subject):
            self.git("add", "-A")
            self.git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm",
                     subject + "\n\nClaude-Session: https://claude.ai/code/session_x")
            return self.git("rev-parse", "HEAD")
        def tested():
            return {c["sha"]: c.get("tests") for t in self.data("review-tree") for c in t["commits"]}
        first = claude("One")
        (self.repo / "build").mkdir()
        (self.repo / "build" / "out.o").write_text("ignored\n")
        (self.repo / "test_extra.py").write_text("print('1 passed')\n")
        self.invoke("run", "--", sys.executable, "test_extra.py")
        self.assertIsNone(tested()[first], "what ran was not in the commit")
        run = self.latest()
        self.assertEqual((run["state"], run["clean"], run["source"]["tracked"], run["source"]["untracked"]),
                         ("passed", False, [], ["test_extra.py"]), "ignored files do not count; untracked ones do")
        second = claude("Two")   # the script is in the commit now
        self.invoke("run", "--", sys.executable, "test_extra.py")
        run = self.latest()
        self.assertEqual((run["clean"], run["source"]["fingerprint"]), (True, "tree:" + self.git("rev-parse", "HEAD^{tree}")))
        self.assertEqual(tested()[second], "passed")

    def test_a_change_request_waits_until_its_file_changes_and_a_clear_settles_it(self):
        (self.repo / "sample.cpp").write_text("int a = 1;\n")
        self.assertTrue(self.data("review-request", "--file", "sample.cpp", "--name", "Queue refactor", "--sid", "abc", "--text", "rename a\nplease")["ok"])
        got = self.data("review-requests")
        self.assertEqual([(r["file"], r["name"], r["text"], r["state"]) for r in got], [("sample.cpp", "Queue refactor", "rename a please", "waiting")])
        self.assertEqual(self.data("notebook")["requests"][0]["state"], "waiting", "the notebook gets the thread")
        (self.repo / "sample.cpp").write_text("int renamed = 1;\n")
        self.assertEqual(self.data("review-requests")[0]["state"], "ready", "the file changed: ready for re-review")
        self.assertFalse(json.loads(self.invoke("review-request", "--file", "../outside", "--name", "x", "--text", "y", code=1))["ok"])
        self.assertTrue(self.data("review-request", "--file", "sample.cpp", "--clear", "yes")["ok"])
        self.assertEqual(self.data("review-requests"), [])

    def test_review_stamps_are_pushed_only_where_the_repository_asks(self):
        remote = self.dir / "notes-remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        self.git("commit", "--allow-empty", "-qm", "Change\n\nClaude-Session: https://claude.ai/code/session_example")
        sha = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "-u", "origin", self.git("symbolic-ref", "--short", "HEAD"))
        self.data("reviewed", "--sha", sha)
        self.assertEqual(self.data("push-notes"), {"pushed": False, "reason": "off"}, "off unless asked for")
        there = lambda: subprocess.run(["git", "-C", str(remote), "rev-parse", "--verify", "--quiet", "refs/notes/reviews"], capture_output=True).returncode == 0
        self.assertFalse(there())
        self.git("config", "desk.pushReviewNotes", "true")
        self.assertEqual(self.data("push-notes"), {"pushed": True, "remote": "origin"})
        self.assertTrue(there(), "the stamps are on the remote")

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

    def test_attention_is_shared_ordered_and_a_settled_action_cannot_open(self):
        self.execute("import sys; print('1 failed'); sys.exit(1)", code=1)
        source = self.repo / 'sample.cpp'
        self.data('review-mark', '--root', self.repo, '--key', 'working', '--file', 'sample.cpp',
                  '--signature', 'a' * 64, '--content', hashlib.sha256(source.read_bytes()).hexdigest())
        self.data('review-request', '--root', self.repo, '--file', 'sample.cpp', '--sid', 'peer', '--name', 'Queue', '--text', 'handle empty')
        source.write_text('int changed = 2;\n')
        self.git('add', 'sample.cpp')
        self.git('commit', '-qm', 'Agent change\n\nCo-Authored-By: Claude <claude@example.invalid>')
        source.write_text('int changed = 3;\n')
        expected = self.data('attention', '--root', self.repo)
        self.assertEqual([i['kind'] for i in expected], ['job', 'request', 'commit'])
        self.assertEqual(self.data('notebook', '--root', self.repo)['attention'], expected)
        self.assertEqual(self.data('overview', '--root', self.repo)['attention'], expected)
        self.assertEqual([i['kind'] for i in self.data('attention', '--root', self.repo, '--scope', 'review')], ['request', 'commit'])
        self.assertEqual(expected[1]['action'], {'kind': 'file-diff', 'file': 'sample.cpp'})
        self.data('review-request', '--root', self.repo, '--file', 'sample.cpp', '--clear', 'yes')
        stale = json.loads(self.invoke('open', '--root', self.repo, '--action', 'attention', '--id', expected[1]['id'], code=1))
        self.assertFalse(stale['ok'])
        self.assertIn('settled', stale['message'])

    def test_change_stream_updates_on_writes_and_queries_do_not_feed_back(self):
        watcher = subprocess.Popen([str(BIN), 'watch', '--root', str(self.repo)], cwd=self.repo, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            def event():
                self.assertTrue(select.select([watcher.stdout], [], [], 4)[0], 'no change event arrived')
                return json.loads(watcher.stdout.readline())
            self.assertEqual(event()['version'], 1)
            self.data('task-add', '--root', self.repo, '--text', 'next')
            first = event()
            self.assertEqual(first['root'], str(self.repo))
            self.assertTrue(first['revision'])
            self.data('notebook', '--root', self.repo)
            self.data('attention', '--root', self.repo)
            self.assertFalse(select.select([watcher.stdout], [], [], .15)[0], 'a query caused a refresh loop')
            self.data('signal', '--root', self.repo)
            self.assertNotEqual(event()['revision'], first['revision'])
        finally:
            watcher.terminate(); watcher.communicate(timeout=5)

    def test_agent_identity_is_namespaced_observed_files_stay_inside_the_checkout_and_dead_agents_leave(self):
        options = ['agent-update', '--root', self.repo, '--session', 'same-id', '--state', 'working', '--pid', str(os.getpid())]
        self.data(*options, '--agent', 'claude', '--title', 'Claude work')
        self.data(*options, '--agent', 'pi', '--title', 'Pi work', '--file', 'sample.cpp')
        sessions = self.data('agents', '--root', self.repo)
        self.assertEqual({s['key'] for s in sessions}, {'claude:same-id', 'pi:same-id'})
        pi = next(s for s in sessions if s['agent'] == 'pi')
        self.assertEqual(pi['files'], ['sample.cpp'])
        self.assertFalse(pi['canMessage'])
        self.invoke(*options, '--agent', 'pi', '--file', '../outside.cpp', code=1)
        self.data('agent-update', '--root', self.repo, '--agent', 'pi', '--session', 'same-id', '--state', 'done')
        self.assertEqual(len(self.data('agents', '--root', self.repo)), 1)
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            self.data('agent-update', '--root', self.repo, '--agent', 'other', '--session', 'dead', '--state', 'working', '--pid', child.pid)
        finally:
            child.terminate(); child.wait(timeout=5)
        self.assertNotIn('other', {s['agent'] for s in self.data('agents', '--root', self.repo)})

    def sleeper(self):
        """A live process of the test's own (sealed: stopped with the rest at the end)."""
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], env=self.env)
        self.addCleanup(child.wait, 5)
        self.addCleanup(child.kill)
        return child

    def test_an_older_process_cannot_end_or_change_a_newer_registration_of_its_session(self):
        older = self.sleeper()
        time.sleep(0.1)   # start times count in clock ticks: the newer one must start a tick later
        newer = self.sleeper()
        update = ['agent-update', '--root', self.repo, '--agent', 'pi', '--session', 'resumed']
        self.data(*update, '--pid', older.pid, '--state', 'working', '--instance', 'old-one')
        self.data(*update, '--pid', newer.pid, '--state', 'waiting', '--instance', 'new-one')
        for extra in (['--instance', 'old-one'], []):
            refused = json.loads(self.invoke(*update, '--pid', older.pid, '--state', 'done', *extra, code=1))
            self.assertEqual(refused['refused'], 'not the owner', refused['message'])
        self.invoke(*update, '--pid', older.pid, '--state', 'working', '--instance', 'old-one', code=1)
        [session] = self.data('agents', '--root', self.repo)
        self.assertEqual((session['pid'], session['state'], session['owner']),
                         (newer.pid, 'waiting', {'adapter': 'pi', 'session': 'resumed', 'instance': 'new-one'}))
        self.data(*update, '--pid', newer.pid, '--state', 'done')   # its owner, as a client that names no instance
        self.assertEqual(self.data('agents', '--root', self.repo), [])

    def test_a_run_is_finished_only_by_its_owner(self):
        run = self.invoke('begin', '--root', self.repo, '--session', 's', '--pid', 'parent', '--adapter', 'pi',
                          '--instance', 'mine', '--command', 'make test').strip()
        self.assertEqual(self.latest()['owner'], {'adapter': 'pi', 'session': 's', 'instance': 'mine'})
        log = Path(self.env['XDG_STATE_HOME']) / 'foxml/work/runs' / run / 'output.log'
        for extra in (['--instance', 'theirs'], ['--pid', str(self.sleeper().pid)]):
            p = subprocess.run([str(BIN), 'finish', '--id', run, '--exit', '0', '--output', '-', *extra], input='5 passed\n',
                               cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
            self.assertEqual((p.returncode, json.loads(p.stdout)['refused']), (1, 'not the owner'), p.stdout + p.stderr)
            self.assertEqual(self.latest()['state'], 'running')
            self.assertFalse(log.exists(), 'a refused finish leaves the output as it was')
        p = subprocess.run([str(BIN), 'finish', '--id', run, '--exit', '0', '--output', '-'], input='5 passed\n',
                           cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(p.stdout)['state'], 'passed', 'the recorded process naming no instance is its owner')

    def finished(self, run, *args, output='', code=0):
        """desk-work finish for a run recorded from outside, as an adapter sends it; its answer."""
        p = subprocess.run([str(BIN), 'finish', '--id', run, '--output', '-', *map(str, args)], input=output,
                           cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return json.loads(p.stdout) if p.stdout.strip() else None

    def test_a_run_whose_end_is_not_known_is_never_a_pass(self):
        run = self.invoke('begin', '--root', self.repo, '--session', 's', '--pid', 'parent', '--command', 'make test').strip()
        answer = self.finished(run, '--exit', '0', '--state', 'unknown', '--why', 'moved to the background', output='3 passed\n')
        self.assertEqual(answer['state'], 'unknown')
        j = self.latest()
        self.assertEqual((j['state'], j['exit'], j['baselineEligible'], j['stateWhy']),
                         ('unknown', None, False, 'moved to the background'))
        later = self.invoke('begin', '--root', self.repo, '--session', 's', '--pid', 'parent', '--command', 'make test').strip()
        self.assertEqual(self.latest()['baseline'], '', 'a run whose end was not known is no one\'s baseline')
        self.assertEqual(self.finished(later, '--state', 'unknown')['state'], 'unknown', 'no exit is needed')

    def test_a_pass_on_partial_output_is_recorded_as_partial_and_is_no_baseline(self):
        begin = ('begin', '--root', self.repo, '--session', 's', '--pid', 'parent', '--command', 'make test')
        run = self.invoke(*begin).strip()
        full = self.dir / 'full output.txt'
        self.finished(run, '--exit', '0', '--output-complete', 'no', '--output-full', full,
                      '--output-why', 'the tool result was cut at 50 KB', output='3 passed\n')
        j = self.latest()
        self.assertEqual((j['state'], j['baselineEligible']), ('passed', False))
        self.assertEqual(j['output'], {'complete': False, 'full': str(full), 'why': 'the tool result was cut at 50 KB'})
        self.invoke(*begin)
        self.assertEqual(self.latest()['baseline'], '', 'a pass seen only in part is no baseline')
        self.finished(self.latest()['id'], '--exit', '0', output='3 passed\n')
        self.assertEqual((self.latest()['output'], self.latest()['baselineEligible']),
                         ({'complete': True, 'full': None, 'why': ''}, True))
        self.finished(self.invoke(*begin).strip(), '--exit', '0', '--output-full', 'relative/path', code=2)

    def test_a_finish_is_applied_once_and_one_for_a_run_that_is_gone_is_stale(self):
        run = self.invoke('begin', '--root', self.repo, '--session', 's', '--pid', 'parent', '--command', 'make test').strip()
        folder = Path(self.env['XDG_STATE_HOME']) / 'foxml/work/runs' / run
        first = self.finished(run, '--exit', '0', '--event', 'tool-1:end', output='3 passed\n')
        self.assertEqual(first['state'], 'passed')
        self.assertNotIn('duplicate', first)
        record, log = (folder / 'run.json').read_bytes(), (folder / 'output.log').read_bytes()
        again = self.finished(run, '--exit', '1', '--event', 'tool-1:end', output='1 failed\n')
        self.assertEqual((again['ok'], again['duplicate'], again['state']), (True, True, 'passed'))
        self.assertEqual(((folder / 'run.json').read_bytes(), (folder / 'output.log').read_bytes()), (record, log),
                         'a repeated event changes nothing')
        for path in folder.iterdir():
            path.unlink()
        folder.rmdir()   # pruned
        late = self.finished(run, '--exit', '0', '--event', 'tool-2:end')
        self.assertEqual((late['ok'], late['stale']), (True, True))
        self.assertFalse(folder.exists(), 'a late finish does not bring a pruned run back')

    def test_newer_engine_prompt_state_overrides_registry_activity_without_losing_observed_files(self):
        self.data('agent-update', '--root', self.repo, '--agent', 'claude', '--session', 'needs-user', '--state', 'working',
                  '--pid', os.getpid(), '--file', 'sample.cpp')
        runtime = Path(self.env['XDG_RUNTIME_DIR']) / 'foxml-claude'
        runtime.mkdir(parents=True)
        (runtime / 'needs-user.state').write_text(json.dumps({'cwd': str(self.repo), 'epoch': int(time.time()) + 1, 'state': 'needs'}))
        sessions = self.data('agents', '--root', self.repo)
        self.assertEqual(sessions[0]['state'], 'needs')
        self.assertEqual(sessions[0]['files'], ['sample.cpp'])
        self.assertEqual(self.data('attention', '--root', self.repo)[0]['kind'], 'agent')
        self.assertEqual(self.data('notebook', '--root', self.repo, '--session', 'needs-user')['attention'], [])

    def test_what_a_test_starts_reaches_no_tmux_server_of_the_session_it_ran_in(self):
        # A legacy Claude record makes desk-work agents ask tmux for its panes. A bare tmux reaches the server in $TMUX,
        # else the default socket under $TMUX_TMPDIR: a recording tmux, first on PATH, shows what this test's
        # environment gives it when the session it runs in has both (stand-ins here, never hers).
        runtime = Path(self.env['XDG_RUNTIME_DIR']) / 'foxml-claude'
        runtime.mkdir(parents=True)
        (runtime / 'legacy.state').write_text(json.dumps({'cwd': str(self.repo), 'epoch': int(time.time()), 'state': 'working'}))
        calls = self.dir / 'tmux-calls.jsonl'
        with mock.patch.dict(os.environ, TMUX='/stand-in/for/her/server,1,0', TMUX_PANE='%9', TMUX_TMPDIR='/stand-in/for/her/sockets'):
            sealed = self.environment()
        # Executable fixtures live beside the test; /tmp can be mounted noexec.
        with tempfile.TemporaryDirectory(prefix='.fox-work-tmux-', dir=Path(__file__).parent) as temp:
            stub = Path(temp) / 'tmux'
            stub.write_text('#!' + sys.executable + '\nimport json, os, sys\nwith open(os.environ["WORK_CALLS"], "a") as f:\n'
                            '    f.write(json.dumps([sys.argv[1:3], os.environ.get("TMUX"), os.environ.get("TMUX_TMPDIR")]) + "\\n")\n')
            stub.chmod(0o755)
            env = dict(sealed, PATH=temp + os.pathsep + sealed['PATH'], WORK_CALLS=str(calls))
            p = subprocess.run([str(BIN), 'agents', '--root', str(self.repo)], cwd=self.repo, env=env, capture_output=True,
                               text=True, timeout=30)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        rows = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual([args for args, _, _ in rows], [['list-panes', '-a']], 'the legacy record made desk-work ask tmux')
        for _, tmux, folder in rows:
            self.assertIsNone(tmux, "the session's $TMUX reached what the test started")
            self.assertTrue(Path(folder).is_relative_to(self.dir), f'tmux would look for its default server in {folder}')

    def test_automatic_observation_refuses_searches_scripts_and_credentials_centrally(self):
        for command in ['rg make tests/', 'echo pytest', 'pytest --token private', 'sudo make test', 'python3 - <<EOF\nmake test\nEOF']:
            self.assertFalse(self.data('classify', '--command', command)['observable'], command)
            self.assertEqual(self.invoke('begin', '--root', self.repo, '--pid', 'parent', '--safe', 'yes', '--command', command), '')
        for command in ['make test', 'cd src && python3 -B tests/test_x.py', 'npm run test']:
            self.assertTrue(self.data('classify', '--command', command)['observable'], command)

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
            self.assertIn('--category=desk.work',notices[0][4])
            self.assertIn('--action=default=',notices[0][4])
            self.assertNotIn("--action=jump",notices[0][4])
            units.write_text('')
            self.data('notify-services')
            units.write_text('example.service loaded failed failed Example\n')
            self.data('notify-services')
            rows = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len([r for r in rows if Path(r[0]).name=='setsid']),2)

    def project_dir(self):
        return Path(self.env['XDG_STATE_HOME'])/'foxml/work/projects'/hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest()

    def test_an_unreadable_record_is_named_refuses_writes_and_is_set_aside_by_a_previewed_repair(self):
        self.data('review-request', '--file', 'sample.cpp', '--name', 'peer', '--sid', 'peer', '--text', 'Adjust')
        broken = self.project_dir()/'review-requests.json'
        broken.write_text('{"sample.cpp": {"name": "peer"')
        refused = json.loads(self.invoke('review-request', '--file', 'sample.cpp', '--name', 'peer', '--text', 'Again', code=1))
        self.assertIn('change requests record (review-requests.json) cannot be read', refused['message'])
        self.assertEqual(broken.read_text(), '{"sample.cpp": {"name": "peer"', 'a refused write must leave the record as it was')
        first = self.data('attention')[0]
        self.assertEqual((first['kind'], first['id']), ('records', 'records:review-requests.json'))
        self.assertEqual(self.data('resolve', '--action', 'attention', '--id', first['id'])['action'], {'kind': 'health'})
        self.assertTrue(any('cannot be read' in line for line in self.data('health')['alerts']))
        preview = self.data('records-repair')
        self.assertEqual([a['kind'] for a in preview['actions']], ['set-aside'])
        self.assertEqual(broken.read_text(), '{"sample.cpp": {"name": "peer"', 'a preview changes nothing')
        stale = json.loads(self.invoke('records-repair', '--expected', 'not-the-plan', code=1))
        self.assertIn('preview the repair again', stale['message'])
        self.assertEqual(self.data('records-repair', '--expected', preview['plan'])['repaired'], 1)
        kept = list(self.project_dir().glob('review-requests.broken-*.json'))
        self.assertEqual([p.read_text() for p in kept], ['{"sample.cpp": {"name": "peer"'], 'the original is kept, byte for byte')
        self.assertFalse(broken.exists())
        self.assertTrue(self.data('review-request', '--file', 'sample.cpp', '--name', 'peer', '--text', 'Again')['ok'])
        self.assertEqual([i['kind'] for i in self.data('attention')], [])

    @staticmethod
    def waiting_for_lock(pid):
        """Whether pid waits for an flock someone else holds (a blocked waiter in /proc/locks: "N: -> FLOCK ... PID")."""
        for line in Path('/proc/locks').read_text().splitlines():
            parts = line.split()
            if '->' in parts and parts[parts.index('->') + 1:][:1] == ['FLOCK'] and parts[parts.index('->') + 4] == str(pid):
                return True
        return False

    def test_a_repair_leaves_a_record_that_changed_after_the_preview(self):
        import fcntl
        self.data('task-add', '--text', 'first step')
        tasks = self.project_dir() / 'tasks.json'
        tasks.write_text('[{"id": "x", "text": "cut sho')
        preview = self.data('records-repair')
        self.assertEqual([(a['kind'], a['file']) for a in preview['actions']], [('set-aside', 'tasks.json')])
        # Hold the record's lock as a writer would: the repair checks its token, then waits for the lock.
        lock = os.open(self.project_dir() / 'tasks.lock', os.O_CREAT | os.O_RDWR, 0o600)
        self.addCleanup(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        repair = subprocess.Popen([str(BIN), 'records-repair', '--expected', preview['plan']], cwd=self.repo, env=self.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: repair.poll() is None and repair.kill())
        deadline = time.monotonic() + 20
        while not self.waiting_for_lock(repair.pid):
            self.assertIsNone(repair.poll(), 'the repair must wait for the record\'s lock')
            self.assertLess(time.monotonic(), deadline, 'the repair never reached the lock')
            time.sleep(0.02)
        healthy = json.dumps([{'id': 'n' * 32, 'text': 'newer step', 'done': False, 'at': 1}])
        tasks.write_text(healthy)   # the writer's newer, healthy record
        fcntl.flock(lock, fcntl.LOCK_UN)
        out, err = repair.communicate(timeout=30)
        answer = json.loads(out)
        self.assertEqual((answer['repaired'], [s['file'] for s in answer['skipped']]), (0, ['tasks.json']), out + err)
        self.assertIn('changed since the preview', answer['message'])
        self.assertEqual(tasks.read_text(), healthy, 'a record newer than the preview is never acted on')
        self.assertEqual(list(self.project_dir().glob('tasks.broken-*.json')), [])
        self.assertEqual([t['text'] for t in self.data('tasks')], ['newer step'])

    def test_records_report_names_stale_references_and_tidies_only_requests(self):
        (self.repo/'gone.cpp').write_text('int gone;\n')
        self.data('review-request', '--file', 'gone.cpp', '--name', 'peer', '--text', 'Adjust')
        (self.repo/'gone.cpp').unlink()
        missing = '0' * 40
        (self.project_dir()/'reviewed.json').write_text(json.dumps({missing: 1}))
        report = self.data('records')
        self.assertEqual(report['problems'], 0)
        stale = {row['file']: row for row in report['stale']}
        self.assertEqual(stale['review-requests.json']['entries'], ['gone.cpp'])
        self.assertEqual(stale['reviewed.json']['entries'], [missing])
        self.assertFalse(stale['reviewed.json']['tidy'], 'finished reviews are history, not something to tidy away')
        preview = self.data('records-repair')
        self.assertEqual([(a['kind'], a['file']) for a in preview['actions']], [('tidy', 'review-requests.json')])
        self.data('records-repair', '--expected', preview['plan'])
        self.assertEqual(self.data('review-requests'), [])
        copies = list(self.project_dir().glob('review-requests.before-repair-*.json'))
        self.assertEqual(len(copies), 1)
        self.assertIn('gone.cpp', json.loads(copies[0].read_text()))

    def test_every_refusal_says_why(self):
        sources = list((BIN.parent).glob('*.cpp')) + list((BIN.parent).glob('*.hpp'))
        sources.append(BIN.parents[1]/('desk-' + 'install')/'modules/workflow_update.hpp')
        bare = [f'{p.name}:{n}' for p in sources for n, line in enumerate(p.read_text().splitlines(), 1)
                if '{"ok", false}}' in line]
        self.assertEqual(bare, [], 'a refusal without a message shows the person a blank notice')
        self.assertIn('A next step needs some text', json.loads(self.invoke('task-add', '--text', ' ', code=1))['message'])
        usage = subprocess.run([str(BIN), 'snooze'], cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(usage.returncode, 1)
        self.assertIn('Choose an item to snooze', json.loads(usage.stdout)['message'])
        unknown = subprocess.run([str(BIN), 'no-such-command'], cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(unknown.returncode, 2)
        self.assertIn('desk-work no-such-command: missing or invalid arguments', unknown.stderr)

    def test_sessions_on_older_code_carry_the_steps_that_keep_their_work(self):
        directory = Path(self.env['XDG_STATE_HOME'])/'foxml/work/integrations'
        directory.mkdir(parents=True)
        record = {'transaction': '100-1', 'clients': {'nvim': 'new', 'notebook': 'new', 'pi': 'new'}, 'files': [], 'source': []}
        (directory/'current.json').write_text(json.dumps(record))
        (directory/'transactions/100-1').mkdir(parents=True)
        (directory/'transactions/100-1/manifest.json').write_text(json.dumps(record))
        self.data('client-report', '--client', 'nvim', '--build', 'old', '--pid', os.getpid(), '--root', self.repo)
        self.data('agent-update', '--agent', 'claude', '--session', 'abc-123', '--pid', os.getpid(), '--state', 'working', '--build', 'old')
        self.data('agent-update', '--agent', 'pi', '--session', 'pi-1', '--pid', os.getpid(), '--state', 'working', '--build', 'new')
        health = self.data('health')
        steps = {row['client']: row.get('reload', '') for row in health['sessions'] if row['status'] == 'reload-pending'}
        self.assertEqual(set(steps), {'nvim', 'notebook'}, 'a session already on the installed code needs nothing')
        self.assertIn(':restart', steps['nvim'])
        self.assertIn('a restart ends them', steps['nvim'], 'terminal jobs inside Neovim must be named before a restart')
        self.assertIn('claude --resume abc-123', steps['notebook'])
        labels = [check['label'] for check in health['checks']]
        self.assertTrue(any(label.startswith('nvim') and 'older code' in label for label in labels))

    def test_the_digest_greets_with_when_the_reader_last_caught_up(self):
        self.execute("print('1 passed')")
        digest = self.data('digest', '--consumer', 'nvim')
        self.data('digest', '--consumer', 'nvim', '--through', digest['through'])
        quiet = self.data('digest', '--consumer', 'nvim')
        self.assertRegex(quiet['greeting'], r'^Nothing new since you looked this (morning|afternoon|evening)$')
        self.execute("print('2 passed')")
        later = self.data('digest', '--consumer', 'nvim')
        self.assertRegex(later['greeting'], r'^Since you last looked this (morning|afternoon|evening): 1 run passed')
        self.assertEqual(self.data('digest', '--consumer', 'fresh-reader')['greeting'],
                         self.data('digest', '--consumer', 'fresh-reader')['summary'], 'a first look has no "since"')

    def test_the_overview_leaves_out_checkouts_that_are_gone_or_idle_and_rewrites_nothing_unchanged(self):
        idle = self.dir / "idle"; idle.mkdir()
        gone = self.dir / "gone"; gone.mkdir()
        old = dict(self.env, GIT_AUTHOR_DATE="2020-01-01T00:00:00", GIT_COMMITTER_DATE="2020-01-01T00:00:00")
        for path in (idle, gone):
            subprocess.run(["git", "init", "-q", str(path)], env=self.env, check=True)
            (path / "a.txt").write_text("a\n")
            subprocess.run(["git", "-C", str(path), "add", "."], env=self.env, check=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=T", "-c", "user.email=t@e.invalid", "commit", "-qm",
                            "old\n\nClaude-Session: https://claude.ai/code/session_x"], env=old, check=True)
            self.data("tasks", "--root", path)            # registered, the way any read registers a checkout
            self.data("task-add", "--root", path, "--text", "something")
        import shutil; shutil.rmtree(gone)
        self.data("task-add", "--text", "here")          # this checkout: committed today
        seen = {t["root"] for t in self.data("overview")["tasks"]}
        self.assertIn(str(self.repo.resolve()), seen)
        self.assertNotIn(str(idle.resolve()), seen, "a checkout idle for weeks stays out of the lists")
        self.assertFalse(any("gone" in root for root in seen), "a checkout no longer on disk stays out")
        self.assertIn(str(idle.resolve()), {t["root"] for t in self.data("overview", "--root", idle)["tasks"]},
                      "asked for by name, it counts")
        # Reading twice writes nothing the second time: the review caches hit and the registry is not rewritten.
        self.data("overview")
        files = [p for p in (Path(self.env["XDG_STATE_HOME"]) / "foxml/work/projects").rglob("*") if p.is_file()]
        before = {p: p.stat().st_mtime_ns for p in files}
        time.sleep(0.05)
        self.data("overview")
        self.assertEqual({p: p.stat().st_mtime_ns for p in files if p.exists()}, before, "a read rewrote a record")

    def test_the_review_backlog_can_be_set_aside_and_brought_back_without_stamping_anything(self):
        claude = "\n\nClaude-Session: https://claude.ai/code/session_example"
        for n in (1, 2):
            self.git("commit", "--allow-empty", "-qm", f"old {n}{claude}")
        self.assertEqual([i["kind"] for i in self.data("attention")].count("commit"), 2)
        done = self.data("set-aside")
        self.assertEqual(done["count"], 2)
        self.assertNotIn("commit", [i["kind"] for i in self.data("attention")], "set-aside commits leave what needs you")
        self.assertEqual(self.data("set-aside", "--show", "yes")["count"], 2)
        self.assertEqual(self.data("notebook")["aside"]["count"], 2)
        self.assertEqual(self.data("notebook")["pending"], 0, "the review's count leaves them out too")
        self.assertEqual(len(self.data("reviews", "--all", "yes")), 3 - 1, "the review tree still lists them, unreviewed")
        self.assertFalse(any(r["reviewed"] for r in self.data("reviews", "--all", "yes")), "nothing was stamped reviewed")
        later = dict(self.env, GIT_COMMITTER_DATE=str(int(time.time()) + 60) + " +0000")
        subprocess.run(["git", "-C", str(self.repo), "commit", "--allow-empty", "-qm", f"new{claude}"], env=later, check=True, capture_output=True)
        self.assertEqual([i["kind"] for i in self.data("attention")].count("commit"), 1, "a commit made after still needs you")
        self.assertTrue(any("set aside" in e["label"] for e in self.data("timeline")), "the timeline records it")
        self.data("set-aside", "--undo", "yes")
        self.assertEqual([i["kind"] for i in self.data("attention")].count("commit"), 3, "bringing them back undoes it")
        refused = json.loads(self.invoke("set-aside", "--undo", "yes", code=1))
        self.assertIn("Nothing is set aside here", refused["message"])

    def parsed(self, text):
        p = subprocess.run([str(BIN), "metrics-parse"], cwd=self.repo, env=self.env, input=text, capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return {m["name"]: (m["value"], m["unit"]) for m in json.loads(p.stdout)}

    def test_metrics_are_read_only_from_lines_that_read_as_name_value_unit(self):
        read = self.parsed("\n".join([
            "p99 412ns", "throughput: 1.2M/s", "elapsed=4.1s", "ns/op 38.2", "  - wall: 3.5 ms", "[bench] p50=120us p90=300µs",
            "coverage 87.5%", "rss 12 MB", "rate=1200 ops/s", "took 3s.", "pid=4123 latency=9ms", "\x1b[32mspeed 2K/s\x1b[0m",
        ]))
        self.assertEqual(read, {
            "p99": (412, "ns"), "throughput": (1.2, "M/s"), "elapsed": (4.1, "s"), "ns/op": (38.2, "ns/op"), "wall": (3.5, "ms"),
            "p50": (120, "us"), "p90": (300, "µs"), "coverage": (87.5, "%"), "rss": (12, "MB"), "rate": (1200, "ops/s"),
            "took": (3, "s"), "latency": (9, "ms"), "speed": (2, "K/s")})
        # Numbers in prose, ids, versions, times of day, locations and counts with no unit are never metrics.
        for line in ["Ran 12 tests in 0.004s", "error at line 42", "line 42", "2026-11-15 12:00:01 started", "version 1.2.3",
                     "port=8080", "exit code 1", "Downloading 45% [=====>   ]", "test_x.py:42: in test_case", "p99 412ns but slower",
                     "OK (0.4s)", "Time elapsed: 3.2s", "retries 3x", "INFO request done in 12ms", "12 passed in 0.3s",
                     "commit abc123 · 4 files", "p99 412 nanoseconds", "build 3 of 9"]:
            self.assertEqual(self.parsed(line), {}, line)

    def test_a_project_declares_exact_metric_patterns(self):
        (self.repo / ".desk").mkdir()
        (self.repo / ".desk/metrics").write_text("# name unit regex\n"
                                                 "fills - ^Filled ([0-9]+) orders\n"
                                                 "p99 us ^latency p99 is ([0-9.]+)\n"
                                                 "broken ms ([unclosed\n"
                                                 "bogus parsecs ([0-9]+)\n")
        read = self.parsed("Filled 1200 orders\nlatency p99 is 41.5\np99 412ns\n")
        self.assertEqual(read, {"fills": (1200, ""), "p99": (41.5, "us")}, "a declared pattern wins over the plain reading")

    def test_metrics_compare_with_the_previous_run_of_the_same_job(self):
        bench = "print(open('figure.txt').read())"   # one job, printing what figure.txt holds at the time
        (self.repo / "figure.txt").write_text("p99 400ns\nthroughput: 1.0M/s\ncoverage 80%\n2 passed\n")
        self.execute(bench)
        self.execute("print('p99 999ns')")   # another command: never the previous run
        (self.repo / "figure.txt").write_text("p99 412ns\nthroughput: 1.2M/s\ncoverage 80%\nrss 3 MB\n2 passed\n")
        self.execute(bench)
        report = self.data("metrics")
        self.assertTrue(report["ok"])
        self.assertEqual(set(report), {"ok", "root", "job", "previous", "metrics"})
        self.assertEqual(set(report["job"]), {"id", "title", "command", "state", "ended", "testRun"})
        runs = self.data("jobs")
        self.assertEqual(report["job"]["id"], runs[0]["id"])
        self.assertEqual(report["previous"]["id"], runs[2]["id"], "the previous run of the same command, not the one between")
        by = {m["name"]: m for m in report["metrics"]}
        self.assertEqual(set(by["p99"]), {"name", "value", "unit", "source", "previous", "change", "percent", "delta", "better", "verdict"})
        self.assertEqual((by["p99"]["previous"], by["p99"]["change"], by["p99"]["delta"]), (400, 12, "+12"))
        self.assertEqual((by["p99"]["better"], by["p99"]["verdict"]), ("lower", "worse"), "slower latency is worse")
        self.assertEqual((by["throughput"]["better"], by["throughput"]["verdict"], by["throughput"]["delta"]), ("higher", "better", "+0.2"))
        self.assertEqual((by["coverage"]["verdict"], by["coverage"]["delta"]), ("same", ""))
        self.assertEqual((by["rss"]["verdict"], by["rss"]["previous"], by["rss"]["better"]), ("new", None, None))
        self.assertEqual((by["tests passed"]["value"], by["tests passed"]["source"]), (2, "tests"))
        self.assertEqual(self.data("notebook")["metrics"]["job"]["id"], runs[0]["id"], "the notebook carries the same report")
        # Units of one kind compare across scales: 0.5us is 88ns faster than 588ns, said in the new unit.
        for figure in ("p99 588ns", "p99 0.5us"):
            (self.repo / "figure.txt").write_text(figure + "\n")
            self.execute(bench)
        p99 = self.data("metrics")["metrics"][0]
        self.assertEqual((p99["unit"], p99["delta"], p99["verdict"]), ("us", "-0.088", "better"))
        # A named run is read from its log even when it finished before metrics were kept.
        record = Path(self.env["XDG_STATE_HOME"]) / "foxml/work/runs" / runs[2]["id"] / "run.json"
        saved = json.loads(record.read_text()); saved.pop("metrics"); record.write_text(json.dumps(saved))
        old = self.data("metrics", "--job", runs[2]["id"])
        self.assertEqual({m["name"] for m in old["metrics"]}, {"p99", "throughput", "coverage", "tests passed", "tests failed"})
        self.assertEqual(json.loads(self.invoke("metrics", "--job", "f" * 32, code=1))["ok"], False)

    def test_metrics_between_two_chosen_runs_with_what_changed_between_them(self):
        bench = "print(open('figure.txt').read())"
        (self.repo / "figure.txt").write_text("p99 400ns\n")
        self.execute(bench)
        (self.repo / "engine.c").write_text("int tick(void) { return 1; }\n")
        self.git("add", "engine.c"); self.git("commit", "-qm", "a slower tick")
        (self.repo / "figure.txt").write_text("p99 480ns\n")
        self.execute(bench)
        runs = self.data("jobs")
        slow, base = runs[0]["id"], runs[1]["id"]
        got = self.data("metrics", "--job", slow, "--against", base)
        p99 = got["metrics"][0]
        self.assertEqual((p99["previous"], p99["delta"], p99["verdict"]), (400, "+80", "worse"), "the slower run against the baseline chosen")
        self.assertEqual((got["job"]["command"], got["baseline"]["head"] != got["job"]["head"], got["binary"]), (runs[0]["command"], True, "not recorded by the runs"),
                         "what each run was: its command and the commit it ran at; the binary said not recorded, never guessed")
        self.assertEqual(([c["subject"] for c in got["commits"]], got["files"]), (["a slower tick"], ["engine.c"]), "… and what changed between them")
        self.assertEqual(json.loads(self.invoke("metrics", "--job", slow, "--against", "f" * 32, code=1))["ok"], False)

    def test_metrics_between_says_the_recent_range_and_the_first_difference(self):
        # Codex's E18 (2026-11-19): each figure's range over the other recent runs of the job, and whether the slower
        # one is outside it; the first condition the two runs differ in (command, folder, commit, edits)
        bench = "print(open('figure.txt').read())"
        for figure in ("p99 410ns", "p99 390ns", "p99 420ns", "p99 400ns"):
            (self.repo / "figure.txt").write_text(figure + "\n")
            self.execute(bench)
        self.execute("print('p99 9000ns')")
        (self.repo / "engine.c").write_text("int tick(void) { return 1; }\n")
        self.git("add", "engine.c"); self.git("commit", "-qm", "a slower tick")
        (self.repo / "figure.txt").write_text("p99 480ns\n")
        self.execute(bench)
        runs = [r for r in self.data("jobs") if "figure.txt" in r["command"]]
        slow, base = runs[0]["id"], runs[1]["id"]
        got = self.data("metrics", "--job", slow, "--against", base)
        p99 = got["metrics"][0]
        self.assertEqual((p99["range"]["low"], p99["range"]["high"], p99["range"]["runs"], p99["range"]["outside"]), (390, 420, 3, True),
                         "the other three runs of this job: 390–420ns, and 480 is outside it (the other job's figure left out)")
        self.assertEqual((got["differs"]["what"], got["differs"]["slower"] == got["job"]["head"], got["differs"]["baseline"] == got["baseline"]["head"]),
                         ("commit", True, True), "the same command and folder: the commit is the first difference")
        same = self.data("metrics", "--job", runs[1]["id"], "--against", runs[2]["id"])
        self.assertEqual((same["differs"]["what"], same["metrics"][0]["range"]["outside"]), ("nothing recorded", False),
                         "two runs of one command at one commit: nothing recorded differs; 400 is inside the others' 390–480")

    def test_a_runs_coverage_kept_with_it(self):
        lcov = "SF:engine.c\nFN:1,tick\nFN:5,spare\nFNDA:3,tick\nFNDA:0,spare\nDA:1,3\nDA:2,3\nDA:5,0\nend_of_record\nSF:/elsewhere/lib.c\nDA:1,1\nend_of_record\n"
        # a run that writes lcov.info where it runs: its coverage found and kept with it (Codex's #16)
        self.execute("open('lcov.info', 'w').write(%r)" % lcov)
        run = self.data("jobs")[0]
        self.assertEqual(run["coverage"]["files"], 1, "found after the run: one file of this checkout (the one outside left out)")
        got = self.data("coverage", "--run", run["id"], "--file", "engine.c")
        f = got["files"]["engine.c"]
        self.assertEqual((f["lines"], [(x["name"], x["line"], x["count"]) for x in f["functions"]], got["head"] == run["head"], got["command"] == run["command"]),
                         ({"1": 3, "2": 3, "5": 0}, [("tick", 1, 3), ("spare", 5, 0)], True, True),
                         "its lines and functions with their counts, the run's commit and command with them")
        # attached by hand to another run, with the executable named
        self.execute("print('no coverage here')")
        other = self.data("jobs")[0]["id"]
        self.assertFalse(json.loads(self.invoke("coverage", "--run", other, code=1))["ok"], "a run with none: said")
        (self.repo / "cov.info").write_text(lcov.replace("DA:2,3", "DA:2,0"))
        self.assertEqual(self.data("coverage", "add", "--run", other, "--lcov", self.repo / "cov.info", "--executable", "/w/build/app")["files"], 1)
        again = self.data("coverage", "--run", other)
        self.assertEqual((again["executable"], again["files"]["engine.c"]["lines"]["2"]), ("/w/build/app", 0), "… another test's run: another branch")

    def test_a_runs_coverage_keeps_its_branches(self):
        # Codex's E4 (2026-11-19): lcov's BRDA lines, each condition's outcomes and how many were taken ("-": the
        # condition never ran, none taken); two records of the same line (two blocks) add up
        lcov = ("SF:engine.c\nDA:3,4\nBRDA:3,0,0,4\nBRDA:3,0,1,0\nBRDA:7,0,0,-\nBRDA:7,0,1,-\n"
                "BRDA:9,0,0,2\nBRDA:9,0,1,1\nBRDA:9,1,0,0\nBRDA:9,1,1,3\nBRF:8\nBRH:5\nend_of_record\n")
        self.execute("open('lcov.info', 'w').write(%r)" % lcov)
        run = self.data("jobs")[0]
        f = self.data("coverage", "--run", run["id"], "--file", "engine.c")["files"]["engine.c"]
        self.assertEqual(f.get("branches"), {"3": {"taken": 1, "of": 2}, "7": {"taken": 0, "of": 2}, "9": {"taken": 3, "of": 4}},
                         "each line's outcomes and how many happened")

    def test_suggested_tests_put_the_one_that_ran_the_file_first(self):
        # Codex's E1 (2026-11-19): a run's recorded coverage is the strongest reason; the suggester said "coverage of this
        # file is not established" even when a run had kept it.
        def run_test(name, hits):
            lines = "".join(f"DA:{n},{c}\n" for n, c in zip((1, 2, 3), hits))
            (self.repo / name).write_text(f"open('lcov.info', 'w').write({('SF:engine.c' + chr(10) + lines + 'end_of_record' + chr(10))!r})\nprint('1 passed')\n")
            self.invoke("run", "--", sys.executable, name)
        run_test("test_most.py", (4, 1, 0))
        run_test("test_some.py", (2, 0, 0))
        run_test("test_none.py", (0, 0, 0))
        (self.repo / "test_plain.py").write_text("print('1 passed')\n")
        self.invoke("run", "--", sys.executable, "test_plain.py")
        got = self.data("suggest-tests", "--file", "engine.c")
        name_of = lambda s: s["label"].split()[-1].strip("'\"")
        by = {name_of(s): s for s in got}
        self.assertEqual([name_of(s) for s in got][:2], ["test_most.py", "test_some.py"], "the one that ran most of the file first")
        self.assertEqual(by["test_most.py"]["reason"], "Ran 2 of this file's 3 executable lines (its recorded coverage)")
        self.assertEqual((by["test_most.py"]["ran"], by["test_most.py"]["lines"]), (2, 3), "… the counts with it, for the review")
        self.assertEqual(by["test_none.py"]["reason"], "Its recorded coverage reached none of this file's 3 executable lines")
        self.assertEqual(name_of(got[-1]), "test_none.py", "… and one that ran none of it last")
        self.assertIn("not established", by["test_plain.py"]["reason"], "a run with no coverage keeps its old reason")

    def agent(self, state, *extra):
        return self.data("agent-update", "--agent", "claude", "--session", "s1", "--pid", os.getpid(), "--state", state,
                         "--title", "Queue work", *extra)

    def test_a_turn_that_edited_files_is_one_event_with_its_files(self):
        self.agent("working")
        self.agent("working", "--file", "sample.cpp")
        (self.repo / "other.py").write_text("x = 1\n")
        self.agent("working", "--file", "other.py")
        self.agent("waiting")
        turns = [e for e in self.data("timeline") if e["kind"] == "turn"]
        self.assertEqual(len(turns), 1)
        self.assertEqual(sorted(turns[0]["files"]), ["other.py", "sample.cpp"])
        self.assertEqual((turns[0]["label"], turns[0]["session"], turns[0]["action"]["kind"]), ("Queue work · 2 files", "s1", "file-diff"))
        # A turn that only answered a question edits nothing and records nothing; nor does an idle session going idle.
        self.agent("working")
        self.agent("waiting")
        self.agent("waiting")
        self.assertEqual(len([e for e in self.data("timeline") if e["kind"] == "turn"]), 1)
        # The next turn lists only what it edited, not the files of the turn before.
        time.sleep(1.1)
        self.agent("working")
        self.agent("working", "--file", "other.py")
        self.agent("done")
        turns = [e for e in self.data("timeline") if e["kind"] == "turn"]
        self.assertEqual([t["files"] for t in turns][0], ["other.py"], "the newest turn, ended by the session ending")

    def test_since_lists_what_happened_after_the_reader_last_looked_and_marks_now(self):
        bench = "print(open('figure.txt').read())"
        for figure in ("p99 400ns", "p99 412ns"):
            (self.repo / "figure.txt").write_text(figure + "\n")
            self.execute(bench)
        self.execute("print('3 passed')")
        self.agent("working")
        self.agent("working", "--file", "sample.cpp")
        self.agent("waiting")
        time.sleep(1.1)
        first = self.data("since", "--mark", "yes")
        self.assertEqual(set(first), {"ok", "root", "from", "first", "since", "at", "items", "truncated"})
        self.assertTrue(first["first"], "a reader who never looked gets the last day")
        kinds = [i["kind"] for i in first["items"]]
        self.assertEqual(sorted(set(kinds)), ["commit", "job", "tests", "turn"])
        self.assertEqual([i["at"] for i in first["items"]], sorted([i["at"] for i in first["items"]], reverse=True), "newest first")
        commit = next(i for i in first["items"] if i["kind"] == "commit")
        self.assertEqual((commit["label"], commit["sha"]), ("initial", self.git("rev-parse", "HEAD")))
        tests = next(i for i in first["items"] if i["kind"] == "tests")
        self.assertEqual((tests["state"], tests["passed"], tests["failed"]), ("passed", 3, 0))
        jobs = [i for i in first["items"] if i["kind"] == "job"]
        self.assertEqual([[(m["name"], m["delta"], m["verdict"]) for m in j["metrics"]] for j in jobs], [[("p99", "+12", "worse")], []],
                         "the newer run says how its figures moved; the first had nothing to move from")
        turn = next(i for i in first["items"] if i["kind"] == "turn")
        self.assertEqual((turn["files"], turn["session"]), (["sample.cpp"], "s1"))
        # Opened: what came before is no longer new. Another reader keeps its own place.
        again = self.data("since")
        self.assertFalse(again["first"])
        self.assertEqual(again["items"], [])
        self.assertTrue(self.data("since", "--reader", "drawer")["first"])
        self.git("commit", "--allow-empty", "-qm", "later")
        self.assertEqual([i["label"] for i in self.data("since")["items"]], ["later"])
        # A read position the store cannot read is reported, never overwritten.
        seen = Path(self.env["XDG_STATE_HOME"]) / "foxml/work/projects" / hashlib.sha256(str(self.repo.resolve()).encode()).hexdigest() / "seen.json"
        seen.write_text("not json")
        self.assertIn("seen.json", json.loads(self.invoke("since", "--mark", "yes", code=1))["message"])
        self.assertEqual(seen.read_text(), "not json")
        self.assertEqual(json.loads(self.invoke("since", "--reader", "no spaces", code=1))["ok"], False)

    # ─── editors: Neovims on their own sockets, in this test's runtime folder only ─────────────────────────────────
    def stand_in(self):
        """A live process standing for an editor in the client records, which live as long as their process."""
        child = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.addCleanup(lambda: (child.kill(), child.wait()))
        return child

    def editor(self, *commands, files=(), env=None):
        """A headless Neovim on its own socket in this test's runtime folder (never the user's), with this repository's
        Lua and this build of desk-work. Returns the process and its socket."""
        runtime = Path(self.env["XDG_RUNTIME_DIR"])
        runtime.mkdir(mode=0o700, exist_ok=True)
        self.editors = getattr(self, "editors", 0) + 1
        sock = runtime / f"editor{self.editors}.sock"
        argv = ["nvim", "--headless", "--clean", "--listen", str(sock),
                "--cmd", "lua package.path = vim.env.DESK_LUA .. '/?.lua;' .. package.path"]
        for command in commands:
            argv += ["-c", command]
        child = subprocess.Popen(argv + ["--", *files], cwd=self.repo, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env=dict(self.env, DESK_LUA=str(NVIM_LUA), PATH=str(BIN.parent) + os.pathsep + self.env["PATH"],
                                          NVIM_LOG_FILE=str(self.dir / "nvim.log"), **(env or {})),
                                 start_new_session=True)
        self.addCleanup(self.end_editor, child)
        deadline = time.monotonic() + 15
        while not sock.exists():
            self.assertIsNone(child.poll(), "the test editor ended before it listened")
            self.assertLess(time.monotonic(), deadline, "the test editor did not listen")
            time.sleep(0.02)
        return child, sock

    def end_editor(self, child):
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=10)

    def remote(self, sock, lua):
        """A Lua expression's value in that editor, as text: another Neovim is the client."""
        expr = "luaeval('" + lua.replace("'", "''") + "')"
        p = subprocess.run(["nvim", "--clean", "--headless", "--server", str(sock), "--remote-expr", expr], env=self.env,
                           capture_output=True, text=True, timeout=30)
        return p.stdout.strip()

    def test_editors_lists_each_live_editor_of_a_checkout_with_its_socket_pane_and_role(self):
        main, viewer, stopped, elsewhere = (self.stand_in() for _ in range(4))
        other = self.dir / "other"
        other.mkdir()
        subprocess.run(["git", "init", "-q", str(other)], check=True, env=self.env)

        def report(child, root, *extra, code=0):
            return json.loads(self.invoke("client-report", "--client", "nvim", "--build", "b", "--pid", child.pid, "--root", root, *extra, code=code))
        report(main, self.repo, "--server", "/run/test/main.sock", "--pane", "%7", "--role", "main")
        report(viewer, self.repo, "--server", "/run/test/viewer.sock", "--pane", "", "--role", "viewer")
        report(stopped, self.repo, "--server", "/run/test/stopped.sock", "--role", "main", "--stream", "stopped")
        report(elsewhere, other, "--server", "/run/test/other.sock", "--role", "main")
        report(main, self.repo, "--stream", "connected")   # a later report without them keeps them
        self.assertEqual(sorted((e["server"], e["pane"], e["role"], e["pid"]) for e in self.data("editors")),
                         sorted([("/run/test/main.sock", "%7", "main", main.pid), ("/run/test/viewer.sock", "", "viewer", viewer.pid)]),
                         "a stopped editor closed its last file here; another checkout's editor is not listed")
        self.assertEqual([e["server"] for e in self.data("editors", "--root", other)], ["/run/test/other.sock"])
        main.kill(); main.wait()
        self.assertEqual([e["role"] for e in self.data("editors")], ["viewer"], "an editor that ended is gone")
        for flag, value in (("--role", "boss"), ("--pane", "7"), ("--server", "relative.sock"), ("--server", "/" + "x" * 120)):
            self.assertTrue(report(viewer, self.repo, flag, value, code=1)["message"], f"{flag} {value} is refused with a reason")

    @unittest.skipUnless(subprocess.run(["sh", "-c", "command -v nvim"], capture_output=True).returncode == 0, "needs Neovim")
    def test_a_neovim_registers_its_socket_pane_and_role_for_the_checkouts_it_follows(self):
        # desk.sync follows each loaded file's checkout; its watcher writes the record. Only a Neovim inside tmux names
        # its pane: one in a kitty of its own may have inherited it.
        _, in_tmux = self.editor("lua require('desk.sync').setup()", "edit sample.cpp", env={"TERM": "tmux-256color", "TMUX_PANE": "%123"})
        _, in_kitty = self.editor("lua require('desk.sync').setup()", "edit sample.cpp", env={"TERM": "xterm-kitty", "TMUX_PANE": "%123"})
        _, viewer = self.editor("lua require('desk.sync').setup()", files=["desk-work:log", "0123"], env={"TERM": "xterm-kitty"})
        deadline = time.monotonic() + 15
        while len(self.data("editors")) < 3 and time.monotonic() < deadline:
            time.sleep(0.1)
        found = {e["server"]: (e["pane"], e["role"]) for e in self.data("editors")}
        self.assertEqual(found, {str(in_tmux): ("%123", "main"), str(in_kitty): ("", "main"), str(viewer): ("", "viewer")})

    def ask(self, message, *args, code=0):
        """desk-work editor: one message on stdin, the editor's answer as JSON."""
        p = subprocess.run([str(BIN), "editor", *map(str, args), "--input", "-"], input=message if isinstance(message, str) else json.dumps(message),
                           cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return json.loads(p.stdout)

    def keys(self, sock, keys):
        subprocess.run(["nvim", "--clean", "--headless", "--server", str(sock), "--remote-send", keys], env=self.env, timeout=30, check=True)

    @unittest.skipUnless(subprocess.run(["sh", "-c", "command -v nvim"], capture_output=True).returncode == 0, "needs Neovim")
    def test_a_message_reaches_the_editor_through_the_bridge_and_its_answer_comes_back(self):
        (self.repo / "sample.cpp").write_text("int original = 1;\nint second = 2;\nint third = 3;\n")
        _, sock = self.editor("lua require('desk.bridge').setup()", "edit sample.cpp")
        pong = self.ask({"version": 1, "type": "ping"}, "--server", sock)
        self.assertEqual((pong["role"], pong["roots"], pong["mode"]), ("main", [str(self.repo.resolve())], "n"))
        self.assertGreater(pong["last_focus"], 0)
        seen = self.ask({"version": 1, "type": "view"}, "--server", sock)
        self.assertEqual((seen["file"], seen["root"]), (str((self.repo / "sample.cpp").resolve()), str(self.repo.resolve())))
        self.assertEqual((seen["cursor"], seen["visible"], seen["modified"], seen["diagnostics"]),
                         ({"line": 1, "col": 1}, {"first": 1, "last": 3}, False, []))
        self.assertIsInstance(seen["changedtick"], int)
        self.assertNotIn("selection", seen)
        self.keys(sock, "Vj")
        self.assertEqual(self.ask({"version": 1, "type": "view"}, "--server", sock)["selection"],
                         {"first": 1, "last": 2, "text": "int original = 1;\nint second = 2;", "truncated": False})
        self.keys(sock, "<Esc>")
        # Another checkout hears nothing about this one.
        other = self.dir / "other"
        other.mkdir()
        subprocess.run(["git", "init", "-q", str(other)], check=True, env=self.env)
        refused = self.ask({"version": 1, "type": "view"}, "--server", sock, "--root", other, code=1)
        self.assertEqual(refused, {"refused": "another project", "ok": False, "message": "another project"})
        # Refused by name: a type nobody registered, a field its type does not list; and an old version.
        self.assertIn('"edit"', self.ask({"version": 1, "type": "edit"}, "--server", sock, code=1)["message"])
        self.assertIn('"line"', self.ask({"version": 1, "type": "view", "line": 3}, "--server", sock, code=1)["message"])
        self.assertIn("version 1", self.ask({"version": 2, "type": "ping"}, "--server", sock, code=1)["message"])
        # desk-work's own limits come first: one object of at most 64 KiB, flat enough, for the checkout it was given.
        self.assertIn("64 KiB", self.ask({"version": 1, "type": "ping", "pad": "x" * 70000}, "--server", sock, code=1)["message"])
        self.assertIn("one JSON object", self.ask("[1, 2]", "--server", sock, code=1)["message"])
        self.assertIn("nested", self.ask({"version": 1, "type": "ping", "deep": [[[[[[[[[[1]]]]]]]]]]}, "--server", sock, code=1)["message"])
        self.assertIn("another checkout", self.ask({"version": 1, "type": "view", "root": str(other)}, "--server", sock, code=1)["message"])
        # No editor registered on the checkout: nothing to ask.
        self.assertIn("No Neovim", self.ask({"version": 1, "type": "ping"}, code=2)["message"])

    def test_an_editor_that_never_answers_costs_its_caller_one_second(self):
        runtime = Path(self.env["XDG_RUNTIME_DIR"])
        runtime.mkdir(mode=0o700, exist_ok=True)
        silent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(silent.close)
        silent.bind(str(runtime / "silent.sock"))
        silent.listen(4)   # takes the connection and the request, and never answers
        started = time.monotonic()
        answer = self.ask({"version": 1, "type": "ping"}, "--server", runtime / "silent.sock", code=2)
        took = time.monotonic() - started
        self.assertIn("did not answer within 1000 ms", answer["message"])
        self.assertTrue(0.9 <= took < 3, f"{took:.2f} s")
        # Nothing listening, or no socket at all: at once.
        silent.close()
        for target in (runtime / "silent.sock", self.repo / "sample.cpp", "relative.sock"):
            started = time.monotonic()
            self.assertFalse(self.ask({"version": 1, "type": "ping"}, "--server", target, code=2)["ok"])
            self.assertLess(time.monotonic() - started, 0.9)

    @unittest.skipUnless(subprocess.run(["sh", "-c", "command -v nvim"], capture_output=True).returncode == 0, "needs Neovim")
    def test_with_several_editors_on_a_checkout_the_one_focused_last_takes_the_message(self):
        (self.repo / "second.cpp").write_text("int second = 2;\n")
        first = self.editor("lua require('desk.bridge').setup()", "edit sample.cpp")
        second = self.editor("lua require('desk.bridge').setup()", "edit second.cpp")
        viewer = self.editor("lua require('desk.bridge').setup()", "edit sample.cpp")
        for (child, sock), role in ((first, "main"), (second, "main"), (viewer, "viewer")):
            self.data("client-report", "--client", "nvim", "--build", "b", "--pid", child.pid, "--root", self.repo, "--server", sock, "--role", role)
        focus = "vim.api.nvim_exec_autocmds('FocusGained', {}) or 'focused'"
        answered = lambda: Path(self.ask({"version": 1, "type": "view"})["file"]).name
        self.assertEqual(answered(), "second.cpp", "until either is focused, the one started last")
        self.assertEqual(self.remote(first[1], focus), "focused")
        self.assertEqual(answered(), "sample.cpp")
        self.remote(viewer[1], focus)
        self.assertEqual(answered(), "sample.cpp", "a viewer is never asked, however recently focused")
        self.remote(second[1], focus)
        self.assertEqual(answered(), "second.cpp")
        self.end_editor(second[0])
        self.assertEqual(answered(), "sample.cpp", "an editor that ended is not asked")

    @unittest.skipUnless(subprocess.run(["sh", "-c", "command -v nvim"], capture_output=True).returncode == 0, "needs Neovim")
    def test_editors_that_do_not_answer_are_waited_for_together_not_one_after_another(self):
        # Codex's review, 2026-11-18: each main editor got its own 300 ms ping in turn, so eight stuck ones held a
        # message back 2.4 s. Four sockets that take the connection and never answer, and one real editor.
        runtime = Path(self.env["XDG_RUNTIME_DIR"])
        runtime.mkdir(mode=0o700, exist_ok=True)
        live = self.editor("lua require('desk.bridge').setup()", "edit sample.cpp")
        self.data("client-report", "--client", "nvim", "--build", "b", "--pid", live[0].pid, "--root", self.repo, "--server", live[1], "--role", "main")
        for n in range(4):
            path = runtime / f"silent{n}.sock"
            silent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            silent.bind(str(path))
            silent.listen(8)
            self.addCleanup(silent.close)
            holder = subprocess.Popen(["sleep", "60"])
            self.addCleanup(holder.kill)
            self.data("client-report", "--client", "nvim", "--build", "b", "--pid", holder.pid, "--root", self.repo, "--server", path, "--role", "main")
        started = time.monotonic()
        answer = self.ask({"version": 1, "type": "view"})
        took = time.monotonic() - started
        self.assertEqual(Path(answer["file"]).name, "sample.cpp", "the editor that answers takes the message")
        self.assertLess(took, 0.9, f"four silent editors held the message back {took:.2f} s (one after another: 1.2 s and more)")

    @unittest.skipUnless(subprocess.run(["sh", "-c", "command -v nvim"], capture_output=True).returncode == 0, "needs Neovim")
    def test_open_goes_to_her_running_editor_in_a_new_tab_and_otherwise_to_a_window_of_its_own(self):
        with tempfile.TemporaryDirectory(prefix=".fox-work-editor-", dir=Path(__file__).parent) as temp:
            fake, calls = Path(temp), self.dir / "calls.jsonl"
            for name in ("kitty", "desk-drawer"):
                (fake / name).write_text("#!" + sys.executable + "\nimport json,os,sys\nwith open(os.environ['WORK_CALLS'], 'a') as f:\n"
                                         "    f.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + '\\n')\n")
                (fake / name).chmod(0o755)
            self.env.update(PATH=str(fake) + os.pathsep + self.env["PATH"], WORK_CALLS=str(calls))

            def called():
                seen = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
                calls.unlink(missing_ok=True)
                return seen
            second = self.repo / "second.cpp"
            second.write_text("int second = 2;\n")
            child, sock = self.editor("lua require('desk.bridge').setup()", "edit sample.cpp")
            self.data("client-report", "--client", "nvim", "--build", "b", "--pid", child.pid, "--root", self.repo,
                      "--server", sock, "--pane", "%77", "--role", "main")
            shown = ("vim.json.encode({ tabs = #vim.api.nvim_list_tabpages(), front = vim.fn.expand('%:t'), viewer = vim.g.desk_work_view == true,"
                     " first = vim.fn.fnamemodify(vim.fn.bufname(vim.fn.tabpagebuflist(1)[1]), ':t') })")
            # The bridge caps each field: an oversized one is refused by name, over the socket too.
            self.assertIn('"id" is limited to 4096', self.ask({"version": 1, "type": "open", "action": "file", "id": "/" + "x" * 5000}, code=1)["message"])

            self.invoke("open", "--action", "file", "--file", "second.cpp")
            self.assertEqual(called(), [["desk-drawer", "run", "work-jump", "%77"]], "no window of its own; her pane comes forward")
            deadline = time.monotonic() + 10
            while json.loads(self.remote(sock, shown))["tabs"] < 2 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(json.loads(self.remote(sock, shown)), {"tabs": 2, "front": "second.cpp", "viewer": False, "first": "sample.cpp"})

            # She is typing there: refused, so it opens in a window of its own as before, and nothing changes there.
            self.keys(sock, "i")
            self.invoke("open", "--action", "file", "--file", "second.cpp")
            window = called()
            self.assertEqual([c[0] for c in window], ["kitty"])
            self.assertEqual(window[0][-3:], ["desk-work:file", str(second.resolve()), ""])
            self.keys(sock, "<Esc>")
            self.assertEqual(json.loads(self.remote(sock, shown))["tabs"], 2)

            # The editor ended: its record went with it.
            self.end_editor(child)
            self.invoke("open", "--action", "file", "--file", "second.cpp")
            self.assertEqual([c[0] for c in called()], ["kitty"])


if __name__ == "__main__":
    unittest.main()
