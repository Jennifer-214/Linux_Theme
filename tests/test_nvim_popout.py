#!/usr/bin/env python3
"""desk.popout (shared/nvim_lua/desk/popout.lua): the pop-out window and the main editor it follows.

- End to end: shared/nvim_lua/tests/test_popout.lua drives a main editor and its pop-out, two headless Neovims on
  private sockets, in a sandbox of its own (private HOME and XDG folders under tests/, stubs of kitty, hyprctl, desk-hl,
  desk-drawer and desk-work first on PATH). Never her sockets, tmux, Hyprland or terminal.
- init.lua's desk-popout block, rendered for every theme: in a pop-out it switches the language servers off, in the
  main editor it leaves them alone; and the work modules init.lua sets up start nothing in a pop-out.
- The Hyprland rule for the pop-out's class, in rules.lua and its rules.conf twin, loaded under every theme.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'shared/nvim_lua'
RENDER = ROOT / 'src/desk-render/desk-render-fast'


@unittest.skipUnless(shutil.which('nvim'), 'Neovim required')
class PopOut(unittest.TestCase):
    def test_the_pop_out_and_its_editor(self):
        ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(LUA / 'tests/test_popout.lua')],
                             capture_output=True, text=True, timeout=180)
        out = (ran.stdout + ran.stderr).strip()
        print('    ' + out.replace('\n', '\n    '))
        self.assertEqual(ran.returncode, 0, out)


BLOCK_RUN = r'''
local block = assert(io.open(os.getenv('POPOUT_BLOCK'))):read('*a')
vim.lsp.config('fake_a', { cmd = { 'true' }, filetypes = { 'fakelang' } })
vim.lsp.config('fake_b', { cmd = { 'true' }, filetypes = { 'fakelang2' } })
vim.lsp.enable({ 'fake_a', 'fake_b' })
if os.getenv('POPOUT') == '1' then vim.g.desk_popout = 1 end
assert(loadstring(block))()
io.stdout:write(vim.json.encode({ servers = #vim.lsp.get_configs({ enabled = true }) }))
'''
# The work modules init.lua sets up, in a pop-out: no commands, autocommands, timers or keys of theirs.
MODULES_RUN = r'''
local lua = os.getenv('POPOUT_LUA')
package.path = lua .. '/?.lua;' .. package.path
table.insert(package.loaders, 2, function(name)
  local file = lua .. '/' .. name:gsub('%.', '/') .. '.lua'
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
vim.g.mapleader = ' '
vim.g.desk_popout = 1
for _, name in ipairs({ 'desk.sync', 'desk.claude', 'desk.planmarks' }) do require(name).setup() end
local out = { commands = {}, groups = {} }
local commands = vim.api.nvim_get_commands({})
for _, name in ipairs({ 'ClaudeChanges', 'WorkSave', 'WorkResume', 'WorkTests', 'PlanMarks', 'CallGraph', 'PopOut' }) do
  if commands[name] then table.insert(out.commands, name) end
end
for _, group in ipairs({ 'foxml_live_files', 'foxml_claude', 'foxml_workspace', 'foxml_plan_marks', 'desk_bridge', 'desk_popout' }) do
  if pcall(vim.api.nvim_get_autocmds, { group = group }) then table.insert(out.groups, group) end
end
out.home = vim.fn.maparg('<leader><leader>', 'n') ~= ''
io.stdout:write(vim.json.encode(out))
'''


@unittest.skipUnless(shutil.which('nvim'), 'Neovim required')
class InitBlock(unittest.TestCase):
    @unittest.skipUnless(os.access(RENDER, os.X_OK), 'a built desk-render-fast (make) required')
    def test_the_pop_out_block_in_every_theme(self):
        blocks = {}
        with tempfile.TemporaryDirectory(prefix='popout-render-') as temp:
            for palette in sorted((ROOT / 'themes').glob('*/palette.sh')):
                out = Path(temp) / palette.parent.name
                subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/nvim'), str(out)], check=True, capture_output=True,
                               timeout=120)
                found = re.search(r'^-- >>> desk-popout\n(.*?)^-- <<< desk-popout$', (out / 'init.lua').read_text(), re.S | re.M)
                self.assertIsNotNone(found, f'{palette.parent.name}: the rendered init.lua has no desk-popout block')
                blocks[palette.parent.name] = found.group(1)
            self.assertGreater(len(blocks), 1)
            self.assertEqual(len(set(blocks.values())), 1, 'the block reads the same in every theme')
            block = Path(temp) / 'block.lua'
            block.write_text(next(iter(blocks.values())))
            script = Path(temp) / 'run.lua'
            script.write_text(BLOCK_RUN)
            servers = {}
            for popout in ('1', '0'):
                env = dict(os.environ, POPOUT=popout, POPOUT_BLOCK=str(block), HOME=temp, XDG_STATE_HOME=temp, XDG_CACHE_HOME=temp,
                           XDG_CONFIG_HOME=temp, XDG_DATA_HOME=temp)
                ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True, timeout=60,
                                     env=env)
                self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
                servers[popout] = json.loads(ran.stdout.strip().splitlines()[-1])['servers']
        self.assertEqual(servers, {'1': 0, '0': 2}, 'a pop-out switches every language server off; the main editor keeps them')

    def test_the_work_modules_start_nothing_in_a_pop_out(self):
        with tempfile.TemporaryDirectory(prefix='popout-modules-') as temp:
            script = Path(temp) / 'run.lua'
            script.write_text(MODULES_RUN)
            (Path(temp) / 'runtime').mkdir(mode=0o700)
            # No desk-work on PATH and private folders: even a module that ignored the pop-out could reach nothing real.
            env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE', 'NVIM', 'HYPRLAND_INSTANCE_SIGNATURE')}
            env.update(POPOUT_LUA=str(LUA), HOME=temp, XDG_STATE_HOME=temp, XDG_CACHE_HOME=temp, XDG_CONFIG_HOME=temp,
                       XDG_DATA_HOME=temp, XDG_RUNTIME_DIR=str(Path(temp) / 'runtime'), PATH='/usr/bin:/bin')
            ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True, timeout=60, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            found = json.loads(ran.stdout.strip().splitlines()[-1])
        self.assertEqual((found['commands'] or [], found['groups'] or [], found['home']), ([], [], False),
                         'desk.sync, desk.claude (and with it desk.work) and desk.planmarks set nothing up in a pop-out')


class HyprlandRule(unittest.TestCase):
    LUA_RULE = re.compile(r'hl\.window_rule\(\{\n\s*name = "desk-popout",(.*?)\n\}\)', re.S)
    CONF_RULE = re.compile(r'^windowrule \{\n\s*name = desk-popout\n(.*?)\n\}', re.S | re.M)

    def test_the_rule_in_both_languages(self):
        lua = self.LUA_RULE.search((ROOT / 'shared/hyprland_modules/rules.lua').read_text())
        conf = self.CONF_RULE.search((ROOT / 'shared/hyprland_modules/rules.conf').read_text())
        self.assertIsNotNone(lua, 'rules.lua has the desk-popout rule')
        self.assertIsNotNone(conf, 'rules.conf has its twin')
        for effect in ('match = { class = "^(desk-popout)$" }', 'no_initial_focus = true', 'float = true'):
            self.assertIn(effect, lua.group(1))
        for effect in ('match:class = ^(desk-popout)$', 'no_initial_focus = true', 'float = true'):
            self.assertIn(effect, conf.group(1))
        self.assertIn("M.CLASS = 'desk-popout'", (ROOT / 'shared/nvim_lua/desk/popout.lua').read_text(),
                      'kitty is started with the class the rule matches')

    def test_every_theme_loads_it(self):
        # A shared module, deployed the same under every theme (specials.cpp skips only theme and nvidia), which the
        # entry config loads; test_hyprland_lua.py's VerifyWithHyprland parses each theme's assembled config with it.
        entry = (ROOT / 'shared/hyprland.lua').read_text()
        self.assertIn('"rules"', re.search(r'local modules = \{(.*?)\}', entry, re.S).group(1))
        self.assertFalse((ROOT / 'templates/hyprland/rules.lua').exists(), "the rule is shared, not one theme's")


if __name__ == '__main__':
    unittest.main(verbosity=1)
