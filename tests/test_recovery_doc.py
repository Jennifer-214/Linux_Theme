#!/usr/bin/env python3
"""RECOVERY.md's ways back to port 22 (2026-11-16). Once sshd has moved, the endlessh tarpit holds 22, and sshd put
back on 22 beside it cannot bind: the documented recovery left a tarpit and no sshd. Every block that puts the SSH
wizard's previous config back, or removes it, stops endlessh before it restarts sshd."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DROP_IN = "/etc/ssh/sshd_config.d/50-foxml-hardening.conf"


def blocks(text):
    return re.findall(r"^```[^\n]*\n(.*?)^```", text, re.S | re.M)


class BackTo22(unittest.TestCase):
    def test_the_tarpit_stops_before_sshd_restarts(self):
        back = [b for b in blocks((ROOT / "RECOVERY.md").read_text())
                if f"rm {DROP_IN}" in b or f"{DROP_IN}.foxml-bak {DROP_IN}" in b]
        self.assertGreaterEqual(len(back), 3, "the previous config, no config, and the whole stack backed out")
        for block in back:
            stop, restart = block.find("systemctl disable --now endlessh"), block.find("systemctl restart sshd")
            self.assertTrue(0 <= stop < restart, "endlessh is stopped before sshd restarts:\n" + block)


if __name__ == "__main__":
    unittest.main()
