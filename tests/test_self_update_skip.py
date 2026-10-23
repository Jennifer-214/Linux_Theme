#!/usr/bin/env python3
"""install.sh says why it skipped the self-update (installer batch 3a, finding 20). The installer itself is never run:
the marked block is cut out of install.sh and run on its own in bash, against throwaway git repos — clean on main, dirty,
off main, detached, and without an origin remote."""
import os, pathlib, re, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
text = (ROOT / "install.sh").read_text()
m = re.search(r"    # >>> self-update skip reason.*?\n(.*?)    # <<< self-update skip reason", text, re.S)
fails = []
if not m:
    print("FAIL the marked block is missing from install.sh"); sys.exit(1)
block = m.group(1)

def git(d, *a):
    subprocess.run(["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", *a], check=True, capture_output=True)

def run(setup):
    with tempfile.TemporaryDirectory() as d:
        git(d, "init", "-q", "-b", "main"); pathlib.Path(d, "f").write_text("x\n"); git(d, "add", "f"); git(d, "commit", "-qm", "c")
        git(d, "remote", "add", "origin", "https://example.invalid/r.git")
        setup(d)
        script = ('SCRIPT_DIR="$1"\nbranch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"\n'
                  'dirty="$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -c 1 || echo)"\n' + block)
        r = subprocess.run(["bash", "-c", script, "bash", d], capture_output=True, text=True)
        return r.stderr.strip()

cases = [
    ("clean on main → silent", lambda d: None, ""),
    ("local changes → says so", lambda d: pathlib.Path(d, "f").write_text("y\n"), "local changes"),
    ("off main → names the branch", lambda d: git(d, "checkout", "-qb", "feature"), "on 'feature', not main"),
    ("detached HEAD → says detached", lambda d: git(d, "checkout", "-q", "--detach"), "on a detached HEAD, not main"),
    ("no origin → silent here (install.sh's own line covers it)", lambda d: (git(d, "remote", "remove", "origin"), pathlib.Path(d, "f").write_text("y\n")), ""),
]
for name, setup, want in cases:
    got = run(setup)
    if (want and want not in got) or (not want and got):
        fails.append(f"{name}: got {got!r}")
for f in fails:
    print("FAIL", f)
print("self-update skip reason:", "OK" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
