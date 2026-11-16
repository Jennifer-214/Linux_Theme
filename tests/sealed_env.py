"""The one sealed environment for a test that starts Neovim, tmux, Quickshell or the desktop's scripts.

What a test starts with environment(base) gets none of the running session's addresses (LIVE: tmux, a parent Neovim,
Hyprland, Wayland, X, the session bus, kitty, sway, the SSH agent, Qt's GTK theme) and folders of its own under
base/seal: state, cache, runtime (where Neovim makes its server socket), tmux's socket folder, Neovim's log, and a
HOME with its own config and data folders. keep_home=True leaves HOME and XDG_DATA_HOME as they are, for a test whose
Neovim reads installed plugins or parsers from where Neovim keeps them; never for one that starts tmux or a desktop
script (they read their config from HOME).

Every process started with it carries the run's mark (MARK, in its environment), so stop(env) ends each one still
running, also one that left its parent's process group (the server of a terminal Neovim does). sealed() does both: a
temporary folder with the environment in it, and at the end every marked process stopped before the folder goes.
"""
import contextlib
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import tempfile
import time

LIVE = ('TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY', 'DISPLAY',
        'DBUS_SESSION_BUS_ADDRESS', 'KITTY_LISTEN_ON', 'KITTY_WINDOW_ID', 'SWAYSOCK', 'SSH_AUTH_SOCK',
        # Qt's GTK platform theme opens the X display and asks the desktop portal over the session bus.
        'QT_QPA_PLATFORMTHEME', 'QT_GUI_GTK_JSON')
MARK = 'DESK_TEST_SEAL'
# With no address at all a program looks for the bus in the runtime folder or starts one (D-Bus autolaunch).
NO_BUS = 'unix:path=/nonexistent'


def environment(base, *, keep_home=False, **more):
    """os.environ without LIVE, with the folders a program writes to by itself under base/seal; then `more` (a value
    of None removes that variable)."""
    seal = Path(base) / 'seal'
    folders = {'XDG_STATE_HOME': 'state', 'XDG_CACHE_HOME': 'cache', 'XDG_RUNTIME_DIR': 'run', 'TMUX_TMPDIR': 'tmux',
               'XDG_CONFIG_HOME': 'config'}
    if not keep_home:
        folders.update(HOME='home', XDG_DATA_HOME='home/.local/share')
    env = {name: value for name, value in os.environ.items() if name not in LIVE}
    for name, folder in folders.items():
        (seal / folder).mkdir(mode=0o700, parents=True, exist_ok=True)
        env[name] = str(seal / folder)
    env.update(DBUS_SESSION_BUS_ADDRESS=NO_BUS, NVIM_LOG_FILE=str(seal / 'nvim.log'))
    env[MARK] = secrets.token_hex(8)
    for name, value in more.items():
        if value is None:
            env.pop(name, None)
        else:
            env[name] = str(value)
    return env


def running(env):
    """The processes still running with env's mark (a zombie has no environment left, so it is not one)."""
    mark = f'{MARK}={env[MARK]}'.encode()
    found = []
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            with open(f'/proc/{entry.name}/environ', 'rb') as f:
                if mark in f.read().split(b'\0'):
                    found.append(int(entry.name))
        except OSError:
            continue
    return found


def stop(env, wait=5):
    """Kill every process still running with env's mark; it is an error when one is still there after `wait` s.
    A process in the middle of an exec shows no environment for a moment, so only two empty looks in a row end it."""
    deadline, empty = time.monotonic() + wait, 0
    while empty < 2:
        alive = running(env)
        empty = 0 if alive else empty + 1
        if alive and time.monotonic() > deadline:
            raise RuntimeError(f'processes the test started outlived it: {alive}')
        for pid in alive:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.02)


@contextlib.contextmanager
def sealed(prefix, **options):
    """(env, folder): a temporary folder with environment(folder, **options) in it. At the end every process still
    running with the env's mark is stopped, then the folder is removed."""
    with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
        env = environment(tmp, **options)
        try:
            yield env, Path(tmp)
        finally:
            stop(env)


def run(args, env, timeout, sandboxes=None, **options):
    """subprocess.run with its output captured as text. Past its timeout it is killed and this returns what it printed
    until then, exit code 124 and a last line saying so (subprocess.run's TimeoutExpired drops that output).
    sandboxes: (folder, glob) naming the folders the program makes for itself and removes as it ends (a Lua test's
    sandbox under tests/); after a timeout, what it started is stopped and a sandbox it left removed."""
    before = set(sandboxes[0].glob(sandboxes[1])) if sandboxes else set()
    try:
        return subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout, **options)
    except subprocess.TimeoutExpired as stuck:
        if sandboxes:
            stop(env)
            for left in set(sandboxes[0].glob(sandboxes[1])) - before:
                shutil.rmtree(left, ignore_errors=True)
        out, err = (part.decode(errors='replace') if isinstance(part, bytes) else part or '' for part in (stuck.stdout, stuck.stderr))
        return subprocess.CompletedProcess(args, 124, out, err + f'\n(still running after {timeout} s: stopped)\n')
