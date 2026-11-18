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
io.stdout:write(vim.json.encode({ first = (t1 - t0) / 1e6, again = (vim.uv.hrtime() - t1) / 1e6, files = #files }) .. "\n")
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
            {"name": "review.unread.again", "value": round(probe["again"], 1), "unit": "ms"}]


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
        return review(env, base) + [{"name": "nvim.start", "value": round(statistics.median(starts), 1), "unit": "ms"},
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
