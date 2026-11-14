"""Neovim key definitions as written in the config and the foxml modules: global maps, by mode and key.

Shared by tests/test_nvim_keys.py. A static read: lazy.nvim plugins are not installed in CI, so the config's maps are
read from its source in the three ways it writes them: map(...), vim.keymap.set(...) and lazy `keys = {...}` rows.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / 'templates/nvim/init.lua', *sorted((ROOT / 'shared/nvim_lua/foxml').glob('*.lua'))]

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
    """[(mode, key, 'file:line')] for every global (not buffer-local) mapping."""
    found = []
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
