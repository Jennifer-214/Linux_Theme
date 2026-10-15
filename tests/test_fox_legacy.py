#!/usr/bin/env python3
"""tests/test_fox_legacy.py — the flat fox commands once the compiled fox owns ~/.local/bin/fox (installer audit
2026-10-15). The compiled fox hands anything that isn't a namespace to shared/bin/fox-legacy, which keeps the old
meanings (`fox vault` is the pass wrapper fox-pass, not the compiled in-RAM fox-vault) and finds the clone that
`make install` recorded.

Runs the built src/fox/fox and the real fox-legacy with stub fox-* tools, a throwaway $HOME and a PATH the test
controls.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOX = ROOT / "src/fox/fox"
LEGACY = ROOT / "shared/bin/fox-legacy"


def stub(path, body):
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


@unittest.skipUnless(FOX.exists(), "src/fox/fox not built (make)")
class FoxLegacyTest(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-legacy-test-", dir=base))
        self.home, self.bin, self.clone = self.tmp / "home", self.tmp / "bin", self.tmp / "clone"
        for d in (self.home / ".local/share/foxml", self.home / ".local/bin", self.bin, self.clone):
            d.mkdir(parents=True)
        (self.home / ".local/share/foxml/repo-dir").write_text(f"{self.clone}\n")
        stub(self.clone / "update.sh", 'echo "clone update.sh:$*"')
        os.symlink(LEGACY, self.bin / "fox-legacy")
        stub(self.bin / "fox-pass", 'echo "fox-pass:$*"')
        stub(self.bin / "fox-vault", 'echo "compiled fox-vault:$*"')
        stub(self.bin / "fox-vpn", 'echo "fox-vpn:$*"')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fox(self, *args, prog=FOX):
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C.UTF-8"}
        r = subprocess.run([str(prog), *args], env=env, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout + r.stderr

    def test_vault_is_the_pass_wrapper(self):
        rc, out = self.fox("vault", "init")
        self.assertEqual((rc, out.strip()), (0, "fox-pass:init"))

    def test_flat_command_and_its_help(self):
        self.assertEqual(self.fox("vpn", "--status"), (0, "fox-vpn:--status\n"))
        self.assertEqual(self.fox("help", "vpn"), (0, "fox-vpn:--help\n"))

    def test_unknown_name_is_reported_by_fox_legacy(self):
        rc, out = self.fox("nosuch")
        self.assertEqual(rc, 1)
        self.assertIn("Unknown command: nosuch", out)

    def test_repo_commands_use_the_recorded_clone(self):
        self.assertEqual(self.fox("update", "x"), (0, "clone update.sh:x\n"))

    def test_recorded_clone_gone_falls_back_to_the_default_path(self):
        shutil.rmtree(self.clone)
        rc, out = self.fox("update")
        self.assertEqual(rc, 1)
        self.assertIn(f"FoxML directory not found at {self.home}/code/Linux_Theme", out)
        default = self.home / "code/Linux_Theme"
        default.mkdir(parents=True)
        stub(default / "update.sh", 'echo "default update.sh:$*"')
        self.assertEqual(self.fox("update", "y"), (0, "default update.sh:y\n"))

    def test_without_fox_legacy_the_leaf_still_runs(self):
        (self.bin / "fox-legacy").unlink()
        self.assertEqual(self.fox("vpn", "x"), (0, "fox-vpn:x\n"))
        rc, out = self.fox("nosuch")
        self.assertEqual(rc, 2)
        self.assertIn("unknown namespace 'nosuch'", out)

    def test_help_names_fox_and_leaves_itself_out(self):
        os.symlink(LEGACY, self.home / ".local/bin/fox-legacy")
        stub(self.home / ".local/bin/fox-pass", "# fox-pass — pass (password store) wrapper")
        rc, out = self.fox("help", prog=LEGACY)
        self.assertEqual(rc, 0)
        self.assertIn("Per-command help: fox help <command>", out)
        self.assertIn("fox-pass", out)
        self.assertNotIn("fox-legacy", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
