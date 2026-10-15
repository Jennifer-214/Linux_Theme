#!/usr/bin/env python3
"""tests/test_fox_llm_sync.py — fox-llm-update offline: the wanted list, the Hugging Face downloads, the
queue, and --sync.

Runs the real script (and the real fox-llm-serve beside it) against a throwaway $HOME, with fake `curl`
(a Hugging Face of files the test writes), `llama-server`, `llama-fit-params`, `npm` and `systemctl` on
PATH — no network, no model server, no pi install. The contract under test: every model comes from a
Hugging Face file, verified before it goes live and checked against llama.cpp's loader before a long
download; sync only ADDS (user keys survive), mirrors what the routers serve, fills missing defaults,
moves the sync's own stand-in to the agent once it lands, and is idempotent.
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shared/bin/fox-llm-update"
CORE = ROOT / "shared/llm/core-models.txt"
ROLES_DEFAULT = ROOT / "shared/llm/roles.default"


# curl for the tests: Hugging Face's file records (hf-tree.json) and the files themselves (hf/<path>) come
# from what the test writes — whole, resumed on -C -, or a byte range on -r. Anything else (the router
# reload, a speed sample) is only logged — never sent anywhere.
FAKE_CURL = r'''#!/usr/bin/env python3
import os, sys
TMP = "@TMP@"
args = sys.argv[1:]
with open(TMP + "/curl.log", "a") as log:
    log.write(" ".join(args) + "\n")
url = next((a for a in args if a.startswith("http")), "")
if "-w" in args:
    sys.stdout.write("0")
elif "/api/models/" in url:
    sys.stdout.write(open(TMP + "/hf-tree.json").read())
elif "-o" in args and "/resolve/main/" in url:
    out = args[args.index("-o") + 1]
    blob = open(TMP + "/hf/" + url.split("/resolve/main/", 1)[1].replace("/", "__"), "rb").read()
    if "-r" in args:
        a, b = args[args.index("-r") + 1].split("-")
        open(out, "wb").write(blob[int(a):int(b) + 1])
    else:
        have = os.path.getsize(out) if "-C" in args and os.path.exists(out) else 0
        with open(out, "ab" if have else "wb") as f:
            f.write(blob[have:])
'''


def gguf(arch, pad=4096):
    """A real GGUF header (one key: general.architecture, no tensors) and some weight bytes."""
    key, val = b"general.architecture", arch.encode()
    return (b"GGUF" + struct.pack("<IQQ", 3, 0, 1) + struct.pack("<Q", len(key)) + key
            + struct.pack("<IQ", 8, len(val)) + val + os.urandom(pad))


class SyncTest(unittest.TestCase):
    def setUp(self):
        # Not /tmp: the noexec_tmp module mounts it noexec, so fake binaries there can't run.
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="fox-llm-test-", dir=base))
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.npm_root = self.tmp / "npm-root"
        self.models = self.home / ".local/share/fox-llm/gguf"
        self.home.mkdir()
        self.bin.mkdir()
        self.models.mkdir(parents=True)
        (self.tmp / "hf").mkdir()
        (self.tmp / "hf-tree.json").write_text("[]")
        # Fake pi examples tree, as `npm root -g` would expose it (pi ≥ 1.0's package name).
        self._examples("@earendil-works/pi-coding-agent")
        (self.bin / "npm").write_text(f'#!/bin/sh\n[ "$1" = root ] && echo "{self.npm_root}"\n')
        # Only `is-enabled` matters to sync: the routers' units come from the test, not the box.
        (self.bin / "systemctl").write_text(
            '#!/bin/sh\necho "$*" >> "$SYSTEMCTL_LOG"\ncase "$*" in *is-enabled*)\n'
            '  for u in $FAKE_UNITS; do case "$*" in *" $u.service"*) exit 0;; esac; done; exit 1;;\n'
            'esac\nexit 0\n')
        (self.bin / "llama-server").write_text('#!/bin/sh\necho "Available devices:"\n')
        # llama.cpp's header-only loader: an architecture named "gptoss" is one this build doesn't know.
        (self.bin / "llama-fit-params").write_text(
            '#!/bin/sh\necho "$2" >> "$PROBE_LOG"\n'
            'if grep -q gptoss "$2"; then echo "E llama_model_load: error loading model: '
            "unknown model architecture: 'gptoss'\"; exit 1; fi\nexit 0\n")
        (self.bin / "curl").write_text(FAKE_CURL.replace("@TMP@", str(self.tmp)))
        # Desktop notices only logged — a test never reaches her real desktop.
        (self.bin / "notify-send").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$NOTIFY_LOG"\n')
        # The report card's background run only logged — a test never starts a job in her user manager.
        (self.bin / "systemd-run").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RUN_LOG"\n')
        for f in ("npm", "systemctl", "llama-server", "llama-fit-params", "curl", "notify-send", "systemd-run"):
            (self.bin / f).chmod(0o755)

    def _examples(self, pkg):
        ex = self.npm_root / pkg / "examples/extensions"
        (ex / "plan-mode").mkdir(parents=True)
        (ex / "subagent/agents").mkdir(parents=True)
        (ex / "subagent/prompts").mkdir(parents=True)
        for f in ("git-checkpoint.ts", "subagent/index.ts", "subagent/agents.ts", "plan-mode/index.ts"):
            (ex / f).write_text("// stub\n")
        (ex / "subagent/agents/scout.md").write_text("---\nname: scout\nmodel: claude-haiku-4-5\n---\nbody\n")
        (ex / "subagent/prompts/implement.md").write_text("implement\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, *args, meminfo_gb=32, server_on=False, units=None, core=True):
        meminfo = self.tmp / "meminfo"
        meminfo.write_text(f"MemTotal:       {meminfo_gb * 1048576 - 1000} kB\n")
        cfg = self.home / ".config"
        (cfg / "foxml/llm").mkdir(parents=True, exist_ok=True)
        if core:
            shutil.copy(CORE, cfg / "foxml/llm/core-models.txt")
        else:
            (cfg / "foxml/llm/core-models.txt").write_text("")
        shutil.copy(ROLES_DEFAULT, cfg / "foxml/llm/roles.default")          # deployed beside it, as on a box
        env = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(cfg),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FOX_LLM_MEMINFO": str(meminfo),
            "FAKE_UNITS": units if units is not None else ("fox-llm-server" if server_on else ""),
            "SYSTEMCTL_LOG": str(self.tmp / "systemctl.log"),
            "PROBE_LOG": str(self.tmp / "probe.log"),
            "NOTIFY_LOG": str(self.tmp / "notify.log"),
            "RUN_LOG": str(self.tmp / "run.log"),
            "FOX_LLM_SERVER": str(self.bin / "llama-server"),
        }
        r = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def install(self, *names):
        """Models already downloaded (the router serves what is in the folder)."""
        for n in names:
            (self.models / f"{n}.gguf").write_bytes(b"GGUF")

    def hf_add(self, name, src, blob=None, sha=None, listed="machine"):
        """A file on the fake Hugging Face, listed as `name src` in this machine's list ("machine"), your
        custom_models list ("private"), or nowhere (None). Returns its bytes and where it lands."""
        blob = blob if blob is not None else gguf("qwen2")
        repo_file = src.split("/", 2)[2]
        (self.tmp / "hf" / repo_file.replace("/", "__")).write_bytes(blob)
        tree = json.loads((self.tmp / "hf-tree.json").read_text())
        tree = [t for t in tree if t["path"] != repo_file] + [{
            "type": "file", "path": repo_file, "size": len(blob),
            "lfs": {"oid": sha or hashlib.sha256(blob).hexdigest(), "size": len(blob)}}]
        (self.tmp / "hf-tree.json").write_text(json.dumps(tree))
        if listed:
            lst = (self.home / "code/custom_models/gguf-models.conf" if listed == "private"
                   else self.home / ".config/foxml/llm/gguf-models.txt")
            lst.parent.mkdir(parents=True, exist_ok=True)
            with open(lst, "a") as f:
                f.write(f"{name} {src}\n")
        return blob, self.models / f"{name}.gguf"

    def roles(self, text):
        f = self.home / ".config/foxml/llm/roles.conf"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    @property
    def oc_path(self):
        return self.home / ".config/opencode/opencode.json"

    def oc(self):
        return json.loads(self.oc_path.read_text())

    def pi(self, name):
        return json.loads((self.home / ".pi/agent" / name).read_text())

    def notices(self):
        """Desktop notices since the last call, one string each ("-a fox-llm TITLE BODY")."""
        log = self.tmp / "notify.log"
        text = log.read_text() if log.exists() else ""
        log.unlink(missing_ok=True)
        return text

    def curl_log(self):
        log = self.tmp / "curl.log"
        return log.read_text() if log.exists() else ""

    # ── sync: opencode + pi follow what the routers serve ──

    def test_fresh_home_gets_full_config(self):
        self.install("qwen3-coder:30b", "qwen2.5:3b", "mxbai-embed-large")    # roles.default's agent/title/embed
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        self.assertEqual(oc["model"], "llamacpp/qwen3-coder:30b")
        self.assertEqual(oc["small_model"], "llamacpp/qwen2.5:3b")
        self.assertFalse(oc["autoupdate"])
        self.assertEqual(oc["share"], "disabled")
        self.assertEqual(oc["permission"]["bash"]["*"], "ask")
        self.assertNotIn("find *", oc["permission"]["bash"])
        self.assertNotIn("ollama", oc["provider"])
        models = oc["provider"]["llamacpp"]["models"]
        self.assertNotIn("mxbai-embed-large", models)                    # embeddings: no chat picker's
        self.assertEqual(models["qwen3-coder:30b"]["limit"]["context"], 131072)
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen3-coder:30b"))
        self.assertFalse(st["enableInstallTelemetry"])
        pi = self.pi("models.json")["providers"]
        self.assertNotIn("ollama", pi)
        self.assertEqual(sorted(m["id"] for m in pi["llamacpp"]["models"]), ["qwen2.5:3b", "qwen3-coder:30b"])

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
        self.assertIn("@earendil-works", os.readlink(agent / "extensions/plan-mode"))

    def test_pi_resources_from_the_old_package_before_the_move(self):
        # a machine still on pi 0.73.1 (@mariozechner): the links come from there until the update moves it
        shutil.rmtree(self.npm_root / "@earendil-works")
        self._examples("@mariozechner/pi-coding-agent")
        self.run_script("--sync")
        self.assertIn("@mariozechner", os.readlink(self.home / ".pi/agent/extensions/plan-mode"))

    def test_user_keys_survive_and_backup_made(self):
        self.install("qwen3-coder:30b")
        self.oc_path.parent.mkdir(parents=True)
        user = {"model": "anthropic/claude-x", "theme": "mine", "permission": {"edit": "allow"},
                "provider": {"ollama": {"options": {"baseURL": "http://box:11434/v1"}, "models": {}}}}
        self.oc_path.write_text(json.dumps(user))
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        self.assertEqual(oc["model"], "anthropic/claude-x")       # a cloud default: never touched
        self.assertEqual(oc["theme"], "mine")
        self.assertEqual(oc["permission"]["edit"], "allow")
        self.assertNotIn("*", oc["permission"]["bash"])         # only the secret rules join her block
        self.assertEqual(oc["provider"]["ollama"]["options"]["baseURL"], "http://box:11434/v1")   # not this box's
        self.assertIn("qwen3-coder:30b", oc["provider"]["llamacpp"]["models"])
        self.assertEqual(json.loads((self.oc_path.parent / "opencode.json.foxml-bak").read_text()), user)

    def test_this_machines_ollama_provider_goes_and_its_default_moves_to_llama_cpp(self):
        self.install("qwen2.5:7b")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "ollama/qwen2.5:7b", "provider": {"ollama": {
            "options": {"baseURL": "http://localhost:11434/v1"}, "models": {"qwen2.5:7b": {}}}}}))
        pi_dir = self.home / ".pi/agent"
        pi_dir.mkdir(parents=True)
        (pi_dir / "models.json").write_text(json.dumps({"providers": {"ollama": {
            "baseUrl": "http://localhost:11434/v1", "models": [{"id": "qwen2.5:7b"}]}}}))
        (pi_dir / "settings.json").write_text(json.dumps({"defaultProvider": "ollama", "defaultModel": "qwen2.5:7b"}))
        out = self.run_script("--sync", server_on=True)
        oc = self.oc()
        self.assertNotIn("ollama", oc["provider"])
        self.assertEqual(oc["model"], "llamacpp/qwen2.5:7b")             # same model, on llama.cpp
        self.assertNotIn("ollama", self.pi("models.json")["providers"])
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen2.5:7b"))
        self.assertIn("opencode: − ollama provider", out)

    def test_quick_model_stands_in_until_the_agent_lands_and_her_pick_stays_hers(self):
        self.install("qwen3.5:4b", "qwen2.5-coder:1.5b-base", "qwen2.5:7b")   # roles.default's agent: not yet
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "llamacpp/qwen3.5:4b")             # sized for this machine
        said = self.notices()
        self.assertIn("Local model default changed", said)
        self.assertIn("pi default → llamacpp/qwen3.5:4b (standing in for the agent, which isn't served yet)", said)
        self.assertIn("A role has no model to serve", said)
        self.assertIn("qwen3-coder:30b (agent)", said)
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.notices(), "")                                    # each change said once
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen3.5:4b"))
        self.install("qwen3-coder:30b")                                         # the agent lands: the sync's
        self.run_script("--sync", server_on=True)                               # own stand-in gives way
        self.assertEqual(self.oc()["model"], "llamacpp/qwen3-coder:30b")
        said = self.notices()
        self.assertIn("opencode default → llamacpp/qwen3-coder:30b (the roles file's agent)", said)
        self.assertNotIn("no model to serve", said)
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp", "qwen3-coder:30b"))
        oc = self.oc(); oc["model"] = "llamacpp/qwen2.5:7b"                     # her own pick (fox-ai-swap)
        self.oc_path.write_text(json.dumps(oc))
        for _ in range(2):                                                       # stays hers, sync after sync
            self.run_script("--sync", server_on=True)
            self.assertEqual(self.oc()["model"], "llamacpp/qwen2.5:7b")

    def test_default_on_a_model_no_longer_served_is_replaced(self):
        self.install("qwen3-coder:30b")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"model": "llamacpp/gone:1b"}))
        self.run_script("--sync", server_on=True)
        self.assertEqual(self.oc()["model"], "llamacpp/qwen3-coder:30b")

    def test_opencode_asks_before_a_secret_path_and_those_rules_come_last(self):
        self.install("qwen2.5:3b")
        self.run_script("--sync")
        perm, home = self.oc()["permission"], str(self.home)
        bash = list(perm["bash"].items())
        self.assertEqual(bash[0], ("*", "ask"))
        self.assertEqual(perm["bash"]["cat *"], "allow")
        first_secret = next(i for i, (k, _) in enumerate(bash) if k == "*~/.ssh*")
        self.assertTrue(all(v == "ask" for _, v in bash[first_secret:]))          # last: they win over `cat *`
        self.assertTrue(all(v == "allow" for _, v in bash[1:first_secret]))
        for pat in ("*$HOME/.gnupg*", f"*{home}/.config/foxml*", "*/priv/*", "*id_ed25519*"):
            self.assertEqual(perm["bash"][pat], "ask")
        for tool in ("read", "grep", "glob", "list"):
            self.assertEqual(perm[tool][f"{home}/.ssh/*"], "ask")
            self.assertEqual(perm[tool]["*.pem*"], "ask")
            self.assertNotIn("*", perm[tool])                                       # the rest stays opencode's
        for root in (home, home + "/", "/"):
            self.assertEqual(perm["grep"][root], "ask")                            # a search from ~ reads ~/.ssh
            self.assertNotIn(root, perm["read"])

    def test_opencode_secret_rules_join_her_own_once_and_keep_her_choices(self):
        self.install("qwen2.5:3b")
        self.oc_path.parent.mkdir(parents=True)
        mine = {"bash": {"*": "allow", "npm *": "deny"}, "read": "deny"}
        self.oc_path.write_text(json.dumps({"permission": mine}))
        out = self.run_script("--sync")
        perm = self.oc()["permission"]
        self.assertEqual(list(perm["bash"].items())[:2], [("*", "allow"), ("npm *", "deny")])
        self.assertEqual(perm["bash"]["*~/.ssh*"], "ask")
        self.assertEqual(perm["read"], "deny")                                      # one action for the tool: hers
        self.assertIn("secret paths ask first", out)
        before = self.oc_path.read_text()
        self.assertNotIn("secret paths", self.run_script("--sync"))
        self.assertEqual(self.oc_path.read_text(), before)

    def test_opencode_secret_list_is_fox_guards(self):
        import re
        guard = (ROOT / "shared/pi/extensions/fox-guard.ts").read_text()
        prefixes = re.search(r"PROTECTED_PREFIXES = \[(.*?)\];", guard, re.S).group(1)
        dirs = re.findall(r"`\$\{HOME\}/([^`]+)`", prefixes)
        bits = re.findall(r'"([^"]+)"', re.search(r"PROTECTED_FRAGMENTS = \[(.*?)\];", guard, re.S).group(1))
        script = SCRIPT.read_text()
        self.assertEqual(eval(re.search(r"^SECRET_DIRS = (\[.*?\])$", script, re.M).group(1)), dirs)
        self.assertEqual(eval(re.search(r"^SECRET_BITS = (\[.*?\])$", script, re.M).group(1)),
                         [b for b in bits if b != "/.git/"])        # .git/ is a write rule in pi, not a secret

    # ── the prompt library → opencode's commands (format 1: ~/.config/foxml/prompts/README.md) ──

    def prompt(self, name, text):
        d = self.home / ".config/foxml/prompts"
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(text)
        return d / name

    @property
    def commands(self):
        return self.home / ".config/opencode/commands"

    def test_prompt_library_becomes_opencode_commands(self):
        self.install("qwen2.5:3b")
        self.prompt("README.md", "# The prompt library — format 1\n")
        self.prompt("_draft.md", "---\ndescription: not yet\n---\nbody\n")
        src = self.prompt("review-diff.md",
                          "---\ndescription: Review the staged diff for correctness bugs\nargument-hint: \"[focus]\"\n"
                          "targets: [pi, opencode]\nopencode:\n  agent: build\n  subtask: false\n"
                          "codecompanion:\n  interaction: chat\n---\n"
                          "## system\nYou review C++ for correctness.\n## user\nReview `git diff --cached`, focus: $ARGUMENTS\n")
        self.prompt("explain-sel.md", "---\ndescription: Explain the selection\n---\nExplain:\n{{selection}}\n")
        self.prompt("cc-only.md", "---\ndescription: chat\ntargets: [codecompanion]\n---\nHi $1\n")
        self.prompt("forced.md", "---\ndescription: x\ntargets: [opencode]\n---\nSee {{file}}\n")
        self.prompt("Bad_Name.md", "---\ndescription: x\n---\nbody\n")
        self.prompt("nodesc.md", "---\nargument-hint: x\n---\nbody\n")
        self.prompt("review.md", "---\ndescription: clash\n---\nbody\n")
        out = self.run_script("--sync")
        self.assertEqual(sorted(p.name for p in self.commands.iterdir()), ["review-diff.md"])
        self.assertEqual((self.commands / "review-diff.md").read_text(),
                         f"---\n# generated by fox-llm-update from {src}\n"
                         "description: Review the staged diff for correctness bugs\nagent: build\nsubtask: false\n---\n"
                         "You review C++ for correctness.\n\nReview `git diff --cached`, focus: $ARGUMENTS\n")
        self.assertIn("/review-diff (from the prompt library)", out)
        self.assertIn("/forced not made — it uses the editor's context", out)     # an explicit target it can't fit
        self.assertIn("/Bad_Name not made — a name is lowercase", out)
        self.assertIn("/nodesc not made — no description", out)
        self.assertIn("/review not made — /review is opencode's own command", out)
        for quiet in ("explain-sel", "cc-only", "_draft", "README"):
            self.assertNotIn(f"/{quiet} ", out)                                  # not opencode's: nothing to say

    def test_prompt_commands_leave_hers_alone_follow_deletions_and_rewrite_nothing_unchanged(self):
        self.install("qwen2.5:3b")
        self.commands.mkdir(parents=True)
        (self.commands / "mine.md").write_text("---\ndescription: hand-written\n---\nmine\n")
        self.prompt("mine.md", "---\ndescription: from the library\n---\nlibrary\n")
        gone = self.prompt("gone.md", "---\ndescription: soon gone\n---\nbody\n")
        out = self.run_script("--sync")
        self.assertIn("/mine not made", out)
        self.assertEqual((self.commands / "mine.md").read_text(), "---\ndescription: hand-written\n---\nmine\n")
        made = self.commands / "gone.md"
        stamp = made.stat().st_mtime_ns
        self.assertNotIn("/gone", self.run_script("--sync"))                    # unchanged: not written again
        self.assertEqual(made.stat().st_mtime_ns, stamp)
        gone.unlink()
        self.assertIn("− /gone", self.run_script("--sync"))
        self.assertFalse(made.exists())
        self.assertTrue((self.commands / "mine.md").exists())

    def test_idempotent(self):
        self.install("qwen3-coder:30b", "qwen2.5:3b")
        self.run_script("--sync", server_on=True)
        first = (self.oc_path.read_text(), (self.home / ".pi/agent/settings.json").read_text())
        out = self.run_script("--sync", server_on=True)
        second = (self.oc_path.read_text(), (self.home / ".pi/agent/settings.json").read_text())
        self.assertEqual(first, second)
        self.assertEqual(out.strip(), "")

    def test_router_off_lists_nothing_and_moves_no_default(self):
        self.install("qwen3-coder:30b", "qwen2.5:3b")
        self.run_script("--sync", server_on=False)
        oc = self.oc()
        self.assertFalse(oc["provider"].get("llamacpp", {}).get("models"))   # nothing a client could reach
        self.assertNotIn("model", oc)

    def test_cloud_default_untouched(self):
        self.install("qwen3-coder:30b")
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
        self.assertEqual(oc["model"], "llamacpp-turbo/qwen3-coder:30b")
        st = self.pi("settings.json")
        self.assertEqual((st["defaultProvider"], st["defaultModel"]), ("llamacpp-turbo", "qwen3-coder:30b"))

    def test_turbo_agent_not_default_while_its_unit_is_off(self):
        self.install("qwen3-coder:30b", "qwen2.5:7b")
        self.roles("agent qwen3-coder:30b llama-turbo\n")
        self.run_script("--sync", units="fox-llm-server")              # only the main router is on
        self.assertEqual(self.oc()["model"], "llamacpp/qwen2.5:7b")      # a model something serves

    def test_router_reloads_its_model_list_only_while_enabled(self):
        self.install("qwen2.5:7b")
        self.run_script("--sync", server_on=False)
        self.assertNotIn("models?reload", self.curl_log())
        self.run_script("--sync", server_on=True)
        self.assertIn("http://127.0.0.1:8080/models?reload=1", self.curl_log())
        self.assertNotIn(":8081", self.curl_log())                       # turbo unit is off

    def test_lists_mirror_the_router_and_keep_her_settings_on_an_entry(self):
        self.install("qwen2.5-coder:14b", "qwen2.5:7b", "qwen2.5-coder:1.5b-base", "nomic-embed-text")
        self.oc_path.parent.mkdir(parents=True)
        self.oc_path.write_text(json.dumps({"provider": {"llamacpp": {"models": {
            "gone-model:7b": {"name": "gone-model:7b"},                        # deleted long ago
            "qwen2.5:7b": {"name": "my 7b", "limit": {"context": 4096, "output": 512}}}}}}))
        self.run_script("--sync", server_on=True)
        lm = self.oc()["provider"]["llamacpp"]["models"]
        self.assertEqual(sorted(lm), ["qwen2.5-coder:14b", "qwen2.5:7b"])     # no fim, no embeddings, no ghosts
        self.assertEqual(lm["qwen2.5:7b"]["name"], "my 7b")
        self.assertEqual(lm["qwen2.5-coder:14b"], {"name": "qwen2.5-coder:14b", "limit": {"context": 32768, "output": 8192}})
        pi = self.pi("models.json")["providers"]
        self.assertEqual(sorted(x["id"] for x in pi["llamacpp"]["models"]), ["qwen2.5-coder:14b", "qwen2.5:7b"])

    def test_roles_in_the_custom_models_repo_count(self):
        self.install("qwen2.5:7b", "qwen2.5-coder:1.5b-base")
        repo = self.home / "code/custom_models/roles.conf"                 # no ~/.config roles.conf
        repo.parent.mkdir(parents=True)
        repo.write_text("agent qwen2.5:7b llama\nfim qwen2.5-coder:1.5b-base llama\n")
        self.run_script("--sync", server_on=True)
        oc = self.oc()
        self.assertEqual(oc["model"], "llamacpp/qwen2.5:7b")
        self.assertEqual(oc["provider"]["llamacpp"]["models"]["qwen2.5:7b"]["name"], "qwen2.5:7b (agent)")

    # ── the wanted list fox-install's models step hands to the queue ──

    def test_wanted_follows_ram_tier_with_the_helpers_first(self):
        large = [l.split() for l in self.run_script("--wanted", meminfo_gb=32).splitlines()]
        names = [n for n, _ in large]
        self.assertTrue(all(src.count("/") >= 2 and src.endswith(".gguf") for _, src in large))
        self.assertIn("qwen3-coder:30b", names)
        self.assertLess(names.index("mxbai-embed-large"), names.index("qwen3-coder:30b"))   # helpers first
        small = self.run_script("--wanted", meminfo_gb=8)
        self.assertNotIn("qwen3-coder:30b", small)
        self.assertIn("qwen2.5-coder:7b", small)
        self.assertEqual(len(names), len(set(names)))

    def test_wanted_reads_your_lists_in_order_and_skips(self):
        cfg = self.home / ".config/foxml/llm"
        cfg.mkdir(parents=True, exist_ok=True)
        (cfg / "gguf-models.txt").write_text("# this machine\nmine:7b u/r/mine.gguf\n-gpt-oss:20b\n")
        repo = self.home / "code/custom_models"
        repo.mkdir(parents=True)
        (repo / "gguf-models.conf").write_text("yours:9b u/r/yours.gguf\nmine:7b u/other/ignored.gguf\n")
        (repo / "foxml-models.txt").write_text("old-ollama-name:7b\n")              # an Ollama list: not read
        (cfg / "extra-models.txt").write_text("another-old:3b\n")
        out = [l.split() for l in self.run_script("--wanted").splitlines()]
        names = [n for n, _ in out]
        helpers = [l.split()[0] for l in CORE.read_text().split("# tier: all", 1)[1].splitlines()
                   if l.strip() and not l.startswith("#")]
        self.assertEqual(names[:len(helpers)], helpers)                             # the core list's helpers
        self.assertEqual(names[len(helpers):len(helpers) + 2], ["mine:7b", "yours:9b"])   # then yours, in order
        self.assertIn(["mine:7b", "u/r/mine.gguf"], out)                            # the first list decides
        self.assertNotIn("gpt-oss:20b", names)                                      # a skip drops it everywhere
        self.assertNotIn("old-ollama-name:7b", names)
        self.assertNotIn("another-old:3b", names)
        self.assertIn("qwen3-coder:30b", names)                                     # then the core tier

    def test_queue_restarts_so_an_update_runs_the_new_code(self):
        self.run_script("--queue")
        calls = (self.tmp / "systemctl.log").read_text()
        self.assertIn("--user restart fox-llm-pull.service", calls)        # not `enable --now`: a running
        self.assertNotIn("--now", calls)                                   # queue would keep its old code
        self.assertTrue((self.home / ".config/systemd/user/fox-llm-pull.service").exists())

    # ── Hugging Face downloads ──

    def test_download_verified_recorded_and_served(self):
        src = "mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF/Huihui-Qwen3.5-9B-abliterated.Q4_K_M.gguf"
        blob, dst = self.hf_add("huihui-qwen3.5-abliterated:9b", src, listed="private")   # the list a reinstall finds
        self.run_script("--models", server_on=True, core=False)
        self.assertEqual(dst.read_bytes(), blob)
        self.assertFalse(dst.with_name(dst.name + ".part").exists())
        self.assertEqual((self.models / ".src/huihui-qwen3.5-abliterated:9b").read_text().split(),
                         [src, hashlib.sha256(blob).hexdigest()])
        self.assertIn("huihui-qwen3.5-abliterated:9b", self.oc()["provider"]["llamacpp"]["models"])
        probes = (self.tmp / "probe.log").read_text().splitlines()
        self.assertIn("/.probe/", probes[0])                         # its header, before the download …
        self.assertEqual(probes[1:], [str(dst)])                        # … then the file, as the router serves it

    def test_download_resumes(self):
        blob, dst = self.hf_add("x:7b", "u/r/x.gguf")
        part = dst.with_name(dst.name + ".part")
        part.write_bytes(blob[:1000])                                    # an earlier run, cut off
        self.run_script("--models", core=False)
        self.assertEqual(dst.read_bytes(), blob)
        self.assertIn("-C -", self.curl_log())

    def test_wrong_checksum_is_discarded(self):
        _, dst = self.hf_add("x:7b", "u/r/x.gguf", sha="0" * 64)
        out = self.run_script("--models", core=False)
        self.assertIn("sha256 mismatch", out + self.curl_log())
        self.assertFalse(dst.exists())
        self.assertFalse(dst.with_name(dst.name + ".part").exists())   # the next try starts clean

    def test_a_model_this_llama_cpp_cannot_load_is_never_downloaded(self):
        _, dst = self.hf_add("newfangled:20b", "u/r/newfangled.gguf", blob=gguf("gptoss"))
        out = self.run_script("--models", core=False)
        self.assertFalse(dst.exists())
        self.assertNotIn(" -C - ", self.curl_log())                       # only the header was fetched
        self.assertIn("-r 0-", self.curl_log())
        self.assertIn("unknown model architecture: 'gptoss'", out + (self.home / ".cache/fox-llm-update/incompatible").read_text())
        self.run_script("--models", core=False)                          # remembered for this build:
        self.assertEqual(len((self.tmp / "probe.log").read_text().splitlines()), 1)   # not fetched again

    def test_a_split_model_is_refused(self):
        _, dst = self.hf_add("big:200b", "u/r/big-00001-of-00003.gguf")
        out = self.run_script("--models", core=False)
        self.assertFalse(dst.exists())
        self.assertIn("one part of a split model", out + self.curl_log() + self.run_script("--models", core=False))

    def test_a_newer_upload_of_a_downloaded_file_replaces_it(self):
        old, dst = self.hf_add("x:7b", "u/r/x.gguf")
        self.run_script("--models", core=False)
        self.assertEqual(dst.read_bytes(), old)
        self.run_script("--models", core=False)                          # unchanged upstream: nothing fetched
        self.assertEqual(self.curl_log().count("/resolve/main/x.gguf") - self.curl_log().count("-r 0-"), 1)
        new, _ = self.hf_add("x:7b", "u/r/x.gguf", blob=gguf("qwen2", pad=8192), listed=None)
        self.run_script("--models", core=False)
        self.assertEqual(dst.read_bytes(), new)
        self.assertEqual((self.models / ".src/x:7b").read_text().split()[1], hashlib.sha256(new).hexdigest())

    def test_a_model_you_put_there_yourself_is_never_replaced(self):
        mine = self.models / "x:7b.gguf"
        mine.write_bytes(b"GGUF my own")                                 # no .src record: hers
        self.hf_add("x:7b", "u/r/x.gguf")
        self.run_script("--models", core=False)
        self.assertEqual(mine.read_bytes(), b"GGUF my own")

    def test_queue_downloads_what_is_missing_and_ends(self):
        a, dst_a = self.hf_add("a:1b", "u/r/a.gguf")
        _, dst_b = self.hf_add("b:1b", "u/r/b.gguf", blob=gguf("gptoss"))   # can't load here: left out
        out = self.run_script("--queue-run", core=False)
        self.assertEqual(dst_a.read_bytes(), a)
        self.assertFalse(dst_b.exists())
        self.assertIn("ALL_DONE", out)
        self.assertIn("--user disable fox-llm-pull.service", (self.tmp / "systemctl.log").read_text())
        said = self.notices()
        self.assertIn("Model downloaded a:1b: verified", said)
        self.assertEqual((self.home / ".local/state/fox-llm-update/grade-pending.txt").read_text(), "a:1b\n")
        self.assertIn("fox-llm-grade --pending", (self.tmp / "run.log").read_text())     # graded once nothing's in use
        self.assertNotIn("b:1b", said)
        self.assertIn("Downloads finished", said)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
