#!/usr/bin/env python3
"""The two bottom lines say different things (theme idea 6, 2026-11-18): inside tmux the pane's footer says where (the
place, the branch and its sync counts), so Neovim's status line leaves the branch out and says what (the file, its diff
and diagnostics, tests, position); a Neovim with no tmux footer under it keeps the branch. The install's own config
(tests/perf.py's sealed layout: the rendered template, the deployed files, the installed plugins read-only), asked of
lualine itself."""
import json
import shutil
import sys

import perf
import sealed_env

if not shutil.which("nvim") or not shutil.which("bwrap") or not perf.RENDER.exists() or not (perf.DATA / "lazy").is_dir():
    print("    nvim bottom lines: skipped (requires nvim, bwrap, desk-render-fast and the installed plugins)")
    sys.exit(0)
PROBE = r"""
vim.schedule(function()
  pcall(function() require('lazy').load({ plugins = { 'lualine.nvim' } }) end)
  local b = require('lualine').get_config().sections.lualine_b
  local shown = {}
  for _, part in ipairs(b) do
    local name = type(part) == 'table' and part[1] or part
    shown[#shown + 1] = { name = name, shown = not (type(part) == 'table' and part.cond) or part.cond() }
  end
  io.stdout:write(vim.json.encode(shown) .. '\n')
  vim.cmd('qa!')
end)
"""
failed = []
with sealed_env.sealed("desk-bottom-") as (env, base):
    perf.config(base, "retro-amber")
    (base / "probe.lua").write_text(PROBE)
    for tmux, want in (("/tmp/tmux-1000/default,1,0", False), (None, True)):
        run = perf.nvim(["--headless", "-n", "-i", "NONE", "+luafile " + str(base / "probe.lua")],
                        {k: v for k, v in (env | {"TMUX": tmux}).items() if v is not None}, base)
        line = [l for l in run.stdout.splitlines() if l.startswith("[")]
        if not line:
            failed.append("no answer: " + (run.stdout + run.stderr)[-800:])
            continue
        parts = {p["name"]: p["shown"] for p in json.loads(line[-1])}
        where = "inside tmux" if tmux else "outside tmux"
        if parts.get("branch") is not want:
            failed.append(f"{where}: the branch {'shown' if parts.get('branch') else 'left out'} ({parts})")
        if not (parts.get("diff") and parts.get("diagnostics")):
            failed.append(f"{where}: the file's diff and diagnostics must stay ({parts})")
print("    nvim bottom lines: " + ("; ".join(failed) if failed else "inside tmux no branch (the footer has it); outside, the branch"))
sys.exit(1 if failed else 0)
