#!/usr/bin/env python3
"""tests/test_fox_llm_serve.py — fox-llm-serve's preset generation, offline.

A throwaway model folder (~/.local/share/fox-llm/gguf, as fox-llm-update fills it) and a fake
`llama-server` that answers `--list-devices` with or without a GPU stand in for the real ones.
Contract under test: roles become preset sections named after the model and pointing at its file;
every other downloaded model is served too (embedding models in embedding mode); models not
downloaded are skipped, not fatal; roles.conf beats roles.default; a model this llama.cpp can't
load is left out, checked once per file version.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
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
        self.models = self.tmp / "data/fox-llm/gguf"
        (self.cfg / "foxml/llm").mkdir(parents=True)
        self.models.mkdir(parents=True)
        shutil.copy(DEFAULT_ROLES, self.cfg / "foxml/llm/roles.default")
        self.server = self.tmp / "llama-server"
        self.server.write_text('#!/bin/sh\n[ "$1" = --list-devices ] || exit 1\n'
                               'echo "Available devices:"\n'
                               'if [ "$FAKE_GPU" = 1 ]; then echo "  CUDA0: NVIDIA T1200 Laptop GPU ($FAKE_GPU_MIB MiB, 3300 MiB free)";'
                               ' else echo "  (none)"; fi\n')
        self.server.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def add_model(self, name, content=b"GGUF", embed_header=False):
        """A downloaded model. `embed_header`: the file's header carries a pooling type, as an
        embedding model's does whatever its name."""
        f = self.models / f"{name}.gguf"
        f.write_bytes(content + (b"\0bert.pooling_type\0" if embed_header else b""))
        return f

    def env(self, gpu=False, ram_gb=32, extra=None):
        """`gpu`: False for none, True for the 3722 MiB T1200, or a size in MiB."""
        meminfo = self.tmp / "meminfo"
        meminfo.write_text(f"MemTotal:       {ram_gb * 1048576 - 1000} kB\n")
        # XDG_CACHE_HOME too: the load-check cache must never land in the real ~/.cache.
        return {**os.environ, "XDG_CONFIG_HOME": str(self.cfg),
                "XDG_CACHE_HOME": str(self.tmp / "cache"), "XDG_DATA_HOME": str(self.tmp / "data"),
                "HOME": str(self.tmp / "home"),         # never the real ~/code/custom_models/roles.conf
                "FOX_LLM_SERVER": str(self.server), "FAKE_GPU": "1" if gpu else "0",
                "FAKE_GPU_MIB": str(3722 if gpu is True else int(gpu)),
                "FOX_LLM_MEMINFO": str(meminfo), **(extra or {})}

    def preset(self, *extra, gpu=False, ram_gb=32, env=None, engine="main"):
        r = subprocess.run(["bash", str(SERVE), "--engine", engine, "preset", *extra],
                           env=self.env(gpu, ram_gb, env), capture_output=True, text=True)
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

    def test_sections_from_roles_with_file_paths(self):
        coder = self.add_model("qwen3-coder:30b")
        fim = self.add_model("qwen2.5-coder:1.5b-base")
        self.add_model("qwen2.5:3b")                                    # roles.default: title
        ini = self.preset()
        self.assertIn(f"model = {coder}", self.section(ini, "qwen3-coder:30b"))
        self.assertIn(f"model = {fim}", self.section(ini, "qwen2.5-coder:1.5b-base"))
        # the router mangles `name:tag` section names; the alias keeps the real name routable
        self.assertIn("alias = qwen2.5-coder:1.5b-base", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertIn("[qwen2.5:3b]\n; role: title", ini)
        self.assertIn("c = 8192", self.section(ini, "qwen2.5:3b"))
        self.assertIn("sleep-idle-seconds = 3600", self.section(ini, "qwen3-coder:30b"))   # the agent: an hour
        self.assertIn("; skipped qwen3.5:4b (quick): not downloaded yet (fox-llm-update)", ini)
        self.assertIn("cache-type-k = q8_0", self.section(ini, "*"))
        self.assertIn("load-on-startup = true", self.section(ini, "qwen2.5-coder:1.5b-base"))
        self.assertIn("c = 131072", self.section(ini, "qwen3-coder:30b"))

    def test_no_placement_flags_auto_fit_decides(self):
        # Any manual placement turns llama.cpp's auto-fit off and the load tries the whole model on the
        # GPU: n-gpu-layers OOMed the 4B beside the fim model, cpu-moe OOMed every extra model; and the
        # Arch build has no --moe-cache-mib at all (2026-10-14). GPU or not, roles or extras: none.
        # `fit-target` (a small GPU's agent) is the margin the fit leaves free; the fit itself is never set.
        self.add_model("qwen3-coder:30b")                                # roles.default's agent (MoE)
        self.add_model("qwen2.5-coder:14b")                              # an extra (dense)
        for gpu in (False, True, 12288):
            ini = self.preset(gpu=gpu)
            self.assertIn("[qwen3-coder:30b]", ini)
            self.assertEqual([l for l in ini.splitlines() if l.startswith(
                ("n-gpu-layers", "ngl", "cpu-moe", "n-cpu-moe", "moe-cache", "override-tensor", "fit ", "fit="))], [])

    def test_small_gpu_gives_its_room_to_the_agent(self):
        # A 3.7 GB T1200: the always-loaded fim model held 1.2 GB and auto-fit's default 1 GiB margin left the
        # agent's dense layers on the CPU (6.6 tok/s writing). Fim on demand and a 512 MiB margin at 64k: 14.2
        # (2026-10-16).
        self.add_model("qwen3-coder:30b")                                # roles.default's agent
        self.add_model("qwen2.5-coder:1.5b-base")                        # roles.default's fim
        ini = self.preset(gpu=True)
        agent, fim = self.section(ini, "qwen3-coder:30b"), self.section(ini, "qwen2.5-coder:1.5b-base")
        self.assertIn("fit-target = 512", agent)
        self.assertIn("c = 65536", agent)
        self.assertNotIn("load-on-startup = true", fim)
        self.assertIn("sleep-idle-seconds = 600", fim)
        # the helpers run on the CPU: beside the agent the quick 4B couldn't load, and loaded first it left
        # the agent at the CPU-only speed
        self.add_model("qwen3.5:4b")                                     # roles.default's quick
        ini = self.preset(gpu=True)
        for helper in ("qwen2.5-coder:1.5b-base", "qwen3.5:4b"):
            self.assertIn("device = none", self.section(ini, helper))
        self.assertFalse(any(l.startswith("device") for l in self.section(ini, "qwen3-coder:30b")))
        big = self.section(self.preset(gpu=True, ram_gb=64), "qwen3-coder:30b")
        self.assertIn("kv-unified-per-slot = 65536", big)                # slots still follow RAM
        for gpu in (12288, False):                                       # a bigger GPU, or none: as before
            ini = self.preset(gpu=gpu)
            agent, fim = self.section(ini, "qwen3-coder:30b"), self.section(ini, "qwen2.5-coder:1.5b-base")
            self.assertIn("c = 131072", agent)
            self.assertFalse(any(l.startswith("fit") for l in agent))
            self.assertIn("load-on-startup = true", fim)
            self.assertFalse(any(l.startswith("sleep-idle") for l in fim))
            self.assertNotIn("device = none", ini)

    def test_roles_conf_beats_roles_default(self):
        self.add_model("qwen3-coder:30b")
        mine = self.add_model("huihui-qwen3.6-abliterated:35b-a3b")
        (self.cfg / "foxml/llm/roles.conf").write_text("agent huihui-qwen3.6-abliterated:35b-a3b llama\n")
        ini = self.preset()
        self.assertIn(f"model = {mine}", self.section(ini, "huihui-qwen3.6-abliterated:35b-a3b"))
        self.assertIn("[huihui-qwen3.6-abliterated:35b-a3b]\n; role: agent", ini)
        # roles.default's agent is still downloaded: served as an ordinary model, not as the agent
        self.assertIn("[qwen3-coder:30b]\n; extra", ini)
        self.assertEqual(ini.count("; role: agent"), 1)

    def test_extra_models_appended_once(self):
        self.add_model("qwen3-coder:30b")
        self.add_model("qwen2.5-coder:14b")
        ini = self.preset("qwen2.5-coder:14b", "qwen3-coder:30b", "not-downloaded:1b")
        self.assertEqual(ini.count("[qwen3-coder:30b]"), 1)
        self.assertEqual(ini.count("[qwen2.5-coder:14b]"), 1)
        self.assertIn("; skipped not-downloaded:1b: not downloaded", ini)

    def test_turbo_engine_serves_only_turbo_roles_with_turbo_kv(self):
        self.add_model("qwen3-coder:30b")
        self.add_model("qwen2.5-coder:1.5b-base")
        (self.cfg / "foxml/llm/roles.conf").write_text(
            "agent qwen3-coder:30b llama-turbo\nfim qwen2.5-coder:1.5b-base llama\n")
        self.add_model("qwen2.5-coder:14b")                              # in no role
        turbo = self.preset(engine="turbo")
        self.assertIn("[qwen3-coder:30b]", turbo)
        self.assertNotIn("[qwen2.5-coder:1.5b-base]", turbo)            # a mainline role
        self.assertNotIn("[qwen2.5-coder:14b]", turbo)                  # extras are the main engine's
        self.assertIn("cache-type-v = turbo4", self.section(turbo, "*"))
        self.assertTrue((self.cfg / "foxml/llm/llama-presets-turbo.ini").exists())
        main = self.preset()
        self.assertIn("[qwen2.5-coder:1.5b-base]", main)
        self.assertIn("[qwen2.5-coder:14b]", main)
        self.assertNotIn("[qwen3-coder:30b]", main)                      # its role puts it on :8081
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
        self.add_model("qwen3.5:4b")                              # roles.default's quick model
        quick = self.section(self.preset(ram_gb=32), "qwen3.5:4b")
        self.assertIn("sleep-idle-seconds = 600", quick)
        self.assertIn('chat-template-kwargs = {"enable_thinking": false}', quick)   # short jobs: no hidden reasoning
        self.assertFalse(any(l.startswith("sleep-idle") for l in self.section(self.preset(ram_gb=64), "qwen3.5:4b")))
        self.add_model("qwen2.5-coder:1.5b-base")
        fim_sec = self.section(self.preset(ram_gb=32), "qwen2.5-coder:1.5b-base")
        self.assertIn("load-on-startup = true", fim_sec)          # ghost text never sleeps
        self.assertFalse(any(l.startswith("sleep-idle") for l in fim_sec))

    # ── the main engine serves every downloaded model ──

    def test_every_downloaded_model_served_embeddings_in_embedding_mode(self):
        self.add_model("qwen2.5-coder:14b")                              # in no role: an extra
        self.add_model("qwen2.5:3b")                                     # roles.default: title
        self.add_model("nomic-embed-text")                               # embedding, by name
        self.add_model("bge-m3", embed_header=True)                      # embedding, by its header only
        self.add_model("qwen3.6-35b-a3b.mmproj")                         # a vision projector: never a model
        (self.models / "half-done:7b.gguf.part").write_bytes(b"GG")      # still downloading
        (self.models / ".probe").mkdir()
        (self.models / ".probe/checking:1b.gguf").write_bytes(b"GGUF")   # fox-llm-update's header check
        ini = self.preset()
        self.assertIn("[qwen2.5-coder:14b]\n; extra", ini)
        self.assertIn("c = 32768", self.section(ini, "qwen2.5-coder:14b"))
        self.assertIn("[qwen2.5:3b]\n; role: title", ini)
        for name in ("nomic-embed-text", "bge-m3"):                      # embedding models: embedding mode
            self.assertIn(f"[{name}]\n; extra embedding", ini)
            emb = self.section(ini, name)
            self.assertIn("embeddings = true", emb)
            self.assertIn(f"alias = {name},{name}:latest", emb)          # the Ollama-era spelling still routes
            self.assertFalse(any(l.startswith(("c =", "kv-unified")) for l in emb))   # the model's own context
        for gone in ("mmproj", "half-done", "checking"):
            self.assertNotIn(gone, ini)
        self.assertNotIn("[qwen2.5-coder:14b]", self.preset(env={"FOX_LLM_ONLY_ROLES": "1"}))

    def fake_probe(self):
        """llama-fit-params beside the fake server (called as `-m <file> -c 512 -dev none`): a file holding
        "gptoss" can't load; one holding "huge" only fails to fit the free RAM (which must not count).
        Logs each call."""
        probe = self.server.parent / "llama-fit-params"
        probe.write_text('#!/bin/sh\necho "$2" >> "$PROBE_LOG"\n'
                         'if grep -q gptoss "$2"; then echo "0.1 E llama_model_load: error loading model: '
                         "unknown model architecture: 'gptoss'\"; exit 1; fi\n"
                         'if grep -q huge "$2"; then echo "0.1 W common_fit_params: failed to fit params to free '
                         'device memory: was unable to fit model into system memory by reducing context, abort"; exit 1; fi\n'
                         'exit 0\n')
        probe.chmod(0o755)
        return self.tmp / "probe.log"

    def test_models_this_llama_cpp_cannot_load_are_left_out_checked_once_per_version(self):
        log = self.fake_probe()
        old = self.add_model("gpt-oss:20b", content=b"GGUF gptoss")
        self.add_model("qwen3.6:35b-a3b", content=b"GGUF huge")
        self.add_model("qwen2.5-coder:14b")
        ini = self.preset(env={"PROBE_LOG": str(log)})
        self.assertNotIn("[gpt-oss:20b]", ini)
        self.assertIn("; skipped gpt-oss:20b: this llama.cpp can't load it (unknown model architecture: 'gptoss')", ini)
        self.assertIn("[qwen3.6:35b-a3b]", ini)                          # too big right now ≠ can't load
        self.assertIn("[qwen2.5-coder:14b]", ini)
        calls = len(log.read_text().splitlines())
        self.assertEqual(calls, 3)
        self.preset(env={"PROBE_LOG": str(log)})                          # verdicts cached per file version
        self.assertEqual(len(log.read_text().splitlines()), calls)
        time.sleep(1.1)
        old.write_bytes(b"GGUF fixed upload")                            # a refreshed download: checked again
        ini = self.preset(env={"PROBE_LOG": str(log)})
        self.assertEqual(len(log.read_text().splitlines()), calls + 1)
        self.assertIn("[gpt-oss:20b]", ini)

    def test_role_model_this_llama_cpp_cannot_load_is_skipped_with_advice(self):
        log = self.fake_probe()
        self.add_model("gpt-oss:20b", content=b"GGUF gptoss")
        (self.cfg / "foxml/llm/roles.conf").write_text("agent gpt-oss:20b llama\n")
        ini = self.preset(env={"PROBE_LOG": str(log)})
        self.assertNotIn("[gpt-oss:20b]", ini)
        self.assertIn("; skipped gpt-oss:20b (agent): this llama.cpp can't load it "
                      "(unknown model architecture: 'gptoss') — pick another model for the role", ini)

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

    def test_untagged_names_and_their_ollama_spelling_are_one_model(self):
        self.add_model("mxbai-embed-large")
        self.add_model("qwen2.5:3b")
        # the Ollama spelling on the embed line, and no newline after the last line (a hand edit)
        (self.cfg / "foxml/llm/roles.conf").write_text("title qwen2.5:3b llama\nembed mxbai-embed-large:latest llama")
        ini = self.preset()
        self.assertEqual(ini.count("[mxbai-embed-large]"), 1)                    # one model, one section
        self.assertNotIn("[mxbai-embed-large:latest]", ini)
        sec = self.section(ini, "mxbai-embed-large")
        self.assertIn("alias = mxbai-embed-large,mxbai-embed-large:latest", sec)  # both names route
        self.assertIn("embeddings = true", sec)
        self.assertIn("[mxbai-embed-large]\n; role: embed", ini)                 # the last line was read

    def test_a_roles_file_from_the_ollama_days_still_serves_on_llama_cpp(self):
        self.add_model("qwen2.5:3b")
        (self.cfg / "foxml/llm/roles.conf").write_text("title qwen2.5:3b ollama\n")
        self.assertIn("[qwen2.5:3b]\n; role: title", self.preset())


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
