#!/usr/bin/env python3
"""Jupyter notebooks in Neovim: the desk-jupyter block of templates/nvim/init.lua.

- The block reads no theme token, so every theme renders it the same; lazy.nvim pins its three plugins and loads none
  of them at startup.
- With no plugin installed, a notebook buffer gets its keys and which-key the Jupyter group; a Markdown file does not.
- Cells are found as jupytext writes them: a code block inside a region or a raw block is prose.
- Retro covers molten's ✓ / ✗ with code page 437 glyphs; other themes leave them.
- When jupytext and jupytext.nvim are on this machine (the installer puts them there): the fixture notebook (Markdown,
  code, every kind of output, cell and notebook metadata) opens as Markdown, saves back byte for byte, keeps every cell
  and output when a cell is added, and loses only its outputs when they are cleared.
- When molten, Neovim's Python (pynvim, jupyter_client, nbformat), a python3 kernel and the python parser are there too:
  cells run on the kernel, a save writes their outputs into the right cells and changes nothing else, and a cell edited
  past what ran makes the save say its outputs were not saved.
  DESK_JUPYTEXT, DESK_JUPYTEXT_NVIM, DESK_MOLTEN_NVIM, DESK_JUPYTER_PYTHON and DESK_TS_SITE (a folder holding
  parser/python.so) point at other copies of each.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NVIM = shutil.which('nvim')
RENDER = ROOT / 'src/desk-render/desk-render-fast'
TEMPLATE = ROOT / 'templates/nvim/init.lua'
BLOCK_LUA = ROOT / 'tests/jupyter_block.lua'
FIXTURE = ROOT / 'tests/fixtures/jupyter/assignment.ipynb'
LOCK = ROOT / 'shared/nvim_lazy-lock.json'
BLOCK = re.compile(r'-- >>> desk-jupyter\n(.*?)\n-- <<< desk-jupyter', re.S)


def jupytext():
    for path in (os.environ.get('DESK_JUPYTEXT'), shutil.which('jupytext'), str(Path.home() / '.local/bin/jupytext')):
        if path and os.access(path, os.X_OK):
            return path


def jupytext_nvim():
    path = Path(os.environ.get('DESK_JUPYTEXT_NVIM') or Path.home() / '.local/share/nvim/lazy/jupytext.nvim')
    return path if (path / 'lua/jupytext.lua').is_file() else None


def kernel_parts():
    """(molten dir, Neovim's Python, treesitter site folder) when cells can really run here, else None."""
    molten = Path(os.environ.get('DESK_MOLTEN_NVIM') or Path.home() / '.local/share/nvim/lazy/molten-nvim')
    python = os.environ.get('DESK_JUPYTER_PYTHON') or '/usr/bin/python3'
    site = Path(os.environ.get('DESK_TS_SITE') or Path.home() / '.local/share/nvim/site')
    if not (molten / 'rplugin/python3/molten').is_dir() or not (site / 'parser/python.so').is_file():
        return None
    probe = ('import pynvim, jupyter_client, nbformat\nfrom jupyter_client.kernelspec import find_kernel_specs\n'
             'assert "python3" in find_kernel_specs()')
    if not os.access(python, os.X_OK) or subprocess.run([python, '-c', probe], capture_output=True).returncode != 0:
        return None
    return molten, python, site


def run_lua(base, body, init, extra_env=None, timeout=60):
    """Run body in a bare Neovim (no user config) with J = the block of init; returns the last JSON line it prints."""
    script = base / 'driver.lua'
    script.write_text(f'vim.g.mapleader = " "\nlocal J = dofile({json.dumps(str(BLOCK_LUA))})({json.dumps(str(init))})\n'
                      f'local function out(v) io.stdout:write(vim.json.encode(v) .. "\\n") end\n{body}\nvim.cmd("qa!")\n')
    home = base / 'home'
    home.mkdir(exist_ok=True)
    env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'XDG_CONFIG_HOME': str(home / 'config'),
           'XDG_DATA_HOME': str(home / 'data'), 'XDG_STATE_HOME': str(home / 'state'),
           'XDG_CACHE_HOME': str(home / 'cache'), 'XDG_RUNTIME_DIR': str(home), 'NVIM_LOG_FILE': str(base / 'nvim.log'),
           **(extra_env or {})}
    ran = subprocess.run([NVIM, '--clean', '--headless', '-l', str(script)], capture_output=True, text=True,
                         timeout=timeout, env=env)
    if ran.returncode != 0:
        raise AssertionError(ran.stdout + ran.stderr)
    return json.loads([line for line in ran.stdout.splitlines() if line.startswith(('{', '['))][-1])


