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

    def add_model(self, ref, *kinds, family="qwen2", content=b"GGUF"):
        """A store entry; `kinds` adds Modelfile layers (messages, adapter, system), `family` goes in
        the config blob the way Ollama records it (nomic-bert, bert … for embedding models)."""
        name, _, tag = ref.partition(":")
        ns, _, model = name.rpartition("/")
        digest = "sha256:" + format(abs(hash(ref)), "064x")[:64]
        config = "sha256:" + format(abs(hash(ref + "/config")), "064x")[:64]
        man = self.store / "manifests/registry.ollama.ai" / (ns or "library") / model / (tag or "latest")
        man.parent.mkdir(parents=True, exist_ok=True)
        man.write_text(json.dumps({
            "config": {"mediaType": "application/vnd.docker.container.image.v1+json", "digest": config},
            "layers": [{"mediaType": "application/vnd.ollama.image.template", "digest": "sha256:" + "1" * 64},
                       {"mediaType": "application/vnd.ollama.image.model", "digest": digest}]
                      + [{"mediaType": f"application/vnd.ollama.image.{k}", "digest": "sha256:" + "2" * 64}
                         for k in kinds]}))
        blob = self.store / "blobs" / digest.replace(":", "-")
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(content)
        (self.store / "blobs" / config.replace(":", "-")).write_text(json.dumps({"model_family": family}))
        return blob

    def preset(self, *extra, gpu=False, ram_gb=32, env=None):
        meminfo = self.tmp / "meminfo"
        meminfo.write_text(f"MemTotal:       {ram_gb * 1048576 - 1000} kB\n")
        # XDG_CACHE_HOME too: the load-check cache must never land in the real ~/.cache.
        env = {**os.environ, "XDG_CONFIG_HOME": str(self.cfg), "OLLAMA_MODELS": str(self.store),
               "XDG_CACHE_HOME": str(self.tmp / "cache"), "XDG_DATA_HOME": str(self.tmp / "data"),
               "HOME": str(self.tmp / "home"),         # never the real ~/code/custom_models/roles.conf
               "FOX_LLM_SERVER": str(self.server), "FAKE_GPU": "1" if gpu else "0",
               "FOX_LLM_MEMINFO": str(meminfo), **(env or {})}
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
        self.add_model("qwen2.5:3b")                                    # roles.default: title
        ini = self.preset()
        self.assertIn(f"model = {coder}", self.section(ini, "qwen3-coder:30b"))
        self.assertIn(f"model = {fim}", self.section(ini, "qwen2.5-coder:1.5b-base"))
        # the router mangles `name:tag` section names; the alias keeps the Ollama name routable
        self.assertIn("alias = qwen2.5-coder:1.5b-base", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertIn("[qwen2.5:3b]\n; role: title", ini)               # llama.cpp serves the title model too
        self.assertIn("c = 8192", self.section(ini, "qwen2.5:3b"))
        self.assertIn("sleep-idle-seconds = 3600", self.section(ini, "qwen3-coder:30b"))   # the agent: an hour
        self.assertIn("; skipped qwen2.5-coder:7b (quick): not in Ollama's store yet", ini)
        self.assertIn("cache-type-k = q8_0", self.section(ini, "*"))
        self.assertIn("load-on-startup = true", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertIn("c = 131072", self.section(ini, "qwen3-coder:30b"))

    def test_no_placement_flags_auto_fit_decides(self):
        # Any manual placement turns llama.cpp's auto-fit off and the load tries the whole model on the
        # GPU: n-gpu-layers OOMed the 4B beside the fim model, cpu-moe OOMed every extra model; and the
        # Arch build has no --moe-cache-mib at all (2026-10-14). GPU or not, roles or extras: none.
        self.add_model("qwen3-coder:30b")                                # roles.default's agent (MoE)
        self.add_model("qwen2.5-coder:14b")                              # an extra (dense)
        for gpu in (False, True):
            ini = self.preset(gpu=gpu)
            self.assertIn("[qwen3-coder:30b]", ini)
            self.assertEqual([l for l in ini.splitlines() if l.startswith(
                ("n-gpu-layers", "ngl", "cpu-moe", "n-cpu-moe", "moe-cache", "override-tensor", "fit"))], [])

    def test_roles_conf_beats_roles_default(self):
        self.add_model("qwen3-coder:30b")
        mine = self.add_model("huihui_ai/qwen3.6-abliterated:35b-a3b")
        (self.cfg / "foxml/llm/roles.conf").write_text("agent huihui_ai/qwen3.6-abliterated:35b-a3b llama\n")
        ini = self.preset()
        self.assertIn(f"model = {mine}", self.section(ini, "huihui_ai/qwen3.6-abliterated:35b-a3b"))
        self.assertIn("[huihui_ai/qwen3.6-abliterated:35b-a3b]\n; role: agent", ini)
        # roles.default's agent is still installed: served as an ordinary model, not as the agent
        self.assertIn("[qwen3-coder:30b]\n; extra", ini)
        self.assertEqual(ini.count("; role: agent"), 1)

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
        self.add_model("qwen2.5-coder:14b")                              # in no role
        env = {**os.environ, "XDG_CONFIG_HOME": str(self.cfg), "OLLAMA_MODELS": str(self.store),
               "XDG_CACHE_HOME": str(self.tmp / "cache"), "XDG_DATA_HOME": str(self.tmp / "data"),
               "HOME": str(self.tmp / "home"),
               "FOX_LLM_SERVER": str(self.server), "FAKE_GPU": "0"}
        r = subprocess.run(["bash", str(SERVE), "--engine", "turbo", "preset"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[qwen3-coder:30b]", r.stdout)
        self.assertNotIn("[qwen2.5-coder:1.5b-base]", r.stdout)        # a mainline role
        self.assertNotIn("[qwen2.5-coder:14b]", r.stdout)              # extras are the main engine's
        self.assertIn("cache-type-v = turbo4", self.section(r.stdout, "*"))
        self.assertTrue((self.cfg / "foxml/llm/llama-presets-turbo.ini").exists())
        main = self.preset()
        self.assertIn("[qwen2.5-coder:1.5b-base]", main)
        self.assertIn("[qwen2.5-coder:14b]", main)
        self.assertNotIn("[qwen3-coder:30b]", main)                      # its role puts it on :8081
        self.assertNotIn("[qwen3-coder:30b]", main)
        self.assertIn("cache-type-v = q8_0", self.section(main, "*"))


    def test_agent_slots_follow_ram_and_role_override(self):
        self.add_model("qwen3-coder:30b")
        small = self.section(self.preset(ram_gb=32), "qwen3-coder:30b")
        self.assertIn("parallel = 1", small)                   # one conversation gets the whole context
        self.assertIn("c = 131072", small)
        big = self.section(self.preset(ram_gb=64), "qwen3-coder:30b")
        self.assertIn("parallel = 2", big)                     # two, each capped — none can evict the other
        self.assertIn("kv-unified-per-slot = 131072", big)
        self.assertFalse(any(l.startswith("c =") for l in big))
        (self.cfg / "foxml/llm/roles.conf").write_text("agent qwen3-coder:30b llama slots=3\n")
        forced = self.section(self.preset(ram_gb=32), "qwen3-coder:30b")
        self.assertIn("parallel = 3", forced)


    def test_quick_model_sleeps_soon_only_on_small_ram(self):
        self.add_model("qwen2.5-coder:7b")                       # roles.default's quick model
        quick = self.section(self.preset(ram_gb=32), "qwen2.5-coder:7b")
        self.assertIn("sleep-idle-seconds = 600", quick)
        self.assertIn('chat-template-kwargs = {"enable_thinking": false}', quick)   # short jobs: no hidden reasoning
        self.assertFalse(any(l.startswith("sleep-idle")
                             for l in self.section(self.preset(ram_gb=64), "qwen2.5-coder:7b")))
        fim = self.add_model("qwen2.5-coder:1.5b-base")
        fim_sec = self.section(self.preset(ram_gb=32), "qwen2.5-coder:1.5b-base")
        self.assertIn("load-on-startup = true", fim_sec)          # ghost text never sleeps
        self.assertFalse(any(l.startswith("sleep-idle") for l in fim_sec))


    # ── llama.cpp as the default server: every chat model in Ollama's store ──

    def test_every_store_model_served_except_ollama_only_ones(self):
        self.add_model("qwen2.5-coder:14b")                              # in no role: an extra
        self.add_model("qwen2.5:3b")                                     # roles.default: title
        self.add_model("qwen2.5:7b", "system")                           # the library's stock SYSTEM layer
        self.add_model("nomic-embed-text:latest", family="nomic-bert")   # embedding, by name
        self.add_model("bge-m3:latest", family="bert")                   # embedding, by family only
        self.add_model("gameproject:latest", "system", "messages")      # Modelfile with example chat
        self.add_model("lora-thing:latest", "adapter")
        ini = self.preset()
        self.assertIn("[qwen2.5-coder:14b]\n; extra", ini)
        self.assertIn("c = 32768", self.section(ini, "qwen2.5-coder:14b"))
        self.assertIn("[qwen2.5:7b]\n; extra", ini)
        self.assertIn("[qwen2.5:3b]\n; role: title", ini)
        for name in ("nomic-embed-text:latest", "bge-m3:latest"):        # embedding models: embedding mode
            self.assertIn(f"[{name}]\n; extra embedding", ini)
            emb = self.section(ini, name)
            self.assertIn("embeddings = true", emb)
            self.assertFalse(any(l.startswith(("c =", "kv-unified")) for l in emb))   # the model's own context
        for name in ("gameproject:latest", "lora-thing:latest"):
            self.assertNotIn(f"[{name}]", ini)
        self.assertIn("; on Ollama only: gameproject:latest — its Modelfile bakes in example messages", ini)
        self.assertIn("; on Ollama only: lora-thing:latest — its Modelfile adds a LoRA adapter", ini)
        self.assertNotIn("[qwen2.5-coder:14b]", self.preset(env={"FOX_LLM_ONLY_ROLES": "1"}))

    def fake_probe(self):
        """llama-fit-params beside the fake server (called as `-m <blob> -c 512 -dev none`): a blob holding "gptoss" can't load; one holding
        "huge" only fails to fit the free RAM (which must not count). Logs each call."""
        probe = self.server.parent / "llama-fit-params"
        probe.write_text('#!/bin/sh\necho "$2" >> "$PROBE_LOG"\n'
                         'if grep -q gptoss "$2"; then echo "0.1 E llama_model_load: error loading model: '
                         "unknown model architecture: 'gptoss'\"; exit 1; fi\n"
                         'if grep -q huge "$2"; then echo "0.1 W common_fit_params: failed to fit params to free '
                         'device memory: was unable to fit model into system memory by reducing context, abort"; exit 1; fi\n'
                         'exit 0\n')
        probe.chmod(0o755)
        return self.tmp / "probe.log"

    def test_models_llama_cpp_cannot_load_stay_on_ollama(self):
        log = self.fake_probe()
        self.add_model("gpt-oss:20b", content=b"GGUF gptoss")
        self.add_model("qwen3.6:35b-a3b", content=b"GGUF huge")
        self.add_model("qwen2.5-coder:14b")
        ini = self.preset(env={"PROBE_LOG": str(log)})
        self.assertNotIn("[gpt-oss:20b]", ini)
        self.assertIn("; on Ollama only: gpt-oss:20b — this llama.cpp can't load it "
                      "(unknown model architecture: 'gptoss')", ini)
        self.assertIn("[qwen3.6:35b-a3b]", ini)                          # too big right now ≠ can't load
        self.assertIn("[qwen2.5-coder:14b]", ini)
        calls = len(log.read_text().splitlines())
        self.assertEqual(calls, 3)
        self.preset(env={"PROBE_LOG": str(log)})                          # verdicts cached per blob
        self.assertEqual(len(log.read_text().splitlines()), calls)

    def test_role_model_llama_cpp_cannot_load_is_skipped_with_advice(self):
        log = self.fake_probe()
        self.add_model("gpt-oss:20b", content=b"GGUF gptoss")
        (self.cfg / "foxml/llm/roles.conf").write_text("agent gpt-oss:20b llama\n")
        ini = self.preset(env={"PROBE_LOG": str(log)})
        self.assertNotIn("[gpt-oss:20b]", ini)
        self.assertIn("; skipped gpt-oss:20b (agent): this llama.cpp can't load it "
                      "(unknown model architecture: 'gptoss') — give the role server ollama", ini)

    def test_preset_written_on_cpu_only_box_whatever_the_last_section(self):
        # `(( gpu )) && …` as role_flags' last command made its status 1 on a CPU-only box, and the
        # preset was never written when an extra came last.
        self.add_model("zz-last-dense:7b")
        self.assertIn("[zz-last-dense:7b]", self.preset(gpu=False))


    def test_roles_from_the_custom_models_repo_and_a_machine_override(self):
        self.add_model("qwen2.5:7b")
        mine = self.tmp / "home/code/custom_models/roles.conf"            # survives a reinstall
        mine.parent.mkdir(parents=True)
        mine.write_text("quick qwen2.5:7b llama\n")
        ini = self.preset()
        self.assertIn(f"from {mine}", ini)
        self.assertIn("[qwen2.5:7b]\n; role: quick", ini)
        (self.cfg / "foxml/llm/roles.conf").write_text("agent qwen2.5:7b llama\n")   # this machine wins
        self.assertIn("[qwen2.5:7b]\n; role: agent", self.preset())

    def test_untagged_role_name_is_the_latest_tag_served_once(self):
        self.add_model("mxbai-embed-large:latest", family="bert")
        self.add_model("qwen2.5:3b")
        # no tag on the embed line, and no newline after the last line (a hand edit)
        (self.cfg / "foxml/llm/roles.conf").write_text("title qwen2.5:3b llama\nembed mxbai-embed-large llama")
        ini = self.preset()
        self.assertEqual(ini.count("[mxbai-embed-large:latest]"), 1)            # one model, one section
        sec = self.section(ini, "mxbai-embed-large:latest")
        self.assertIn("alias = mxbai-embed-large:latest,mxbai-embed-large", sec)  # both names, as on Ollama
        self.assertIn("embeddings = true", sec)
        self.assertIn("[mxbai-embed-large:latest]\n; role: embed", ini)          # the last line was read

    # ── Hugging Face GGUFs (fox-llm-update's gguf-models.txt downloads) ──

    def hf_model(self, name, content=b"GGUF"):
        d = self.tmp / "data/fox-llm/gguf"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{name}.gguf").write_bytes(content)
        return d / f"{name}.gguf"

    def test_hugging_face_ggufs_served_by_name_and_as_roles(self):
        agent = self.hf_model("huihui-qwen3.6-abliterated:35b-a3b")
        extra = self.hf_model("huihui-qwen3.5-abliterated:9b")
        self.hf_model("huihui-qwen3.6-abliterated:35b-a3b.mmproj")    # a vision projector: never a model
        (self.tmp / "data/fox-llm/gguf/half-done:7b.gguf.part").write_bytes(b"GG")   # still downloading
        (self.cfg / "foxml/llm/roles.conf").write_text("agent huihui-qwen3.6-abliterated:35b-a3b llama\n")
        ini = self.preset()
        self.assertIn("[huihui-qwen3.6-abliterated:35b-a3b]\n; role: agent", ini)
        self.assertIn(f"model = {agent}", self.section(ini, "huihui-qwen3.6-abliterated:35b-a3b"))
        self.assertIn("[huihui-qwen3.5-abliterated:9b]\n; extra", ini)
        self.assertIn(f"model = {extra}", self.section(ini, "huihui-qwen3.5-abliterated:9b"))
        self.assertNotIn("mmproj", ini)
        self.assertNotIn("half-done", ini)

    def test_hugging_face_download_wins_over_an_ollama_model_of_the_same_name(self):
        self.add_model("qwen3.5:9b")
        mine = self.hf_model("qwen3.5:9b")
        ini = self.preset()
        self.assertEqual(ini.count("[qwen3.5:9b]"), 1)
        self.assertIn(f"model = {mine}", self.section(ini, "qwen3.5:9b"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
