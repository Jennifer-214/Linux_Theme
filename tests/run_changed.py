#!/usr/bin/env python3
"""Run only the tests for what changed: `make test-fast`.

Chooses the test files that name a changed file (or its tool), builds first when C++ changed, and says so when files
changed while the tests ran, because a failure from a half-edited tree is not a real one. The full run is `make test`.

Usage: tests/run_changed.py [--since REV] [--list]
  no argument   what differs from the last commit (tracked and untracked); a clean tree means the last commit itself
  --since REV   everything changed since REV as well
  --list        only say which tests would run
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
# Folder names too common to say which test covers a file.
COMMON = {'bin', 'tests', 'hooks', 'shared', 'src', 'docs', 'core', 'modules', 'foxml', 'templates', 'types', 'lua', 'scripts', 'themes'}


def handles(path):
    """The words a test would use to name this file: its name, its stem, its tool, a telling folder."""
    parts = Path(path).parts
    name = parts[-1]
    out = {name}
    stem = name.rsplit('.', 1)[0]
    if len(stem) >= 5:
        out.add(stem)
    if len(parts) >= 2 and parts[0] == 'src':
        out.add(parts[1])
    for folder in parts[:-1]:
        if folder not in COMMON and len(folder) >= 5:
            out.add(folder)
    return out


def choose(changed, tests):
    """tests: {path: source}. A test runs when it changed itself or its source names a changed file's handle."""
    chosen = []
    words = set()
    for path in changed:
        words |= handles(path)
    for path, source in sorted(tests.items()):
        if path in changed or any(word in source for word in words):
            chosen.append(path)
    return chosen


def git(*args):
    return subprocess.run(['git', '--no-optional-locks', '-C', str(ROOT), *args], capture_output=True, text=True).stdout


def changed_files(since=None):
    files = set(git('diff', '--name-only', 'HEAD').split()) | set(git('ls-files', '--others', '--exclude-standard').split())
    if since:
        files |= set(git('diff', '--name-only', f'{since}...HEAD').split())
    if not files:
        files = set(git('diff', '--name-only', 'HEAD~1', 'HEAD').split())
    return sorted(files)


def fingerprint(files):
    seen = hashlib.sha256(git('status', '--porcelain').encode() + git('rev-parse', 'HEAD').encode())
    for name in files:
        try:
            seen.update(f'{name}:{os.stat(ROOT / name).st_mtime_ns}'.encode())
        except OSError:
            seen.update(f'{name}:gone'.encode())
    return seen.hexdigest()


def main(argv):
    since = argv[argv.index('--since') + 1] if '--since' in argv and argv.index('--since') + 1 < len(argv) else None
    changed = changed_files(since)
    tests = {str(p.relative_to(ROOT)): p.read_text(errors='replace')
             for p in sorted(ROOT.glob('tests/test_*.py')) + sorted(ROOT.glob('src/*/tests/test_*.py'))}
    chosen = choose(changed, tests)
    print(f'{len(changed)} changed files · {len(chosen)} of {len(tests)} test files chosen')
    if '--list' in argv:
        print('\n'.join('  ' + t for t in chosen))
        return 0
    if not chosen:
        print('No test names what changed. `make test` runs everything.')
        return 0
    before = fingerprint(changed)
    if any(name.startswith('src/') for name in changed):
        built = subprocess.run(['make', '-s'], cwd=ROOT, capture_output=True, text=True)
        if built.returncode != 0:
            print('the build failed:\n' + (built.stdout + built.stderr)[-2000:])
            return 1
    failed = []
    for test in chosen:
        ran = subprocess.run([sys.executable, '-B', test], cwd=ROOT, capture_output=True, text=True)
        print(('  ok      ' if ran.returncode == 0 else '  FAILED  ') + test)
        if ran.returncode != 0:
            failed.append(test)
            print('\n'.join('      ' + line for line in (ran.stdout + ran.stderr).strip().splitlines()[-12:]))
    moved = fingerprint(changed) != before
    if moved:
        print('Files changed while the tests ran: a failure above may not be real. Run again on a still tree.')
    print(f'{len(chosen) - len(failed)} passed · {len(failed)} failed' + (' · tree moved during the run' if moved else ''))
    return 3 if moved and failed else 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
