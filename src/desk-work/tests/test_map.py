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

from sealed import sealed

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
        self.env = dict(sealed(os.environ, str(self.dir)), HOME=str(self.dir / "home"), XDG_STATE_HOME=str(self.dir / "state"),
                        XDG_CONFIG_HOME=str(self.dir / "config"), XDG_RUNTIME_DIR=str(self.dir / "runtime"),
                        XDG_DATA_HOME=str(self.dir / "data"), FOXML_WORK_NOTIFY="0", PYTHONDONTWRITEBYTECODE="1",
                        DESK_MAP_LUA=str(MAP_LUA))
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
        for node in graph["nodes"]:
            self.assertEqual(set(node) - {"detail"}, {"id", "label", "file", "line", "kind"})
        self.assertTrue(all(set(e) == {"from", "to", "kind"} for e in graph["edges"]))

        reach = self.query("--q", "reach", "--from", "M.alpha", "--depth", "2")
        self.assertEqual(reach["from"]["label"], "M.alpha")
        self.assertEqual({(s["from"].split("::")[-1], s["to"].split("::")[-1]) for s in reach["steps"]},
                         {("M.alpha", "M.beta"), ("M.alpha", "helper"), ("M.beta", "helper")})
        self.assertEqual(reach["providers"], ["syntax"])
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
