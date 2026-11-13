#!/usr/bin/env python3
"""Run only the tests for what changed: `make test-fast`.

Chooses Python tests that name changed files and affected components' native test targets. A tree that moves during
the run is inconclusive, including when its tests pass. The full run is `make test`.

Usage: tests/run_changed.py [--since REV] [--list]
  no argument   what differs from the last commit (tracked and untracked); a clean tree means the last commit itself
  --since REV   everything changed since REV as well
  --list        only say which tests would run
"""
import argparse
import hashlib
from pathlib import Path
import re
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


def git(*args, optional=False):
    ran = subprocess.run(['git', '--no-optional-locks', '-C', str(ROOT), *args], capture_output=True, text=True)
    if ran.returncode and not optional:
        raise RuntimeError(ran.stderr.strip() or 'Git could not read the checkout.')
    return ran.stdout if ran.returncode == 0 else ''


def changed_files(since=None):
    head = git('rev-parse', '--verify', '--quiet', 'HEAD', optional=True).strip()
    files = set(git('diff', '--name-only', '-z', *(['HEAD'] if head else [])).split('\0'))
    if not head:
        files |= set(git('diff', '--cached', '--name-only', '-z').split('\0'))
    files |= set(git('ls-files', '--others', '--exclude-standard', '-z').split('\0'))
    files.discard('')
    if since:
        revision = git('rev-parse', '--verify', '--end-of-options', since + '^{commit}').strip()
        files |= set(git('diff', '--name-only', '-z', f'{revision}...HEAD').split('\0'))
    if not files and not since and head:
        parent = git('rev-parse', '--verify', '--quiet', 'HEAD~1', optional=True).strip()
        files = set((git('diff', '--name-only', '-z', parent, head) if parent
                     else git('ls-tree', '-r', '--name-only', '-z', head)).split('\0'))
    return sorted(files - {''})


def native_targets(changed):
    """Run a component's own test recipe, including its C++ and shell tests and shared-library dependents."""
    makefiles = {str(p.parent.relative_to(ROOT)): p.read_text() for p in ROOT.glob('src/*/Makefile')}
    affected = {'/'.join(Path(p).parts[:2]) for p in changed if p.startswith('src/')}
    if 'Makefile' in changed:
        affected |= set(makefiles)
    sources = {}
    for folder in makefiles:
        sources[folder] = '\n'.join(p.read_text(errors='replace') for p in (ROOT / folder / 'tests').rglob('*')
                                    if p.is_file() and p.suffix in {'.cpp', '.hpp', '.py', '.sh', '.mjs'})
    affected |= set(choose(changed, sources))
    while True:
        dependents = {folder for folder, source in makefiles.items()
                      if any('../' + Path(dep).name in source for dep in affected)}
        if dependents <= affected:
            break
        affected |= dependents
    return sorted(folder for folder in affected if re.search(r'^test\s*:', makefiles.get(folder, ''), re.M))


def fingerprint(files):
    seen = hashlib.sha256(git('status', '--porcelain', '-z', '--untracked-files=all').encode()
                          + git('rev-parse', '--verify', 'HEAD', optional=True).encode())
    for name in files:
        try:
            seen.update(name.encode())
            with (ROOT / name).open('rb') as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    seen.update(chunk)
        except OSError:
            seen.update(f'{name}:gone'.encode())
    return seen.hexdigest()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--since', metavar='REV')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args(argv)
    try:
        changed = changed_files(args.since)
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 2
    tests = {str(p.relative_to(ROOT)): p.read_text(errors='replace')
             for p in sorted(ROOT.glob('tests/test_*.py')) + sorted(ROOT.glob('src/*/tests/test_*.py'))}
    chosen = choose(changed, tests)
    native = native_targets(changed)
    # Component recipes already run their Python tests.
    chosen = [p for p in chosen if not any(p.startswith(folder + '/') for folder in native)]
    print(f'{len(changed)} changed files · {len(chosen)} Python test files · {len(native)} component test targets', flush=True)
    if args.list:
        print('\n'.join('  ' + t for t in chosen))
        for folder in native:
            print('  make -C ' + folder + ' test')
        return 0
    if not chosen and not native:
        print('No test names what changed. `make test` runs everything.')
        return 0
    before = fingerprint(changed)
    if any(name.startswith('src/') for name in changed):
        built = subprocess.run(['make', '-s'], cwd=ROOT, capture_output=True, text=True)
        if built.returncode != 0:
            print('the build failed:\n' + (built.stdout + built.stderr)[-2000:])
            return 1
    failed = []
    commands = [(test, [sys.executable, '-B', test]) for test in chosen]
    commands += [(folder + ' test', ['make', '--no-print-directory', '-C', folder, 'test']) for folder in native]
    for test, command in commands:
        ran = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        print(('  ok      ' if ran.returncode == 0 else '  FAILED  ') + test, flush=True)
        if ran.returncode != 0:
            failed.append(test)
            print('\n'.join('      ' + line for line in (ran.stdout + ran.stderr).strip().splitlines()[-12:]))
    moved = fingerprint(changed) != before
    if moved:
        print('Files changed while the tests ran: these results do not cover a single version. Run again on a still tree.')
    print(f'{len(commands) - len(failed)} passed · {len(failed)} failed' + (' · tree moved during the run' if moved else ''))
    return 3 if moved else 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
