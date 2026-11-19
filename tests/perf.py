#!/usr/bin/env python3
"""How fast the editor feels, as numbers: `make perf`, or `python3 -B tests/perf.py [--json] [--theme NAME]`.

Her ask (2026-11-18): "can performance start being a metric we judge stuff by to catch regressions and make it a
smooth lag free experience". Each figure times something she feels, in a Neovim that is the install's own: the repo's
template rendered with a theme, the files the installer puts in ~/.config/nvim (symlinks_data.hpp), and the plugins
and parsers installed in ~/.local/share/nvim, mounted read-only (bwrap) so nothing here can change them. It runs sealed
(tests/sealed_env.py): none of the running session's addresses, its own state, cache and runtime folders.

Figures (medians; a move or scroll is the key plus the handlers its event runs, as a typed key runs them):
  nvim.start      ms  Neovim started with the config (--startuptime), median of 5
  nvim.move       ms  j in a 3 000-line Lua file, CursorMoved's handlers included
  nvim.move.p95   ms  the slow end of those moves
  nvim.scroll     ms  Ctrl+e in the same file, WinScrolled's handlers included
  review.unread   ms  "next unread" in a live review of 300 changed files, the first press (every file read)
  review.unread.again  ms  the same, pressed again
  review.cycles.heap   KB  Lua memory still held after 19 more opens and closes of that review (a leak grows it)
  review.cycles.rss    MB  the process's resident memory, the same way
Each has a ceiling in tests/perf_budgets.json; over one, the run fails and names it. desk-work keeps the figures
run to run (.desk/tools.json declares this as a figures tool; `desk-work metrics` and the notebook show what got
worse). A machine slower than hers can scale every ceiling with DESK_PERF_SLACK (2 doubles them)."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

import sealed_env

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
DATA = Path.home() / ".local/share/nvim"
BUDGETS = ROOT / "tests/perf_budgets.json"
DEPLOY = ROOT / "src/desk-install/modules/symlinks_data.hpp"

# Waits for the config to settle on the fixture (treesitter attached, the plugins loaded on opening a file), then
# times moves and scrolls; prints one JSON line.
PROBE = r"""
local function settle()
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(10000, function() return vim.treesitter.highlighter.active[buf] ~= nil end, 20)
  vim.wait(1500, function() return false end, 50)
end
local function times(n, keys, event)
  vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd("normal! zt")
  local each = {}
  for i = 1, n do
    local t = vim.uv.hrtime()
    vim.cmd('exe "normal! ' .. keys .. '"')
    vim.api.nvim_exec_autocmds(event, event == "WinScrolled" and { pattern = tostring(vim.api.nvim_get_current_win()) } or {})
    each[i] = (vim.uv.hrtime() - t) / 1e6
  end
  table.sort(each)
  return each
