#!/usr/bin/env python3
"""The bar's hand-built JSON stays JSON when free text goes into it. On a fresh install in the test VM, desk theme
check's D5 found custom/overwatch printing a line the bar cannot read: a new listener goes in as "address<TAB>process"
and a raw tab is not allowed inside a JSON string (a quote or a backslash in an alert's text breaks it the same way).
Sealed: a home and runtime folder of its own, stand-in ss, nvidia-smi and notify-send, no session addresses."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
OVERWATCH = ROOT / "shared/waybar_scripts/hw_overwatch.sh"


class Overwatch(unittest.TestCase):
    def setUp(self):
        # Beside the test, not in /tmp: the stand-in commands must be executable, and /tmp may be noexec.
        self.dir = Path(tempfile.mkdtemp(prefix=".fox-bar-json-", dir=Path(__file__).parent))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.bin = self.dir / "bin"
        for sub in ("bin", "home", "run", "data/foxml"):
            (self.dir / sub).mkdir(parents=True)

    def stand_in(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def test_a_new_listener_and_an_alert_with_quotes_stay_json(self):
        self.stand_in("ss", "printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\\n'\n"
                            "printf 'LISTEN 0      128          0.0.0.0:22        0.0.0.0:*    users:((\"sshd\",pid=410,fd=3))\\n'")
        self.stand_in("nvidia-smi", "exit 0")
        self.stand_in("notify-send", "exit 0")
        (self.dir / "data/foxml/alerts.log").write_text(f'{int(time.time())}\tfail2ban\tbanned "203.0.113.9" via C:\\path\n')
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.dir / "home"), "XDG_RUNTIME_DIR": str(self.dir / "run"),
               "XDG_DATA_HOME": str(self.dir / "data"), "FOX_NVIDIA_STATE": str(self.dir / "absent")}
        ran = subprocess.run(["bash", str(OVERWATCH)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        line = ran.stdout.strip().splitlines()[-1]
        module = json.loads(line)   # the bar reads exactly this; a raw tab or quote raises here
        self.assertEqual(module["class"], "alert")
        self.assertIn("sshd", module["tooltip"])
        self.assertIn('"203.0.113.9"', module["tooltip"])


if __name__ == "__main__":
    unittest.main()
