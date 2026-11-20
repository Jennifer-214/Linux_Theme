"""Neovim keys: the reference tables are generated from the action registry, and no key is mapped twice by accident.

`python3 tests/test_nvim_keys.py --write` rewrites the generated sections of shared/nvim_NVIM-KEYBINDS.md: the review's
keys (the rows shared/nvim_lua/desk/review.lua adds), the call graph's, the pop-out's (desk/popout.lua), the project
map's (desk/map.lua), the desk keys (every row on the editor surface: the global keys and the home menu's rows), and
the Jupyter notebook keys.
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
BEGIN = '<!-- review-keys:begin · generated from shared/nvim_lua/desk/review.lua: python3 tests/test_nvim_keys.py --write -->'
END = '<!-- review-keys:end -->'
DESK_BEGIN = ('<!-- desk-keys:begin · generated from the action registry (shared/nvim_lua/desk/actions.lua): '
              'python3 tests/test_nvim_keys.py --write -->')
DESK_END = '<!-- desk-keys:end -->'
GRAPH_BEGIN = '<!-- callgraph-keys:begin · generated from shared/nvim_lua/desk/callgraph.lua: python3 tests/test_nvim_keys.py --write -->'
GRAPH_END = '<!-- callgraph-keys:end -->'
POPOUT_BEGIN = '<!-- popout-keys:begin · generated from shared/nvim_lua/desk/popout.lua: python3 tests/test_nvim_keys.py --write -->'
POPOUT_END = '<!-- popout-keys:end -->'
MAP_BEGIN = '<!-- map-keys:begin · generated from shared/nvim_lua/desk/map.lua: python3 tests/test_nvim_keys.py --write -->'
MAP_END = '<!-- map-keys:end -->'
REVIEW = {'review-list': 'list', 'review-diff': 'diff'}
GRAPH = {'callgraph': 'tab', 'callgraph-panel': 'panel'}
# Where a key works, as a reference line says it: for a line of one place, then per key when a line mixes them.
REVIEW_PLACES = ({'list': ' in the file list', 'diff': ' in a diff'}, {'list': ' (list)', 'diff': ' (diff)'})
GRAPH_PLACES = ({'tab': ' in the graph tab', 'panel': ' in the panel', 'both': ' in a graph'}, {'tab': ' (graph tab)', 'panel': ' (panel)'})
POPOUT_PLACES = ({'popout': ' in the pop-out', 'graph': ' in a graph'}, {'popout': ' (pop-out)', 'graph': ' (graph)'})
MAP_PLACES = ({'map': ' in the map'}, {'map': ' (map)'})
# The home menu's key; the pop-out's own row is that menu there (the editor's rows for the box it has selected).
HOME_ROWS = {'desk.home', 'popout.home'}
JUPYTER_BEGIN = ('<!-- jupyter-keys:begin · generated from the desk-jupyter block of templates/nvim/init.lua: '
                 'python3 tests/test_nvim_keys.py --write -->')
JUPYTER_END = '<!-- jupyter-keys:end -->'

# Deliberate: the same action in both places, or keys that never meet in one buffer.
SHARED_GLOBALS = {
    ('n', '<leader>Cq'): 'the work viewer binds the same close action the Claude module does',
    ('n', '<leader>cf'): 'the LSP-attach map is buffer-local and formats the same way as the global one',
}
REVIEW_OVER_GLOBAL = {
    '<leader>bd': 'in a review, closing the buffer means closing the review',
    '<leader>rn': 'LSP rename attaches to source buffers; review panes are scratch buffers with no language server',
    '<leader>dd': 'the review opens the working source before asking symdeps for its card',
    '<leader>dm': 'the review opens the working source before asking symdeps for its menu',
}
# Space i, investigate this function (I1, 2026-11-19): the same action as in code, about the review's selected
# changed function instead of the cursor's (map.function_here) — the point, not a clash.
REVIEW_OVER_GLOBAL.update({key: 'Space i asks about the selected changed function, as it asks about the cursor\'s in code'
                           for key in ('<leader>ic', '<leader>ii', '<leader>it', '<leader>iT', '<leader>iu', '<leader>id', '<leader>ik', '<leader>ir')})


def entry(row, on):
    """A row as a reference table reads it: row is the line it is on, doc its words (False: left out)."""
    return {'id': row['id'], 'lhs': row.get('key'), 'on': on, 'desc': row['name'], 'row': row.get('line') or row['id'],
            'doc': row['doc'] if 'doc' in row else row.get('about'), 'also': row.get('also')}


def own_first(keys, module):
    """A view's own rows first, then the ones every view shares (desk.keys, ?), each in the order they were added."""
    return sorted(keys, key=lambda k: not k['id'].startswith(module + '.'))


