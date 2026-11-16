#!/usr/bin/env python3
"""Neovim plugins held to a branch because upstream changed under this config. Installs restore the commits in
shared/nvim_lazy-lock.json; :Lazy update follows each spec's branch.

nvim-scrollbar: on 2026-11-16 v2 replaced v1 on its main branch, and main's last v1 commit warns at every start that
this config (options, the gitsigns and search handlers) breaks under v2 (VM test 2026-11-16, F15). The spec follows v1
and the lock pins v1's commit. With lazy.nvim's clone of the plugin on this machine (DESK_NVIM_SCROLLBAR names
another), the pinned commit, loaded and set up the way lazy.nvim runs the rendered spec, says nothing. The clone is only
read (git archive); Neovim runs with its own state, cache and runtime folders and none of the session's addresses."""
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / "src/desk-render/desk-render-fast"
TEMPLATE = ROOT / "templates/nvim/init.lua"
LOCK = json.loads((ROOT / "shared/nvim_lazy-lock.json").read_text())
CLONE = Path(os.environ.get("DESK_NVIM_SCROLLBAR") or Path.home() / ".local/share/nvim/lazy/nvim-scrollbar")
LIVE = ("TMUX", "TMUX_PANE", "NVIM", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "SWAYSOCK")

# The rendered nvim-scrollbar spec with the palette it reads, loaded as lazy.nvim loads it after startup: the plugin on
# the runtime path, its plugin/ files sourced, then the spec's config with its opts.
LOAD = r"""
local source = table.concat(vim.fn.readfile(vim.env.DESK_INIT), "\n")
local at = assert(source:find('"petertriho/nvim-scrollbar"', 1, true), "no nvim-scrollbar spec")
local P = assert(loadstring("return " .. assert(source:match("local P = (%b{})"), "no palette")))()
local spec = assert(loadstring("return " .. source:match("%b{}", source:sub(1, at):match(".*(){"))))
spec = setfenv(spec, setmetatable({ P = P }, { __index = _G }))()
local said = {}
vim.notify = function(msg) said[#said + 1] = msg end
-- its dependencies, which lazy.nvim loads first: as much of gitsigns and hlslens as the handlers' setup reads
package.loaded.gitsigns = { get_hunks = function() return {} end }
package.loaded.hlslens, package.loaded["hlslens.config"] = {}, {}
vim.opt.rtp:prepend(vim.env.DESK_PLUGIN)
for _, file in ipairs(vim.fn.glob(vim.env.DESK_PLUGIN .. "/plugin/*.lua", false, true)) do vim.cmd.source(file) end
local ok, err = pcall(spec.config, nil, spec.opts)
vim.wait(300)
io.stdout:write(vim.json.encode({ said = said, setup = ok or tostring(err) }) .. "\n")
"""


def git(*args):
    return subprocess.run(["git", "--no-optional-locks", "-C", str(CLONE), *args], capture_output=True)


class Scrollbar(unittest.TestCase):
    def test_the_spec_and_the_lock_follow_v1(self):
        spec = re.search(r'"petertriho/nvim-scrollbar",(.*?)\n  \},', TEMPLATE.read_text(), re.S)
        self.assertIsNotNone(spec, "no nvim-scrollbar spec in the template")
        self.assertRegex(spec.group(1), r'\n    branch = "v1",', 'the spec does not follow the "v1" branch')
        self.assertEqual(LOCK["nvim-scrollbar"]["branch"], "v1", "the lock pins another branch than v1")

    @unittest.skipUnless(shutil.which("nvim") and shutil.which("git") and RENDER.exists(),
                         "requires nvim, git and desk-render-fast (make)")
    def test_the_pinned_scrollbar_says_nothing_at_startup(self):
        commit = LOCK["nvim-scrollbar"]["commit"]
        if git("cat-file", "-e", commit + "^{commit}").returncode != 0:
            self.skipTest(f"requires lazy.nvim's clone of nvim-scrollbar holding {commit[:7]} ({CLONE}; :Lazy restore)")
        if git("rev-parse", "--verify", "--quiet", "origin/v1").returncode == 0:
            self.assertEqual(git("merge-base", "--is-ancestor", commit, "origin/v1").returncode, 0,
                             "the pinned commit is not on the v1 branch")
        with tempfile.TemporaryDirectory(prefix="nvim-pins-") as tmp:
            base = Path(tmp)
            plugin = base / "nvim-scrollbar"
            archive = git("archive", "--format=tar", commit)
            self.assertEqual(archive.returncode, 0, archive.stderr.decode())
            with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
                tar.extractall(plugin, filter="data")
            rendered = base / "render"
            subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates/nvim"),
                            str(rendered)], check=True, capture_output=True, timeout=60)
            (base / "load.lua").write_text(LOAD)
            (base / "run").mkdir(mode=0o700)
            env = {k: v for k, v in os.environ.items() if k not in LIVE}
            env.update(DESK_INIT=str(rendered / "init.lua"), DESK_PLUGIN=str(plugin), XDG_STATE_HOME=str(base),
                       XDG_CACHE_HOME=str(base), XDG_CONFIG_HOME=str(base), XDG_DATA_HOME=str(base),
                       XDG_RUNTIME_DIR=str(base / "run"), NVIM_LOG_FILE=str(base / "nvim.log"))
            ran = subprocess.run(["nvim", "--headless", "--clean", "-l", str(base / "load.lua")], capture_output=True,
                                 text=True, timeout=60, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            seen = json.loads(ran.stdout.strip().splitlines()[-1])
            self.assertIs(seen["setup"], True, "the spec's config failed")
            self.assertEqual(seen["said"], [], f"the pinned nvim-scrollbar ({commit[:7]}) speaks at startup")


if __name__ == "__main__":
    unittest.main()
