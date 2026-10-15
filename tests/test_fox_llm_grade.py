#!/usr/bin/env python3
"""tests/test_fox_llm_grade.py — fox-llm-grade against a fake model server and the real C++ compiler.

The fake server answers like llama.cpp's router (/models, /models/unload, /v1/chat/completions, /infill) with canned
answers: right C++ for four tasks and a ring buffer that masks with N-1 (wrong when N isn't a power of two), so the score
is known in advance. A throwaway $HOME; no real model, no desktop notice. Skips (passes) without g++ or clang++.
"""
import http.server
import importlib.machinery
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/fox-llm-grade"
GRADE = importlib.machinery.SourceFileLoader("fox_llm_grade", str(SCRIPT)).load_module()

ANSWERS = {
    "top_k": "#include <vector>\n#include <algorithm>\nstd::vector<int> top_k(const std::vector<int>& v, int k) {\n"
             "  if (k <= 0) return {};\n  std::vector<int> r = v; std::sort(r.rbegin(), r.rend());\n"
             "  if ((size_t)k < r.size()) r.resize(k);\n  return r;\n}",
    "next_pow2": "#include <cstdint>\nstd::uint64_t next_pow2(std::uint64_t x) {\n  if (x <= 1) return 1;\n"
                 "  x--; x |= x >> 1; x |= x >> 2; x |= x >> 4; x |= x >> 8; x |= x >> 16; x |= x >> 32;\n  return x + 1;\n}",
    "parse_price": "#include <cstdint>\nbool parse_price(const char* s, std::int64_t* out) {\n"
                   "  bool neg = *s == '-'; if (neg) ++s;\n  if (*s < '0' || *s > '9') return false;\n"
                   "  unsigned __int128 v = 0;\n  while (*s >= '0' && *s <= '9') { v = v * 10 + (*s++ - '0'); if (v >> 80) return false; }\n"
                   "  int d = 0;\n  if (*s == '.') { ++s; if (*s < '0' || *s > '9') return false;\n"
                   "    while (*s >= '0' && *s <= '9') { if (++d > 4) return false; v = v * 10 + (*s++ - '0'); } }\n"
                   "  if (*s) return false;\n  for (; d < 4; ++d) v *= 10;\n"
                   "  if (v > (unsigned __int128)9223372036854775807LL) return false;\n"
                   "  *out = neg ? -(std::int64_t)v : (std::int64_t)v;\n  return true;\n}",
    "merge_intervals": "#include <vector>\n#include <algorithm>\n#include <utility>\n"
                       "std::vector<std::pair<int, int>> merge_intervals(std::vector<std::pair<int, int>> v) {\n"
                       "  std::sort(v.begin(), v.end()); std::vector<std::pair<int, int>> r;\n"
                       "  for (auto& p : v) { if (!r.empty() && p.first <= r.back().second) "
                       "r.back().second = std::max(r.back().second, p.second); else r.push_back(p); }\n  return r;\n}",
    "ring": "#include <cstddef>\ntemplate <typename T, std::size_t N> class Ring {\n  T a[N]; std::size_t h = 0, n = 0;\n"
            "public:\n  bool push(const T& v) { if (n == N) return false; a[(h + n) & (N - 1)] = v; ++n; return true; }\n"
            "  bool pop(T& o) { if (!n) return false; o = a[h]; h = (h + 1) & (N - 1); --n; return true; }\n"
            "  std::size_t size() const { return n; }\n  bool empty() const { return n == 0; }\n"
            "  bool full() const { return n == N; }\n};",
}


