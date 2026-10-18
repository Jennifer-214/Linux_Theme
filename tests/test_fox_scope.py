#!/usr/bin/env python3
"""tests/test_fox_scope.py — run the fox-scope pi extension under node against a scratch folder tree.

fox-scope is TypeScript with only a type import from pi, so plain node ≥ 22 runs it (--experimental-strip-types)
without pi installed. Skips (passes) when node is missing or too old, per testing discipline.

Then a type-check against pi's own types (2026-10-17): pi strips an extension's types without checking them, so a call
to a method pi does not provide ran until pi's start crashed on it — the startup notice called getSystemPromptOptions,
which only a /command's context has. TypeScript 5 checks fox-scope against the installed pi's .d.ts, mapped for BOTH
package names pi aliases: the fox extensions import the old one, and unmapped every pi type is `any`, so the check
passes over anything. Its own control first — the bad call planted back into a copy must be refused, or the check
cannot see pi's types. Skips (passes) when tsc 5, pi or pi's node types are missing.
"""
import json
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
# Not /tmp: the noexec_tmp module mounts it noexec
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="fox-scope-test-", dir=base))


def type_check(tmp):
    """'' when fox-scope type-checks against pi's types; else what failed — or 'skip: …'."""
    tsc = shutil.which("tsc")
    if not tsc:
        return "skip: tsc (TypeScript 5) not installed"
    ver = subprocess.run([tsc, "--version"], capture_output=True, text=True).stdout.split()[-1]
    if int(ver.split(".")[0]) < 5:
        return f"skip: tsc {ver} is too old (pi's node types need TypeScript 5)"
    pi = shutil.which("pi")
    if not pi:
        return "skip: pi not installed"
    pkg = Path(pi).resolve().parent
    while pkg != pkg.parent and not (pkg / "package.json").is_file():
        pkg = pkg.parent
    meta = json.loads((pkg / "package.json").read_text()) if (pkg / "package.json").is_file() else {}
    if not meta.get("types") or not (pkg / "node_modules/@types/node").is_dir():
        return f"skip: pi's types or its node types not found under {pkg}"
    types = str(pkg / meta["types"])
    (tmp / "tsconfig.json").write_text(json.dumps({
        "compilerOptions": {"strict": True, "noEmit": True, "target": "es2022", "module": "esnext",
                            "moduleResolution": "bundler", "allowImportingTsExtensions": True, "skipLibCheck": True,
                            "typeRoots": [str(pkg / "node_modules/@types")], "types": ["node"],
                            "paths": {"@mariozechner/pi-coding-agent": [types], "@earendil-works/pi-coding-agent": [types]}},
        "files": ["fox-scope.ts"]}))
    src = (ROOT / "shared/pi/extensions/fox-scope.ts").read_text()
    anchor = 'pi.on("session_start", () => {'
    if src.count(anchor) != 1:
        return f"the control's anchor is gone ({anchor!r}) — re-plant it"
    (tmp / "fox-scope.ts").write_text(src.replace(anchor, 'pi.on("session_start", (_e, ctx) => {\n\t\tctx.getSystemPromptOptions();'))
    c = subprocess.run([tsc, "-p", str(tmp / "tsconfig.json")], capture_output=True, text=True)
    if c.returncode == 0 or "getSystemPromptOptions" not in c.stdout:
        return f"the planted bad call was not refused: the check cannot see pi's types ({pi} → {pkg})\n{c.stdout[-600:]}"
    (tmp / "fox-scope.ts").write_text(src)
    r = subprocess.run([tsc, "-p", str(tmp / "tsconfig.json")], capture_output=True, text=True)
    return "" if r.returncode == 0 else r.stdout[-1500:] + r.stderr[-400:]


try:
    shutil.copy(ROOT / "shared/pi/extensions/fox-scope.ts", tmp / "fox-scope.ts")
    home = tmp / "home"
    home.mkdir()
    env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(home / ".pi/agent"))
    r = subprocess.run([node, "--experimental-strip-types", "--no-warnings",
                        str(ROOT / "tests/fox-scope-test.mjs"), str(tmp / "fox-scope.ts"), str(home)],
                       capture_output=True, text=True, env=env)
    (tmp / "tc").mkdir()
    tc = type_check(tmp / "tc")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(r.stdout[-1500:] + r.stderr[-800:] if r.returncode else "    fox-scope: " + r.stdout.strip().splitlines()[-1])
print("    fox-scope types: " + (tc if tc.startswith("skip") else "match pi's (the planted bad call refused)" if not tc else "FAIL\n" + tc))
sys.exit(r.returncode or (1 if tc and not tc.startswith("skip") else 0))
