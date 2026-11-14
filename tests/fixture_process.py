"""Keep disposable editors and their helpers inside an owned process group."""
import os
from pathlib import Path
import signal
import subprocess
import time


def start(args, **options):
    child = subprocess.Popen(args, start_new_session=True, **options)
    child.fixture_group = child.pid
    return child


def _live_group(group):
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry/'stat').read_text()
            fields = stat[stat.rfind(')')+2:].split()
            if fields[0] not in ('Z', 'X') and int(fields[2]) == group and int(fields[3]) == group:
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def stop(child):
    if getattr(child, 'fixture_group', None) != child.pid:
        raise ValueError('Only processes created by this fixture owner can be stopped')
    try:
        os.killpg(child.fixture_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait(timeout=5)
    deadline = time.monotonic()+5
    while _live_group(child.fixture_group):
        if time.monotonic() >= deadline:
            raise RuntimeError('A fixture helper did not exit before temporary-home cleanup')
        time.sleep(.01)
    for pipe in (child.stdin, child.stdout, child.stderr):
        if pipe is not None:
            pipe.close()


def run(args, *, input=None, capture_output=False, timeout=None, check=False, **options):
    if capture_output:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if input is not None:
        options['stdin'] = subprocess.PIPE
    child = start(args, **options)
    try:
        stdout, stderr = child.communicate(input, timeout=timeout)
        result = subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
    finally:
        stop(child)
    if check:
        result.check_returncode()
    return result
