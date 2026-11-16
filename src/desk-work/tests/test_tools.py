"""Declared tools (.desk/tools.json and desk.d): the declarations, running them, and their answers as desk-result/1.

Real Git repositories in disposable homes. Nothing a declaration names runs unless a test answers the yes at a terminal
of its own (a pty), the way her keypress runs it. ToolsCase holds the helpers test_toolchain.py shares."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parents[1] / "desk-work"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tests"))
import sealed_env  # noqa: E402


class ToolsCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name).resolve()
        self.config = self.dir / "config"
        # Sealed from the session (tests/sealed_env.py).
        self.env = sealed_env.environment(self.dir, CLAUDECODE=None, HOME=self.dir / "home", XDG_STATE_HOME=self.dir / "state",
                                          XDG_CONFIG_HOME=self.config, XDG_RUNTIME_DIR=self.dir / "runtime", FOXML_WORK_NOTIFY="0",
                                          PYTHONDONTWRITEBYTECODE="1", TZ="UTC")
        self.addCleanup(sealed_env.stop, self.env)
        self.repo = self.checkout("project", {"sample.cpp": "int x = 1;\n"})
        self.marker = self.dir / "ran"

    # ---- helpers

    def git(self, where, *args):
        return subprocess.run(["git", "-C", str(where), *args], env=self.env, capture_output=True, text=True, check=True).stdout.strip()

    def checkout(self, name, files):
        where = self.dir / name
        where.mkdir(parents=True)
        self.git(where, "init", "-q")
        self.git(where, "config", "user.name", "Test")
        self.git(where, "config", "user.email", "test@example.invalid")
        for rel, text in files.items():
            (where / rel).parent.mkdir(parents=True, exist_ok=True)
            (where / rel).write_text(text)
        self.git(where, "add", ".")
        self.git(where, "commit", "-qm", "initial")
        return where

    def invoke(self, *args, code=0, env=None):
        p = subprocess.run([str(BIN), *map(str, args)], cwd=self.repo, env=env or self.env, capture_output=True, text=True,
                           timeout=60, stdin=subprocess.DEVNULL)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return p.stdout

    def data(self, *args, code=0):
        return json.loads(self.invoke(*args, code=code))

    def register(self):
        """Work health reads .desk/tools.json in the checkouts desk-work keeps records of: a recorded job makes this one."""
        self.invoke("run", "--", "true")

    def declare(self, tools):
        (self.repo / ".desk").mkdir(exist_ok=True)
        (self.repo / ".desk/tools.json").write_text(json.dumps({"version": 1, "tools": tools}))
        return self.repo / ".desk/tools.json"

    def declare_private(self, name, doc):
        folder = self.config / "foxml/desk.d"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(doc if isinstance(doc, str) else json.dumps(doc))
        return folder / name

    def at_terminal(self, *args, answer=None, env=None):
        """desk-work on a terminal of its own, as her keypress runs it. Answers the yes question (with `answer`, or an
        empty line) if it is asked. Returns the exit status, what it printed, and whether it asked."""
        master, slave = pty.openpty()
        p = subprocess.Popen([str(BIN), *map(str, args)], cwd=self.repo, env=env or self.env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        out, asked, deadline = b"", False, time.time() + 60
        try:
            while True:
                if time.time() > deadline:
                    p.kill()
                    self.fail("desk-work did not finish: " + out.decode(errors="replace"))
                ready, _, _ = select.select([master], [], [], 0.2)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    out += chunk
                    if not asked and b"[y/N]" in out:
                        asked = True
                        os.write(master, ((answer or "") + "\n").encode())
                elif p.poll() is not None:
                    break
        finally:
            os.close(master)
        return p.wait(timeout=10), out.decode(errors="replace").replace("\r\n", "\n"), asked

    def answer(self, fmt, gives, text):
        """What desk-work makes of a tool's answer: a file the tool wrote, declared with `reads` (nothing runs)."""
        path = self.dir / "answer.out"
        path.write_text(text)
        self.declare([{"id": "t", "gives": gives, "format": fmt, "reads": str(path)}])
        return self.data("tools", "result", "t")

    def record_text(self, values):
        """The fixture record (the runner's own shape) with its placeholders filled in."""
        text = (FIXTURES / "fox-contract.json").read_text()
        for key, value in values.items():
            text = text.replace(key, str(value))
        return json.loads(text)

    def contract(self):
        """The three checkouts a contract run reads, and symdeps' own declaration of its record (the desk.d form)."""
        self.plugin = self.checkout("plugin", {"lua/x.lua": "return 1\n"})
        self.ws = self.checkout("ws", {"tools/run.py": "print(1)\n", "tools/plugins/README": "kept here\n", "plans/a.md": "a\n"})
        self.engine = self.checkout("engine", {"main.cpp": "int main() {}\n"})
        self.record = self.plugin / ".git/fox-contract.json"
        self.log = self.plugin / ".git/fox-contract.log"
        self.declare_private("fox-symdeps.json", {"version": 1, "written_by": "fox-symdeps", "root": str(self.plugin), "tools": [
            {"id": "contract", "name": "symdeps contract tests", "gives": "status", "reads": str(self.record), "format": "fox-contract/1"}]})

    def write_record(self, change=None):
        """The fixture record, filled in with these checkouts as they are now, and written where the runner writes it."""
        record = self.record_text({"@PLUGIN@": self.plugin, "@PLUGIN_COMMIT@": self.git(self.plugin, "rev-parse", "HEAD"),
                                   "@WORKSPACE@": self.ws, "@WORKSPACE_HEAD@": self.git(self.ws, "rev-parse", "HEAD"),
                                   "@TOOLS_TREE@": self.git(self.ws, "rev-parse", "HEAD:tools"), "@ENGINE@": self.engine,
                                   "@ENGINE_HEAD@": self.git(self.engine, "rev-parse", "HEAD"), "@LOG@": self.log})
        if change:
            change(record)
        self.record.write_text(json.dumps(record))
        return record

    def card(self):
        health = self.data("health")
        cards = [c for c in health["checks"] if c["label"].startswith("Contract tests")]
        self.assertEqual(len(cards), 1, cards)
        return cards[0], health["alerts"]