end
vim.schedule(function()
  settle()
  local moves = times(300, "j", "CursorMoved")
  local scrolls = times(300, "\\<C-e>", "WinScrolled")
  local function median(t) return t[math.floor(#t / 2) + 1] end
  io.stdout:write(vim.json.encode({ move = median(moves), move_p95 = moves[math.floor(#moves * 0.95)],
    scroll = median(scrolls), treesitter = vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil }) .. "\n")
  vim.cmd("qa!")
end)
"""


def fixture(path):
    """A 3 000-line Lua file, the same every run: nested tables and calls, so brackets and scopes are deep."""
    lines = ["local M = {}"]
    for i in range(150):
        lines += [f"function M.f{i}(items, opts)",
                  "  local out = {}",
                  "  for k, v in ipairs(items or {}) do",
                  "    if type(v) == 'table' and (opts or {}).deep then",
                  f"      out[#out + 1] = {{ key = k, value = M.f{max(i - 1, 0)}(v, {{ deep = false }}), tag = '{i}' }}",
                  "    elseif v ~= nil then",
                  "      out[#out + 1] = { key = k, value = tostring(v), parts = { (k % 2), (k % 3), { k, v } } }",
                  "    end",
                  "  end",
                  "  return vim.tbl_map(function(x) return { x.key, x.value, (x.parts or {})[3] } end, out)",
                  "end"] + ["-- " + "x" * (40 + (i * 7) % 60)] * 9
    lines.append("return M")
    path.write_text("\n".join(lines) + "\n")


def config(base, theme):
    """The config as the installer lays it out: the template rendered with the theme, and every symlinks_data.hpp
    entry for ~/.config/nvim linked from shared/."""
    rendered = base / "render"
    subprocess.run([str(RENDER), str(ROOT / f"themes/{theme}/palette.sh"), str(ROOT / "templates/nvim"), str(rendered)],
                   check=True, capture_output=True, timeout=60)
    nvim = base / "seal/config/nvim"
    nvim.mkdir(parents=True)
    shutil.copy(rendered / "init.lua", nvim / "init.lua")
    for source, target in re.findall(r'\{\s*"([^"]+)",\s*"~/\.config/nvim/([^"]+)"\s*\}', DEPLOY.read_text()):
        if target == "init.lua":
            continue
        (nvim / target).parent.mkdir(parents=True, exist_ok=True)
        if target.endswith(".json"):
            shutil.copy(ROOT / "shared" / source, nvim / target)   # lazy.nvim writes its lock file
        else:
            (nvim / target).symlink_to(ROOT / "shared" / source)
    data = base / "seal/home/.local/share/nvim"
    data.mkdir(parents=True)
    # Everything Neovim keeps there (plugins, parsers, mason's and copilot's servers), read-only under bwrap: a part left out
    # is one a plugin downloads at start (copilot's server did, and Neovim waited a second on it to quit).
    for part in DATA.iterdir():
        (data / part.name).symlink_to(part)


REVIEW_PROBE = r"""
package.path = vim.env.DESK_LUA .. '/?.lua;' .. package.path
vim.notify = function() end
local C, R = require('desk.claude'), require('desk.review')
local root = vim.env.DESK_REVIEW_ROOT
local files = vim.fn.globpath(root, 'src/*/*.cpp', false, true)
C.open_review({ kind = 'live', sid = 'perf1', name = 'perf', short = 'perf', files = files }, root)
local t0 = vim.uv.hrtime(); R.unread()
local t1 = vim.uv.hrtime(); R.unread()
local first, again = (t1 - t0) / 1e6, (vim.uv.hrtime() - t1) / 1e6
-- Open, read and close it 20 times: what a session keeps after each close (Lua's heap after a full collection, and
-- the process's resident set). A higher floor after the first open is the caches; a staircase is something kept.
local function rss_kib()
  for line in io.lines('/proc/self/status') do local v = line:match('^VmRSS:%s+(%d+)') if v then return tonumber(v) end end
end
C.close()
-- A closed review is held until its waits end (the language server's 5 s, the pop-out's 16 s), then let go: measured
-- after they have, so held is not read as kept.
local function settled()
  vim.wait(17500, function() return false end, 250)
  collectgarbage(); collectgarbage()
  return collectgarbage('count'), rss_kib()
end
local heap0, rss0 = settled()
for i = 1, 19 do
  C.open_review({ kind = 'live', sid = 'perf' .. i, name = 'perf', short = 'perf', files = files }, root)
  R.unread()
  C.close()
end
local heap1, rss1 = settled()
io.stdout:write(vim.json.encode({ first = first, again = again, files = #files,
  heap_growth = heap1 - heap0, rss_growth = rss1 - rss0 }) .. "\n")
vim.cmd('qa!')
"""


def review(env, base):
    """300 changed files of 400 lines, a change every 37 lines, committed then edited: a large working change."""
    repo = base / "review"
    def git(*args):
        subprocess.run(["git", "-C", str(repo), "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
                       check=True, capture_output=True, env=env, timeout=60)
    repo.mkdir()
    git("init", "-q")
    git("config", "user.name", "perf")
    git("config", "user.email", "perf@example.invalid")
    for i in range(300):
        (repo / f"src/m{i % 10}").mkdir(parents=True, exist_ok=True)
        (repo / f"src/m{i % 10}/f{i}.cpp").write_text("".join(f"int v{i}_{n} = {n};\n" for n in range(400)))
    git("add", ".")
    git("commit", "-qm", "base")
    for i in range(300):
        path = repo / f"src/m{i % 10}/f{i}.cpp"
        text = path.read_text().splitlines(True)
        for n in range(0, 400, 37):
            text[n] = text[n].replace("=", "= 1 +")
        path.write_text("".join(text))
        # Edited a minute ago: the review reads again any file written within the last second (its stamp could repeat).
        os.utime(path, (time.time() - 60, time.time() - 60))
    (base / "review.lua").write_text(REVIEW_PROBE)
    time_env = dict(env, DESK_LUA=str(ROOT / "shared/nvim_lua"), DESK_REVIEW_ROOT=str(repo))
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(base / "review.lua")], time_env, timeout=300)
    found = [l for l in run.stdout.splitlines() if l.startswith("{")]
    if not found:
        sys.exit("perf: the review probe gave no answer:\n" + run.stdout[-2000:] + run.stderr[-2000:])
    probe = json.loads(found[-1])
    return [{"name": "review.unread", "value": round(probe["first"], 1), "unit": "ms"},
            {"name": "review.unread.again", "value": round(probe["again"], 1), "unit": "ms"},
            # Kept across 19 more opens and closes once their waits are over: a leak shows as growth here.
            {"name": "review.cycles.heap", "value": round(probe["heap_growth"], 1), "unit": "KB"},
            {"name": "review.cycles.rss", "value": round(probe["rss_growth"] / 1024, 2), "unit": "MB"}]


# The desk's own views (2026-11-19): the call graph, the trace, the map and the review, drawn as the editor draws them,
# on inputs as big as a real day's (a wide graph, a long trace, a big map answer, a large changed file).
DESK_PROBE = r"""
package.path = vim.env.DESK_LUA .. '/?.lua;' .. package.path
vim.notify = function() end
vim.g.desk_style = 'retro'
local G, Map, R = require('desk.callgraph'), require('desk.map'), require('desk.review')
local function median(f, n)
  local each = {}
  for i = 1, n do local t = vim.uv.hrtime(); f(i); each[i] = (vim.uv.hrtime() - t) / 1e6 end
  table.sort(each)
  return each[math.floor(n / 2) + 1]
end
local out = {}
-- a wide graph: three levels of 40 functions each, every one linked to two above it
local function at(name, line) return { name = name, detail = 'f' .. line .. '.cpp:' .. line, uri = 'file:///w/f' .. line .. '.cpp', range = { start = { line = line, character = 0 } } } end
local g = { center = at('Engine::tick', 1), layers = { callees = {} } }
for d = 1, 3 do
  local tier = {}
  for k = 1, 40 do tier[k] = at(('Level%d::fn_%02d(const Order&)'):format(d, k), d * 100 + k) end
  g.layers.callees[d] = tier
  if d > 1 then for k, it in ipairs(tier) do G._link(g, it, g.layers.callees[d - 1][k]); G._link(g, it, g.layers.callees[d - 1][(k % 40) + 1]) end end
end
local drawn
out.graph_layout = median(function() drawn = G.layout(g, 200, true) end, 20)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, drawn.lines)
local s = { buf = buf, drawn = drawn }
out.graph_select = median(function(i) G.select(s, (i % #drawn.boxes) + 1) end, 60)
-- a long trace: 16 steps, 8 parameters each with fields read and written, every fold open
local steps, calls, folds = {}, {}, {}
for k = 1, 16 do
  local params = {}
  for p = 1, 8 do params[p] = { name = 'p' .. p, type = 'const Tick &', pass = 'const ref', dir = 'in', reads = { 'px', 'ts', 'seq' }, writes = { 'flags' } } end
  steps[k] = { id = 'e.cpp::s' .. k, label = 'step_' .. k, file = 'e.cpp', line = k * 10, kind = 'function', role = k == 8 and 'focus' or (k < 8 and 'up' or 'down'),
    returns = 'bool', params = params, callers = {}, more_callers = 0, callees = {}, more_callees = 0 }
  for _, f in ipairs({ 'params', 'uses', 'layout', 'callers' }) do folds['e.cpp::s' .. k .. '|' .. f] = true end
  if k > 1 then calls[k - 1] = { from = 'e.cpp::s' .. (k - 1), to = 'e.cpp::s' .. k, kind = 'call-by-name', line = k * 10 - 5, args = { 'a', 'b', 'c' } } end
end
local trace = { ok = true, q = 'trace', focus = 'e.cpp::s8', depth = 16, steps = steps, calls = calls }
out.trace_page = median(function() Map.layout(Map.trace_page(trace, folds), 160, true) end, 20)
-- a big map answer: what a function reaches, 1500 functions over 3 levels
local nodes, msteps = { { id = 'r', label = 'root', file = 'a.c', line = 1, depth = 0 } }, {}
for k = 1, 1500 do
  nodes[#nodes + 1] = { id = 'n' .. k, label = 'fn_' .. k, file = 'f' .. (k % 50) .. '.c', line = k, depth = (k % 3) + 1 }
  msteps[#msteps + 1] = { from = k <= 500 and 'r' or ('n' .. (k - 500)), to = 'n' .. k, depth = (k % 3) + 1, mark = 'follow' }
end
local reach = { ok = true, q = 'reach', from = nodes[1], depth = 3, nodes = nodes, steps = msteps }
out.map_reach = median(function() Map.layout(Map.level_query(reach), 200, true) end, 10)
-- the map draws every box (2026-11-19, no "+N more"): a file of 1000 functions in a chain, 1000 callers from elsewhere
local big = { ok = true, q = 'module', module = 'eng', files = { { file = 'eng/f.c', functions = 1000, types = 0 } }, nodes = {}, edges = {}, outside = {} }
for k = 1, 1000 do
  big.nodes[k] = { id = 'eng/f.c::f' .. k, label = 'f' .. k, file = 'eng/f.c', line = k, kind = 'function', module = 'eng' }
  if k > 1 then big.edges[#big.edges + 1] = { from = 'eng/f.c::f' .. (k - 1), to = 'eng/f.c::f' .. k, kind = 'call' } end
  big.outside[k] = { id = 'o/c' .. k .. '.c::c' .. k, label = 'c' .. k, file = 'o/c' .. k .. '.c', line = 1, kind = 'function', module = 'o' }
  big.edges[#big.edges + 1] = { from = 'o/c' .. k .. '.c::c' .. k, to = 'eng/f.c::f1', kind = 'call' }
end
out.map_all = median(function() Map.layout(Map.level_nodes(big, 'eng', 'eng/f.c'), 160, true) end, 5)
-- the review's rows of a large changed C file: 300 functions, each changed
local left, right = {}, {}
for k = 1, 300 do
  local fn = ('int f%d(int a, int b) {\n  int x = a + b;\n  return helper%d(x);\n}\n'):format(k, k)
  left[#left + 1] = fn
  right[#right + 1] = fn:gsub('a %+ b', 'a * b')
end
local file = { rel = 'big.c', left = table.concat(left), right = table.concat(right), loaded = true }
file.hunks = (vim.text and vim.text.diff or vim.diff)(file.left, file.right, { result_type = 'indices', algorithm = 'histogram', linematch = 60 })
out.review_symbols = median(function(i) file.symbols = nil; file.signature = 's' .. i; R.changed_symbols(file) end, 5)
-- a map rebuild with the per-file cache: 120 C files, nothing changed
local root = vim.env.DESK_PERF_ROOT
local files = {}
for k = 1, 120 do
  local rel = ('src/m%d.c'):format(k)
  local lines = {}
  for f = 1, 20 do lines[#lines + 1] = ('int m%d_f%d(int x) { return m%d_f%d(x) + %d; }'):format(k, f, k, (f % 20) + 1, f) end
  vim.fn.mkdir(root .. '/src', 'p')
  vim.fn.writefile(lines, root .. '/' .. rel)
  files[#files + 1] = rel
end
local t0 = vim.uv.hrtime()
Map.syntax_graph({ root = root, files = files, cache = root .. '/cache' })
out.map_build = (vim.uv.hrtime() - t0) / 1e6
t0 = vim.uv.hrtime()
Map.syntax_graph({ root = root, files = files, cache = root .. '/cache' })
out.map_rebuild = (vim.uv.hrtime() - t0) / 1e6
io.stdout:write(vim.json.encode(out) .. "\n")
vim.cmd('qa!')
"""


def desk(env, base):
    """The desk's own views timed as the editor draws them (DESK_PROBE)."""
    (base / "desk.lua").write_text(DESK_PROBE)
    (base / "maproot").mkdir()
    run = sealed_env.run(["nvim", "--headless", "--clean", "-l", str(base / "desk.lua")],
                         dict(env, DESK_LUA=str(ROOT / "shared/nvim_lua"), DESK_PERF_ROOT=str(base / "maproot")), timeout=300)
    found = [l for l in run.stdout.splitlines() if l.startswith("{")]
    if not found:
        sys.exit("perf: the desk probe gave no answer:\n" + run.stdout[-2000:] + run.stderr[-2000:])
    p = json.loads(found[-1])
    return [{"name": "graph.layout", "value": round(p["graph_layout"], 2), "unit": "ms"},
            {"name": "graph.select", "value": round(p["graph_select"], 2), "unit": "ms"},
            {"name": "trace.page", "value": round(p["trace_page"], 2), "unit": "ms"},
            {"name": "map.reach", "value": round(p["map_reach"], 1), "unit": "ms"},
            {"name": "map.all", "value": round(p["map_all"], 1), "unit": "ms"},
            {"name": "review.symbols", "value": round(p["review_symbols"], 1), "unit": "ms"},
            {"name": "map.build", "value": round(p["map_build"], 0), "unit": "ms"},
            {"name": "map.rebuild", "value": round(p["map_rebuild"], 0), "unit": "ms"}]


def nvim(args, env, base, timeout=120):
    """Neovim under bwrap with the installed plugins and parsers read-only."""
    sealed = ["bwrap", "--dev-bind", "/", "/", "--ro-bind", str(DATA), str(DATA), "--chdir", str(base), "--"]
    return sealed_env.run(sealed + ["nvim"] + args, env, timeout=timeout)


def measure(theme):
    with sealed_env.sealed("desk-perf-") as (env, base):
        config(base, theme)
        lua = base / "fixture.lua"
        fixture(lua)
        starts = []
        for i in range(5):
            log = base / f"start{i}.log"
            nvim(["--headless", "-n", "-i", "NONE", "--startuptime", str(log), "+qa!"], env, base)
            done = [l for l in log.read_text().splitlines() if "NVIM STARTED" in l]
            if done:
                starts.append(float(done[-1].split()[0]))
        (base / "probe.lua").write_text(PROBE)
        run = nvim(["--headless", "-n", "-i", "NONE", str(lua), "+luafile " + str(base / "probe.lua")], env, base, timeout=300)
        found = [l for l in run.stdout.splitlines() if l.startswith("{")]
        if not found or not starts:
            sys.exit("perf: the probe gave no answer:\n" + run.stdout[-2000:] + run.stderr[-2000:])
        probe = json.loads(found[-1])
        if not probe["treesitter"]:
            print("perf: treesitter did not attach to the fixture (no lua parser installed?): moves are measured without it",
                  file=sys.stderr)
        return review(env, base) + desk(env, base) + [{"name": "nvim.start", "value": round(statistics.median(starts), 1), "unit": "ms"},
                {"name": "nvim.move", "value": round(probe["move"], 2), "unit": "ms"},
                {"name": "nvim.move.p95", "value": round(probe["move_p95"], 2), "unit": "ms"},
                {"name": "nvim.scroll", "value": round(probe["scroll"], 2), "unit": "ms"}]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="the figures as desk-work reads a figures tool's answer")
    parser.add_argument("--theme", default="retro-amber")
    args = parser.parse_args()
    if not shutil.which("nvim") or not shutil.which("bwrap") or not RENDER.exists() or not (DATA / "lazy").is_dir():
        print("    perf: skipped (requires nvim, bwrap, desk-render-fast (make) and the installed plugins)")
        return 0
    figures = measure(args.theme)
    if args.json:
        print(json.dumps(figures))
        return 0
    slack = float(os.environ.get("DESK_PERF_SLACK") or 1)
    budgets = json.loads(BUDGETS.read_text())
    over = []
    for f in figures:
        ceiling = budgets.get(f["name"], {}).get("max")
        mark = ""
        if ceiling is not None:
            mark = f"   (ceiling {ceiling * slack:g} {f['unit']})"
            if f["value"] > ceiling * slack:
                over.append(f["name"])
                mark += "   OVER: " + budgets[f["name"]].get("why", "")
        print(f"    {f['name']} {f['value']:g} {f['unit']}{mark}")
    if over:
        print("    perf: over budget: " + ", ".join(over))
        return 1
    print("    perf: every figure within its ceiling")
    return 0


if __name__ == "__main__":
    sys.exit(main())
