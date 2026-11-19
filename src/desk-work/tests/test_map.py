"""desk-work map: the project map's store, end to end in a disposable home — a build (a job like any other), its
status and staleness, the queries, the binary reader on a program compiled here (read with objdump, never run)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "desk-work"
MAP_LUA = HERE.parents[2] / "shared/nvim_lua/desk/map.lua"
NVIM = shutil.which("nvim") is not None
CC = shutil.which("cc") or shutil.which("gcc")
OBJDUMP = shutil.which("objdump") is not None
sys.path.insert(0, str(HERE.parents[2] / "tests"))
import sealed_env  # noqa: E402

LUA = """local M = {}
local function helper(x) return x + 1 end
function M.alpha()
  return M.beta() + helper(2)
end
function M.beta()
  return helper(1)
end
return M
"""
C = """#include <stdio.h>
__attribute__((noinline)) int leaf(int x) { return x + 1; }
__attribute__((noinline)) int middle(int x) { return leaf(x) * 2; }
int main(int argc, char **argv) { (void)argv; puts("map"); return middle(argc); }
"""


class Map(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.repo = self.dir / "project with spaces"
        (self.repo / "lua").mkdir(parents=True)
        (self.repo / "csrc").mkdir()
        # Sealed from the session (tests/sealed_env.py).
        self.env = sealed_env.environment(self.dir, HOME=self.dir / "home", XDG_STATE_HOME=self.dir / "state",
                                          XDG_CONFIG_HOME=self.dir / "config", XDG_RUNTIME_DIR=self.dir / "runtime",
                                          XDG_DATA_HOME=self.dir / "data", FOXML_WORK_NOTIFY="0", PYTHONDONTWRITEBYTECODE="1",
                                          DESK_MAP_LUA=MAP_LUA)
        self.addCleanup(sealed_env.stop, self.env)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "lua/mod.lua").write_text(LUA)
        (self.repo / "csrc/prog.c").write_text(C)
        (self.repo / "README.md").write_text("notes\n")
        (self.repo / ".gitignore").write_text("build/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, capture_output=True, text=True,
                              check=True).stdout.strip()

    def invoke(self, *args, code=0, stdin=None):
        p = subprocess.run([str(BIN), *map(str, args)], cwd=self.repo, env=self.env, capture_output=True, text=True,
                           timeout=180, input=stdin)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        return p.stdout

    def data(self, *args, code=0):
        return json.loads(self.invoke(*args, code=code).strip().splitlines()[-1])

    def build(self, *args, code=0):
        return self.data("map", "build", "--root", self.repo, "--wait", "yes", *args, code=code)

    def status(self):
        return self.data("map", "status", "--root", self.repo)

    def query(self, *args, code=0):
        return self.data("map", "query", "--root", self.repo, *args, code=code)

    def provider(self, status, name):
        return next(p for p in status["providers"] if p["name"] == name)

    def compile(self):
        (self.repo / "build").mkdir(exist_ok=True)
        out = self.repo / "build/prog"
        subprocess.run([CC, "-O2", "-o", str(out), str(self.repo / "csrc/prog.c")], check=True, capture_output=True)
        return out

    def test_before_a_build_nothing_is_made_up(self):
        status = self.status()
        self.assertFalse(status["built"])
        self.assertIn("requires a built binary", self.provider(status, "binary")["why"])
        self.assertEqual(self.provider(status, "syntax")["state"], "not built")
        refused = self.query("--q", "module", code=1)
        self.assertIn("No project map", refused["message"])
        self.assertEqual(self.data("map", "build", "--root", self.repo, "--provider", "nope", code=1)["ok"], False)
        (self.repo / "notes.txt").write_text("not a program")
        self.assertIn("not an ELF", self.data("map", "build", "--root", self.repo, "--binary", self.repo / "notes.txt", code=1)["message"])
        self.assertEqual(list((Path(self.env["XDG_STATE_HOME"]) / "foxml/work").glob("projects/*/map/graph.json")), [])

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_handoff_corrections_are_hers_and_kept_outside_the_checkout(self):
        self.build("--provider", "syntax")
        lane = lambda t: [st["label"] for st in t["steps"]]
        self.assertEqual(lane(self.query("--q", "trace", "--from", "leaf")), ["main", "middle", "leaf"])
        added = self.data("map", "handoff", "add", "--root", self.repo, "--from", "leaf", "--to", "M.beta", "--label", "a queue")
        self.assertEqual(added["did"], "added")
        file = Path(added["file"])
        self.assertEqual(file.parent, Path(self.env["XDG_CONFIG_HOME"]) / "foxml/desk.d")
        self.assertEqual(file.name, "map-project with spaces.json")
        decl = json.loads(file.read_text())
        self.assertEqual((decl["version"], decl["root"], decl["tools"]), (1, str(self.repo), []))
        traced = self.query("--q", "trace", "--from", "leaf")
        self.assertEqual(lane(traced), ["main", "middle", "leaf", "M.beta", "helper"], "an added handoff carries the lane on")
        self.assertEqual({k: traced["calls"][2][k] for k in ("kind", "label", "by_hand")}, {"kind": "handoff", "label": "a queue", "by_hand": True})
        self.assertEqual(self.data("map", "handoff", "drop", "--root", self.repo, "--from", "leaf", "--to", "M.beta")["did"], "forgotten (it was yours)")
        self.assertEqual(lane(self.query("--q", "trace", "--from", "leaf")), ["main", "middle", "leaf"], "dropping one she added forgets it")
        self.assertEqual(self.data("map", "handoff", "drop", "--root", self.repo, "--from", "main", "--to", "middle")["did"], "dropped")
        self.assertEqual(lane(self.query("--q", "trace", "--from", "leaf")), ["main", "middle", "leaf"], "a dropped pair that is a call stays a call")
        listed = self.data("map", "handoff", "list", "--root", self.repo)["handoffs"]
        self.assertEqual((len(listed["drop"]), len(listed["add"])), (1, 0))
        self.assertEqual(self.data("map", "handoff", "forget", "--root", self.repo, "--from", "main", "--to", "middle")["did"], "forgotten")
        refused = self.data("map", "handoff", "add", "--root", self.repo, "--from", "nobody", "--to", "leaf", code=1)
        self.assertIn("From: ", refused["message"])
        # Never in the checkout; the declaration reader takes the file as one of its own (no tools, nothing refused).
        self.assertEqual(self.git("status", "--porcelain"), "")
        tools = self.data("tools", "list", "--root", self.repo)
        self.assertFalse(any("refused" in json.dumps(f) and str(file) in json.dumps(f) for f in tools.get("files", [])), tools)
        # A name that fits several: refused with the candidates and the flag they go back in (a picker's).
        (self.repo / "lua/dup.lua").write_text("local function leaf(x) return x end\nreturn leaf\n")
        self.git("add", "."); self.git("commit", "-qm", "a second leaf")
        self.build("--provider", "syntax")
        start = self.query("--q", "trace", "--from", "middle", "--start", "leaf", code=1)
        self.assertEqual((start["flag"], len(start["candidates"]), start["message"][:7]), ("--start", 2, "Start: "))
        to = self.query("--q", "trace", "--from", "middle", "--to", "leaf", code=1)
        self.assertEqual(to["flag"], "--to")
        dest = self.data("map", "handoff", "add", "--root", self.repo, "--from", "middle", "--to", "leaf", code=1)
        self.assertEqual((dest["flag"], len(dest["candidates"])), ("--to", 2))
        # A file there desk-work cannot read is left as it is.
        file.write_text("not json")
        self.assertIn("left as it is", self.data("map", "handoff", "add", "--root", self.repo, "--from", "middle", "--to", "M.beta", code=1)["message"])
        self.assertEqual(file.read_text(), "not json")

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_handoff_corrections_review_page_checks_their_ends_after_a_rebuild(self):
        self.build("--provider", "syntax")
        self.data("map", "handoff", "add", "--root", self.repo, "--from", "leaf", "--to", "M.beta", "--label", "a queue")
        self.data("map", "handoff", "drop", "--root", self.repo, "--from", "main", "--to", "middle")
        review = self.query("--q", "handoffs")
        own = review["file"]
        ends = lambda e: (e["side"], e["from"]["state"], e["to"]["state"], e.get("label"), e["own"], e["declared_in"] == own, e.get("stale"))
        self.assertEqual([ends(e) for e in review["entries"]],
                         [("add", "ok", "ok", "a queue", True, True, None), ("drop", "ok", "ok", None, True, True, True)],
                         "each correction, its label and where it is declared; a drop of a pair the reader never read as a handoff: stale")
        # leaf renamed away, M.beta moved to another file, middle renamed with two others of its name elsewhere: the ends
        # are checked against the map as built now.
        (self.repo / "csrc/prog.c").write_text(C.replace("leaf", "leafy").replace("middle", "mid"))
        (self.repo / "csrc/m1.c").write_text("int middle(int x) { return x; }\n")
        (self.repo / "csrc/m2.c").write_text("int middle(int x) { return x + 1; }\n")
        (self.repo / "lua/mod.lua").write_text(LUA.replace("function M.beta()\n  return helper(1)\nend\n", ""))
        (self.repo / "lua/two.lua").write_text("local M = {}\nfunction M.beta() return 2 end\nreturn M\n")
        self.git("add", "."); self.git("commit", "-qm", "renamed")
        self.build("--provider", "syntax")
        added, dropped = self.query("--q", "handoffs")["entries"]
        self.assertEqual((added["from"]["state"], added["to"]["state"], added["to"].get("now", {}).get("file")), ("gone", "moved", "lua/two.lua"),
                         "after a rebuild: an end renamed away is gone; one moved to another file is found there by its name")
        self.assertEqual((dropped["from"]["state"], dropped["to"]["state"], len(dropped["to"].get("candidates", []))), ("ok", "ambiguous", 2),
                         "… one whose name is now two functions is ambiguous, with both")
        # forget takes an end the map no longer has by the id it was kept by
        forgot = self.data("map", "handoff", "forget", "--root", self.repo, "--from", added["from"]["id"], "--to", added["to"]["id"])
        self.assertEqual(forgot["did"], "forgotten")
        self.assertEqual([e["side"] for e in self.query("--q", "handoffs")["entries"]], ["drop"])
        # one she declares herself elsewhere: listed as hers to edit (own is false)
        (self.repo / ".desk").mkdir()
        (self.repo / ".desk/tools.json").write_text(json.dumps({"version": 1, "tools": [], "map": {"handoffs": {"add": [{"from": "x", "to": "y"}]}}}))
        theirs = [e for e in self.query("--q", "handoffs")["entries"] if not e["own"]]
        self.assertEqual([(e["declared_in"].endswith(".desk/tools.json"), e["from"]["state"]) for e in theirs], [(True, "gone")])

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_exclude_leaves_functions_out_of_one_question(self):
        self.build("--provider", "syntax")
        labels = lambda answer: sorted(n["label"] for n in answer["nodes"] if n.get("depth", 0) > 0)
        whole = self.query("--q", "reach", "--from", "main", "--depth", "3")
        self.assertEqual(labels(whole), ["leaf", "middle"])
        middle = next(n["id"] for n in whole["nodes"] if n["label"] == "middle")
        cut = self.query("--q", "reach", "--from", "main", "--depth", "3", "--exclude", middle + "\nnot/there.c::x")
        self.assertEqual((labels(cut), cut["excluded"]), ([], [middle]),
                         "middle left out of this question: main reaches nothing (leaf only through it); only what the map had is said back")
        self.assertNotIn("excluded", self.query("--q", "reach", "--from", "main", "--depth", "3"), "… and the next question has it back")
        # --avoid: can main reach leaf without going through middle? No: said with what was searched.
        ways = self.query("--q", "paths", "--from", "main", "--to", "leaf")
        self.assertEqual(len(ways["paths"]), 1)
        none = self.query("--q", "paths", "--from", "main", "--to", "leaf", "--avoid", "middle")
        self.assertEqual((none["paths"], none["avoided"]["label"], none["searched"]["edges"], none["searched"]["depth"] > 0, "excluded" in none),
                         ([], "middle", ["call", "call-by-name", "handoff"], True, False),
                         "no way avoids middle: the avoided function, and what a no covers (the map, the edges, the depth)")
        self.assertIn("Avoid: Nothing in the map is named nobody", self.query("--q", "paths", "--from", "main", "--to", "leaf", "--avoid", "nobody", code=1)["message"])
        (self.repo / "csrc/two.c").write_text("int middle(int x) { return x; }\n")
        self.git("add", "."); self.git("commit", "-qm", "a second middle")
        self.build("--provider", "syntax")
        several = self.query("--q", "paths", "--from", "main", "--to", "leaf", "--avoid", "middle", code=1)
        self.assertEqual((several["flag"], len(several["candidates"])), ("--avoid", 2), "a name that fits several: the candidates, under --avoid")

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_a_rebuild_says_what_it_changed(self):
        self.build("--provider", "syntax")
        self.assertTrue(self.status()["changes"]["first"], "the first build: nothing to compare")
        (self.repo / "csrc/prog.c").write_text(C.replace("return leaf(x) * 2;", "return leaf(x) * 2 + extra(x);") + "int extra(int x) { return x; }\n")
        self.build("--provider", "syntax")
        status = self.status()["changes"]
        self.assertEqual((status["edges_added"], status["nodes_added"], status["because"]), (1, 1, ["the source changed (edits not committed)"]),
                         "status: the counts and why")
        listed = self.query("--q", "changes")
        self.assertEqual(([n["label"] for n in listed["nodes_added_list"]], listed["edges_added_list"][0]["to"].endswith("::extra")), (["extra"], True),
                         "query --q changes: which ones")

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_syntax_build_status_staleness_and_queries(self):
        status = self.build("--provider", "syntax")
        self.assertTrue(status["built"], status)
        self.assertEqual(status["exit"], 0)
        self.assertFalse(status["stale"], status)
        syntax = self.provider(status, "syntax")
        self.assertEqual(syntax["state"], "ok", syntax)
        self.assertEqual(self.provider(status, "binary")["state"], "not built")
        self.assertGreaterEqual(syntax["stats"]["functions"], 6)
        # The build is a desk-work job: its record, title and log are there like any other run's.
        job = next(j for j in self.data("jobs", "--root", self.repo) if j.get("title") == "Project map")
        self.assertEqual(job["state"], "passed")
        self.assertIn("syntax:", self.invoke("log", "--id", job["id"]))
        # Kept with the work records, never in the project.
        self.assertEqual(self.git("status", "--porcelain"), "")
        graph = self.data("map", "show", "--root", self.repo)
        labels = {n["label"] for n in graph["nodes"]}
        self.assertTrue({"M.alpha", "M.beta", "helper", "leaf", "middle", "main"} <= labels, labels)
        self.assertEqual(graph["version"], 1)
        # A C or C++ function also has its signature (params, returns) and a call its line and arguments: the trace's.
        for node in graph["nodes"]:
            self.assertEqual(set(node) - {"detail", "params", "returns"}, {"id", "label", "file", "line", "kind"})
        self.assertTrue(all(set(e) - {"line", "args", "sites", "to_line"} == {"from", "to", "kind"} for e in graph["edges"]))
        # every call between two kept as a site of the one edge (the trace offers each)
        self.assertTrue(all(len(e["sites"]) >= 1 and all(site["line"] > 0 for site in e["sites"]) for e in graph["edges"] if "sites" in e))
        self.assertTrue(any("params" in n for n in graph["nodes"] if n["file"].endswith(".c")), "a C function has its parameters")

        reach = self.query("--q", "reach", "--from", "M.alpha", "--depth", "2")
        self.assertEqual(reach["from"]["label"], "M.alpha")
        self.assertEqual({(s["from"].split("::")[-1], s["to"].split("::")[-1]) for s in reach["steps"]},
                         {("M.alpha", "M.beta"), ("M.alpha", "helper"), ("M.beta", "helper")})
        self.assertEqual(reach["providers"], ["syntax"])
        located = self.query("--q", "reach", "--from", "M.alpha", "--file", self.repo / "lua/mod.lua",
                             "--line", "4", "--depth", "13")
        self.assertEqual((located["root"], located["from"]["id"], located["depth"]),
                         (str(self.repo), reach["from"]["id"], 13))
        wrong_file = self.query("--q", "reach", "--from", "M.alpha", "--file", "csrc/prog.c", "--line", "3", code=1)
        self.assertIn("No function in the map matches this location", wrong_file["message"])
        callers = self.query("--q", "callers", "--of", "helper")
        self.assertEqual({s["from"].split("::")[-1] for s in callers["steps"]}, {"M.alpha", "M.beta"})
        ways = self.query("--q", "paths", "--from", "main", "--to", "leaf")
        self.assertEqual([[i.split("::")[-1] for i in p["nodes"]] for p in ways["paths"]], [["main", "middle", "leaf"]])
        parts = self.query("--q", "module")
        self.assertEqual({m["name"] for m in parts["modules"]}, {"lua", "csrc"})
        inside = self.query("--q", "module", "--name", "lua")
        self.assertEqual({f["file"] for f in inside["files"]}, {"lua/mod.lua"})
        self.assertIn("Nothing in the map", self.query("--q", "reach", "--from", "nope", code=1)["message"])
        self.assertTrue(self.invoke("map", "export", "--root", self.repo, "--format", "dot").startswith("digraph"))

        # Stale, never rebuilt by itself: an edit to a mapped file, again, a commit; an unmapped file is no change.
        (self.repo / "README.md").write_text("more notes\n")
        self.assertFalse(self.status()["stale"], "a file the map does not read")
        (self.repo / "lua/mod.lua").write_text(LUA.replace("return helper(1)", "return helper(1) + 0"))
        status = self.status()
        self.assertTrue(status["stale"])
        self.assertIn("1 changed file", status["stale_why"])
        (self.repo / "lua/mod.lua").write_text(LUA.replace("return helper(1)", "return helper(1) + 1"))
        self.assertTrue(self.status()["stale"], "edited again: still stale")
        self.assertEqual(self.data("map", "show", "--root", self.repo)["built_at"], graph["built_at"], "status never rebuilds")
        self.git("commit", "-qam", "edit")
        self.assertIn("HEAD moved", self.status()["stale_why"])
        touched = self.query("--q", "touched", "--commit", "HEAD")
        self.assertEqual({f["file"] for f in touched["files"]}, {"README.md", "lua/mod.lua"})
        self.assertEqual([n["label"] for n in touched["nodes"]], ["M.beta"], "the function around the edit")
        self.assertEqual(touched["moved"], ["lua/mod.lua"], "the map was built before that commit: its lines may have moved")
        self.build("--provider", "syntax")
        self.assertFalse(self.status()["stale"])
        self.assertEqual(self.query("--q", "touched", "--commit", "HEAD")["moved"], [])

    @unittest.skipUnless(NVIM and CC and OBJDUMP, "needs nvim, a C compiler and objdump")
    def test_binary_reader_merges_and_is_remembered(self):
        program = self.compile()
        status = self.build("--binary", program)
        binary = self.provider(status, "binary")
        self.assertEqual(binary["state"], "ok", binary)
        self.assertEqual(status["binary"], str(program.resolve()))
        graph = self.data("map", "show", "--root", self.repo)
        by_id = {n["id"]: n for n in graph["nodes"]}
        calls = {(by_id[e["from"]]["label"], by_id[e["to"]]["label"]) for e in graph["edges"] if e["kind"] == "call"}
        self.assertIn(("main", "middle"), calls)
        self.assertIn(("middle", "leaf"), calls)
        self.assertIn(("main", "puts"), calls, "a library call ends at a leaf")
        main = next(n for n in graph["nodes"] if n["label"] == "main")
        self.assertEqual(main["file"], "csrc/prog.c", "the binary's main and the source's are one node")
        kinds = {e["kind"] for e in graph["edges"] if by_id[e["from"]]["label"] == "main" and by_id[e["to"]]["label"] == "middle"}
        self.assertEqual(kinds, {"call", "call-by-name"}, "each edge keeps where it came from")
        self.assertGreater(graph["matched"], 0)
        exact = self.query("--q", "paths", "--from", "main", "--to", "puts")
        self.assertEqual(exact["paths"][0]["kinds"], ["call"])
        # Remembered: the next build reads the same binary; rebuilding it makes only the binary's answer stale.
        self.build("--provider", "binary")
        self.assertEqual(self.provider(self.status(), "binary")["state"], "ok")
        time.sleep(0.01)
        self.compile()
        os.utime(program, None)
        status = self.status()
        self.assertTrue(status["stale"])
        self.assertTrue(self.provider(status, "binary")["stale"])
        self.assertFalse(self.provider(status, "syntax")["stale"])
        self.assertIn("binary", status["stale_why"])

    def test_the_disassembly_reader_on_its_own(self):
        text = (HERE / "fixtures/objdump-sample.txt").read_text()
        graph = json.loads(self.invoke("map", "objdump-parse", stdin=text))
        self.assertIn("bin:main", {n["id"] for n in graph["nodes"]})
        self.assertIn({"from": "bin:main", "to": "ext:puts", "kind": "call"}, graph["edges"])

    @unittest.skipUnless(NVIM, "nvim is not installed")
    def test_a_build_runs_in_the_background(self):
        started = time.monotonic()
        answer = self.data("map", "build", "--root", self.repo, "--provider", "syntax")
        self.assertTrue(answer["started"])
        self.assertLess(time.monotonic() - started, 5, "map build hands the work to a job and returns")
        again = self.data("map", "build", "--root", self.repo, "--provider", "syntax")
        self.assertTrue(again.get("running") or again.get("started"))
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            status = self.status()
            if status["built"] and not status["building"]:
                break
            time.sleep(0.2)
        self.assertTrue(status["built"] and not status["building"], status)
        self.assertEqual(self.provider(status, "syntax")["state"], "ok")


if __name__ == "__main__":
    unittest.main()