class Tools(ToolsCase):
    # ---- declarations

    def test_one_format_in_two_places_and_a_desk_d_file_is_for_the_checkout_it_names(self):
        project = self.declare([{"id": "lint", "gives": "findings", "format": "lines", "argv": ["true"], "colour": "ignored"}])
        private = self.declare_private("mine.json", {"version": 1, "written_by": "someone", "root": str(self.repo),
                                                     "tools": [{"id": "dag", "gives": "graph", "format": "dot", "reads": str(self.dir / "g.dot")}]})
        other = self.checkout("other", {"a.txt": "a\n"})
        self.declare_private("other.json", {"version": 1, "root": str(other),
                                            "tools": [{"id": "elsewhere", "gives": "status", "format": "json", "argv": ["true"]}]})
        tools = {t["id"]: t for t in self.data("tools", "list")["tools"]}
        self.assertEqual(set(tools), {"lint", "dag"}, "a desk.d file's tools are for the checkout its root names")
        self.assertEqual((tools["lint"]["file"], tools["dag"]["file"]), (str(project), str(private)))
        self.assertEqual(tools["dag"]["written_by"], "someone")
        self.assertNotIn("refused", tools["lint"], "a field desk-work does not read is ignored")
        self.assertEqual([t["id"] for t in self.data("tools", "list", "--root", other)["tools"]], ["elsewhere"])

    def test_a_tool_declared_twice_is_refused_in_both_places_naming_each(self):
        project = self.declare([{"id": "dag", "gives": "graph", "format": "json", "argv": ["touch", str(self.marker)]}])
        private = self.declare_private("dup.json", {"version": 1, "root": str(self.repo),
                                                    "tools": [{"id": "dag", "gives": "graph", "format": "dot", "reads": str(self.dir / "g.dot")}]})
        expected = f"declared twice: {project} and {private}"
        self.assertEqual([t.get("refused") for t in self.data("tools", "list")["tools"]], [expected, expected], "never one picked silently")
        self.assertIn(expected, self.data("tools", "result", "dag", code=1)["message"])
        code, out, asked = self.at_terminal("tools", "run", "dag", answer="y")
        self.assertEqual((code, asked), (1, False), out)
        self.assertFalse(self.marker.exists())
        self.register()
        problems = [c for c in self.data("health")["checks"] if c["label"].startswith("Tool declarations")]
        self.assertEqual(len(problems), 1)
        self.assertIn(expected, problems[0]["detail"])
        self.declare([{"id": "x", "gives": "status", "format": "json", "argv": ["true"]}, {"id": "x", "gives": "status", "format": "json", "argv": ["false"]}])
        self.declare_private("dup.json", {"version": 1, "root": str(self.repo), "tools": []})
        self.assertEqual({t["refused"] for t in self.data("tools", "list")["tools"]},
                         {f"declared twice: {project} (tool 1) and {project} (tool 2)"})

    def test_a_declaration_desk_work_cannot_use_says_why(self):
        broken = {"version-2": ({"version": 2, "tools": []}, "version 2: this desk-work reads version 1"),
                  "no-root": ({"version": 1, "tools": []}, "names the checkout its tools are for (root)"),
                  "relative-root": ({"version": 1, "root": "project", "tools": []}, "is not an absolute path"),
                  "not-json": ("{", "not valid JSON")}
        for name, (doc, _) in broken.items():
            self.declare_private(name + ".json", doc)
        entries = [({"id": "a", "gives": "pictures", "format": "json", "argv": ["true"]}, "gives must be graph, findings, figures or status"),
                   ({"id": "b", "gives": "status", "format": "dot", "argv": ["true"]}, "dot does not give status"),
                   ({"id": "c", "gives": "status", "format": "json", "argv": "true"}, "argv must be a list"),
                   ({"id": "d", "gives": "status", "format": "json", "reads": "relative.json"}, "reads must be the absolute path"),
                   ({"id": "e", "gives": "status", "format": "json"}, "neither argv nor reads"),
                   ({"id": "bad id!", "gives": "status", "format": "json", "argv": ["true"]}, "is not 1 to 48"),
                   ({"id": "f", "gives": "status", "format": "yaml", "argv": ["true"]}, "format must be"),
                   ({"id": "g", "gives": "status", "format": "json", "argv": ["true"], "when": "hourly"}, "when must be ask, save or run"),
                   ({"id": "g2", "gives": "status", "format": "json", "argv": ["true"], "when": 5}, "when must be ask, save or run"),
                   ({"id": "h", "gives": "status", "format": "json", "argv": ["true"], "timeout_ms": 5}, "timeout_ms must be")]
        self.declare([entry for entry, _ in entries])
        listing = self.data("tools", "list")
        files = {Path(f["file"]).stem: f for f in listing["files"]}
        for name, (_, why) in broken.items():
            self.assertFalse(files[name]["ok"])
            self.assertIn(why, files[name]["message"])
        for (entry, why), tool in zip(entries, listing["tools"]):
            self.assertIn(why, tool.get("refused", ""), entry)
        self.register()
        health = self.data("health")
        self.assertIn("Tool declarations · 14 refused", [c["label"] for c in health["checks"]])
        self.assertIn("Tool declarations: 14 refused", health["alerts"])

    # ---- viewing and running

    def test_viewing_runs_nothing_a_declaration_names(self):
        status = self.dir / "status.json"
        status.write_text(json.dumps({"state": "ok", "text": "fine"}))
        self.declare([{"id": "st", "gives": "status", "format": "json", "argv": ["touch", str(self.marker)], "reads": str(status)},
                      {"id": "contract", "gives": "status", "format": "fox-contract/1", "argv": ["touch", str(self.marker)],
                       "reads": str(self.dir / "absent.json")}])
        self.register()
        self.assertEqual(self.data("tools", "result", "st")["state"], "ok")
        self.data("tools", "list")
        self.data("tools", "show", "st")
        self.data("tools", "result", "contract", code=1)
        self.data("health")
        self.data("notebook", "--health", "yes")
        self.assertIn("keypress", self.data("tools", "run", "st", code=1)["message"])
        self.assertFalse(self.marker.exists(), "listing, showing, reading, health and an agent's run start nothing")

    def test_a_run_waits_for_her_yes_at_a_terminal_and_a_changed_entry_asks_again(self):
        def entry(word):
            return {"id": "mark", "gives": "status", "format": "lines", "argv": ["sh", "-c", f"echo {word} >> '{self.marker}'; echo ok all good"]}
        self.declare([entry("ran")])
        self.assertIn("desk-work tools result mark", self.data("tools", "run", "mark", code=1)["message"])
        code, out, asked = self.at_terminal("tools", "run", "mark", answer="y", env=dict(self.env, CLAUDECODE="1"))
        self.assertEqual((code, asked), (1, False), out)
        self.assertFalse(self.marker.exists(), "no terminal, or Claude Code's own shell: nothing runs")
        code, out, asked = self.at_terminal("tools", "run", "mark", answer="n")
        self.assertTrue(asked)
        self.assertIn("Not run.", out)
        self.assertFalse(self.marker.exists())
        code, out, asked = self.at_terminal("tools", "run", "mark", answer="y")
        self.assertEqual((code, asked), (0, True), out)
        self.assertIn("echo ran", out, "the question shows the exact command")
        self.assertEqual(self.marker.read_text(), "ran\n")
        code, out, asked = self.at_terminal("tools", "run", "mark")
        self.assertEqual((code, asked), (0, False), "the same entry runs again without asking")
        self.declare([entry("changed")])
        code, out, asked = self.at_terminal("tools", "run", "mark", answer="n")
        self.assertTrue(asked, "a changed command asks again")
        self.assertEqual(self.marker.read_text(), "ran\nran\n")
        result = self.data("tools", "result", "mark")
        self.assertEqual((result["format"], result["state"], result["summary"]), ("desk-result/1", "ok", "all good"))
        runs = [j for j in self.data("jobs") if j.get("kind") == "tool"]
        self.assertEqual([(j["state"], j["testRun"], j["tool"]["id"]) for j in runs], [("passed", False, "mark")] * 2)

    def test_a_program_that_is_not_installed_says_requires_and_nothing_runs(self):
        self.declare([{"id": "graph", "gives": "graph", "format": "dot", "argv": ["no-such-program-for-desk-work", "-t", "graph"]},
                      {"id": "local", "gives": "status", "format": "lines", "argv": ["tools/missing.sh"]},
                      {"id": "here", "gives": "status", "format": "lines", "argv": ["sh", "-c", "echo ok"]}])
        tools = {t["id"]: t for t in self.data("tools", "list")["tools"]}
        self.assertEqual((tools["graph"].get("requires"), tools["local"].get("requires"), tools["here"].get("requires")),
                         ("no-such-program-for-desk-work", "tools/missing.sh", None))
        self.assertEqual(self.data("tools", "show", "local")["requires"], "tools/missing.sh")
        code, out, asked = self.at_terminal("tools", "run", "graph", answer="y")
        self.assertEqual((code, asked), (1, False), out)
        self.assertIn("graph requires no-such-program-for-desk-work", out)
        self.assertEqual([j for j in self.data("jobs") if j.get("kind") == "tool"], [], "nothing ran, so no run was recorded")

    def test_lines_read_everything_a_run_printed_since_compilers_warn_on_stderr(self):
        (self.repo / "compile.py").write_text("import sys\nprint('compiling sample.cpp')\n"
                                              "print('sample.cpp:1:5: warning: x is unused', file=sys.stderr)\n")
        self.declare([{"id": "cc", "gives": "findings", "format": "lines", "argv": [sys.executable, "compile.py"]}])
        self.assertEqual(self.at_terminal("tools", "run", "cc", answer="y")[0], 0)
        found = self.data("tools", "result", "cc")["findings"]
        self.assertEqual([(f["file"], f["line"], f["col"], f["severity"], f["message"]) for f in found],
                         [("sample.cpp", 1, 5, "warn", "x is unused")])

    def test_an_unreadable_approval_record_refuses_the_yes_and_shows_in_health(self):
        self.declare([{"id": "mark", "gives": "status", "format": "lines", "argv": ["touch", str(self.marker)]}])
        self.register()
        project = next((Path(self.env["XDG_STATE_HOME"]) / "foxml/work/projects").glob("*"))
        (project / "tool-approvals.json").write_text("{")
        code, out, _ = self.at_terminal("tools", "run", "mark", answer="y")
        self.assertEqual(code, 1, out)
        self.assertIn("tool approvals record (tool-approvals.json) cannot be read", out)
        self.assertFalse(self.marker.exists())
        self.assertTrue(any("tool approvals record cannot be read" in a for a in self.data("health")["alerts"]))

    def test_a_runs_answer_is_its_stdout_alone_and_toolio_exit_1_is_an_answer(self):
        envelope = {"envelope_version": "1.0", "kind": "findings", "producer": {"tool": "lint", "version": "1.2", "command": "lint ."},
                    "status": {"ok": False, "code": 1, "findings": [["sample.cpp", 1, "error", "x is unused", "unused"]]},
                    "target": {"paths": ["."], "git_head": "abc123"}, "payload": {}}
        (self.repo / "lint_tool.py").write_text("import json, sys\nprint('warning: noisy', file=sys.stderr, flush=True)\n"
                                                f"print(json.dumps({envelope!r}))\nprint('3 passed', file=sys.stderr)\nsys.exit(1)\n")
        self.declare([{"id": "lint", "gives": "findings", "format": "toolio", "argv": [sys.executable, "lint_tool.py"]}])
        code, out, _ = self.at_terminal("tools", "run", "lint", answer="y")
        self.assertEqual(code, 1, out)
        result = self.data("tools", "result", "lint")
        self.assertEqual([(f["file"], f["line"], f["severity"], f["kind"], f["message"]) for f in result["findings"]],
                         [("sample.cpp", 1, "error", "unused", "x is unused")])
        self.assertEqual(result["source"]["producer"]["tool"], "lint")
        job = next(j for j in self.data("jobs") if j.get("kind") == "tool")
        self.assertEqual((job["state"], job["testRun"]), ("passed", False), "toolio's 1 answers with findings; a tool run is no test run")
        self.assertIn("warning: noisy", self.invoke("log", "--id", job["id"]), "stderr still goes to the job's log")

    def test_a_figures_tool_run_is_set_against_its_previous_run(self):
        value = self.dir / "value"
        (self.repo / "bench.py").write_text("import json, sys\nn = int(open(sys.argv[1]).read())\n"
                                            "print(json.dumps([{'name': 'p99', 'value': n, 'unit': 'ns'}, {'name': 'odd', 'value': 1, 'unit': 'widgets'}]))\n")
        self.declare([{"id": "bench", "gives": "figures", "format": "json", "argv": [sys.executable, "bench.py", str(value)]}])
        value.write_text("400")
        self.assertEqual(self.at_terminal("tools", "run", "bench", answer="y")[0], 0)
        value.write_text("450")
        self.assertEqual(self.at_terminal("tools", "run", "bench")[0], 0)
        metrics = self.data("metrics")["metrics"]
        self.assertEqual([(m["name"], m["value"], round(m["previous"], 6), m["verdict"]) for m in metrics], [("p99", 450, 400, "worse")],
                         "a unit desk-work cannot compare is not set against a run")
        self.assertEqual(len(self.data("tools", "result", "bench")["facts"]), 2, "the answer itself keeps every figure")

    # ---- the converter: every format into desk-result/1

    def test_the_json_shapes_become_desk_result(self):
        graph = self.answer("json", "graph", json.dumps({"version": 1, "nodes": [
            {"id": "a", "label": "main", "file": str(self.repo / "sample.cpp"), "line": 3, "kind": "function", "extra": 1},
            {"id": "b"}, {"id": "a", "label": "again"}], "edges": [{"from": "a", "to": "b", "kind": "calls"}, {"to": "b"}], "complete": True}))
        self.assertEqual((graph["format"], graph["gives"], graph["complete"]), ("desk-result/1", "graph", True))
        self.assertEqual(graph["graph"]["nodes"], [{"id": "a", "label": "main", "file": "sample.cpp", "line": 3, "kind": "function"},
                                                   {"id": "b", "label": "b", "file": None, "line": None, "kind": None}])
        self.assertEqual(graph["graph"]["edges"], [{"from": "a", "to": "b", "kind": "calls"}])
        self.assertIsNone(self.answer("json", "graph", json.dumps({"nodes": [], "edges": []}))["complete"],
                          "a graph that does not say it is whole is unknown, not whole")
        findings = self.answer("json", "findings", json.dumps([{"file": "sample.cpp", "line": 2, "severity": "warning", "message": "m"},
                                                               {"message": "nowhere"}]))
        self.assertEqual([(f["file"], f["line"], f["severity"], f["message"]) for f in findings["findings"]],
                         [("sample.cpp", 2, "warn", "m"), (None, None, None, "nowhere")])
        figures = self.answer("json", "figures", json.dumps([{"name": "p99", "value": 412, "unit": "ns"}, {"name": "count", "value": 3}]))
        self.assertEqual(figures["facts"], [{"name": "p99", "value": 412, "unit": "ns"}, {"name": "count", "value": 3, "unit": ""}])
        status = self.answer("json", "status", json.dumps({"state": "warn", "text": "w" * 60}))
        self.assertEqual((status["state"], len(status["summary"].encode())), ("warn", 43), "40 characters and an ellipsis")
        self.assertEqual(self.answer("json", "status", json.dumps({"state": "great"}))["state"], "unknown")
        bad = self.answer("json", "status", "not json")
        self.assertEqual((bad["complete"], bad["read"]["ok"], bad["state"]), (False, False, "unknown"))
        big = self.answer("json", "graph", json.dumps({"nodes": [{"id": str(i)} for i in range(5001)], "edges": []}))
        self.assertEqual((big["complete"], big["graph"]["nodes"]), (False, []))
        self.assertIn("around", big["why"])

    def test_toolio_and_fox_symdeps_envelopes_are_taken_as_they_are(self):
        def envelope(code, findings=(), payload=None):
            return json.dumps({"envelope_version": "1.0", "kind": "k", "producer": {"tool": "t", "version": "9", "command": "t --json"},
                               "status": {"ok": code == 0, "code": code, "findings": list(findings)},
                               "target": {"git_head": "f00d"}, "payload": payload or {}, "unknown": 1})
        status = self.answer("toolio", "status", envelope(0))
        self.assertEqual((status["state"], status["complete"], status["about"][0]["version"]["head"]), ("ok", True, "f00d"))
        self.assertEqual(self.answer("toolio", "status", envelope(1, [["a.c", 4, "warning", "w", "x"]]))["state"], "warn")
        refused = self.answer("fox-symdeps/2", "findings", envelope(2, [["", 0, "refused", "no compile DB", "refused"]]))
        self.assertEqual((refused["complete"], refused["why"], refused["findings"]), (False, "refused: no compile DB", []))
        self.assertEqual(refused["read"]["ok"], True, "the tool refused; desk-work read it fine")
        timing = {"timing": {"schema": ["name", "value", "unit"], "rows": [["p50", 100, "ns"], ["p99", 412, "ns"]]},
                  "other": {"schema": ["path"], "rows": [["x"]]}}
        self.assertEqual([(f["name"], f["value"]) for f in self.answer("toolio", "figures", envelope(0, payload=timing))["facts"]],
                         [("p50", 100), ("p99", 412)])
        tables = {"nodes": {"schema": ["id", "label", "line"], "rows": [["n1", "one", 7], ["n2", "two", None]]},
                  "edges": {"schema": ["from", "to", "kind"], "rows": [["n1", "n2", "calls"]]}}
        graph = self.answer("toolio", "graph", envelope(0, payload=tables))["graph"]
        self.assertEqual(([(n["id"], n["label"], n["line"]) for n in graph["nodes"]], graph["edges"]),
                         ([("n1", "one", 7), ("n2", "two", None)], [{"from": "n1", "to": "n2", "kind": "calls"}]))

    def test_lines_give_a_status_compiler_style_findings_or_figures(self):
        status = self.answer("lines", "status", "building…\nFAIL: 3 broken\n")
        self.assertEqual((status["state"], status["summary"]), ("fail", "3 broken"))
        self.assertEqual(self.answer("lines", "status", "just words\n")["state"], "unknown", "no run and no leading word: unknown")
        findings = self.answer("lines", "findings", "src/a.cpp:12:5: error: boom\nsample.cpp:3: note: here\nsample.cpp:4: plain\nnot a finding\n")
        self.assertEqual([(f["file"], f["line"], f["col"], f["severity"], f["message"]) for f in findings["findings"]],
                         [("src/a.cpp", 12, 5, "error", "boom"), ("sample.cpp", 3, None, "info", "here"), ("sample.cpp", 4, None, None, "plain")])
        figures = self.answer("lines", "figures", "p99 412ns\nRan 12 tests in 0.4s\nthroughput: 1.2M/s\n")
        self.assertEqual([(f["name"], f["value"], f["unit"]) for f in figures["facts"]], [("p99", 412, "ns"), ("throughput", 1.2, "M/s")])

    def test_a_fox_contract_record_becomes_a_status_with_what_it_ran_against(self):
        record = self.record_text({"@PLUGIN@": "/nowhere/plugin", "@PLUGIN_COMMIT@": "a" * 40, "@WORKSPACE@": "/nowhere/ws",
                                   "@WORKSPACE_HEAD@": "b" * 40, "@TOOLS_TREE@": "c" * 40, "@ENGINE@": "/nowhere/engine",
                                   "@ENGINE_HEAD@": "d" * 40, "@LOG@": "/nowhere/run.log"})
        result = self.answer("fox-contract/1", "status", json.dumps(record))
        self.assertEqual((result["state"], result["complete"], result["at"], result["started"], result["log"], result["summary"]),
                         ("ok", True, 1794812098, 1794812098, "/nowhere/run.log", "fox-symdeps: 12 passed, 0 failed · network-isolated"))
        self.assertEqual([(f["name"], f["value"]) for f in result["facts"]], [("passed", 12), ("failed", 0), ("skipped", 0), ("expected", 12)])
        self.assertEqual([a["name"] for a in result["about"]], ["plugin", "workspace", "engine"], "in the record's order")
        plugin, workspace, engine = result["about"]
        self.assertEqual((plugin["path"], plugin["version"]["head"], plugin["scope"], plugin["version"]["uncommitted"]),
                         ("/nowhere/plugin", "a" * 40, "", []))
        self.assertEqual((workspace["scope"], workspace["how"], workspace["version"]),
                         ("tools", "FOX_WORKSPACE_TOOLS", {"head": "b" * 40, "tree": "c" * 40, "release": "0.99.1", "dirty": False, "uncommitted": []}))
        self.assertEqual((engine["version"]["dirty"], engine["version"]["uncommitted"]), (False, None), "no list is unknown, not empty")
        record["result"].update(state="refused", why="unknown test name")
        refused = self.answer("fox-contract/1", "status", json.dumps(record))
        self.assertEqual((refused["complete"], refused["why"], refused["state"], refused["read"]["ok"]), (False, "refused: unknown test name", "unknown", True))
        record["result"]["state"] = "pass"
        record["moved"] = ["workspace.head"]
        record["inputs"]["end"]["engine"] = {"why": "no engine checkout found"}
        moved = {a["name"]: a for a in self.answer("fox-contract/1", "status", json.dumps(record))["about"]}
        self.assertEqual((moved["workspace"]["moved"], moved["engine"]["why"], moved["engine"]["path"]), (["head"], "no engine checkout found", None))
        self.assertEqual(self.answer("fox-contract/1", "status", json.dumps(dict(record, kind="fox-contract/2")))["read"]["ok"], False)

    def test_dot_reads_what_ninja_t_graph_prints(self):
        printed = ('digraph ninja {\nrankdir="LR"\nnode [fontsize=10, shape=box, height=0.25]\nedge [fontsize=10]\n'
                   '"0x1" [label="all"]\n"0x2" -> "0x1" [label=" phony"]\n"0x2" [label="foo"]\n"0x3" [label="cxx", shape=ellipse]\n'
                   '"0x3" -> "0x2"\n"0x4" -> "0x3" [arrowhead=none style=dotted]\n"0x4" [label="foo.cc"]\n'
                   '// a comment\nsubgraph cluster_x { a -> { b c } }\n}\n')
        graph = self.answer("dot", "graph", printed)
        self.assertEqual({n["id"]: n["label"] for n in graph["graph"]["nodes"]},
                         {"0x1": "all", "0x2": "foo", "0x3": "cxx", "0x4": "foo.cc", "a": "a", "b": "b", "c": "c"})
        self.assertEqual([(e["from"], e["to"], e.get("label")) for e in graph["graph"]["edges"]],
                         [("0x2", "0x1", "phony"), ("0x3", "0x2", None), ("0x4", "0x3", None), ("a", "b", None), ("a", "c", None)])
        self.assertIsNone(graph["complete"], "DOT cannot say a graph is whole")
        self.assertEqual(self.answer("dot", "graph", "nodes and edges\n")["read"]["ok"], False)
        if shutil.which("ninja"):
            build = self.dir / "build"
            build.mkdir()
            (build / "build.ninja").write_text("rule cc\n  command = cc -c $in -o $out\nbuild foo.o: cc foo.c\nbuild all: phony foo.o\n")
            real = subprocess.run(["ninja", "-C", str(build), "-t", "graph"], capture_output=True, text=True, check=True).stdout
            labels = {n["label"] for n in self.answer("dot", "graph", real)["graph"]["nodes"]}
            self.assertTrue({"foo.c", "foo.o", "all"} <= labels, labels)


if __name__ == "__main__":
    unittest.main()