class FakeRouter(http.server.BaseHTTPRequestHandler):
    loaded = set()           # names the fake says are in memory
    log = []                 # (path, model) of every request

    def log_message(self, *a):
        pass

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/models":
            names = ["qwen2.5-coder:1.5b-base", "qwen3.5:9b", "qwen3.5:4b"]
            self.reply({"data": [{"id": n.replace(":", "_"), "aliases": [n],
                                  "status": {"value": "loaded" if n in FakeRouter.loaded else "unloaded"}} for n in names]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeRouter.log.append((self.path, body.get("model")))
        if self.path == "/models/unload":
            FakeRouter.loaded.discard(body["model"]); return self.reply({"success": True})
        FakeRouter.loaded.add(body.get("model"))
        if self.path == "/infill":
            return self.reply({"content": "a + b", "timings": {"prompt_per_second": 900.0, "predicted_per_second": 40.0}})
        if body.get("tools"):
            msg = {"role": "assistant", "content": "",
                   "tool_calls": [{"type": "function", "function": {"name": "read_file",
                                                                    "arguments": json.dumps({"path": "src/engine/main.cpp"})}}]}
            return self.reply({"choices": [{"message": msg}]})
        prompt = body["messages"][0]["content"]
        task = next((n for n, (p, _) in GRADE.TASKS.items() if prompt == p), None)
        text = f"Here it is:\n```cpp\n{ANSWERS[task]}\n```\n" if task else "This code tests five functions."
        self.reply({"choices": [{"message": {"role": "assistant", "content": text}}],
                    "timings": {"prompt_per_second": 150.5, "predicted_per_second": 6.2, "prompt_n": 1400}})


@unittest.skipUnless(shutil.which("g++") or shutil.which("clang++"), "no C++ compiler")
class GradeTest(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-llm-grade-test-", dir=base))
        self.home, self.bin = self.tmp / "home", self.tmp / "bin"
        llm = self.home / ".config/foxml/llm"
        llm.mkdir(parents=True)
        self.bin.mkdir()
        (llm / "roles.conf").write_text("quick qwen3.5:4b llama\nfim qwen2.5-coder:1.5b-base llama\n")
        (llm / "llama-presets.ini").write_text(
            "[*]\nflash-attn = on\n\n[qwen3.5:4b]\n; role: quick\n\n[qwen2.5-coder:1.5b-base]\n; role: fim\n\n"
            "[qwen3.5:9b]\n; extra\n")
        gguf = self.home / ".local/share/fox-llm/gguf"
        gguf.mkdir(parents=True)
        for n in ("qwen3.5:9b", "qwen2.5-coder:1.5b-base"):
            (gguf / f"{n}.gguf").write_bytes(b"GGUF")
        (self.bin / "llama-server").write_text('#!/bin/sh\necho "version: 11429 (d812350)"\n')
        (self.bin / "notify-send").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$NOTIFY_LOG"\n')
        (self.bin / "systemd-run").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RUN_LOG"\n')
        for f in self.bin.iterdir():
            f.chmod(0o755)
        FakeRouter.loaded, FakeRouter.log = {"qwen2.5-coder:1.5b-base"}, []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeRouter)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.tmp)

    def run_grade(self, *args):
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin",
               "XDG_CONFIG_HOME": str(self.home / ".config"), "XDG_STATE_HOME": str(self.home / ".local/state"),
               "XDG_CACHE_HOME": str(self.home / ".cache"), "XDG_DATA_HOME": str(self.home / ".local/share"),
               "FOX_LLM_URL": f"http://127.0.0.1:{self.server.server_port}", "FOX_LLM_GRADE_RUNS": "1",
               "FOX_LLM_SERVER": str(self.bin / "llama-server"),
               "NOTIFY_LOG": str(self.tmp / "notify.log"), "RUN_LOG": str(self.tmp / "run.log")}
        r = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=600)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def scores(self):
        f = self.home / ".local/state/fox-llm-update/grades.tsv"
        rows = [l.split("\t") for l in f.read_text().splitlines()] if f.exists() else []
        return {(r[2], r[4]): r[5] for r in rows}, rows

    def test_a_chat_model_card_scores_what_its_answers_earn(self):
        out = self.run_grade("qwen3.5:9b")
        s, rows = self.scores()
        self.assertEqual(s[("qwen3.5:9b", "cxx")], "4/5")                      # the ring buffer's N-1 mask fails
        self.assertEqual(s[("qwen3.5:9b", "cxx:ring")], "0/1")
        self.assertEqual(s[("qwen3.5:9b", "cxx:parse_price")], "1/1")
        self.assertEqual((s[("qwen3.5:9b", "read_tps")], s[("qwen3.5:9b", "write_tps")]), ("150.5", "6.2"))
        self.assertEqual(s[("qwen3.5:9b", "tools")], "ok")
        self.assertEqual({r[1] for r in rows}, {"11429"})                      # the llama.cpp build it ran on
        self.assertIn("qwen3.5:9b: C++ 4/5", out)
        paths = [p for p, _ in FakeRouter.log]
        self.assertEqual(FakeRouter.log[paths.index("/infill")][1], "qwen2.5-coder:1.5b-base")   # ghost text first
        self.assertLess(paths.index("/infill"), paths.index("/v1/chat/completions"))
        self.assertEqual(FakeRouter.log[-1], ("/models/unload", "qwen3.5:9b"))              # and freed after
        self.assertTrue((self.home / ".cache/fox-llm-grade/qwen3.5:9b/ring-1.md").exists())

    def test_a_base_model_is_graded_on_ghost_text(self):
        self.run_grade("qwen2.5-coder:1.5b-base")
        s, _ = self.scores()
        self.assertEqual(s[("qwen2.5-coder:1.5b-base", "fim")], "ok")
        self.assertNotIn(("qwen2.5-coder:1.5b-base", "cxx"), s)

    def test_pending_waits_while_a_chat_model_is_in_use_then_grades_and_says_so(self):
        state = self.home / ".local/state/fox-llm-update"
        state.mkdir(parents=True)
        (state / "grade-pending.txt").write_text("qwen3.5:9b\nnot-downloaded:1b\n")
        FakeRouter.loaded.add("qwen3.5:4b")                                     # the quick model is in use
        self.assertIn("waiting: qwen3.5:4b is in use", self.run_grade("--pending"))
        self.assertEqual((state / "grade-pending.txt").read_text(), "qwen3.5:9b\n")   # a model not there: dropped
        self.assertEqual(self.scores()[1], [])
        FakeRouter.loaded.discard("qwen3.5:4b")
        self.run_grade("--pending")
        self.assertEqual((state / "grade-pending.txt").read_text(), "")
        self.assertIn(("qwen3.5:9b", "cxx"), self.scores()[0])
        self.assertIn("Model graded", (self.tmp / "notify.log").read_text())

    def test_queue_lists_the_model_and_starts_a_background_run(self):
        self.run_grade("--queue", "qwen3.5:9b")
        self.run_grade("--queue", "qwen3.5:9b")                                # listed once
        self.assertEqual((self.home / ".local/state/fox-llm-update/grade-pending.txt").read_text(), "qwen3.5:9b\n")
        runs = (self.tmp / "run.log").read_text().splitlines()
        self.assertEqual(len(runs), 2)
        self.assertIn("--unit=fox-llm-grade", runs[0])
        self.assertIn("--nice=19", runs[0])                                     # never ahead of her editor
        self.assertTrue(runs[0].endswith("--pending"))

    def test_report_suggests_but_never_switches_a_role(self):
        self.run_grade("qwen3.5:9b")
        roles = (self.home / ".config/foxml/llm/roles.conf").read_text()
        out = self.run_grade("--report")
        self.assertIn("qwen3.5:9b", out)
        self.assertIn("the quick role would be qwen3.5:9b (now qwen3.5:4b)", out)      # 4/5 = 80 % passes the bar
        self.assertEqual((self.home / ".config/foxml/llm/roles.conf").read_text(), roles)


if __name__ == "__main__":
    unittest.main(verbosity=1)
