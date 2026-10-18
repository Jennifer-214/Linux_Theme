#!/usr/bin/env python3
"""tests/test_pi_launcher.py — shared/bin/pi, the launcher that stops pi's context files at the project.

Live leg (node ≥ 22 and pi installed): pi in RPC mode in a scratch HOME and agent folder, run from a git project with a
CLAUDE.md in each of two folders above it. A probe extension reads the context files from the system prompt at session
start (one <project_instructions path=…> per file) and ends pi — no model, no network. Through the launcher: pi's global
file and the project's own, nothing else; through plain pi, the two above as well (the control: the tree exercises the
rule). The control is the REAL pi, found by its package — never `which pi`, which is the launcher once it is deployed.
Fallback leg (node only — a FAKE pi package): a pi with no DefaultResourceLoader, and a pi whose code throws while
loading — each named in one line on stderr, then pi's own entry runs in this process with the same arguments and its
exit code; the launcher never takes itself for pi; no pi on PATH → 127, said.
Skips (passes) without node ≥ 22; the live leg also without pi — per testing discipline.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "shared/bin/pi"
PKG = "@earendil-works/pi-coding-agent"

node = shutil.which("node")
if not node:
    print("    skip: node not installed")
    sys.exit(0)
if int(subprocess.run([node, "--version"], capture_output=True, text=True).stdout.lstrip("v").split(".")[0]) < 22:
    print("    skip: node is older than 22 (no TypeScript import)")
    sys.exit(0)

fails = 0


def check(ok, what):
    global fails
    fails += 0 if ok else 1
    print(("    ok   " if ok else "    FAIL ") + what)


def real_pi():
    """The installed pi's entry: the first `pi` on PATH whose real path lies inside pi's own package."""
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = Path(d or ".") / "pi"
        if not cand.exists():
            continue
        entry = cand.resolve()
        for up in entry.parents:
            try:
                if json.loads((up / "package.json").read_text()).get("name") == PKG:
                    return entry
            except (OSError, ValueError):
                continue
    return None


def put(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


check(os.access(LAUNCHER, os.X_OK), "the launcher is executable (the installer copies its mode)")
base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))  # not /tmp: the noexec_tmp module
base.mkdir(parents=True, exist_ok=True)
tmp = Path(tempfile.mkdtemp(prefix="pi-launcher-test-", dir=base))
try:
    home, agent = tmp / "home", tmp / "home/.pi/agent"
    put(agent / "extensions/fox-scope.ts", (ROOT / "shared/pi/extensions/fox-scope.ts").read_text())
    env0 = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(agent))
    selfbin = tmp / "selfbin"  # the launcher reached through PATH, as when deployed: it must skip itself
    selfbin.mkdir()
    (selfbin / "pi").symlink_to(LAUNCHER)

    # ── live: the context files pi's own loader gives the session ──
    pi = real_pi()
    if not pi:
        print("    skip (live leg): pi not installed")
    else:
        tree = tmp / "tree"
        proj = tree / "code/proj"
        (proj / ".git").mkdir(parents=True)
        for f in (agent / "AGENTS.md", tree / "CLAUDE.md", tree / "code/CLAUDE.md", proj / "AGENTS.md"):
            put(f, f"instructions in {f.relative_to(tmp)}\n")
        put(tmp / "probe.ts", """import { writeFileSync } from "node:fs";
