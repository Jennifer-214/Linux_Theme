#!/usr/bin/env python3
"""tests/test_fox_llm_serve.py — fox-llm-serve's preset generation, offline.

A throwaway Ollama store (manifests + blobs) and a fake `llama-server` that answers
`--list-devices` with or without a GPU stand in for the real ones. Contract under test:
llama-served roles become preset sections named after the Ollama model and pointing at its
blob; missing models are skipped, not fatal; roles.conf beats roles.default; GPU-only flags
appear only when llama.cpp itself reports a device.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVE = ROOT / "shared/bin/fox-llm-serve"
DEFAULT_ROLES = ROOT / "shared/llm/roles.default"


class ServeTest(unittest.TestCase):
    def setUp(self):
        # Not /tmp: the noexec_tmp module mounts it noexec, so the fake server couldn't run there.
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-llm-serve-test-", dir=base))
        self.cfg = self.tmp / "config"
        self.store = self.tmp / "store"
        (self.cfg / "foxml/llm").mkdir(parents=True)
        shutil.copy(DEFAULT_ROLES, self.cfg / "foxml/llm/roles.default")
        self.server = self.tmp / "llama-server"
        self.server.write_text('#!/bin/sh\n[ "$1" = --list-devices ] || exit 1\n'
                               'echo "Available devices:"\n'
                               'if [ "$FAKE_GPU" = 1 ]; then echo "  CUDA0: NVIDIA T1200 Laptop GPU (3722 MiB, 3300 MiB free)";'
                               ' else echo "  (none)"; fi\n')
        self.server.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def add_model(self, ref):
        name, _, tag = ref.partition(":")
        ns, _, model = name.rpartition("/")
        digest = "sha256:" + format(abs(hash(ref)), "064x")[:64]
        man = self.store / "manifests/registry.ollama.ai" / (ns or "library") / model / (tag or "latest")
        man.parent.mkdir(parents=True, exist_ok=True)
        man.write_text(json.dumps({"layers": [
            {"mediaType": "application/vnd.ollama.image.template", "digest": "sha256:" + "1" * 64},
            {"mediaType": "application/vnd.ollama.image.model", "digest": digest}]}))
        blob = self.store / "blobs" / digest.replace(":", "-")
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(b"GGUF")
        return blob

    def preset(self, *extra, gpu=False):
        env = {**os.environ, "XDG_CONFIG_HOME": str(self.cfg), "OLLAMA_MODELS": str(self.store),
               "FOX_LLM_SERVER": str(self.server), "FAKE_GPU": "1" if gpu else "0"}
        r = subprocess.run(["bash", str(SERVE), "preset", *extra], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    @staticmethod
    def section(ini, name):
        out, on = [], False
        for line in ini.splitlines():
            if line.startswith("["):
                on = line == f"[{name}]"
                continue
            if on and line.strip() and not line.startswith(";"):
                out.append(line.strip())
        return out

    def test_sections_from_roles_with_blob_paths(self):
        coder = self.add_model("qwen3-coder:30b")
        fim = self.add_model("qwen2.5-coder:1.5b-base")
        self.add_model("qwen2.5:3b")                                    # an ollama role
        ini = self.preset()
        self.assertIn(f"model = {coder}", self.section(ini, "qwen3-coder:30b"))
        self.assertIn(f"model = {fim}", self.section(ini, "qwen2.5-coder:1.5b-base"))
        # the router mangles `name:tag` section names; the alias keeps the Ollama name routable
        self.assertIn("alias = qwen2.5-coder:1.5b-base", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertNotIn("[qwen2.5:3b]", ini)                           # served by ollama, not here
        self.assertIn("; skipped qwen2.5-coder:7b (quick): not in Ollama's store yet", ini)
        self.assertIn("cache-type-k = q8_0", self.section(ini, "*"))
        self.assertIn("load-on-startup = true", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertIn("c = 131072", self.section(ini, "qwen3-coder:30b"))

    def test_gpu_flags_only_when_llama_cpp_sees_a_device(self):
        self.add_model("qwen3-coder:30b")
        cpu = self.section(self.preset(gpu=False), "qwen3-coder:30b")
        self.assertFalse(any(l.startswith(("cpu-moe", "moe-cache")) for l in cpu))
        gpu = self.section(self.preset(gpu=True), "qwen3-coder:30b")
        for flag in ("cpu-moe = true", "moe-cache-mib = 512"):
            self.assertIn(flag, gpu)
        # layers are never forced (auto-fit): a forced count OOMed the 4B beside the fim model
        self.assertFalse(any(l.startswith("n-gpu-layers") for l in self.preset(gpu=True).splitlines()))

    def test_roles_conf_beats_roles_default(self):
        self.add_model("qwen3-coder:30b")
        mine = self.add_model("huihui_ai/qwen3.6-abliterated:35b-a3b")
        (self.cfg / "foxml/llm/roles.conf").write_text("agent huihui_ai/qwen3.6-abliterated:35b-a3b llama\n")
        ini = self.preset()
        self.assertIn(f"model = {mine}", self.section(ini, "huihui_ai/qwen3.6-abliterated:35b-a3b"))
        self.assertNotIn("[qwen3-coder:30b]", ini)

    def test_extra_models_appended_once(self):
        self.add_model("qwen3-coder:30b")
        self.add_model("qwen2.5-coder:14b")
        ini = self.preset("qwen2.5-coder:14b", "qwen3-coder:30b", "not-downloaded:1b")
        self.assertEqual(ini.count("[qwen3-coder:30b]"), 1)
        self.assertIn("[qwen2.5-coder:14b]", ini)
        self.assertIn("; skipped not-downloaded:1b: not in Ollama's store", ini)


    def test_turbo_engine_serves_only_turbo_roles_with_turbo_kv(self):
        self.add_model("qwen3-coder:30b")
        self.add_model("qwen2.5-coder:1.5b-base")
        (self.cfg / "foxml/llm/roles.conf").write_text(
            "agent qwen3-coder:30b llama-turbo\nfim qwen2.5-coder:1.5b-base llama\n")
        env = {**os.environ, "XDG_CONFIG_HOME": str(self.cfg), "OLLAMA_MODELS": str(self.store),
               "FOX_LLM_SERVER": str(self.server), "FAKE_GPU": "0"}
        r = subprocess.run(["bash", str(SERVE), "--engine", "turbo", "preset"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[qwen3-coder:30b]", r.stdout)
        self.assertNotIn("[qwen2.5-coder:1.5b-base]", r.stdout)        # a mainline role
        self.assertIn("cache-type-v = turbo4", self.section(r.stdout, "*"))
        self.assertTrue((self.cfg / "foxml/llm/llama-presets-turbo.ini").exists())
        main = self.preset()
        self.assertIn("[qwen2.5-coder:1.5b-base]", main)
        self.assertNotIn("[qwen3-coder:30b]", main)
        self.assertIn("cache-type-v = q8_0", self.section(main, "*"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