def review_keys():
    """The review's keys: on is 'list' (the file list), 'diff' (the comparison panes) or 'both'."""
    keys = []
    for row in nvim_keys.registry()['rows']:
        places = {REVIEW[s] for s in row['on'] if s in REVIEW}
        if row.get('key') and places:
            keys.append(entry(row, 'both' if len(places) > 1 else places.pop()))
    return own_first(keys, 'review')


def callgraph_keys():
    """The call graph's keys: on is 'editor' (Space cc, Space co), 'tab' (the graph tab), 'panel' or 'both'."""
    keys = []
    for row in nvim_keys.registry()['rows']:
        places = {GRAPH[s] for s in row['on'] if s in GRAPH}
        # The shared desk rows (?) too; another module's row on a graph (the pop-out's o) is in that module's table.
        if row.get('key') and (row['id'].startswith('callgraph.') or (places and row['id'].startswith('desk.'))):
            keys.append(entry(row, 'editor' if 'editor' in row['on'] else 'both' if len(places) > 1 else places.pop()))
    return own_first(keys, 'callgraph')


def popout_keys():
    """The pop-out's keys: on is 'popout' (its window), 'graph' (the graph tab and the panel) or 'editor'."""
    keys = []
    for row in nvim_keys.registry()['rows']:
        if row['id'].startswith('popout.') and row.get('key'):
            keys.append(entry(row, 'popout' if 'popout' in row['on'] else 'graph' if set(row['on']) & set(GRAPH) else 'editor'))
    return keys


def map_keys():
    """The project map's keys: on is 'editor' (Space cm) or 'map' (the map's tab)."""
    keys = []
    for row in nvim_keys.registry()['rows']:
        # The shared desk rows (?) too; another module's row on the map would be in that module's table.
        if row.get('key') and (row['id'].startswith('map.') or ('map' in row['on'] and row['id'].startswith('desk.'))):
            keys.append(entry(row, 'editor' if 'editor' in row['on'] else 'map'))
    return own_first(keys, 'map')


def desk_keys():
    """Every row on the editor surface, by group as the home menu orders them, then as the modules add them."""
    found = nvim_keys.registry()
    order = {group: i for i, group in enumerate(found['groups'])}
    rows = [row for row in found['rows'] if 'editor' in row['on']]
    for i, row in enumerate(rows):
        order.setdefault(row['group'], len(found['groups']) + i)
    return [entry(row, 'editor') for row in sorted(rows, key=lambda row: order[row['group']])]


def jupyter_keys():
    """The notebook keys as the template's desk-jupyter block lists them: [{lhs, desc, modes}]."""
    with tempfile.TemporaryDirectory() as home:
        script = Path(home) / 'dump.lua'
        script.write_text(f'''
local J = dofile({json.dumps(str(ROOT / 'tests/jupyter_block.lua'))})({json.dumps(str(ROOT / 'templates/nvim/init.lua'))})
local out = {{}}
for _, k in ipairs(J.keymap) do
  out[#out + 1] = {{ lhs = k.lhs, desc = k.desc, modes = type(k.mode) == 'table' and k.mode or {{ k.mode }} }}
end
io.stdout:write(vim.json.encode(out))
''')
        env = {'HOME': home, 'PATH': '/usr/bin:/bin', 'XDG_STATE_HOME': home, 'XDG_CACHE_HOME': home,
               'XDG_CONFIG_HOME': home, 'XDG_DATA_HOME': home}
        ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True, timeout=60, env=env)
        if ran.returncode != 0:
            raise RuntimeError(ran.stdout + ran.stderr)
        return json.loads(ran.stdout)


def jupyter_reference(keys):
    lines = [JUPYTER_BEGIN, '| Key in a notebook | Action |', '|---|---|']
    for key in keys:
        name = 'Shift+Enter' if key['lhs'] == '<S-CR>' else shown(key['lhs'])
        lines.append(f"| `{name}`{' (also in insert mode)' if 'i' in key['modes'] else ''} | {key['desc']} |")
    lines.append(JUPYTER_END)
    return '\n'.join(lines)