@unittest.skipUnless(NVIM and RENDER.exists(), 'build desk-render-fast and install nvim')
class Jupyter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='desk-jupyter-')
        cls.base = Path(cls.temp.name)
        cls.rendered = {}
        for palette in sorted((ROOT / 'themes').glob('*/palette.sh')):
            out = cls.base / 'render' / palette.parent.name
            subprocess.run([str(RENDER), str(palette), str(ROOT / 'templates/nvim'), str(out)], check=True,
                           capture_output=True)
            cls.rendered[palette.parent.name] = out / 'init.lua'

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_every_theme_renders_the_same_block(self):
        self.assertNotIn('{{', BLOCK.search(TEMPLATE.read_text()).group(1), 'the block reads a theme token')
        blocks = {theme: BLOCK.search(path.read_text()).group(1) for theme, path in self.rendered.items()}
        self.assertGreaterEqual(len(blocks), 2)
        self.assertEqual(len(set(blocks.values())), 1, 'the block differs between themes')
        self.assertIn('vim.list_extend(plugins, Jupyter.specs)', TEMPLATE.read_text())

    def test_the_plugins_are_pinned_and_none_loads_at_startup(self):
        specs = run_lua(self.base, '''
local specs = {}
for _, s in ipairs(J.specs) do
  specs[#specs + 1] = { repo = s[1], lazy = s.lazy or false, event = s.event or false, ft = s.ft or false,
    keys = s.keys or false, cmd = s.cmd or false, cond = type(s.cond) == "function" }
end
out(specs)''', self.rendered['Paper'])
        lock = json.loads(LOCK.read_text())
        by = {s['repo']: s for s in specs}
        self.assertEqual(sorted(by), ['3rd/image.nvim', 'benlubas/molten-nvim', 'goerz/jupytext.nvim'])
        for repo in by:
            self.assertIn(repo.split('/')[1], lock, f'{repo} has no lazy-lock.json entry (Lazy! restore would skip it)')
        self.assertEqual(by['goerz/jupytext.nvim']['event'], 'BufReadCmd *.ipynb')
        self.assertTrue(by['goerz/jupytext.nvim']['cond'], 'without the jupytext command it must not load at all')
        for repo in ('benlubas/molten-nvim', '3rd/image.nvim'):
            self.assertEqual((by[repo]['lazy'], by[repo]['event'], by[repo]['ft'], by[repo]['keys'], by[repo]['cmd']),
                             (True, False, False, False, False), f'{repo} would load before a cell runs')

    def test_keys_exist_in_notebooks_only_and_cells_are_found_as_jupytext_writes_them(self):
        seen = run_lua(self.base, r'''
local api = vim.api
local nb = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(nb, vim.fn.getcwd() .. "/work.ipynb")
api.nvim_set_current_buf(nb)
api.nvim_buf_set_lines(nb, 0, -1, false, {
  "---", "jupyter:", "  kernelspec:", "    display_name: Python 3 (ipykernel)", "    language: python",
  "    name: python3", "---", "",
  "# Title", "",
  "<!-- #region -->", "Prose with code:", "", "```python", "print('not a cell')", "```", "<!-- #endregion -->", "",
  "```python", "a = 1", "```", "",
  "```python tags=[\"solution\"]", "b = 2", "b", "```", "",
  "<!-- #raw -->", "```python", "raw()", "```", "<!-- #endraw -->", "",
  "```python", "```", })
vim.bo[nb].filetype = "markdown"
local md = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(md, vim.fn.getcwd() .. "/notes.md")
vim.bo[md].filetype = "markdown"
local maps, missing = {}, {}
for _, k in ipairs(J.keymap) do
  for _, mode in ipairs(type(k.mode) == "table" and k.mode or { k.mode }) do
    local m = vim.fn.maparg(k.lhs, mode, false, true)
    if m.buffer ~= 1 or m.desc ~= k.desc then missing[#missing + 1] = mode .. " " .. k.lhs end
  end
end
api.nvim_set_current_buf(md)
local in_md = vim.fn.maparg("<leader>jj", "n", false, true).buffer == 1
api.nvim_set_current_buf(nb)
local cells = {}
for _, c in ipairs(J.cells(nb)) do cells[#cells + 1] = { c.open, c.first, c.last, c.close } end
local moves = {}
api.nvim_win_set_cursor(0, { 9, 0 }); J.run.next(); moves[#moves + 1] = api.nvim_win_get_cursor(0)[1]
J.run.next(); moves[#moves + 1] = api.nvim_win_get_cursor(0)[1]
api.nvim_win_set_cursor(0, { 25, 0 }); J.run.prev(); moves[#moves + 1] = api.nvim_win_get_cursor(0)[1]
J.run.prev(); moves[#moves + 1] = api.nvim_win_get_cursor(0)[1]
api.nvim_win_set_cursor(0, { 20, 0 }); J.run.add_below(); vim.cmd("stopinsert")
local added = api.nvim_buf_get_lines(nb, 21, 26, false)
out({ missing = missing, in_md = in_md, cells = cells, moves = moves, added = added, cursor = api.nvim_win_get_cursor(0)[1],
      spec = J.kernelspec(nb) })''', self.rendered['Paper'])
        self.assertEqual(seen['missing'], [], 'a notebook key is not mapped in the notebook buffer')
        self.assertFalse(seen['in_md'], 'a plain Markdown file got the notebook keys')
        self.assertEqual(seen['spec'], {'name': 'python3', 'language': 'python'})
        # the region's and the raw block's fences are prose; the last cell is empty (last < first)
        self.assertEqual(seen['cells'], [[19, 20, 20, 21], [23, 24, 25, 26], [34, 35, 34, 35]])
        self.assertEqual(seen['moves'], [20, 24, 24, 20], 'next / previous cell')
        self.assertEqual(seen['added'], ['', '```python', '', '```', ''], 'a new code cell after the cell')
        self.assertEqual(seen['cursor'], 24, 'the cursor goes into the new cell')

    def test_which_key_names_the_jupyter_group(self):
        source = TEMPLATE.read_text()
        self.assertIn('{ "<leader>j", group = "Jupyter"', source)
        plugin = Path.home() / '.local/share/nvim/lazy/which-key.nvim'
        if not plugin.is_dir():
            self.skipTest('which-key.nvim is not installed (the spec line above is checked)')
        seen = run_lua(self.base, f'''
vim.opt.rtp:append({json.dumps(str(plugin))})
local source = table.concat(vim.fn.readfile({json.dumps(str(self.rendered['Paper']))}), "\\n")
local _, at = assert(source:find('"folke/which-key.nvim"', 1, true))
require("which-key").setup(assert(loadstring("return " .. assert(source:sub(at):match("opts = (%b{{}})"))))())
local nb = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(nb, vim.fn.getcwd() .. "/work.ipynb")
vim.api.nvim_set_current_buf(nb)
vim.bo[nb].filetype = "markdown"
vim.wait(200)
local found = require("which-key.buf").get({{ mode = "n" }})
local group = found and found.tree.root:find(require("which-key.util").keys("<leader>j", {{ norm = true }}))
out({{ group = group and group.desc or vim.NIL }})''', self.rendered['Paper'])
        self.assertEqual(seen['group'], 'Jupyter')

    def test_retro_covers_the_glyphs_molten_writes(self):
        for theme, done, failed in (('retro-amber', '√', 'x'), ('Paper', '✓', '✗')):
            with self.subTest(theme=theme):
                seen = run_lua(self.base, r'''
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Out[1]: ✓ Done 0.1s", "Out[2]: ✗ Failed" })
vim.bo[buf].filetype = "molten_output"
vim.cmd("redraw!")
out({ done = vim.fn.screenstring(1, 9), failed = vim.fn.screenstring(2, 9),
      q = vim.fn.maparg("q", "n", false, true).buffer == 1 })''', self.rendered[theme])
                self.assertEqual((seen['done'], seen['failed']), (done, failed))
                self.assertTrue(seen['q'], 'q closes an output window')

    def test_a_notebook_saves_back_without_losing_anything(self):
        command, plugin = jupytext(), jupytext_nvim()
        if not command or not plugin:
            self.skipTest('needs the jupytext command and jupytext.nvim (both come with the installer)')
        work = self.base / 'notebook'
        work.mkdir()
        notebook = work / 'assignment.ipynb'
        shutil.copy(FIXTURE, notebook)
        clears = subprocess.run(['python3', '-c', 'import nbformat'], capture_output=True).returncode == 0
        seen = run_lua(self.base, f'''
vim.opt.rtp:append({json.dumps(str(plugin))})
J.specs[1].config(nil, J.specs[1].opts())  -- as lazy.nvim loads it
local api, steps = vim.api, {{}}
vim.cmd("edit " .. vim.fn.fnameescape({json.dumps(str(notebook))}))
local buf = api.nvim_get_current_buf()
steps.first, steps.filetype = api.nvim_buf_get_lines(buf, 0, 1, false)[1], vim.bo.filetype
steps.keys = vim.fn.maparg("<leader>jj", "n", false, true).buffer == 1
steps.cells = #J.cells(buf)
vim.cmd("write")
steps.saved = not vim.bo.modified
vim.fn.writefile(vim.fn.readfile({json.dumps(str(notebook))}, "b"), {json.dumps(str(work / 'after-save.ipynb'))}, "b")
api.nvim_win_set_cursor(0, {{ api.nvim_buf_line_count(buf), 0 }})
J.run.add_below()
vim.cmd("stopinsert")
local row = api.nvim_win_get_cursor(0)[1]
api.nvim_buf_set_lines(buf, row - 1, row, false, {{ "y = 41 + 1", "print(y)" }})
vim.cmd("write")
vim.fn.writefile(vim.fn.readfile({json.dumps(str(notebook))}, "b"), {json.dumps(str(work / 'after-add.ipynb'))}, "b")
if {json.dumps(clears)} then
  J.run.clear()
  vim.cmd("write")
end
steps.messages = api.nvim_exec2("messages", {{ output = true }}).output
out(steps)''', self.rendered['retro-amber'], {'PATH': f'{Path(command).parent}:/usr/bin:/bin'}, timeout=120)
        self.assertEqual((seen['first'], seen['filetype'], seen['keys']), ('---', 'markdown', True), seen['messages'])
        self.assertEqual(seen["cells"], 5, 'every code cell of the fixture is a cell in the buffer')
        self.assertTrue(seen['saved'])
        self.assertEqual((work / 'after-save.ipynb').read_bytes(), FIXTURE.read_bytes(), 'open + save changed the file')

        before, added = json.loads(FIXTURE.read_text()), json.loads((work / 'after-add.ipynb').read_text())
        self.assertEqual(added['metadata'], before['metadata'])
        self.assertEqual(added['cells'][:-1], before['cells'], 'adding a cell changed another one or its outputs')
        self.assertEqual((added['cells'][-1]['cell_type'], ''.join(added['cells'][-1]['source'])),
                         ('code', 'y = 41 + 1\nprint(y)'))
        if clears:
            cleared = json.loads(notebook.read_text())
            self.assertEqual([(c['cell_type'], c['source'], c['metadata']) for c in cleared['cells']],
                             [(c['cell_type'], c['source'], c['metadata']) for c in added['cells']])
            self.assertEqual([c.get('outputs') for c in cleared['cells'] if c['cell_type'] == 'code'],
                             [[]] * sum(c['cell_type'] == 'code' for c in added['cells']), 'outputs left after clearing')
            self.assertEqual(cleared['metadata'], before['metadata'])

    def test_a_notebook_jupytext_cannot_read_is_never_written_over(self):
        command, plugin = jupytext(), jupytext_nvim()
        if not command or not plugin:
            self.skipTest('needs the jupytext command and jupytext.nvim (both come with the installer)')
        work = self.base / 'broken'
        work.mkdir()
        # a notebook left half-merged: not JSON, so jupytext.nvim fails before it sets up its own save
        broken = work / 'merged.ipynb'
        broken.write_text('{\n "cells": [\n  {"cell_type": "code", "source": "x = 1"}\n<<<<<<< mine\n ]\n')
        text = broken.read_bytes()
        seen = run_lua(self.base, f'''
vim.opt.rtp:append({json.dumps(str(plugin))})
J.specs[1].config(nil, J.specs[1].opts())
pcall(vim.cmd, "edit " .. vim.fn.fnameescape({json.dumps(str(broken))}))
local writes = {{}}
for _, cmd in ipairs({{ "write", "write!", "wq!" }}) do writes[#writes + 1] = (pcall(vim.cmd, cmd)) end
vim.wait(100)
out({{ writes = writes, buftype = vim.bo.buftype, messages = vim.api.nvim_exec2("messages", {{ output = true }}).output }})
''', self.rendered['Paper'], {'PATH': f'{Path(command).parent}:/usr/bin:/bin'})
        self.assertEqual(broken.read_bytes(), text, 'saving a notebook jupytext could not read wrote over it')
        self.assertEqual((seen['writes'], seen['buftype']), ([False, False, False], 'nowrite'))
        self.assertIn('nvim --clean', seen['messages'], 'nothing says how to open it as JSON')

    def test_cells_run_on_a_kernel_and_their_outputs_are_saved(self):
        command, plugin, parts = jupytext(), jupytext_nvim(), kernel_parts()
        if not command or not plugin or not parts:
            self.skipTest('needs jupytext, jupytext.nvim, molten, pynvim + jupyter_client + nbformat in Neovim\'s Python, '
                          'a python3 kernel and the python parser (all come with the installer)')
        molten, python, site = parts
        work = self.base / 'kernel'
        work.mkdir()
        notebook = work / 'assignment.ipynb'
        shutil.copy(FIXTURE, notebook)
        seen = run_lua(self.base, f'''
for _, dir in ipairs({{ {json.dumps(str(plugin))}, {json.dumps(str(molten))}, {json.dumps(str(site))} }}) do
  vim.opt.rtp:append(dir)
end
vim.g.python3_host_prog = {json.dumps(python)}
J.specs[1].config(nil, J.specs[1].opts())  -- as lazy.nvim loads it
J.specs[2].init()
vim.g.molten_image_provider = "none"  -- no terminal to draw in here
-- --clean never loads a remote-plugin manifest and leaves its path a placeholder: write and load one in the temp home
vim.g.loaded_remote_plugins = {json.dumps(str(work / 'rplugin.vim'))}
vim.cmd("UpdateRemotePlugins")
vim.cmd("source " .. vim.fn.fnameescape(vim.g.loaded_remote_plugins))
local api, steps = vim.api, {{}}
vim.cmd("edit " .. vim.fn.fnameescape({json.dumps(str(notebook))}))
local buf = api.nvim_get_current_buf()
local cells = J.cells(buf)
local ready = false
api.nvim_create_autocmd("User", {{ pattern = "MoltenKernelReady", callback = function() ready = true end }})
api.nvim_win_set_cursor(0, {{ cells[1].first, 0 }})
J.run.cell()  -- starts the notebook's own kernel (python3), then runs the cell with its %matplotlib magic
steps.ready = vim.wait(60000, function() return ready end, 50)
api.nvim_win_set_cursor(0, {{ cells[2].first, 0 }})
J.run.cell()
local function done()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "molten_output" and table.concat(api.nvim_buf_get_lines(b, 0, 1, false)):match("Out%[2%]: .*Done") then
      return true
    end
  end
end
steps.done = vim.wait(20000, done, 100)
vim.wait(300)
vim.cmd("write")
vim.fn.writefile(vim.fn.readfile({json.dumps(str(notebook))}, "b"), {json.dumps(str(work / 'ran.ipynb'))}, "b")
-- split cell 2 in two: what molten ran no longer matches any one cell of the notebook
api.nvim_buf_set_lines(buf, cells[2].first, cells[2].first, false, {{ "```", "", "```python" }})
vim.cmd("write")
vim.wait(200)  -- the warning is scheduled past the save's :silent!
steps.messages = api.nvim_exec2("messages", {{ output = true }}).output
out(steps)''', self.rendered['Paper'], {'PATH': f'{Path(command).parent}:/usr/bin:/bin'}, timeout=150)
        self.assertTrue(seen['ready'], seen['messages'])
        before, ran = json.loads(FIXTURE.read_text()), json.loads((work / 'ran.ipynb').read_text())

        def text(cell):
            return ''.join(''.join(o.get('data', {}).get('text/plain', o.get('text', ''))) for o in cell['outputs'])

        self.assertEqual(ran['metadata'], before['metadata'])
        self.assertEqual(len(ran['cells']), len(before['cells']))
        self.assertIn('hello', text(ran['cells'][1]), 'the output of the first cell was not saved')
        self.assertIn('[0, 1, 4, 9, 16]', text(ran['cells'][2]), 'the output of the second cell was not saved')
        for cell in (ran['cells'][1], ran['cells'][2]):
            self.assertIsInstance(cell['execution_count'], int)
        self.assertEqual([c for k, c in enumerate(ran['cells']) if k not in (1, 2)],
                         [c for k, c in enumerate(before['cells']) if k not in (1, 2)], 'a cell that did not run changed')
        self.assertEqual([(c['id'], c['source'], c['metadata']) for c in ran['cells']],
                         [(c['id'], c['source'], c['metadata']) for c in before['cells']])
        self.assertIn('outputs NOT saved', seen['messages'], 'outputs were dropped without a word')
        split = json.loads(notebook.read_text())
        self.assertEqual([''.join(c['source']) for c in split['cells'][2:4]],
                         ['# a comment inside a cell', 'x = [n * n for n in range(5)]\nx'], 'the split was not saved')
        self.assertEqual(len(split['cells']), len(before['cells']) + 1)
        self.assertEqual(split['cells'][1], ran['cells'][1], 'the outputs saved before were lost')


if __name__ == '__main__':
    unittest.main()
