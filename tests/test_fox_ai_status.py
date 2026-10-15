#!/usr/bin/env python3
"""tests/test_fox_ai_status.py — the waybar AI module asks nvidia-smi once per boot, again when the NVIDIA
library changes, and says "reboot" when an update left the kernel module and the library apart.

Runs the real script with a fake nvidia-smi (counting its calls), a fake fox-llm-run, a throwaway $HOME and runtime dir,
and the NVML library / kernel module version paths pointed at files the test controls.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/fox-ai-status"


@unittest.skipUnless(shutil.which("jq"), "jq not installed")
class AiStatusTest(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-ai-status-test-", dir=base))
        self.home, self.bin, self.run_dir = self.tmp / "home", self.tmp / "bin", self.tmp / "run"
        for d in (self.home / ".config/opencode", self.bin, self.run_dir):
            d.mkdir(parents=True)
        (self.home / ".config/opencode/opencode.json").write_text(json.dumps({"model": "llamacpp/qwen3.5:4b"}))
        (self.bin / "nvidia-smi").write_text(
            '#!/bin/sh\necho call >> "$NVSMI_LOG"\n'
            'if [ "$FAKE_NVSMI" = mismatch ]; then\n'
            '  echo "Failed to initialize NVML: Driver/library version mismatch"\n'
            '  echo "NVML library version: 615.78"; exit 18\nfi\necho 3722\n')
        (self.bin / "fox-llm-run").write_text('#!/bin/sh\n[ "$1" = --ps ] && printf "qwen3.5:4b\\tloaded\\t2.6\\n"\n')
        for f in self.bin.iterdir():
            f.chmod(0o755)
        (self.tmp / "libnvidia-ml.so.615.71.09").write_text("")
        (self.tmp / "libnvidia-ml.so.615.78.08").write_text("")
        self.lib = self.tmp / "libnvidia-ml.so.1"
        self.lib.symlink_to(self.tmp / "libnvidia-ml.so.615.71.09")
        (self.tmp / "version").write_text("NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def status(self, nvsmi="ok", with_smi=True):
        # the fake nvidia-smi by its full path: the real one (on PATH here) must never answer a test
        smi = str(self.bin / "nvidia-smi") if with_smi else str(self.tmp / "no-nvidia-smi")
        r = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, timeout=30, env={
            "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "XDG_RUNTIME_DIR": str(self.run_dir),
            "FOX_NVIDIA_SMI": smi, "FOX_NVML_LIB": str(self.lib), "FOX_NVIDIA_VERSION": str(self.tmp / "version"),
            "FAKE_NVSMI": nvsmi, "NVSMI_LOG": str(self.tmp / "nvsmi.log")})
        self.assertEqual(r.stderr, "")
        return json.loads(r.stdout)

    def calls(self):
        log = self.tmp / "nvsmi.log"
        return len(log.read_text().splitlines()) if log.exists() else 0

    def test_vram_asked_once_per_boot(self):
        for _ in range(3):
            out = self.status()
            self.assertIn("4B 2.6/3.6g", out["text"])
        self.assertEqual(self.calls(), 1)

    def test_an_update_without_a_reboot_says_reboot_once_and_backs_off(self):
        self.status()
        self.lib.unlink()                                                # pacman -Syu: a new NVML library
        self.lib.symlink_to(self.tmp / "libnvidia-ml.so.615.78.08")
        out = self.status("mismatch")
        self.assertIn("reboot", out["text"])
        self.assertEqual(out["class"], "warning")
        self.assertIn("kernel module 615.71.09, driver library 615.78", out["tooltip"])
        self.assertIn("Model: qwen3.5:4b", out["tooltip"])
        for _ in range(3):
            self.assertEqual(self.status("mismatch")["class"], "warning")
        self.assertEqual(self.calls(), 2)                                # asked at boot and once after the update
        shutil.rmtree(self.run_dir); self.run_dir.mkdir()                # the reboot
        self.assertIn("4B 2.6/3.6g", self.status()["text"])

    def test_no_nvidia_no_vram_and_no_warning(self):
        out = self.status(with_smi=False)
        self.assertIn("4B 2.6g", out["text"])
        self.assertNotEqual(out["class"], "warning")


if __name__ == "__main__":
    unittest.main(verbosity=1)
