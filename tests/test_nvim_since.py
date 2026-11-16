"""The since page (shared/nvim_lua/desk/since.lua) in a headless Neovim, with desk-work's answer as fixture data."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
NOW = 1_794_800_000
FIXTURE = {
    'ok': True, 'root': '/code/paper', 'from': NOW - 7200, 'first': False, 'since': 'this morning', 'at': NOW, 'truncated': False,
    'items': [
        {'kind': 'turn', 'at': NOW - 60, 'label': 'Queue work · 2 files', 'files': ['src/queue.cpp', 'README.md'],
         'agent': 'claude', 'session': 's1', 'name': 'Queue work'},
        {'kind': 'job', 'at': NOW - 120, 'id': 'b' * 32, 'label': 'Queue bench', 'state': 'passed', 'metrics': [
            {'name': 'p99', 'value': 412, 'unit': 'ns', 'previous': 400, 'change': 12, 'percent': 3, 'delta': '+12',
             'better': 'lower', 'verdict': 'worse', 'source': 'output'},
            {'name': 'throughput', 'value': 1.2, 'unit': 'M/s', 'previous': 1.1, 'change': 0.1, 'percent': 9, 'delta': '+0.1',
             'better': 'higher', 'verdict': 'better', 'source': 'output'}]},
        {'kind': 'tests', 'at': NOW - 180, 'id': 't' * 32, 'label': 'make test', 'state': 'failed', 'passed': 126, 'failed': 2},
        {'kind': 'commit', 'at': NOW - 240, 'sha': 'a' * 40, 'author': 'Caramel', 'label': 'queue: drain before stop'},
    ]}

LUA = r'''
package.path = vim.env.TEST_LUA .. '/?.lua;' .. package.path
local called = {}
package.loaded['desk.review'] = { open_item = function(item, root) called[#called + 1] = { 'review', item.kind, item.sha, root } end }
package.loaded['desk.work'] = { tests = function(id) called[#called + 1] = { 'tests', id } end,
  refusal = function(args, out) return 'refused: ' .. (out.stdout or '') end }
package.loaded['desk.claude'] = { open_review = function(row, root) called[#called + 1] = { 'turn', row.sid, table.concat(row.files, ','), root } end }
local S = dofile(vim.env.TEST_LUA .. '/desk/since.lua')
package.loaded['desk.since'] = S
local answer = vim.env.TEST_ANSWER
local asked = {}
local real = vim.system
vim.system = function(argv, opts, done)
  if argv[1] ~= 'desk-work' then return real(argv, opts, done) end
  asked[#asked + 1] = table.concat(argv, ' ')
  local out = argv[2] == 'since' and { code = 0, stdout = answer } or { code = 0, stdout = 'p99 412ns\nthroughput: 1.2M/s\n' }
  -- The answer arrives later, the way a real process's does: the page must not wait for it.
  vim.defer_fn(function() done(out) end, 30)
  return { wait = function() error('the since page waited on desk-work') end, kill = function() end }
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false) end
local function find(buf, pattern)
  for i, line in ipairs(lines(buf)) do if line:find(pattern, 1, true) then return i end end
  error('no line with ' .. pattern .. ' in\n' .. table.concat(lines(buf), '\n'))
end
local function enter(buf, pattern)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { find(buf, pattern), 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
end
'''


@unittest.skipUnless(shutil.which('nvim'), 'Neovim required')
class SincePage(unittest.TestCase):
    def run_lua(self, code, answer=FIXTURE):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'since.lua'
            script.write_text(LUA + code)
            env = dict(os.environ, HOME=tmp, XDG_STATE_HOME=tmp, XDG_CACHE_HOME=tmp, XDG_CONFIG_HOME=tmp, XDG_DATA_HOME=tmp,
                       TEST_LUA=str(ROOT / 'shared/nvim_lua'), TEST_ANSWER=json.dumps(answer), TZ='UTC',
                       TEST_COMMIT_AT=time.strftime('%H:%M', time.gmtime(NOW - 240)))
            ran = subprocess.run(['nvim', '--headless', '--clean', '-l', str(script)], capture_output=True, text=True,
                                 timeout=60, env=env, cwd=tmp)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            return ran.stdout

    def test_opening_reads_in_the_background_marks_now_and_lists_newest_first(self):
        self.run_lua(r'''
local buf = S.open('/code/paper')
assert(lines(buf)[3] == 'Reading...', 'the page opens at once, before desk-work answers: ' .. vim.inspect(lines(buf)))
assert(asked[1] == 'desk-work since --root /code/paper --reader nvim --mark yes', asked[1])
assert(vim.wait(2000, function() return #lines(buf) > 4 end, 10), 'the answer was never drawn')
local text = lines(buf)
assert(text[1] == 'Since you last looked · this morning', text[1])
local turn, file, job, worse, better = find(buf, '✎ Queue work · 2 files'), find(buf, '· src/queue.cpp'), find(buf, '◇ Queue bench · passed'),
  find(buf, 'p99 412ns (+12)  ↑ worse'), find(buf, 'throughput 1.2M/s (+0.1)  ↑ better')
local tests, commit = find(buf, '! 2 failed · 126 passed · make test'), find(buf, '❦ aaaaaaa queue: drain before stop · Caramel')
assert(turn < file and file < job and job < worse and worse < better and better < tests and tests < commit, 'newest first')
assert(text[commit]:find(vim.env.TEST_COMMIT_AT, 1, true), 'each line says when: ' .. text[commit])
assert(vim.api.nvim_win_get_cursor(0)[1] == turn, 'the cursor starts on the newest entry')
assert(vim.bo[buf].modifiable == false and vim.bo[buf].buftype == 'nofile')
''')

    def test_enter_opens_what_a_line_names(self):
        self.run_lua(r'''
local buf = S.open('/code/paper')
assert(vim.wait(2000, function() return #lines(buf) > 4 end, 10))
enter(buf, 'queue: drain before stop')
assert(vim.deep_equal(called[#called], { 'review', 'commit', string.rep('a', 40), '/code/paper' }), vim.inspect(called))
enter(buf, 'make test')
assert(vim.deep_equal(called[#called], { 'tests', string.rep('t', 32) }), vim.inspect(called))
enter(buf, 'Queue work · 2 files')
assert(vim.deep_equal(called[#called], { 'turn', 's1', '/code/paper/src/queue.cpp,/code/paper/README.md', '/code/paper' }), vim.inspect(called))
enter(buf, 'p99 412ns')
assert(asked[#asked] == 'desk-work log --id ' .. string.rep('b', 32), asked[#asked])
assert(vim.wait(2000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'p99 412ns' end, 10), 'the job output opens')
vim.cmd('tabclose')
enter(buf, '· README.md')
assert(vim.api.nvim_buf_get_name(0) == '/code/paper/README.md', vim.api.nvim_buf_get_name(0))
''')

    def test_figures_list_the_newest_jobs_numbers_and_enter_opens_its_output(self):
        self.run_lua(r'''
local shown
package.loaded['desk.review'].show_menu = function(items, opts) shown = { items = items, opts = opts } end
local metrics = vim.json.encode({ ok = true, root = '/code/paper',
  job = { id = string.rep('b', 32), title = 'Queue bench', command = 'make bench', state = 'passed', ended = 1794800000 },
  previous = { id = string.rep('c', 32), ended = 1794790000 },
  metrics = { { name = 'p99', value = 412, unit = 'ns', previous = 400, change = 12, percent = 3, delta = '+12', better = 'lower', verdict = 'worse' } } })
local page_system = vim.system
vim.system = function(argv, opts, done)
  if argv[2] ~= 'metrics' then return page_system(argv, opts, done) end
  asked[#asked + 1] = table.concat(argv, ' ')
  vim.defer_fn(function() done({ code = 0, stdout = metrics }) end, 30)
  return { wait = function() error('the figures waited on desk-work') end, kill = function() end }
end
S.figures('/code/paper')
assert(asked[#asked] == 'desk-work metrics --root /code/paper', asked[#asked])
assert(vim.wait(2000, function() return shown ~= nil end, 10), 'the figures were never shown')
assert(shown.opts.title == 'Figures · Queue bench', shown.opts.title)
assert(shown.items[1].name == 'p99 412ns (+12)  ↑ worse', shown.items[1].name)
assert(shown.items[1].label:find('Against the run that ended at', 1, true), shown.items[1].label)
shown.items[1].run()
assert(asked[#asked] == 'desk-work log --id ' .. string.rep('b', 32), asked[#asked])
assert(vim.wait(2000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'p99 412ns' end, 10), 'its output opens')
-- No job has printed figures yet: said so, never an empty menu.
shown, metrics = nil, vim.json.encode({ ok = true, root = '/code/paper', job = vim.NIL, previous = vim.NIL, metrics = {} })
local said
vim.notify = function(text) said = text end
S.figures('/code/paper')
assert(vim.wait(2000, function() return said ~= nil end, 10) and said:find('No job', 1, true), tostring(said))
assert(shown == nil, 'an empty figures menu was shown')
''')

    def test_retro_draws_a_dos_page(self):
        self.run_lua(r'''
vim.g.desk_style = 'retro'
local buf = S.open('/code/paper')
assert(vim.wait(2000, function() return #lines(buf) > 4 end, 10))
assert(lines(buf)[1] == 'SINCE YOU LAST LOOKED · THIS MORNING', lines(buf)[1])
assert(lines(buf)[2] == 'Enter OPENS · q CLOSES · ? KEYS', 'retro: the keys as typed, the words in capitals: ' .. lines(buf)[2])
find(buf, '♦ aaaaaaa'); find(buf, '* Queue work'); find(buf, '► Queue bench'); find(buf, '↑ worse')
-- Every mark the page draws is one code page 437 has.
local cp437 = '♦√!☼○►*·↑↓'
for _, line in ipairs(lines(buf)) do
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    assert(#ch == 1 or cp437:find(ch, 1, true), 'not a DOS character: ' .. ch .. ' in ' .. line)
  end
end
vim.g.desk_style = nil
assert(S.style() == 'paper', 'without the style init.lua publishes, the page draws the normal way')
''')

    def test_opening_again_keeps_the_list_until_something_is_newer(self):
        self.run_lua(r'''
local buf = S.open('/code/paper')
assert(vim.wait(2000, function() return #lines(buf) > 4 end, 10))
local tabs = #vim.api.nvim_list_tabpages()
-- Opened again while it is open: the same page comes back, its list and place kept while nothing is new.
vim.api.nvim_win_set_cursor(0, { find(buf, 'make test'), 0 })
local place = vim.api.nvim_win_get_cursor(0)[1]
vim.cmd('tabnew')
answer = vim.json.encode({ ok = true, root = '/code/paper', from = 1794800000, first = false, since = 'at 14:00', at = 1794800100, items = {} })
assert(S.open('/code/paper') == buf and #vim.api.nvim_list_tabpages() == tabs + 1, 'a second Space Ch opened a second page')
assert(vim.api.nvim_get_current_buf() == buf, 'the page did not come back')
assert(vim.wait(2000, function() return lines(buf)[1]:find('Nothing new since', 1, true) end, 10), lines(buf)[1])
assert(lines(buf)[1]:match('^Nothing new since .+ · what that look showed$'), lines(buf)[1])
find(buf, 'queue: drain before stop'); find(buf, '✎ Queue work · 2 files')
assert(vim.api.nvim_win_get_cursor(0)[1] == place, 'the page lost its place')
enter(buf, 'queue: drain before stop')
assert(vim.deep_equal(called[#called], { 'review', 'commit', string.rep('a', 40), '/code/paper' }), 'the kept list still opens: ' .. vim.inspect(called))
-- Closed, then opened again with nothing new: the kept list, from the state folder (another Neovim reads it too).
vim.api.nvim_set_current_buf(buf); vim.cmd('tabclose')
assert(not vim.api.nvim_buf_is_valid(buf))
local kept = S.kept('/code/paper')
assert(kept and #kept.items == 4 and kept.at == 1794800000, vim.inspect(kept))
buf = S.open('/code/paper')
assert(vim.wait(2000, function() return (lines(buf)[1] or ''):find('Nothing new since', 1, true) end, 10), vim.inspect(lines(buf)))
find(buf, 'queue: drain before stop')
-- Something newer replaces the list, and is what is kept from then on.
answer = vim.json.encode({ ok = true, root = '/code/paper', from = 1794800100, first = false, since = 'at 14:01', at = 1794800200,
  items = { { kind = 'commit', at = 1794800150, sha = string.rep('c', 40), author = 'Caramel', label = 'newer work' } } })
S.open('/code/paper')
assert(vim.wait(2000, function() return lines(buf)[1] == 'Since you last looked · at 14:01' end, 10), lines(buf)[1])
find(buf, 'newer work')
assert(not table.concat(lines(buf), '\n'):find('drain before stop', 1, true), 'the older list stayed beside the new one')
assert(S.kept('/code/paper').items[1].label == 'newer work')
assert(S.layout({ items = kept.items, kept = 1794800000 }, 'retro', '/r')[1]:match('^NOTHING NEW SINCE .+ · WHAT THAT LOOK SHOWED$'), 'retro heading')
''')

    def test_init_lua_publishes_the_style_the_desk_modules_read(self):
        init = (ROOT / 'templates/nvim/init.lua').read_text()
        self.assertIn('vim.g.desk_style = DeskStyle', init)

    def test_nothing_new_a_first_look_and_a_refusal_say_so(self):
        self.run_lua(r'''
local text = S.layout({ items = {}, first = false, since = 'yesterday' }, 'paper', '/r')
assert(text[1] == 'Since you last looked · yesterday' and text[4] == 'Nothing new since you looked.', vim.inspect(text))
text = S.layout({ items = {}, first = true }, 'paper', '/r')
assert(text[1] == 'Since you last looked · the last day' and text[4] == 'Nothing in the last day.', vim.inspect(text))
local _, actions = S.layout({ items = { { kind = 'job', at = 0, id = 'x', label = 'j', state = 'running' } } }, 'paper', '/r')
assert(actions[4] and actions[4].kind == 'log', vim.inspect(actions))
answer = '{"ok":false,"message":"no"}'
vim.system = function(argv, opts, done) vim.defer_fn(function() done({ code = 1, stdout = answer, stderr = '' }) end, 10); return {} end
local buf = S.open('/r')
assert(vim.wait(2000, function() return (lines(buf)[3] or ''):find('refused', 1, true) end, 10), vim.inspect(lines(buf)))
S.setup()
assert(vim.fn.exists(':WorkSince') == 2)
assert(vim.fn.maparg('<Space>Ch', 'n') ~= '' or vim.fn.maparg('\\Ch', 'n') ~= '', 'the key is mapped')
''')


if __name__ == '__main__':
    unittest.main()