def with_jupyter(text, table):
    if JUPYTER_BEGIN in text:
        head, rest = text.split(JUPYTER_BEGIN, 1)
        return head + table + rest.split(JUPYTER_END, 1)[1]
    raise ValueError('the keybinds doc has no generated Jupyter section')


def shown(lhs):
    names = {'<CR>': 'Enter', '<S-CR>': 'Shift+Enter', '<Tab>': 'Tab', '<S-Tab>': 'Shift+Tab', '<Esc>': 'Esc', '<Space>': 'Space'}
    if lhs in names:
        return names[lhs]
    if lhs.startswith('<leader>'):
        rest = lhs[len('<leader>'):]
        named = {key.lower(): name for key, name in names.items()}   # a key read back from a map is lowercased
        return 'Space ' + ('Space' if rest == '<leader>' else named.get(rest.lower(), rest) if rest.startswith('<') else rest)
    return lhs


def reference(keys, begin=BEGIN, end=END, head='| Key in the review | Action |', places_said=REVIEW_PLACES):
    single, mixed = places_said
    rows, order = defaultdict(list), []
    for key in keys:
        if key['row'] not in rows:
            order.append(key['row'])
        rows[key['row']].append(key)
    lines = [begin, head, '|---|---|']
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
        if all(not k['lhs'] for k in entries):
            keys_text = 'home menu: ' + ' / '.join(k['desc'] for k in entries)
        elif len(places) == 1:
            place = places.pop()
            keys_text = ' / '.join(f"`{shown(k['lhs'])}`" for k in entries)
            keys_text += single.get(place, '')
        else:
            keys_text = ' / '.join(f"`{shown(k['lhs'])}`" + mixed.get(k['on'], '') for k in entries)
        also = next((k['also'] for k in entries if k.get('also')), '')
        if also:
            keys_text += ', ' + also
        words = next((k['doc'] for k in entries if isinstance(k.get('doc'), str)), None)
        if words is None:
            raise ValueError(f'the reference line of {name} has no words: give its first row about or doc')
        lines.append(f'| {keys_text} | {words} |')
    lines.append(end)
    return '\n'.join(lines)


def desk_reference():
    return reference(desk_keys(), DESK_BEGIN, DESK_END, '| Key | Action |', ({}, {}))


def callgraph_reference():
    return reference(callgraph_keys(), GRAPH_BEGIN, GRAPH_END, '| Key | Action |', GRAPH_PLACES)


def popout_reference():
    return reference(popout_keys(), POPOUT_BEGIN, POPOUT_END, '| Key | Action |', POPOUT_PLACES)


def map_reference():
    return reference(map_keys(), MAP_BEGIN, MAP_END, '| Key | Action |', MAP_PLACES)


def with_reference(text, table, begin=BEGIN, end=END):
    if begin in text:
        head, rest = text.split(begin, 1)
        return head + table + rest.split(end, 1)[1]
    raise ValueError('the keybinds doc has no generated section ' + begin[:30])


