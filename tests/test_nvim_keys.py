"""Neovim keys: the review's reference table is generated from its key table, and no key is mapped twice by accident.

`python3 tests/test_nvim_keys.py --write` rewrites the generated section of shared/nvim_NVIM-KEYBINDS.md.
"""
from collections import defaultdict
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nvim_keys  # noqa: E402

ROOT = nvim_keys.ROOT
DOC = ROOT / 'shared/nvim_NVIM-KEYBINDS.md'
BEGIN = '<!-- review-keys:begin · generated from shared/nvim_lua/foxml/review.lua: python3 tests/test_nvim_keys.py --write -->'
END = '<!-- review-keys:end -->'

# Deliberate: the same action in both places, or keys that never meet in one buffer.
SHARED_GLOBALS = {
    ('n', '<leader>Cq'): 'the work viewer binds the same close action the Claude module does',
    ('n', '<leader>cf'): 'the LSP-attach map is buffer-local and formats the same way as the global one',
}
REVIEW_OVER_GLOBAL = {
    '<leader>bd': 'in a review, closing the buffer means closing the review',
    '<leader>rn': 'LSP rename attaches to source buffers; review panes are scratch buffers with no language server',
}


def review_keys():
    with tempfile.TemporaryDirectory() as home:
        script = Path(home) / 'dump.lua'
        script.write_text(f'''
package.path = {json.dumps(str(ROOT / 'shared/nvim_lua'))} .. '/?.lua;' .. package.path
local R = dofile({json.dumps(str(ROOT / 'shared/nvim_lua/foxml/review.lua'))})
local out = {{}}
for _, k in ipairs(R.keymap) do
  out[#out + 1] = {{ id = k.id, lhs = k.lhs, on = k.on, desc = k.desc, row = k.row or k.id, doc = k.doc, also = k.also }}
end
io.stdout:write(vim.json.encode(out))
''')
        env = {'HOME': home, 'PATH': '/usr/bin:/bin', 'XDG_STATE_HOME': home, 'XDG_CACHE_HOME': home, 'XDG_CONFIG_HOME': home}
        ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True, timeout=60, env=env)
        if ran.returncode != 0:
            raise RuntimeError(ran.stdout + ran.stderr)
        return json.loads(ran.stdout)


def shown(lhs):
    names = {'<CR>': 'Enter', '<Tab>': 'Tab', '<S-Tab>': 'Shift+Tab', '<Esc>': 'Esc', '<Space>': 'Space'}
    if lhs in names:
        return names[lhs]
    return 'Space ' + lhs[len('<leader>'):] if lhs.startswith('<leader>') else lhs


def reference(keys):
    rows, order = defaultdict(list), []
    for key in keys:
        if key['row'] not in rows:
            order.append(key['row'])
        rows[key['row']].append(key)
    lines = [BEGIN, '| Key in the review | Action |', '|---|---|']
    for name in order:
        entries = []
        for key in rows[name]:
            if key.get('doc') is False:
                continue
            # One key in both places reads once: m in the list and m in a diff is just m.
            same = next((e for e in entries if e['lhs'] == key['lhs']), None)
            if same:
                same['on'] = 'both' if same['on'] != key['on'] else same['on']
            else:
                entries.append(dict(key))
        if not entries:
            continue
        places = {k['on'] for k in entries}
        if len(places) == 1:
            place = places.pop()
            keys_text = ' / '.join(f"`{shown(k['lhs'])}`" for k in entries)
            keys_text += {'list': ' in the file list', 'diff': ' in a diff'}.get(place, '')
        else:
            keys_text = ' / '.join(f"`{shown(k['lhs'])}`" + {'list': ' (list)', 'diff': ' (diff)'}.get(k['on'], '') for k in entries)
        also = next((k['also'] for k in entries if k.get('also')), '')
        if also:
            keys_text += ', ' + also
        words = next(k['doc'] for k in entries if isinstance(k.get('doc'), str))
        lines.append(f'| {keys_text} | {words} |')
    lines.append(END)
    return '\n'.join(lines)


def with_reference(text, table):
    if BEGIN in text:
        head, rest = text.split(BEGIN, 1)
        return head + table + rest.split(END, 1)[1]
    raise ValueError('the keybinds doc has no generated review section')


@unittest.skipUnless(shutil.which('nvim'), 'Neovim required')
class NvimKeys(unittest.TestCase):
    def test_the_review_reference_is_generated_from_its_key_table(self):
        keys = review_keys()
        self.assertGreater(len(keys), 20)
        text = DOC.read_text()
        self.assertIn(BEGIN, text)
        self.assertEqual(text, with_reference(text, reference(keys)),
                         'NVIM-KEYBINDS.md differs from the review key table: run python3 tests/test_nvim_keys.py --write')

    def test_every_leader_key_of_the_work_modules_is_in_the_reference(self):
        doc = DOC.read_text()
        missing = [f'{key} ({where})' for mode, key, where in nvim_keys.global_maps()
                   if 'nvim_lua/foxml' in str(where) and key.startswith('<leader>') and 'Space ' + key[len('<leader>'):] not in doc]
        self.assertEqual(missing, [], 'a leader key with no row in NVIM-KEYBINDS.md')

    def test_no_key_is_mapped_twice_by_accident(self):
        by = defaultdict(list)
        for mode, key, where in nvim_keys.global_maps():
            by[(mode, key)].append(where)
        twice = {k: v for k, v in by.items() if len(v) > 1 and k not in SHARED_GLOBALS}
        self.assertEqual(twice, {}, 'a key mapped twice: the later one silently wins')
        self.assertTrue(set(SHARED_GLOBALS) <= set(k for k, v in by.items() if len(v) > 1), 'an allowed duplicate no longer exists; drop it')

    def test_review_keys_never_shadow_a_global_key_unless_that_is_the_point(self):
        keys = review_keys()
        for place in ('list', 'diff'):
            mine = [k['lhs'] for k in keys if k['on'] in ('both', place)]
            self.assertEqual(sorted(set(k for k in mine if mine.count(k) > 1)), [], f'a review key set twice in the {place}')
        globals_ = {key for mode, key, _ in nvim_keys.global_maps() if mode == 'n'}
        shadowed = sorted({nvim_keys.normal(k['lhs']) for k in keys if k['lhs'].startswith('<leader>')} & globals_)
        self.assertEqual([k for k in shadowed if k not in REVIEW_OVER_GLOBAL], [],
                         'a review key hides a global one inside the review (the Space e clash)')
        self.assertNotIn('<leader>e', [nvim_keys.normal(k['lhs']) for k in keys], 'Space e belongs to Neo-tree')


if __name__ == '__main__':
    if '--write' in sys.argv:
        DOC.write_text(with_reference(DOC.read_text(), reference(review_keys())))
        print('wrote', DOC.relative_to(ROOT))
    else:
        unittest.main()