export default function (pi: any) {
	pi.on("session_start", (_e: any, ctx: any) => {
		const paths = [...ctx.getSystemPrompt().matchAll(/<project_instructions path="([^"]+)"/g)].map((m) => m[1]);
		writeFileSync(process.env.PROBE_OUT!, paths.join("\\n"));
		process.exit(0);
	});
}
""")

        def files(argv, out):
            env = dict(env0, PROBE_OUT=str(tmp / out), PATH=f"{selfbin}{os.pathsep}{os.environ.get('PATH', '')}")
            r = subprocess.run([node, *argv, "--mode", "rpc", "-ne", "--no-session", "-e", str(tmp / "probe.ts")],
                               cwd=proj, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            got = (tmp / out).read_text().splitlines() if (tmp / out).exists() else []
            return r, {str(Path(p).resolve().relative_to(tmp)) if Path(p).resolve().is_relative_to(tmp) else p for p in got}

        r, mine = files([str(LAUNCHER)], "launched.txt")
        check(mine == {"home/.pi/agent/AGENTS.md", "tree/code/proj/AGENTS.md"},
              f"through the launcher: pi's global file and the project's own — nothing above it: {sorted(mine)}")
        check("pi launcher:" not in r.stderr, "…and no fallback taken: " + (r.stderr.strip()[:160] or "(quiet)"))
        r, plain = files([str(pi)], "plain.txt")
        check({"tree/CLAUDE.md", "tree/code/CLAUDE.md"} <= plain and mine < plain,
              f"the control — plain pi on the same tree also reads the folders above: {sorted(plain)}")

    # ── fallback: a fake pi, each way the launcher cannot apply its rule ──
    fake, fakebin = tmp / "fakepi", tmp / "fakebin"
    put(fake / "package.json", json.dumps({"name": PKG, "type": "module"}))  # as pi's own: its code is ES modules
    put(fake / "dist/bundle/cli.js", 'import { writeFileSync } from "node:fs";\n'
        'writeFileSync(process.env.FAKE_OUT, JSON.stringify(process.argv.slice(2)));\nprocess.exit(7);\n')
    put(fake / "dist/cli/setup.js", "export function setupCli() {}\n")
    fakebin.mkdir()
    (fakebin / "pi").symlink_to(fake / "dist/bundle/cli.js")

    def launch(index_js, path, out):
        put(fake / "dist/index.js", index_js)
        env = dict(env0, FAKE_OUT=str(tmp / out), PATH=path)
        r = subprocess.run([node, str(LAUNCHER), "a", "b c"], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=60)
        ran = json.loads((tmp / out).read_text()) if (tmp / out).exists() else None
        return r, ran

    path = os.pathsep.join([str(selfbin), str(fakebin)])
    for name, index_js, why in (
        ("a pi with no DefaultResourceLoader", "export async function main() {}\n", "pi's DefaultResourceLoader has no reload()"),
        ("a pi whose code throws while loading", 'throw new Error("planted failure while loading");\n', "planted failure while loading"),
    ):
        r, ran = launch(index_js, path, name.replace(" ", "_") + ".json")
        lines = [ln for ln in r.stderr.splitlines() if ln.startswith("pi launcher:")]
        check(len(lines) == 1 and why in lines[0] and "running plain pi" in lines[0],
              f"{name}: one line names it — {lines or r.stderr.strip()[:200]}")
        check(ran == ["a", "b c"] and r.returncode == 7,
              f"…and pi's own entry ran, here, with the same arguments and its exit code: {ran}, rc {r.returncode}")
    full = ("export async function main() {}\nexport class DefaultResourceLoader { reload() {} }\n")
    env0["PI_CODING_AGENT_DIR"] = str(tmp / "no-agent")  # fox-scope.ts missing: the rule has nowhere to come from
    r, ran = launch(full, path, "no_fox_scope.json")
    lines = [ln for ln in r.stderr.splitlines() if ln.startswith("pi launcher:")]
    check(len(lines) == 1 and "fox-scope.ts" in lines[0] and ran == ["a", "b c"] and r.returncode == 7,
          f"no fox-scope.ts in pi's agent folder: named, and plain pi ran — {lines or r.stderr.strip()[:200]}")
    env0["PI_CODING_AGENT_DIR"] = str(agent)
    r, ran = launch("export async function main() {}\n", str(selfbin), "none.json")
    check(r.returncode == 127 and "no installed pi on PATH" in r.stderr and ran is None,
          f"no pi on PATH but the launcher itself: 127, said — rc {r.returncode}: {r.stderr.strip()[:120]}")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print("    pi launcher: " + ("all passed" if not fails else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