@unittest.skipUnless(shutil.which('nvim'), 'Neovim required')
class NvimKeys(unittest.TestCase):
    def test_the_review_reference_is_generated_from_its_key_table(self):
        keys = review_keys()
        self.assertGreater(len(keys), 20)
        text = DOC.read_text()
        self.assertIn(BEGIN, text)
        self.assertEqual(text, with_reference(text, reference(keys)),
                         'NVIM-KEYBINDS.md differs from the review key table: run python3 tests/test_nvim_keys.py --write')

    def test_the_desk_reference_is_generated_from_the_registry(self):
        text = DOC.read_text()
        self.assertIn(DESK_BEGIN, text)
        self.assertEqual(text, with_reference(text, desk_reference(), DESK_BEGIN, DESK_END),
                         'NVIM-KEYBINDS.md differs from the action registry: run python3 tests/test_nvim_keys.py --write')
        self.assertIn('| `Space Space` |', desk_reference(), 'the home key leads the desk keys')

    def test_the_call_graph_reference_is_generated_from_its_rows(self):
        text = DOC.read_text()
        self.assertIn(GRAPH_BEGIN, text)
        self.assertEqual(text, with_reference(text, callgraph_reference(), GRAPH_BEGIN, GRAPH_END),
                         'NVIM-KEYBINDS.md differs from the call graph rows: run python3 tests/test_nvim_keys.py --write')
        table = callgraph_reference()
        for line in ('`Space cc`, `:CallGraph`', '`j` / `k` in a graph', '`p` in the panel', '`s` in a graph', '`gs` in a graph',
                     '`o` in a graph', '`?` in a graph'):
            self.assertIn(line, table)
        self.assertTrue(table.rstrip().splitlines()[-2].startswith('| `?`'), 'the shared ? comes after the graph\'s own keys')

    def test_every_view_lists_its_keys_on_question_mark(self):
        rows = {row['id']: row for row in nvim_keys.registry()['rows']}
        self.assertEqual(rows['desk.keys']['key'], '?')
        self.assertEqual(sorted(rows['desk.keys']['on']), sorted(['review-list', 'review-diff', 'callgraph', 'callgraph-panel', 'since', 'map',
                                                                  'menu']))
        # The pop-out's ? is a row of its own (its key line and home menu name it) that opens this same list.
        taken = [row['id'] for row in rows.values() if row.get('key') == '?' and row['id'] not in ('desk.keys', 'popout.keys')]
        self.assertEqual(taken, [], '? is the key list on every view; the review\'s actions are a and Space Space')
        self.assertIn('| `?` |', reference(review_keys()), 'the review reference names ?')

    def test_the_pop_out_reference_is_generated_from_its_rows(self):
        text = DOC.read_text()
        self.assertIn(POPOUT_BEGIN, text)
        self.assertEqual(text, with_reference(text, popout_reference(), POPOUT_BEGIN, POPOUT_END),
                         'NVIM-KEYBINDS.md differs from the pop-out rows: run python3 tests/test_nvim_keys.py --write')
        table = popout_reference()
        # The window's own keys; a view's keys there are its surface's (the call graph's are in its table).
        for line in ('| `Space Tab` |', '`f` / `Shift+Enter` in the pop-out', '`o` in the pop-out', '`Space Tab` in the pop-out'):
            self.assertIn(line, table)

    def test_the_map_reference_is_generated_from_its_rows(self):
        text = DOC.read_text()
        self.assertIn(MAP_BEGIN, text)
        self.assertEqual(text, with_reference(text, map_reference(), MAP_BEGIN, MAP_END),
                         'NVIM-KEYBINDS.md differs from the project map rows: run python3 tests/test_nvim_keys.py --write')
        table = map_reference()
        for line in ('| `Space cm`, `:ProjectMap` |', '| `<BS>` / `-` in the map |', '| `P` in the map |'):
            self.assertIn(line, table)
        self.assertNotIn('`p` in the map', table, "p is the grammar's pin; the ways moved to P")
        self.assertTrue(table.rstrip().splitlines()[-2].startswith('| `?` in the map'), "the shared ? comes after the map's own keys")
        back = next(line for line in table.splitlines() if line.startswith('| `<BS>` / `-` in the map |'))
        self.assertIn('`-` takes a level off instead', back, '- on a callers or reach page of more than one level: its line says so')

    def test_the_registry_takes_every_row_the_modules_add(self):
        found = nvim_keys.registry()
        self.assertEqual(found['problems'], [], 'a row was refused (desk/actions.lua says why at startup too)')
        ids = {row['id'] for row in found['rows']}
        self.assertEqual(len(ids), len(found['rows']), 'two rows with one id')
        self.assertEqual([row['id'] for row in found['rows'] if row.get('line') and row['line'] not in ids], [],
                         'a row joins the reference line of a row that does not exist')
        self.assertEqual([row['id'] for row in found['rows'] if not row['source'].startswith('shared/nvim_lua/desk/')], [],
                         'every row comes from a desk module')

    def test_the_jupyter_reference_is_generated_from_its_key_table(self):
        keys = jupyter_keys()
        self.assertGreater(len(keys), 10)
        text = DOC.read_text()
        self.assertIn(JUPYTER_BEGIN, text)
        self.assertEqual(text, with_jupyter(text, jupyter_reference(keys)),
                         'NVIM-KEYBINDS.md differs from the Jupyter key table: run python3 tests/test_nvim_keys.py --write')

    def test_jupyter_keys_never_shadow_a_global_key(self):
        globals_ = {(mode, key) for mode, key, _ in nvim_keys.global_maps()}
        mine = {(mode, nvim_keys.normal(k['lhs'])) for k in jupyter_keys() for mode in k['modes']}
        self.assertEqual(len(mine), len(jupyter_keys()) + 1, 'a notebook key is listed twice')  # Shift+Enter: n and i
        self.assertEqual(sorted(mine & globals_), [], 'a notebook key hides a global one inside notebooks')

    def test_every_leader_key_of_the_work_modules_is_in_the_reference(self):
        doc = DOC.read_text()
        missing = [f'{key} ({where})' for mode, key, where in nvim_keys.global_maps()
                   if 'nvim_lua/desk' in str(where) and key.startswith('<leader>') and shown(key) not in doc]
        self.assertEqual(missing, [], 'a leader key with no row in NVIM-KEYBINDS.md')

    def test_no_key_is_mapped_twice_by_accident(self):
        by = defaultdict(list)
        for mode, key, where in nvim_keys.global_maps():
            by[(mode, key)].append(where)
        twice = {k: v for k, v in by.items() if len(v) > 1 and k not in SHARED_GLOBALS}
        self.assertEqual(twice, {}, 'a key mapped twice: the later one silently wins')
        self.assertTrue(set(SHARED_GLOBALS) <= set(k for k, v in by.items() if len(v) > 1), 'an allowed duplicate no longer exists; drop it')

    def test_the_home_key_is_free_everywhere_else(self):
        # Space Space opens the home menu in every window: no other map, global or a surface's, may start with it.
        taken = [f'{key} ({where})' for mode, key, where in nvim_keys.global_maps()
                 if mode == 'n' and key.startswith('<leader><leader>') and 'desk.home' not in where]
        taken += [row['id'] for row in nvim_keys.registry()['rows']
                  if (row.get('key') or '').lower().startswith('<leader><leader>') and row['id'] not in HOME_ROWS]
        self.assertEqual(taken, [], 'Space Space belongs to the home menu')

    def test_which_key_names_the_claude_group_in_normal_and_visual_mode(self):
        plugin = Path.home() / '.local/share/nvim/lazy/which-key.nvim'
        if not plugin.is_dir():
            self.skipTest('which-key.nvim is not installed')
        with tempfile.TemporaryDirectory() as home:
            script = Path(home) / 'groups.lua'
            # The which-key options exactly as init.lua passes them, and the keys exactly as desk.claude maps them.
            script.write_text(f'''
vim.g.mapleader = ' '
vim.opt.rtp:append({json.dumps(str(plugin))})
package.path = {json.dumps(str(ROOT / 'shared/nvim_lua'))} .. '/?.lua;' .. package.path
local source = table.concat(vim.fn.readfile({json.dumps(str(ROOT / 'templates/nvim/init.lua'))}), '\\n')
local _, at = assert(source:find('"folke/which-key.nvim"', 1, true))
require('which-key').setup(assert(loadstring('return ' .. assert(source:sub(at):match('opts = (%b{{}})'))))())
require('desk.claude').setup()
vim.wait(200)
local out = {{}}
for _, mode in ipairs({{ 'n', 'x' }}) do
  local found = require('which-key.buf').get({{ mode = mode }})
  local group = found and found.tree.root:find(require('which-key.util').keys('<leader>C', {{ norm = true }}))
  local note = group and group:find(require('which-key.util').keys('n', {{ norm = true }}))
  out[mode] = {{ group = group and group.desc or vim.NIL, note = note and note.desc or vim.NIL }}
end
io.stdout:write(vim.json.encode(out))
vim.cmd('qa!')
''')
            env = {'HOME': home, 'PATH': '/usr/bin:/bin', 'XDG_STATE_HOME': home, 'XDG_CACHE_HOME': home,
                   'XDG_CONFIG_HOME': home, 'XDG_RUNTIME_DIR': home}
            ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True,
                                 timeout=60, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            seen = json.loads(ran.stdout.strip().splitlines()[-1])
        self.assertEqual(seen['n'], {'group': 'Claude', 'note': 'Note to a Claude'})
        self.assertEqual(seen['x'], {'group': 'Claude', 'note': 'Selection to a Claude'})

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
        text = with_reference(DOC.read_text(), reference(review_keys()))
        text = with_reference(text, callgraph_reference(), GRAPH_BEGIN, GRAPH_END)
        text = with_reference(text, popout_reference(), POPOUT_BEGIN, POPOUT_END)
        text = with_reference(text, map_reference(), MAP_BEGIN, MAP_END)
        text = with_reference(text, desk_reference(), DESK_BEGIN, DESK_END)
        DOC.write_text(with_jupyter(text, jupyter_reference(jupyter_keys())))
        print('wrote', DOC.relative_to(ROOT))
    else:
        unittest.main()
