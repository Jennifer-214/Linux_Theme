#!/usr/bin/env python3
"""tests/test_deploy_lists.py — what the installer deploys stays coherent.

- No shared/bin script is named like a tool a src/<tool> Makefile builds. specials' bulk copy puts shared/bin into
  ~/.local/bin, so such a script landed over the compiled binary (installer audit 2026-10-15: fox, fox-vault and
  fox-ai-review). core/built_tools.hpp skips them at install time; this keeps them out of the repo.
"""
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The same rule as core/built_tools.hpp: a Makefile's first `BIN = name` / `BIN := name` line.
BIN_RE = re.compile(r"^[ \t]*BIN[ \t]*:?=[ \t]*([^\s#]+)", re.M)


def built_tools():
    names = {}
    for mk in sorted((ROOT / "src").glob("*/Makefile")):
        m = BIN_RE.search(mk.read_text())
        if m:
            names[m.group(1)] = mk.parent.name
    return names


class DeployListsTest(unittest.TestCase):
    def test_no_shared_bin_script_shadows_a_built_tool(self):
        built = built_tools()
        self.assertIn("fox", built)
        self.assertEqual(built.get("fox-render-fast"), "fox-render")
        clashes = sorted(f"shared/bin/{n} vs src/{built[n]}" for n in os.listdir(ROOT / "shared/bin") if n in built)
        self.assertEqual(clashes, [], "a shared/bin script named like a compiled tool would be copied over it")


if __name__ == "__main__":
    unittest.main(verbosity=2)
