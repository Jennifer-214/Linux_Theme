#!/usr/bin/env python3
"""tests/test_fox_budget.py — run the fox-budget pi extension under node with a fake pi.

A fake llama-tokenize (one token per word), a fake GGUF for qwen3.5:4b and a fake fox-llm-grade row make every number
in the report known. fox-budget has only a type import from pi, so plain node ≥ 22 runs it. Skips (passes) when node is
missing or too old.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

node = shutil.which("node")
if not node:
    print("    skip: node not installed")
    sys.exit(0)
major = int(subprocess.run([node, "--version"], capture_output=True, text=True).stdout.lstrip("v").split(".")[0])
if major < 22:
    print(f"    skip: node {major} has no --experimental-strip-types")
    sys.exit(0)
# Not /tmp: the noexec_tmp module mounts it noexec, and the fake tokenizer has to run
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="fox-budget-test-", dir=base))
try:
    (tmp / "data/fox-llm/gguf").mkdir(parents=True)
    (tmp / "data/fox-llm/gguf/qwen3.5:4b.gguf").write_bytes(b"GGUF")
    (tmp / "state/fox-llm-update").mkdir(parents=True)
    (tmp / "state/fox-llm-update/grades.tsv").write_text(
        "2026-10-14T09:00\t11429\tqwen3.5:4b\tsize:1\tread_tps\t120\n"
        "2026-10-15T09:00\t11429\tqwen3.5:4b\tsize:1\tread_tps\t150\n")
    tok = tmp / "llama-tokenize"
    tok.write_text('#!/bin/sh\nn=$(wc -w | tr -d " ")\necho "[1, 2]"\necho "Total number of tokens: $n"\n')
    tok.chmod(0o755)
    shutil.copy(ROOT / "shared/pi/extensions/fox-budget.ts", tmp / "fox-budget.ts")
    env = dict(os.environ, XDG_DATA_HOME=str(tmp / "data"), XDG_STATE_HOME=str(tmp / "state"), FOX_LLAMA_TOKENIZE=str(tok))
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-budget-test.mjs"), str(tmp / "fox-budget.ts")],
                       capture_output=True, text=True, env=env)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-2000:] + r.stderr[-800:] if r.returncode else "    fox-budget: " + r.stdout.strip().splitlines()[-1])
sys.exit(r.returncode)
