"""Work health's toolchain card: a contract-test record (fox-contract/1) that symdeps' runner writes, read where it
writes it, against the checkouts it names (real Git repositories in disposable homes). Viewing runs no test."""
import json
import os
import unittest

from test_tools import FIXTURES, ToolsCase


class Toolchain(ToolsCase):
    def test_with_nothing_declared_the_card_says_so(self):
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · none declared")
        self.assertIn("fox-contract/1", card["detail"])
        self.assertEqual(alerts, [])

    def test_the_card_shows_a_passing_run_what_it_ran_against_and_its_log(self):
        self.contract()
        record = self.write_record()
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed")
        lines = card["detail"].split("\n")
        self.assertTrue(lines[0].startswith("Passed 2026-11-16 06:54:58, ") and lines[0].endswith("· 12 passed · 0 failed · 0 skipped · 12 expected"), lines[0])
        self.assertEqual(lines[1], "12 passed, 0 failed")
        end = record["inputs"]["end"]
        self.assertIn(f"Ran against: plugin {end['plugin']['commit'][:8]} · workspace 1.2.0 {end['workspace']['head'][:8]}, "
                      f"tools tree {end['workspace']['tools_tree'][:8]} · engine {end['engine']['head'][:8]}", lines)
        self.assertIn(f"workspace tools unchanged since the run (tree {end['workspace']['tools_tree'][:8]}, nothing uncommitted)", lines)
        self.assertIn("Not compared: plugin, engine, gitignored files and the machine's tools", lines)
        self.assertIn(f"Log: {self.log}", lines)
        self.assertEqual(card["log"], str(self.log))
        self.assertEqual(alerts, [])
        result = self.data("tools", "result", "contract", "--root", self.plugin)
        self.assertEqual((result["state"], result["at"], [f["name"] for f in result["facts"]]),
                         ("ok", 1794812098, ["passed", "failed", "skipped", "expected"]))
        # The same record declared for another checkout too (a worktree of the project) is still one result.
        second = self.declare_private("worktree.json", {"version": 1, "root": str(self.repo), "tools": [
            {"id": "contract", "gives": "status", "format": "fox-contract/1", "reads": str(self.record)}]})
        card, _ = self.card()
        self.assertIn(str(second), card["detail"])
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed", "named as the tool's own declaration names it")

    def test_the_card_goes_stale_when_tools_are_committed_or_their_uncommitted_files_change(self):
        self.contract()
        tree = self.write_record()["inputs"]["end"]["workspace"]["tools_tree"]
        (self.ws / "plans/a.md").write_text("edited outside tools/\n")
        card, _ = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed", "only the tools folder counts")
        (self.ws / "tools/new.py").write_text("x = 1\n")
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed · STALE")
        self.assertIn("STALE: uncommitted files in workspace tools changed since the run: 1 new (tools/new.py)", card["detail"].split("\n"))
        self.assertIn("symdeps contract tests: stale, what it tested changed since the run", alerts)
        self.git(self.ws, "add", "tools/new.py")
        self.git(self.ws, "commit", "-qm", "a new tool")
        now = self.git(self.ws, "rev-parse", "HEAD:tools")
        card, _ = self.card()
        self.assertIn(f"STALE: tools committed since the run (workspace tools tree {tree[:8]} → {now[:8]})", card["detail"].split("\n"))

    def test_a_commit_after_the_run_is_stale_even_when_the_record_names_none_of_its_uncommitted_files(self):
        self.contract()
        def dirty_without_a_list(record):
            record["inputs"]["end"]["workspace"]["tools_dirty"] = True
            del record["inputs"]["end"]["workspace"]["tools_uncommitted"]
        tree = self.write_record(dirty_without_a_list)["inputs"]["end"]["workspace"]["tools_tree"]
        (self.ws / "tools/new.py").write_text("x = 1\n")
        self.git(self.ws, "add", "tools/new.py")
        self.git(self.ws, "commit", "-qm", "a new tool")
        now = self.git(self.ws, "rev-parse", "HEAD:tools")
        (self.ws / "tools/run.py").write_text("print(5)\n")   # and a file still uncommitted
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed · STALE", card["detail"])
        self.assertIn(f"STALE: tools committed since the run (workspace tools tree {tree[:8]} → {now[:8]})", card["detail"].split("\n"))
        self.assertIn("symdeps contract tests: stale, what it tested changed since the run", alerts)

    def test_a_path_git_quotes_is_read_as_the_file_it_names(self):
        # git status --porcelain (core.quotePath, the default) writes a non-ASCII name in C escapes.
        self.contract()
        ended = json.loads((FIXTURES / "fox-contract.json").read_text())["ended_epoch"]
        name = "tools/café.py"
        (self.ws / name).write_text("print(1)\n")
        os.utime(self.ws / name, (ended - 60, ended - 60))
        listed = self.git(self.ws, "status", "--porcelain", "--", "tools/")
        self.assertEqual(listed, '?? "tools/caf\\303\\251.py"')
        self.write_record(lambda r: r["inputs"]["end"]["workspace"].update(tools_dirty=True, tools_uncommitted=[listed]))
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed with 1 uncommitted file", card["detail"])
        self.assertIn(f"Ran with 1 uncommitted file in workspace tools: {name}", card["detail"].split("\n"))
        self.assertEqual(alerts, [])

    def test_a_cache_git_ignores_in_a_new_folder_is_no_change_but_a_new_file_there_is(self):
        self.contract()
        ended = json.loads((FIXTURES / "fox-contract.json").read_text())["ended_epoch"]
        (self.ws / ".gitignore").write_text("__pycache__/\n")
        self.git(self.ws, "add", ".gitignore")
        self.git(self.ws, "commit", "-qm", "caches are ignored")
        folder = self.ws / "tools/newdir"
        folder.mkdir()
        (folder / "a.py").write_text("x = 1\n")
        for path in (folder / "a.py", folder):
            os.utime(path, (ended - 60, ended - 60))   # as they were when the run ended
        self.write_record(lambda r: r["inputs"]["end"]["workspace"].update(tools_dirty=True, tools_uncommitted=["?? tools/newdir/"]))
        unchanged = "workspace tools unchanged since the run"
        self.assertTrue(any(line.startswith(unchanged) for line in self.card()[0]["detail"].split("\n")))
        (folder / "__pycache__").mkdir()   # an import after the run
        (folder / "__pycache__/a.cpython-314.pyc").write_bytes(b"\0")
        card, alerts = self.card()
        self.assertNotIn("STALE", card["label"], card["detail"])
        self.assertTrue(any(line.startswith(unchanged) for line in card["detail"].split("\n")), card["detail"])
        self.assertEqual(alerts, [])
        (folder / "b.py").write_text("y = 2\n")
        card, _ = self.card()
        self.assertIn("STALE: uncommitted files in workspace tools changed since the run: edited after it ended: tools/newdir/",
                      card["detail"].split("\n"))

    def test_a_pass_on_uncommitted_tool_files_says_so_nested_repos_are_not_counted_and_a_later_edit_is_stale(self):
        self.contract()
        ended = json.loads((FIXTURES / "fox-contract.json").read_text())["ended_epoch"]
        self.checkout("ws/tools/plugins/inner", {"x.lua": "return 2\n"})   # a nested repository kept inside tools/
        (self.ws / "tools/run.py").write_text("print(2)\n")
        (self.ws / "tools/notes.log").write_text("n\n")
        for rel in ("tools/run.py", "tools/notes.log"):
            os.utime(self.ws / rel, (ended - 60, ended - 60))   # as they were when the run ended
        tree = self.git(self.ws, "rev-parse", "HEAD:tools")
        def dirty(entries):
            return lambda record: record["inputs"]["end"]["workspace"].update(tools_dirty=True, tools_uncommitted=entries)
        for entries in (["tools/notes.log", "tools/plugins/inner/", "tools/run.py"], ["?? tools/notes.log", "?? tools/plugins/inner/", " M tools/run.py"]):
            self.write_record(dirty(entries))
            card, alerts = self.card()
            self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed with 2 uncommitted files", entries)
            lines = card["detail"].split("\n")
            self.assertIn("Ran with 2 uncommitted files in workspace tools: tools/notes.log, tools/run.py (1 nested repository not counted)", lines)
            self.assertIn(f"workspace tools unchanged since the run (tree {tree[:8]}; the same 2 uncommitted files, none edited since it ended)", lines)
            self.assertIn(f"tools tree {tree[:8]} + 2 uncommitted files", card["detail"])
            self.assertEqual(alerts, [])
        (self.ws / "tools/run.py").write_text("print(3)\n")
        card, alerts = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · passed with 2 uncommitted files · STALE")
        self.assertIn("STALE: uncommitted files in workspace tools changed since the run: edited after it ended: tools/run.py", card["detail"].split("\n"))
        self.git(self.ws, "checkout", "--", "tools/run.py")
        card, _ = self.card()
        self.assertIn("STALE: uncommitted files in workspace tools changed since the run: 1 no longer uncommitted (tools/run.py)", card["detail"].split("\n"))

    def test_failed_partial_refused_and_moved_runs_say_so_and_a_skip_is_never_a_pass(self):
        self.contract()
        cases = [
            (lambda r: r["result"].update(state="fail", passed=10, failed=2, failed_tests=["test_alpha", "test_bravo"]),
             "failed", "Failed: test_alpha, test_bravo"),
            (lambda r: r["result"].update(state="partial", passed=11, skipped=1, skipped_tests=["test_charlie"]),
             "partial", "Skipped: test_charlie"),
            (lambda r: r["result"].update(skipped=1, skipped_tests=["test_charlie"]), "partial", "Skipped: test_charlie"),
            (lambda r: r.update(missing=["test_lima"]), "partial", "Did not run: test_lima"),
            (lambda r: r["result"].update(state="refused", why="unknown test name test_zulu"), "refused", "refused: unknown test name test_zulu"),
            (lambda r: r.update(moved=["workspace.head"]), "passed · unverified", "Inputs changed during the run: workspace.head"),
            (lambda r: r["inputs"]["end"]["engine"].update(root=None, why="no engine checkout found"), "passed", "engine: no engine checkout found"),
        ]
        for change, word, line in cases:
            self.write_record(change)
            card, alerts = self.card()
            self.assertEqual(card["label"], "Contract tests · symdeps contract tests · " + word, line)
            self.assertIn(line, card["detail"].split("\n"))
            if word != "passed":
                self.assertTrue(any(a.startswith("symdeps contract tests: ") for a in alerts), (word, alerts))
        self.record.write_text("{")
        self.assertEqual(self.card()[0]["label"], "Contract tests · symdeps contract tests · unreadable")
        self.record.unlink()
        card, _ = self.card()
        self.assertEqual(card["label"], "Contract tests · symdeps contract tests · not recorded yet")
        self.assertIn(f"nothing at {self.record} yet", card["detail"])

    def test_a_pass_the_records_own_counts_contradict_is_no_pass_and_says_why(self):
        self.contract()
        cases = [
            (lambda r: r["result"].update(passed=3, failed=2, expected=5, failed_tests=["test_x", "test_y"]),
             "failed", "Inconsistent: the record says pass, but it lists 2 failed tests"),
            (lambda r: r["result"].update(failed_tests=["test_x"]), "failed", "Inconsistent: the record says pass, but it lists 1 failed test"),
            (lambda r: r["result"].update(passed=10), "partial",
             "Inconsistent: the record says pass, but it accounts for 10 of the 12 tests it expected"),
        ]
        for change, word, line in cases:
            self.write_record(change)
            card, alerts = self.card()
            self.assertEqual(card["label"], "Contract tests · symdeps contract tests · " + word, card["detail"])
            self.assertIn(line, card["detail"].split("\n"))
            self.assertIn("symdeps contract tests: " + word, alerts)
        result = self.data("tools", "result", "contract", "--root", self.plugin)
        self.assertEqual((result["state"], [(f["kind"], f["severity"]) for f in result["findings"]]), ("warn", [("inconsistent", "warn")]))


if __name__ == "__main__":
    unittest.main()
