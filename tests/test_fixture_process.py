"""Fixture cleanup stops only owned descendants, including after a timeout."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from fixture_process import run

WRITER = "import pathlib,time,sys; p=pathlib.Path(sys.argv[1]); exec('while True:\\n p.write_text(str(time.monotonic()))\\n time.sleep(.005)')"


class FixtureProcess(unittest.TestCase):
    def exercise(self, timeout):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder)/'writes'
            sibling = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            try:
                script = ('import subprocess,sys,pathlib,time; '
                    'subprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); '
                    'p=pathlib.Path(sys.argv[2]); '
                    'exec("while not p.exists():\\n time.sleep(.005)"); '
                    'print("ready",flush=True); '+('time.sleep(30)' if timeout else 'sys.exit(0)'))
                args = [sys.executable, '-c', script, WRITER, str(marker)]
                if timeout:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        run(args, capture_output=True, text=True, timeout=2)
                else:
                    result = run(args, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), 'ready')
                before = marker.read_text()
                time.sleep(.05)
                self.assertEqual(marker.read_text(), before, 'an owned helper kept writing after the fixture returned')
                self.assertIsNone(sibling.poll(), 'cleanup touched a process outside its owned session')
            finally:
                sibling.terminate(); sibling.wait(timeout=5)

    def test_success_waits_for_owned_helpers_without_touching_a_sibling(self):
        self.exercise(False)

    def test_timeout_also_stops_owned_helpers(self):
        self.exercise(True)

    def test_failures_keep_the_original_exit_code_and_output(self):
        args = [sys.executable, '-c', 'import sys; print("fixture failure"); sys.exit(7)']
        with self.assertRaises(subprocess.CalledProcessError) as error:
            run(args, capture_output=True, text=True, check=True)
        self.assertEqual(error.exception.returncode, 7)
        self.assertIn('fixture failure', error.exception.stdout)


if __name__ == '__main__': unittest.main()
