"""tests/sealed_env.py, the sealed environment of every runner that starts Neovim, tmux, Quickshell or a desktop script:
none of the session's addresses get through, a process that left its group is still stopped, and a run past its
timeout keeps what it printed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import sealed_env

OWN = ('XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR', 'TMUX_TMPDIR', 'XDG_CONFIG_HOME', 'NVIM_LOG_FILE')


class SealedEnv(unittest.TestCase):
    def test_none_of_the_session_gets_through(self):
        session = {name: f'/run/user/1000/{name.lower()}' for name in sealed_env.LIVE}
        with mock.patch.dict(os.environ, session), tempfile.TemporaryDirectory() as tmp:
            env = sealed_env.environment(tmp, EXTRA='kept', LANG=None)
            home = sealed_env.environment(tmp, keep_home=True)
        for name in sealed_env.LIVE:
            self.assertEqual(env.get(name), sealed_env.NO_BUS if name == 'DBUS_SESSION_BUS_ADDRESS' else None, name)
        for name in OWN + ('HOME', 'XDG_DATA_HOME'):
            self.assertTrue(env[name].startswith(tmp + '/seal/'), name)
        self.assertEqual((env['EXTRA'], 'LANG' in env), ('kept', False))
        self.assertEqual(home['HOME'], os.environ['HOME'], 'keep_home leaves HOME')
        self.assertEqual(home.get('XDG_DATA_HOME'), os.environ.get('XDG_DATA_HOME'), '… and the data folder')
        for name in OWN:
            self.assertTrue(home[name].startswith(tmp + '/seal/'), name)

    def test_a_process_that_left_its_group_is_stopped(self):
        # As a terminal Neovim's server does: a session of its own, and its parent gone.
        with sealed_env.sealed('seal-test-') as (env, base):
            subprocess.run(['sh', '-c', 'setsid sleep 300 & echo $! > "$1"', 'sh', str(base / 'pid')], env=env, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pid = int((base / 'pid').read_text())
            # (in the middle of its exec it shows no environment for a moment)
            deadline = time.monotonic() + 5
            while sealed_env.running(env) != [pid] and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(sealed_env.running(env), [pid])
        self.assertEqual(sealed_env.running(env), [])
        stat = Path(f'/proc/{pid}/stat')
        self.assertTrue(not stat.exists() or stat.read_text().rsplit(')', 1)[1].split()[0] in 'ZX', 'it still runs')

    def test_a_run_past_its_timeout_keeps_its_output_and_leaves_no_sandbox(self):
        with sealed_env.sealed('seal-test-') as (env, base):
            parent = base / 'tests'
            parent.mkdir()
            script = 'import os, sys, time; os.mkdir(sys.argv[1] + "/poAbCdEf"); print("so far", flush=True); time.sleep(60)'
            ran = sealed_env.run([sys.executable, '-c', script, str(parent)], env, 1, sandboxes=(parent, 'po??????'))
            self.assertEqual(sealed_env.running(env), [])
            self.assertEqual(list(parent.iterdir()), [], 'the sandbox it made')
        self.assertEqual(ran.returncode, 124)
        self.assertIn('so far', ran.stdout)
        self.assertIn('still running after 1 s', ran.stderr)


if __name__ == '__main__':
    unittest.main()
