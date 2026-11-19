#!/usr/bin/env python3
"""desk.popout (shared/nvim_lua/desk/popout.lua): the pop-out window and the main editor it follows.

- End to end: shared/nvim_lua/tests/test_popout.lua drives a main editor and its pop-out, two headless Neovims on
  private sockets, in a sandbox of its own (private HOME and XDG folders under tests/, stubs of kitty, hyprctl, desk-hl,
  desk-drawer and desk-work first on PATH). Never her sockets, tmux, Hyprland or terminal.
- init.lua's desk-popout block, rendered for every theme: in a pop-out it switches the language servers off, in the
  main editor it leaves them alone; and the work modules init.lua sets up start nothing in a pop-out.
- init.lua's fox-symdeps spec, rendered for every theme: lazy.nvim never loads it in a pop-out (its cond), so its keys
  are not mapped there; in the main editor it loads, on Space dm and Space dd.
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

from required import requires
import sealed_env

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'shared/nvim_lua'
RENDER = ROOT / 'src/desk-render/desk-render-fast'


@requires(shutil.which('nvim'), 'nvim')
class PopOut(unittest.TestCase):
    # Sealed (tests/sealed_env.py): the runner Neovim's log and server socket are the test's own, and every process the
    # Lua starts (the editor, its pop-out, a restarted server) is stopped at the end, also after a timeout; then what
    # the Lua printed is kept, and the sandbox it made under tests/ removed.
    def lua(self, name, timeout):
        with sealed_env.sealed('popout-') as (env, _):
            ran = sealed_env.run(['nvim', '--headless', '--clean', '-l', str(LUA / 'tests' / name)], env, timeout,
                                 sandboxes=(ROOT / 'tests', 'po??????'))
        out = (ran.stdout + ran.stderr).strip()
        print('    ' + out.replace('\n', '\n    '))
        # the failed checks last: the changed-files runner shows only the end of the output, which was the pop-out's
        # closing chatter, so an intermittent failure (2026-11-19, twice) never said which check it was
        lines = out.splitlines()
        failed = [l for i, l in enumerate(lines) if l.startswith('FAIL') or (i and lines[i - 1].startswith('FAIL') and l.startswith('  '))]
        self.assertEqual(ran.returncode, 0, out + ('\n--- the checks that failed ---\n' + '\n'.join(failed[-12:]) if failed else ''))

    def test_the_pop_out_and_its_editor(self):
        self.lua('test_popout.lua', 240)

    # :restart in the editor's terminal UI (a pty here) with the pop-out open: no stall, the pop-out quits, the new
    # editor offers its views again.
    def test_restart_with_the_pop_out_open(self):
        self.lua('test_popout_restart.lua', 120)


BLOCK_RUN = r'''
local block = assert(io.open(os.getenv('POPOUT_BLOCK'))):read('*a')
vim.lsp.config('fake_a', { cmd = { 'true' }, filetypes = { 'fakelang' } })
vim.lsp.config('fake_b', { cmd = { 'true' }, filetypes = { 'fakelang2' } })
vim.lsp.enable({ 'fake_a', 'fake_b' })
-- A stand-in lualine that records what it is asked to hide.
local hidden = {}
package.preload['lualine'] = function() return { hide = function(opts) hidden[#hidden + 1] = opts end } end
if os.getenv('POPOUT') == '1' then vim.g.desk_popout = 1 end
assert(loadstring(block))()
io.stdout:write(vim.json.encode({ servers = #vim.lsp.get_configs({ enabled = true }), hidden = hidden }))
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


# The fox-symdeps spec of a rendered init.lua (POPOUT_INIT), read as lazy.nvim reads it: its table evaluated (what it
# reads of the palette, the paper mode and the role model stood in for: any value will do), then its cond as lazy's
# resolve checks it (false, or a function that returns false: never loaded, and none of its keys mapped). Run with
# --cmd 'let g:desk_popout=1' for a pop-out, as kitty starts one: set before init.lua runs.
SPEC_RUN = r'''
local source = assert(io.open(os.getenv('POPOUT_INIT'))):read('*a')
local name_at = assert(source:find('name = "fox-symdeps",', 1, true), 'the rendered init.lua has no fox-symdeps spec')
local open, from = nil, 1
while true do
  local at = source:find('\n  {\n', from, true)
  if not at or at > name_at then break end
  open, from = at, at + 1
end
local text = assert(source:sub(assert(open, 'its spec opens a table') + 1):match('^%s*(%b{})'), 'its spec is one table')
local function any() return setmetatable({}, { __index = function() return any() end, __call = function() return any() end }) end
local env = setmetatable({ P = any(), Paper = any(), role_model = function() return 'model' end }, { __index = _G })
local spec = setfenv(assert(loadstring('return ' .. text)), env)()
local cond = spec.cond
local keys = {}
for _, key in ipairs(spec.keys or {}) do keys[#keys + 1] = key[1] end
io.stdout:write(vim.json.encode({ name = spec.name, keys = keys,
  loads = not (cond == false or (type(cond) == 'function' and not cond({ name = spec.name }))) }))
'''


def rendered_inits(temp):
    """Every theme's init.lua, rendered by desk-render-fast into temp: {theme: its path}."""
    out = {}
    for palette in sorted((ROOT / 'themes').glob('*/palette.sh')):
        folder = Path(temp) / palette.parent.name
        subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/nvim'), str(folder)], check=True, capture_output=True,
                       timeout=120)
        out[palette.parent.name] = folder / 'init.lua'
    return out


