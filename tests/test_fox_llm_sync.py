#!/usr/bin/env python3
"""tests/test_fox_llm_sync.py — fox-llm-update's --sync and --wanted, offline.

Runs the real script against a throwaway $HOME with fake `ollama` / `npm` on PATH,
so no network, no ollama server, no pi install is needed. The contract under test:
sync only ADDS (user keys survive), fills missing defaults, promotes the stand-in
default once the agent model lands, and is idempotent.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/fox-llm-update"
CORE = ROOT / "shared/llm/core-models.txt"


# curl for the tests: Hugging Face's file record and the download (resuming on -C -) come from files the
# test writes; anything else (the router reload, registry checks) is only logged — never sent anywhere.
FAKE_CURL = r'''#!/usr/bin/env python3
import os, sys
TMP = "@TMP@"
args = sys.argv[1:]
with open(TMP + "/curl.log", "a") as log:
    log.write(" ".join(args) + "\n")
url = next((a for a in args if a.startswith("http")), "")
if "/api/models/" in url:
    sys.stdout.write(open(TMP + "/hf-tree.json").read())
elif "-o" in args and "/resolve/" in url:
    out = args[args.index("-o") + 1]
    blob = open(TMP + "/hf-blob", "rb").read()
    have = os.path.getsize(out) if "-C" in args and os.path.exists(out) else 0
    with open(out, "ab" if have else "wb") as f:
        f.write(blob[have:])
elif "-w" in args:
    sys.stdout.write("404")
'''


class SyncTest(unittest.TestCase):
    def setUp(self):
        # Not /tmp: the noexec_tmp module mounts it noexec, so fake binaries there can't run.
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-llm-test-", dir=base))
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.npm_root = self.tmp / "npm-root"
        self.home.mkdir()
        self.bin.mkdir()
        self.installed = []
        self.modelfile_layers = {}       # model → extra manifest layer kinds (messages, adapter, …)
        # Fake pi examples tree, as `npm root -g` would expose it.
        ex = self.npm_root / "@mariozechner/pi-coding-agent/examples/extensions"
        (ex / "plan-mode").mkdir(parents=True)
        (ex / "subagent/agents").mkdir(parents=True)
        (ex / "subagent/prompts").mkdir(parents=True)
        for f in ("git-checkpoint.ts", "subagent/index.ts", "subagent/agents.ts", "plan-mode/index.ts"):
            (ex / f).write_text("// stub\n")
        (ex / "subagent/agents/scout.md").write_text("---\nname: scout\nmodel: claude-haiku-4-5\n---\nbody\n")
        (ex / "subagent/prompts/implement.md").write_text("implement\n")
        self._write_fakes()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _write_fakes(self):
        rows = "".join(f"{m}\tdeadbeef\t1 GB\tnow\n" for m in self.installed)
        (self.bin / "ollama").write_text(
            "#!/bin/sh\n"
            '[ "$FAKE_OLLAMA_DOWN" = 1 ] && exit 1\n'
            'if [ "$1" = list ]; then printf "NAME\\tID\\tSIZE\\tMODIFIED\\n%s" "$ROWS"; exit 0; fi\n'
            "exit 1\n")
        (self.bin / "npm").write_text(f'#!/bin/sh\n[ "$1" = root ] && echo "{self.npm_root}"\n')
        # Only `is-enabled` matters to sync: the llama.cpp unit's state comes from the test, not the box.
        (self.bin / "systemctl").write_text(
            '#!/bin/sh\ncase "$*" in *is-enabled*)\n'
            '  for u in $FAKE_UNITS; do case "$*" in *" $u.service"*) exit 0;; esac; done; exit 1;;\n'
            'esac\nexit 0\n')
        # Ollama's store as fox-llm-serve reads it (manifest → GGUF blob) and a llama-server with no GPU:
        # sync reads back the preset the launcher writes from these, as on a real box.
        store = self.tmp / "store"
        shutil.rmtree(store, ignore_errors=True)
        for i, ref in enumerate(self.installed):
            name, _, tag = ref.partition(":")
            ns, _, model = name.rpartition("/")
            digest = f"sha256:{i + 1:064x}"
            man = store / "manifests/registry.ollama.ai" / (ns or "library") / model / (tag or "latest")
            man.parent.mkdir(parents=True, exist_ok=True)
            man.write_text(json.dumps({"layers": [
                {"mediaType": "application/vnd.ollama.image.model", "digest": digest}] + [
                {"mediaType": f"application/vnd.ollama.image.{k}", "digest": "sha256:" + "2" * 64}
                for k in self.modelfile_layers.get(ref, [])]}))
            (store / "blobs").mkdir(exist_ok=True)
            (store / "blobs" / digest.replace(":", "-")).write_bytes(b"GGUF")
        (self.bin / "llama-server").write_text('#!/bin/sh\necho "Available devices:"\n')
        (self.bin / "curl").write_text(FAKE_CURL.replace("@TMP@", str(self.tmp)))
        for f in ("ollama", "npm", "systemctl", "llama-server", "curl"):
            (self.bin / f).chmod(0o755)
        self.rows = rows

    def run_script(self, *args, meminfo_gb=32, server_on=False, units=None, ollama_down=False):
        meminfo = self.tmp / "meminfo"
        meminfo.write_text(f"MemTotal:       {meminfo_gb * 1048576 - 1000} kB\n")
        cfg = self.home / ".config"
        (cfg / "foxml/llm").mkdir(parents=True, exist_ok=True)
        shutil.copy(CORE, cfg / "foxml/llm/core-models.txt")
        env = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(cfg),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FOX_LLM_MEMINFO": str(meminfo),
            "ROWS": self.rows,
            "FAKE_UNITS": units if units is not None else ("fox-llm-server" if server_on else ""),
            "OLLAMA_MODELS": str(self.tmp / "store"),
            "FAKE_OLLAMA_DOWN": "1" if ollama_down else "0",
            "FOX_LLM_SERVER": str(self.bin / "llama-server"),
        }
        r = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def install(self, *models):
        self.installed = list(models)
        self._write_fakes()

    @property
    def oc_path(self):
        return self.home / ".config/opencode/opencode.json"

    def oc(self):
        return json.loads(self.oc_path.read_text())

    def pi(self, name):
        return json.loads((self.home / ".pi/agent" / name).read_text())

    # ── tests ──

    def test_fresh_home_gets_full_config(self):
        self.install("qwen3-coder:30b", "qwen2.5:3b", "mxbai-embed-large:latest")
        self.run_script("--sync")
        oc = self.oc()
        self.assertEqual(oc["model"], "ollama/qwen3-coder:30b")
        self.assertEqual(oc["small_model"], "ollama/qwen2.5:3b")
        self.assertFalse(oc["autoupdate"])
        self.assertEqual(oc["share"], "disabled")
        self.assertEqual(oc["permission"]["bash"]["*"], "ask")
        self.assertNotIn("find *", oc["permission"]["bash"])
        models = oc["provider"]["ollama"]["models"]
        self.assertNotIn("mxbai-embed-large:latest", models)        # embeddings stay out
        self.assertEqual(models["qwen3-coder:30b"]["limit"]["context"], 32768)
        self.assertEqual(self.pi("settings.json")["defaultModel"], "qwen3-coder:30b")
        self.assertFalse(self.pi("settings.json")["enableInstallTelemetry"])
        ids = [m["id"] for m in self.pi("models.json")["providers"]["ollama"]["models"]]
        self.assertEqual(sorted(ids), ["qwen2.5:3b", "qwen3-coder:30b"])

    def test_pi_resources_linked_and_agents_unpinned(self):
        self.install("qwen2.5:3b")
        self.run_script("--sync")
        agent = self.home / ".pi/agent"
        self.assertTrue((agent / "extensions/plan-mode").is_symlink())
        self.assertTrue((agent / "extensions/subagent/index.ts").is_symlink())
        scout = (agent / "agents/scout.md").read_text()
        self.assertNotIn("model:", scout)
        self.assertIn("name: scout", scout)
        self.assertTrue((agent / "prompts/implement.md").exists())

    def test_user_keys_survive_and_backup_made(self):
        self.install("qwen3-coder:30b")
        self.oc_path.parent.mkdir(parents=True)
        user = {"model": "anthropic/claude-x", "theme": "mine",
                "permission": {"edit": "allow"},
                "provider": {"ollama": {"options": {"baseURL": "http://box:11434/v1"}, "models": {}}}}
        self.oc_path.write_text(json.dumps(user))
        self.run_script("--sync")
        oc = self.oc()
        self.assertEqual(oc["model"], "anthropic/claude-x")       # other provider: untouched
        self.assertEqual(oc["theme"], "mine")
        self.assertEqual(oc["permission"], {"edit": "allow"})
        self.assertEqual(oc["provider"]["ollama"]["options"]["baseURL"], "http://box:11434/v1")
        self.assertIn("qwen3-coder:30b", oc["provider"]["ollama"]["models"])
        backup = json.loads((self.oc_path.parent / "opencode.json.foxml-bak").read_text())
        self.assertEqual(backup, user)

    def test_standin_promoted_only_when_agent_default_installed(self):
        self.install("qwen2.5-coder:14b")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "ollama/qwen2.5-coder:14b"}))
        self.run_script("--sync")
        self.assertEqual(self.oc()["model"], "ollama/qwen2.5-coder:14b")
        self.install("qwen2.5-coder:14b", "qwen3-coder:30b")
        self.run_script("--sync")
        self.assertEqual(self.oc()["model"], "ollama/qwen3-coder:30b")
        self.assertEqual(self.pi("settings.json")["defaultModel"], "qwen3-coder:30b")

    def test_user_picked_local_default_kept(self):
        self.install("gpt-oss:20b", "qwen3-coder:30b")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "ollama/gpt-oss:20b"}))
        self.run_script("--sync")
        self.assertEqual(self.oc()["model"], "ollama/gpt-oss:20b")

    def test_default_on_removed_model_is_replaced(self):
        self.install("qwen3-coder:30b")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "ollama/gone:1b"}))
        self.run_script("--sync")
        self.assertEqual(self.oc()["model"], "ollama/qwen3-coder:30b")

    def test_idempotent(self):
        self.install("qwen3-coder:30b", "qwen2.5:3b")
        self.run_script("--sync")
        first = (self.oc_path.read_text(), (self.home / ".pi/agent/settings.json").read_text())
        out = self.run_script("--sync")
        second = (self.oc_path.read_text(), (self.home / ".pi/agent/settings.json").read_text())
        self.assertEqual(first, second)
        self.assertEqual(out.strip(), "")

    def test_wanted_follows_ram_tier_and_extras(self):
        large = self.run_script("--wanted", meminfo_gb=32).split()
        self.assertIn("qwen3-coder:30b", large)
        self.assertIn("qwen2.5:3b", large)                         # tier: all
        small = self.run_script("--wanted", meminfo_gb=8).split()
        self.assertNotIn("qwen3-coder:30b", small)
        self.assertIn("qwen2.5-coder:7b", small)
        extra = self.home / ".config/foxml/llm/extra-models.txt"
        extra.parent.mkdir(parents=True, exist_ok=True)
        extra.write_text("# mine\nlaguna-xs-2.1:latest\nqwen2.5:3b\n")
        both = self.run_script("--wanted", meminfo_gb=32).split()
        self.assertIn("laguna-xs-2.1:latest", both)
        self.assertEqual(len(both), len(set(both)))                # no duplicates
        extra.write_text("-gpt-oss:20b\nqwen3.6:35b-a3b\n")         # "-x" skips a core model
        skipped = self.run_script("--wanted", meminfo_gb=32).split()
        self.assertNotIn("gpt-oss:20b", skipped)
        self.assertNotIn("-gpt-oss:20b", skipped)
        self.assertIn("qwen3-coder:30b", skipped)
        self.assertEqual(skipped[0], "qwen3.6:35b-a3b")            # extras first, in their order


    # ── llama.cpp router provider (roles file + fox-llm-server.service) ──

    def roles(self, text):
        f = self.home / ".config/foxml/llm/roles.conf"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    ROLES = "agent qwen3-coder:30b llama\nfim qwen2.5-coder:1.5b-base llama\ntitle qwen2.5:3b ollama\n"

    def test_llama_provider_and_default_when_server_on(self):
        self.install("qwen3-coder:30b", "qwen2.5-coder:1.5b-base", "qwen2.5:3b")
        self.roles(self.ROLES)
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        lp = oc["provider"]["llamacpp"]
        self.assertEqual(lp["options"]["baseURL"], "http://127.0.0.1:8080/v1")
        self.assertEqual(lp["models"]["qwen3-coder:30b"]["limit"]["context"], 131072)
        self.assertNotIn("qwen2.5-coder:1.5b-base", lp["models"])     # the fim base model: no chat picker
        self.assertNotIn("qwen2.5:3b", lp["models"])                  # an ollama role stays on ollama
        self.assertEqual(sorted(oc["provider"]["ollama"]["models"]), ["qwen2.5:3b"])   # each model once
        self.assertEqual(oc["model"], "llamacpp/qwen3-coder:30b")
        self.assertEqual(oc["small_model"], "ollama/qwen2.5:3b")
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen3-coder:30b"))
        ids = [m["id"] for m in self.pi("models.json")["providers"]["llamacpp"]["models"]]
        self.assertEqual(ids, ["qwen3-coder:30b"])

    def test_router_off_lists_nothing_there_and_defaults_stay_on_ollama(self):
        self.install("qwen3-coder:30b", "qwen2.5-coder:1.5b-base")
        self.roles(self.ROLES)
        self.run_script("--sync", server_on=False)
        oc = self.oc()
        self.assertFalse(oc["provider"].get("llamacpp", {}).get("models"))   # nothing a client could reach
        self.assertIn("qwen3-coder:30b", oc["provider"]["ollama"]["models"])
        self.assertEqual(oc["model"], "ollama/qwen3-coder:30b")
        self.assertEqual(self.pi("settings.json")["defaultProvider"], "ollama")

    def test_defaults_return_to_ollama_when_server_stops(self):
        self.install("qwen3-coder:30b", "qwen2.5-coder:1.5b-base")
        self.roles(self.ROLES)
        self.run_script("--sync", server_on=True)
        self.run_script("--sync", server_on=False)
        self.assertEqual(self.oc()["model"], "ollama/qwen3-coder:30b")
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("ollama", "qwen3-coder:30b"))

    def test_cloud_default_untouched_by_llama_roles(self):
        self.install("qwen3-coder:30b")
        self.roles(self.ROLES)
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "anthropic/claude-x"}))
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "anthropic/claude-x")


    def test_turbo_engine_role_gets_its_own_provider_and_default(self):
        self.install("qwen3-coder:30b", "qwen2.5-coder:1.5b-base")
        self.roles("agent qwen3-coder:30b llama-turbo\nfim qwen2.5-coder:1.5b-base llama\n")
        self.run_script("--sync", units="fox-llm-server fox-llm-server-turbo")
        oc = self.oc()
        self.assertEqual(oc["provider"]["llamacpp-turbo"]["options"]["baseURL"], "http://127.0.0.1:8081/v1")
        self.assertIn("qwen3-coder:30b", oc["provider"]["llamacpp-turbo"]["models"])
        self.assertFalse(oc["provider"].get("llamacpp", {}).get("models"))  # main serves only the fim model
        self.assertNotIn("qwen3-coder:30b", oc["provider"]["ollama"]["models"])
        self.assertEqual(oc["model"], "llamacpp-turbo/qwen3-coder:30b")
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp-turbo", "qwen3-coder:30b"))

    def test_turbo_agent_not_default_while_its_unit_is_off(self):
        self.install("qwen3-coder:30b")
        self.roles("agent qwen3-coder:30b llama-turbo\n")
        self.run_script("--sync", units="fox-llm-server")              # only the mainline router is on
        self.assertEqual(self.oc()["model"], "ollama/qwen3-coder:30b")
        self.assertEqual(self.pi("settings.json")["defaultProvider"], "ollama")


    # ── llama.cpp as the default server ──

    def test_installed_models_move_to_llama_cpp_before_and_after_the_agent_lands(self):
        self.install("qwen2.5-coder:14b", "qwen2.5-coder:1.5b-base", "qwen2.5:3b", "qwen2.5:7b",
                     "nomic-embed-text:latest")
        self.roles(self.ROLES)                                   # its agent, qwen3-coder:30b, not here yet
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        lm = oc["provider"]["llamacpp"]["models"]
        self.assertEqual(lm["qwen2.5:7b"], {"name": "qwen2.5:7b", "limit": {"context": 32768, "output": 8192}})
        self.assertIn("qwen2.5-coder:14b", lm)
        self.assertNotIn("nomic-embed-text:latest", lm)          # embeddings stay on Ollama
        self.assertNotIn("qwen2.5:3b", lm)                       # the title role is Ollama's
        self.assertEqual(oc["model"], "llamacpp/qwen2.5-coder:14b")      # the stand-in, on llama.cpp
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen2.5-coder:14b"))
        self.install(*self.installed, "qwen3-coder:30b")         # the agent lands
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "llamacpp/qwen3-coder:30b")
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen3-coder:30b"))

    def test_default_returns_to_ollama_when_llama_cpp_stops_serving_it(self):
        self.install("qwen2.5:7b", "qwen2.5-coder:1.5b-base")
        self.roles("fim qwen2.5-coder:1.5b-base llama\n")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "ollama/qwen2.5:7b"}))           # her pick
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "llamacpp/qwen2.5:7b")                   # same model, faster server
        self.roles("fim qwen2.5-coder:1.5b-base llama\nkeep qwen2.5:7b ollama\n")     # the server column wins
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "ollama/qwen2.5:7b")                     # same model, back on Ollama

    def test_router_reloads_its_model_list_only_while_enabled(self):
        self.install("qwen2.5:7b")
        self.roles(self.ROLES)
        log = self.tmp / "curl.log"
        self.run_script("--sync", server_on=False)
        self.assertFalse(log.exists())
        self.run_script("--sync", server_on=True)
        self.assertIn("http://127.0.0.1:8080/models?reload=1", log.read_text())
        self.assertNotIn(":8081", log.read_text())                                     # turbo unit is off


    # ── the model lists mirror the servers: every model once, under the server that runs it ──

    def test_each_model_listed_once_under_the_server_that_runs_it(self):
        self.modelfile_layers["gameproject:latest"] = ["system", "messages"]   # only Ollama runs it as built
        self.install("qwen2.5-coder:14b", "qwen2.5:7b", "qwen2.5:3b", "qwen2.5-coder:1.5b-base", "gameproject:latest")
        self.roles(self.ROLES)
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"provider": {"ollama": {"models": {
            "gone-model:7b": {"name": "gone-model:7b"},                         # deleted from Ollama long ago
            "qwen2.5:3b": {"name": "my title model", "limit": {"context": 4096, "output": 512}}}}}}))
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        on_ollama, on_llama = oc["provider"]["ollama"]["models"], oc["provider"]["llamacpp"]["models"]
        self.assertEqual(sorted(on_llama), ["qwen2.5-coder:14b", "qwen2.5:7b"])
        self.assertEqual(sorted(on_ollama), ["gameproject:latest", "qwen2.5:3b"])
        self.assertEqual(on_ollama["qwen2.5:3b"]["name"], "my title model")    # her settings on a kept entry
        pi = self.pi("models.json")["providers"]
        self.assertEqual(sorted(x["id"] for x in pi["ollama"]["models"]), ["gameproject:latest", "qwen2.5:3b"])
        self.assertEqual(sorted(x["id"] for x in pi["llamacpp"]["models"]), ["qwen2.5-coder:14b", "qwen2.5:7b"])

    def test_ollama_down_leaves_its_list_alone(self):
        self.install("qwen2.5:7b", "gameproject:latest")
        self.run_script("--sync")
        before = self.oc()["provider"]["ollama"]["models"]
        self.run_script("--sync", ollama_down=True)                          # `ollama list` fails: says nothing
        self.assertEqual(self.oc()["provider"]["ollama"]["models"], before)

    def test_router_off_moves_everything_back_to_ollama(self):
        self.install("qwen2.5-coder:14b", "qwen2.5:7b")
        self.roles(self.ROLES)
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "llamacpp/qwen2.5-coder:14b")
        self.run_script("--sync", server_on=False)
        oc = self.oc()
        self.assertEqual(sorted(oc["provider"]["ollama"]["models"]), ["qwen2.5-coder:14b", "qwen2.5:7b"])
        self.assertFalse(oc["provider"]["llamacpp"]["models"])
        self.assertEqual(oc["model"], "ollama/qwen2.5-coder:14b")

    # ── Hugging Face GGUFs (gguf-models.txt / ~/code/custom_models/gguf-models.conf) ──

    def hf_setup(self, sha=None, private=False):
        """One GGUF on a fake Hugging Face; returns its bytes and where it should land."""
        name, src_file = "huihui-qwen3.5-abliterated:9b", "Huihui-Qwen3.5-9B-abliterated.Q4_K_M.gguf"
        blob = b"GGUF" + os.urandom(4096)
        (self.tmp / "hf-blob").write_bytes(blob)
        (self.tmp / "hf-tree.json").write_text(json.dumps([{
            "type": "file", "path": src_file, "size": len(blob),
            "lfs": {"oid": sha or hashlib.sha256(blob).hexdigest(), "size": len(blob)}}]))
        lst = (self.home / "code/custom_models/gguf-models.conf" if private
               else self.home / ".config/foxml/llm/gguf-models.txt")
        lst.parent.mkdir(parents=True, exist_ok=True)
        lst.write_text(f"# name  user/repo/file\n{name} mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF/{src_file}\n")
        return blob, self.home / ".local/share/fox-llm/gguf" / f"{name}.gguf"

    def test_hugging_face_gguf_downloaded_verified_and_served(self):
        blob, dst = self.hf_setup(private=True)                  # the list a reinstall finds
        self.roles(self.ROLES)
        self.run_script("--models", server_on=True)
        self.assertEqual(dst.read_bytes(), blob)
        self.assertFalse(dst.with_name(dst.name + ".part").exists())
        oc = self.oc()
        self.assertIn("huihui-qwen3.5-abliterated:9b", oc["provider"]["llamacpp"]["models"])  # served by name
        self.assertNotIn("huihui-qwen3.5-abliterated:9b", oc["provider"]["ollama"]["models"])

    def test_hugging_face_gguf_download_resumes(self):
        blob, dst = self.hf_setup()
        part = dst.with_name(dst.name + ".part")
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(blob[:1000])                            # an earlier run, cut off
        self.run_script("--models")
        self.assertEqual(dst.read_bytes(), blob)
        self.assertIn("-C -", (self.tmp / "curl.log").read_text())

    def test_hugging_face_gguf_with_wrong_checksum_is_discarded(self):
        _, dst = self.hf_setup(sha="0" * 64)
        out = self.run_script("--models")
        self.assertIn("sha256 mismatch", out)
        self.assertFalse(dst.exists())
        self.assertFalse(dst.with_name(dst.name + ".part").exists())   # the next try starts clean


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
