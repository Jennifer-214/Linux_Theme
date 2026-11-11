#!/usr/bin/env python3
"""tests/test_install_hints.py — the commands the installer tells you to run exist.

Installer audit 2026-10-15: fprint.cpp said `desk fingerprint enroll`, which the compiled fox rejected ("unknown
namespace", exit 2) until the flat commands were routed to desk-legacy. The hints now name the tool itself. This checks
every `desk-fingerprint <sub>` an installer module prints against that script's own command table.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "src/desk-install/modules"
TOOL = ROOT / "shared/bin/desk-fingerprint"


def subcommands(script):
    """The words of the script's top-level `case "${1:-}" in` arms: `enroll)`, `delete|del)`, ..."""
    text = script.read_text()
    body = text[text.index('case "${1:-}" in'):]
    names = set()
    for arm in re.findall(r'^\s{4}([\w|"-]+)\)', body, re.M):
        names.update(a.strip('"') for a in arm.split("|"))
    return names


class InstallHintsTest(unittest.TestCase):
    def test_fingerprint_hints_name_real_subcommands(self):
        subs = subcommands(TOOL)
        self.assertIn("enroll", subs)
        hints = []
        for cpp in sorted(MODULES.glob("*.cpp")):
            for m in re.finditer(r"`desk-fingerprint ([a-z-]+)", cpp.read_text()):
                hints.append((cpp.name, m.group(1)))
        self.assertTrue(any(f == "fprint.cpp" for f, _ in hints), "fprint.cpp should point at desk-fingerprint")
        unknown = [(f, s) for f, s in hints if s not in subs]
        self.assertEqual(unknown, [], "installer hints naming desk-fingerprint subcommands it doesn't have")

    def test_no_hint_relies_on_the_namespace_spelling(self):
        stale = [cpp.name for cpp in sorted(MODULES.glob("*.cpp"))
                 if re.search(r'ui::\w+\([^;]*`desk fingerprint ', cpp.read_text())]
        self.assertEqual(stale, [], "a printed hint says `desk fingerprint …`; name the tool: `desk-fingerprint …`")


if __name__ == "__main__":
    unittest.main(verbosity=2)