@requires(shutil.which('nvim'), 'nvim')
class InitBlock(unittest.TestCase):
    maxDiff = None   # a failure names each theme and window

    @requires(os.access(RENDER, os.X_OK), 'a built desk-render-fast (make)')
    def test_the_pop_out_block_in_every_theme(self):
        blocks = {}
        with tempfile.TemporaryDirectory(prefix='popout-render-') as temp:
            for theme, init in rendered_inits(temp).items():
                found = re.search(r'^-- >>> desk-popout\n(.*?)^-- <<< desk-popout$', init.read_text(), re.S | re.M)
                self.assertIsNotNone(found, f'{theme}: the rendered init.lua has no desk-popout block')
                blocks[theme] = found.group(1)
            self.assertGreater(len(blocks), 1)
            self.assertEqual(len(set(blocks.values())), 1, 'the block reads the same in every theme')
            block = Path(temp) / 'block.lua'
            block.write_text(next(iter(blocks.values())))
            script = Path(temp) / 'run.lua'
            script.write_text(BLOCK_RUN)
            servers, hidden = {}, {}
            sealed = sealed_env.environment(temp, POPOUT_BLOCK=block)
            self.addCleanup(sealed_env.stop, sealed)
            for popout in ('1', '0'):
                ran = sealed_env.run(['nvim', '--headless', '--clean', '-l', str(script)], sealed | {'POPOUT': popout}, 60)
                self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
                said = json.loads(ran.stdout.strip().splitlines()[-1])
                servers[popout], hidden[popout] = said['servers'], said['hidden'] or []
        self.assertEqual(servers, {'1': 0, '0': 2}, 'a pop-out switches every language server off; the main editor keeps them')
        # The pop-out's tab line is its header and each status line a view's keys: lualine draws none of them there.
        self.assertEqual(hidden, {'1': [{'place': ['statusline', 'tabline', 'winbar'], 'unhide': False}], '0': []},
                         'a pop-out hides lualine for good; the main editor keeps it')

    # 2026-11-17: the spec's keys (Space dm, Space dd) were mapped in the pop-out too, so pressing one there loaded
    # symdeps inside it (its setup, a foxtag run) and opened that copy's menu for the pop-out's scratch buffer.
    @requires(os.access(RENDER, os.X_OK), 'a built desk-render-fast (make)')
    def test_symdeps_never_loads_in_a_pop_out(self):
        seen = {}
        with tempfile.TemporaryDirectory(prefix='popout-spec-') as temp:
            script = Path(temp) / 'spec.lua'
            script.write_text(SPEC_RUN)
            inits = rendered_inits(temp)
            self.assertGreater(len(inits), 1)
            sealed = sealed_env.environment(temp)
            self.addCleanup(sealed_env.stop, sealed)
            for theme, init in inits.items():
                for window, cmd in (('pop-out', ['--cmd', 'let g:desk_popout=1']), ('editor', [])):
                    ran = sealed_env.run(['nvim', '--headless', '--clean', *cmd, '-l', str(script)],
                                         sealed | {'POPOUT_INIT': str(init)}, 60)
                    self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
                    said = json.loads(ran.stdout.strip().splitlines()[-1])
                    seen[(theme, window)] = (said['name'], said['loads'], said['keys'])
        want = {}
        for theme in inits:
            want[(theme, 'pop-out')] = ('fox-symdeps', False, ['<leader>dm', '<leader>dd'])
            want[(theme, 'editor')] = ('fox-symdeps', True, ['<leader>dm', '<leader>dd'])
        self.assertEqual(seen, want, 'lazy.nvim never loads symdeps in a pop-out (cond), so Space dm and Space dd map nothing '
                                     'there; the main editor loads it on them')

    def test_the_work_modules_start_nothing_in_a_pop_out(self):
        with tempfile.TemporaryDirectory(prefix='popout-modules-') as temp:
            script = Path(temp) / 'run.lua'
            script.write_text(MODULES_RUN)
            # No desk-work on PATH and sealed: even a module that ignored the pop-out could reach nothing real.
            env = sealed_env.environment(temp, POPOUT_LUA=LUA, PATH='/usr/bin:/bin')
            self.addCleanup(sealed_env.stop, env)
            ran = sealed_env.run(['nvim', '--headless', '--clean', '-l', str(script)], env, 60)
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
