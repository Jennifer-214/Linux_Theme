"""Exercise session handoff and native hotplug dispatch without real displays."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MonitorSession(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.monitor-session-', dir=ROOT / 'tests')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.trace = self.home / 'calls'
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.env = os.environ | {'HOME': str(self.home), 'TRACE': str(self.trace),
                                  'XDG_RUNTIME_DIR': str(self.home / 'run'),
                                  'PATH': str(self.bin) + ':' + os.environ['PATH']}

    def script(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def test_session_import_precedes_watcher_restart(self):
        self.script(self.bin / 'systemctl', 'printf "%s\\n" "$*" >> "$TRACE"')
        self.script(self.bin / 'dbus-update-activation-environment', 'exit 0')
        self.script(self.bin / 'dbus-launch', 'exit 0')
        result = subprocess.run(['bash', str(ROOT / 'shared/hyprland_scripts/env-init.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.trace.read_text().splitlines()
        self.assertIn('HYPRLAND_INSTANCE_SIGNATURE', calls[0])
        self.assertEqual(calls[1], '--user try-restart fox-pulse.service')

    def test_monitor_events_use_one_shot_native_handler(self):
        self.script(self.home / '.local/bin/fox-monitor', 'printf "native %s\\n" "$*" >> "$TRACE"')
        self.script(self.home / '.config/hypr/scripts/fox-monitor-watch.sh', 'echo legacy >> "$TRACE"')
        self.script(self.home / '.config/foxml/pulse.d/focus.sh', 'exit 0')
        path = self.home / 'run/hypr/test/.socket2.sock'
        path.parent.mkdir(parents=True)
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(path))
            server.listen()
            server.settimeout(3)
            proc = subprocess.Popen([str(ROOT / 'src/fox-pulse/fox-pulse')],
                                    env=self.env | {'HYPRLAND_INSTANCE_SIGNATURE': 'test'},
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                conn, _ = server.accept()
                with conn:
                    conn.sendall(b'monitoradded>>DP-2\nmonitoraddedv2>>1,DP-2,Acer\n')
                    end = time.monotonic() + 4
                    while not self.trace.exists() and time.monotonic() < end:
                        time.sleep(.02)
                    self.assertTrue(self.trace.exists(), 'monitor handler did not run')
                    self.assertEqual(self.trace.read_text().splitlines(), ['native reconcile'])
            finally:
                proc.terminate()
                proc.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
