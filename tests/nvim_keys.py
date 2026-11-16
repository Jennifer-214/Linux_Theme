"""Neovim key definitions as written in the config and the desk modules: global maps, by mode and key.

Shared by tests/test_nvim_keys.py. A static read where it can be: lazy.nvim plugins are not installed in CI, so the
config's maps are read from its source in the three ways it writes them: map(...), vim.keymap.set(...) and lazy
`keys = {...}` rows. The desk modules' keys are rows of the action registry (shared/nvim_lua/desk/actions.lua), data
rather than calls, so those are read from the registry itself, filled by the modules in a headless Neovim.
"""
import functools
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / 'templates/nvim/init.lua', *sorted((ROOT / 'shared/nvim_lua/desk').glob('*.lua'))]
# The modules that add rows, in the order init.lua loads them, so a reference lists rows as the home menu does; any
# other module that adds rows comes after, by name.
FIRST = ['claude', 'work', 'since', 'review']

_DUMP = r'''
package.path = %(lua)s .. '/?.lua;' .. package.path
local A = require('desk.actions')
local loaded = {}
for _, name in ipairs(vim.json.decode(%(modules)s)) do
  local ok, err = pcall(require, 'desk.' .. name)
  if not ok then loaded[#loaded + 1] = name .. ': ' .. tostring(err) end
end
local rows = {}
for _, row in ipairs(A.rows()) do
  local mode = row.key and (type(row.mode) == 'table' and row.mode or { row.mode or 'n' }) or {}
  rows[#rows + 1] = { id = row.id, group = row.group, name = row.name, about = row.about, key = row.key, mode = mode,
    on = type(row.on) == 'table' and row.on or { row.on }, menu = row.menu, line = row.line, doc = row.doc, also = row.also,
    remote = row.remote, source = A.source(row) }
end
io.stdout:write(vim.json.encode({ rows = rows, problems = vim.list_extend(vim.list_extend({}, A.problems), loaded), groups = A.GROUPS }))
'''


@functools.lru_cache(maxsize=None)
def registry():
    """{rows, problems, groups}: every row the desk modules add, in the order they add them, each with its file."""
    desk = ROOT / 'shared/nvim_lua/desk'
    adding = sorted(p.stem for p in desk.glob('*.lua') if p.stem != 'actions' and 'actions.add(' in p.read_text())
    modules = [m for m in FIRST if m in adding] + [m for m in adding if m not in FIRST]
    with tempfile.TemporaryDirectory() as home:
        script = Path(home) / 'rows.lua'
        script.write_text(_DUMP % {'lua': json.dumps(str(ROOT / 'shared/nvim_lua')), 'modules': json.dumps(json.dumps(modules))})
        env = {'HOME': home, 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'XDG_STATE_HOME': home, 'XDG_CACHE_HOME': home,
               'XDG_CONFIG_HOME': home, 'XDG_DATA_HOME': home}
        ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True, timeout=60, env=env)
        if ran.returncode != 0:
            raise RuntimeError(ran.stdout + ran.stderr)
        found = json.loads(ran.stdout)
    found['problems'] = list(found.get('problems') or [])   # an empty list arrives as {}
    for row in found['rows']:
        row['mode'] = list(row.get('mode') or [])
        source = Path(row.get('source') or '')
        row['source'] = str(source.relative_to(ROOT)) if source.is_relative_to(ROOT) else str(source)
    return found

# A call that maps a key: map(...) helpers and vim.keymap.set(...), not a method such as menu:map(...).
_CALL = re.compile(r'''(?<![:.\w])(?:map|vim\.keymap\.set)\(\s*(\{[^}]*\}|"[^"]*"|'[^']*')\s*,\s*(["'])(.+?)\2''')
_LAZY = re.compile(r'''^\s*\{\s*(["'])(<leader>.+?)\1\s*,(.*)$''', re.M)
_MODES = re.compile(r'''["']([nvxoict])["']''')


def normal(lhs):
    """One spelling per key: <Leader>/<leader>, <space>, <c-x> and <C-x> read the same."""
    lhs = re.sub(r'(?i)<leader>', '<leader>', lhs)
    return re.sub(r'<([^>]+)>', lambda m: '<' + (m.group(1).lower() if m.group(1).lower() != 'leader' else 'leader') + '>', lhs)


def _span(text, start):
    """From an opening parenthesis to its partner (strings with parentheses in them are rare enough here)."""
    depth = 0
    for at in range(start, len(text)):
        depth += {'(': 1, ')': -1}.get(text[at], 0)
        if depth == 0:
            return text[start:at + 1]
    return text[start:]


def global_maps():
    """[(mode, key, 'file:line')] for every global (not buffer-local) mapping; a registry row's place is its file and id."""
    found = [(mode, normal(row['key']), f"{row['source']} ({row['id']})")
             for row in registry()['rows'] if row.get('key') and 'editor' in row['on'] for mode in row['mode']]
    for path in SOURCES:
        text = path.read_text()
        line_of = lambda at: f'{path.relative_to(ROOT)}:{text.count(chr(10), 0, at) + 1}'
        for call in _CALL.finditer(text):
            if 'buffer' in _span(text, text.index('(', call.start())):
                continue
            for mode in _MODES.findall(call.group(1)) or ['n']:
                found.append((mode, normal(call.group(3)), line_of(call.start())))
        for lazy in _LAZY.finditer(text):
            if _CALL.search(lazy.group(0)):
                continue
            mode = re.search(r'mode\s*=\s*(\{[^}]*\}|"[^"]*"|\'[^\']*\')', lazy.group(3))
            for each in (_MODES.findall(mode.group(1)) if mode else ['n']):
                found.append((each, normal(lazy.group(2)), line_of(lazy.start(2))))
    return found
