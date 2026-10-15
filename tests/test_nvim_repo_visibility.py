#!/usr/bin/env python3
"""Test for templates/nvim/init.lua's fox-repo-visibility block — Copilot only where the code is public.

The block (between its two sentinel lines) runs on its own in a bare headless nvim, against scratch git repos — one per
remote form, plus another host, no remote, and no repo — and a fake `gh`. PATH holds only the fake `gh` and a link to
git, so the real `gh` (and the network) is never reached. Checks: each file's visibility and its engine in both modes;
that a lookup never blocks; the day cache, its expiry, and its atomic write; the ten-minute hold on "unknown"; no `gh`
at all; and the template's wiring (Copilot's should_attach and the minuet switch both follow RepoVis.engine).

Run directly (`python3 tests/test_nvim_repo_visibility.py`) or via `make test` (the test-scripts target).
Exit 0 = pass (or skipped when nvim or git is not installed — said so), 1 = fail.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "templates/nvim/init.lua"
BEGIN, END = "-- >>> fox-repo-visibility", "-- <<< fox-repo-visibility"

fails = []
def check(name, cond):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


NVIM, GIT, SLEEP = shutil.which("nvim"), shutil.which("git"), shutil.which("sleep")
missing = [n for n, p in (("nvim", NVIM), ("git", GIT), ("sleep", SLEEP)) if not p]
if missing:
    print(f"  skip {', '.join(missing)} not installed here — nothing checked")
    sys.exit(0)

text = TEMPLATE.read_text(encoding="utf-8")
lines = text.split("\n")
b = [i for i, line in enumerate(lines) if line == BEGIN]
e = [i for i, line in enumerate(lines) if line == END]
check("the block's two sentinel lines occur once each, in order", len(b) == 1 and len(e) == 1 and b[0] < e[0])
if fails:
    sys.exit(1)
BLOCK = "\n".join(lines[b[0] + 1:e[0]])

# the wiring, read from the template
check("Copilot's should_attach is its own rule AND RepoVis.engine == copilot",
      'should_attach = function(buf, name)' in text
      and 'require("copilot.config.should_attach").default(buf, name) and RepoVis.engine(buf) == "copilot"' in text)
check("the minuet switch follows RepoVis.engine, per buffer",
      'local copilot = RepoVis.engine(buf) == "copilot"' in text
      and "vim.b[buf].minuet_virtual_text_auto_trigger = not copilot" in text)
check("no engine mode puts Copilot on every buffer (the old global 'copilot' default is gone)",
      'vim.g.fox_completion = vim.g.fox_completion or "copilot"' not in text)

# the scratch world: under the cache dir, not /tmp (which may be mounted noexec — the fake gh must run)
cache_home = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
TMP = Path(tempfile.mkdtemp(prefix="fox-repovis-test-", dir=cache_home if os.path.isdir(cache_home) else None))
ENV0 = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}  # a hook's GIT_DIR must not leak in

def run(argv, **kw):
    return subprocess.run(argv, env=ENV0, capture_output=True, text=True, timeout=60, **kw)

try:
    log = TMP / "gh.log"
    bins = {}
    for name, with_gh in (("bin", True), ("bin-nogh", False)):
        d = TMP / name
        d.mkdir()
        os.symlink(GIT, d / "git")
        if with_gh:
            gh = d / "gh"
            gh.write_text(
                "#!/bin/sh\n"
                "# the fake gh: a visibility per repo, every call logged — never the network\n"
                f'echo "$*" >> "{log}"\n'
                'case "$FAKE_GH_MODE" in fail) echo "fake gh: failing" >&2; exit 1;; '
                f'slow) "{SLEEP}" 1;; esac\n'
                'case "$2" in\n'
                "  repos/octo/pub|repos/octo/pub2) echo public;;\n"
                "  repos/octo/priv) echo private;;\n"
                '  *) echo "fake gh: no such repo $2" >&2; exit 1;;\n'
                "esac\n")
            gh.chmod(0o755)
        bins[name] = d

    def repo(name, url):
        d = TMP / "repos" / name
        d.mkdir(parents=True)
        if url is not False:
            run([GIT, "init", "-q", str(d)])
            if url:
                run([GIT, "-C", str(d), "remote", "add", "origin", url])
        f = d / "src" / "a.cpp"
        f.parent.mkdir()
        f.write_text("int main() { return 0; }\n")
        return str(f)

    CASES = [  # (name, file, visibility expected)
        ("git@ form, public", repo("pub", "git@github.com:octo/pub.git"), "public"),
        ("https form, private", repo("priv", "https://github.com/octo/priv"), "private"),
        ("ssh:// form, public", repo("pub2", "ssh://git@github.com/octo/pub2.git"), "public"),
        ("another host", repo("lab", "git@gitlab.com:octo/x.git"), "unknown"),
        ("no remote", repo("none", None), "unknown"),
        ("not a repo", repo("plain", False), "unknown"),
    ]
    (TMP / "block.lua").write_text(BLOCK + "\nreturn RepoVis\n", encoding="utf-8")
    (TMP / "driver.lua").write_text(r'''
-- runs the block alone; each step's result goes into R, printed as JSON at the end
local RepoVis = assert(loadfile(vim.env.BLOCK))()
local R = { exepath_gh = vim.fn.exepath("gh"), path = RepoVis.path }
local function look(file)
  local v
  local t0 = vim.uv.hrtime()
  RepoVis.lookup(file, function(x) v = x end)
  local call_ms = (vim.uv.hrtime() - t0) / 1e6
  vim.wait(20000, function() return v ~= nil end, 10)
  return v, call_ms
end
local steps = vim.json.decode(vim.env.STEPS)
local files = vim.json.decode(vim.env.FILES)
for _, step in ipairs(steps) do
  if step == "all" then
    R.all = {}
    for _, f in ipairs(files) do
      local v, ms = look(f)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.b[buf].fox_visibility = v
      vim.g.fox_completion = "auto"
      local auto = RepoVis.engine(buf)
      vim.g.fox_completion = "local"
      local loc = RepoVis.engine(buf)
      table.insert(R.all, { file = f, v = v, call_ms = ms, auto = auto, ["local"] = loc })
    end
  elseif step == "again" then -- read back from disk, as the next nvim would
    RepoVis.cache = nil
    R.again = look(files[1])
  elseif step == "expire" then -- the cached answer made two days old
    local c = vim.json.decode(table.concat(vim.fn.readfile(RepoVis.path), "\n"))
    for _, entry in pairs(c) do entry.t = os.time() - 2 * 86400 end
    vim.fn.writefile({ vim.json.encode(c) }, RepoVis.path)
    RepoVis.cache = nil
    R.expire = look(files[1])
  elseif step == "asking" then -- an empty buffer variable is "asking" in the init.lua hook: never copilot
    local buf = vim.api.nvim_create_buf(true, false)
    vim.g.fox_completion = "auto"
    vim.b[buf].fox_visibility = "asking"
    R.asking = RepoVis.engine(buf)
    vim.b[buf].fox_visibility = nil
    R.unset = RepoVis.engine(buf)
  end
end
R.leftover_tmp = vim.fn.glob(RepoVis.path .. ".tmp*")
io.stdout:write(vim.json.encode(R) .. "\n")
''', encoding="utf-8")

    def nvim(tag, bin_dir, steps, files, mode=""):
        env = dict(ENV0, PATH=str(bin_dir), XDG_CACHE_HOME=str(TMP / ("cache-" + tag)), BLOCK=str(TMP / "block.lua"),
                   STEPS=json.dumps(steps), FILES=json.dumps(files), FAKE_GH_MODE=mode, HOME=str(TMP / "home"),
                   XDG_CONFIG_HOME=str(TMP / "cfg"), XDG_DATA_HOME=str(TMP / "data"), XDG_STATE_HOME=str(TMP / "state"),
                   XDG_RUNTIME_DIR=str(TMP / "run"))
        (TMP / "run").mkdir(exist_ok=True)
        log.write_text("")
        r = subprocess.run([NVIM, "--clean", "--headless", "-l", str(TMP / "driver.lua")], env=env,
                           capture_output=True, text=True, timeout=120)
        out = r.stdout.strip().splitlines()
        try:
            return json.loads(out[-1]), log.read_text().splitlines()
        except Exception:
            print(f"  (nvim {tag}: rc {r.returncode}; stderr: {r.stderr.strip()[:400]})")
            return {}, []

    # 1 · every remote form, the engine in both modes, the day cache and its expiry
    R, calls = nvim("main", bins["bin"], ["all", "asking", "again", "expire"], [c[1] for c in CASES])
    check("the driver ran and found only the fake gh", R.get("exepath_gh") == str(bins["bin"] / "gh"))
    for (name, f, want), got in zip(CASES, R.get("all", [{}] * len(CASES))):
        check(f"{name}: {want} (got {got.get('v')})", got.get("v") == want)
        check(f"{name}: per repo → {'copilot' if want == 'public' else 'local'} (got {got.get('auto')})",
              got.get("auto") == ("copilot" if want == "public" else "local"))
        check(f"{name}: local everywhere → local (got {got.get('local')})", got.get("local") == "local")
    check("a buffer still asking, or never asked, is never Copilot's",
          R.get("asking") == "local" and R.get("unset") == "local")
    first = [c for c in calls if c.startswith("api repos/")]
    check(f"gh asked once for each GitHub repo, again when its answer expired (4), never for the others (got {len(first)})",
          sorted(first) == sorted(["api repos/octo/pub --jq .visibility", "api repos/octo/priv --jq .visibility",
                                   "api repos/octo/pub2 --jq .visibility", "api repos/octo/pub --jq .visibility"]))
    cache_file = Path(R.get("path", "/nonexistent"))
    cached = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    check(f"the cache holds the definite answers only (got {sorted(cached)})",
          sorted(cached) == ["octo/priv", "octo/pub", "octo/pub2"] and cached["octo/priv"]["v"] == "private")
    check("a cached answer read back from disk asks gh nothing", R.get("again") == "public")
    check("an answer two days old is asked again (the 4th call above) and answered", R.get("expire") == "public")
    check("the atomic write leaves no temporary file", R.get("leftover_tmp") == "")

    # 2 · gh failing: "unknown", nothing cached, and held ten minutes in memory (one call for two lookups)
    R2, calls2 = nvim("fail", bins["bin"], ["all", "again"], [CASES[0][1]], mode="fail")
    check("gh failing → unknown → the local model", R2.get("all", [{}])[0].get("v") == "unknown"
          and R2.get("all", [{}])[0].get("auto") == "local")
    check(f"…asked once, then held (got {len(calls2)} call(s))", len(calls2) == 1 and R2.get("again") == "unknown")
    check("…and nothing cached", not Path(R2.get("path", "/nonexistent")).exists())

    # 3 · no gh at all: "unknown", no error
    R3, _ = nvim("nogh", bins["bin-nogh"], ["all"], [CASES[0][1]])
    check("no gh installed → unknown → the local model, no error",
          R3.get("exepath_gh") == "" and R3.get("all", [{}])[0].get("v") == "unknown")

    # 4 · a slow gh never blocks the editor: the call returns at once, the answer arrives later
    R4, _ = nvim("slow", bins["bin"], ["all"], [CASES[0][1]], mode="slow")
    got = R4.get("all", [{}])[0]
    check(f"a 1 s gh: the lookup returns in under 100 ms (took {got.get('call_ms', -1):.1f} ms), answered after",
          0 <= got.get("call_ms", 1e9) < 100 and got.get("v") == "public")
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall checks passed")
sys.exit(1 if fails else 0)
