#!/usr/bin/env python3
"""tests/test_deploy_lists.py — what the installer deploys stays coherent.

- No shared/bin script is named like a tool a src/<tool> Makefile builds. specials' bulk copy puts shared/bin into
  ~/.local/bin, so such a script landed over the compiled binary (installer audit 2026-10-15: fox, fox-vault and
  fox-ai-review). core/built_tools.hpp skips them at install time; this keeps them out of the repo.
- mappings.sh (update.sh captures through it) and symlinks_data.hpp (the installer deploys through it) list the
  same rows, every row's source exists, and every pi extension has a row. The audit found fzf-tab.zsh deployed but
  never captured, and pob / fox-word-count captured but deployed only by the bulk copy.
"""
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The same rule as core/built_tools.hpp: a Makefile's first `BIN = name` / `BIN := name` line.
BIN_RE = re.compile(r"^[ \t]*BIN[ \t]*:?=[ \t]*([^\s#]+)", re.M)

# Rows one list has on purpose and the other doesn't: {(array, src, dest): why}. None today.
ONE_SIDED = {}


def sh_rows(name):
    text = (ROOT / "mappings.sh").read_text()
    m = re.search(name + r"=\((.*?)\n\)", text, re.S)
    rows = set()
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith('"'):
            src, dest = line.strip('"').split("|", 1)
            rows.add((src, dest))
    return rows


def hpp_rows(name):
    text = (ROOT / "src/fox-install/modules/symlinks_data.hpp").read_text()
    m = re.search(name + r"\[\] = \{(.*?)\n\};", text, re.S)
    return set(re.findall(r'\{\s*"([^"]+)",\s*"([^"]+)"\s*\}', m.group(1)))


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

    def test_mappings_sh_and_symlinks_data_agree(self):
        for name in ("TEMPLATE_MAPPINGS", "SHARED_MAPPINGS"):
            sh, hpp = sh_rows(name), hpp_rows(name)
            self.assertGreater(len(hpp), 20, name)
            only_sh = sorted(r for r in sh - hpp if (name, *r) not in ONE_SIDED)
            only_hpp = sorted(r for r in hpp - sh if (name, *r) not in ONE_SIDED)
            self.assertEqual(only_sh, [], f"{name}: in mappings.sh only (update.sh captures, the installer never deploys)")
            self.assertEqual(only_hpp, [], f"{name}: in symlinks_data.hpp only (deployed, never captured by update.sh)")

    def test_every_row_has_its_source(self):
        for name, base in (("TEMPLATE_MAPPINGS", "templates"), ("SHARED_MAPPINGS", "shared")):
            missing = sorted(src for src, _ in hpp_rows(name) | sh_rows(name) if not (ROOT / base / src).exists())
            self.assertEqual(missing, [], f"{name}: rows whose {base}/ source is gone")

    def test_every_pi_extension_has_a_row(self):
        want = {(f"pi/extensions/{p.name}", f"~/.pi/agent/extensions/{p.name}")
                for p in (ROOT / "shared/pi/extensions").glob("*.ts")}
        self.assertTrue(want)
        self.assertEqual(sorted(want - hpp_rows("SHARED_MAPPINGS")), [], "pi extensions the installer never deploys")
        self.assertEqual(sorted(want - sh_rows("SHARED_MAPPINGS")), [], "pi extensions update.sh never captures")


if __name__ == "__main__":
    unittest.main(verbosity=2)
