-- A second view kind for test_popout.lua, loaded in both of its Neovims: a list of rows under headings with the
-- description strip below it, the shape of the review's file list, built only from desk.popout's kind interface and
-- the action registry, as the review navigator is to be. Its keys: Enter (run in the editor), c (asks for words), x
-- (asks for a pick and words) and z (the editor's only, never in the pop-out). _G.rows_test says what ran.
local A = require('desk.actions')
local P = require('desk.popout')
A.SURFACES['test-rows'] = 'a list of rows (test_popout.lua)'
A.MODULES['test-rows'] = 'tests.popout_rows'
_G.rows_test = _G.rows_test or { names = { 'alpha', 'beta', 'gamma' } }
local T = _G.rows_test

A.add({
  { id = 'rowstest.open', group = 'Review', name = 'Open the row', key = '<CR>', on = 'test-rows', remote = true,
    about = 'Says which row it was asked for', run = function(ctx) T.opened = ctx.item end },
  { id = 'rowstest.say', group = 'Review', name = 'Say something about the row', key = 'c', on = 'test-rows', remote = true,
    about = 'Asks for words, then says them with the row', input = { prompt = 'About it: ' },
    run = function(ctx) T.said = { ctx.item, ctx.text } end },
  { id = 'rowstest.pick', group = 'Review', name = 'Pick for the row', key = 'x', on = 'test-rows', remote = true,
    about = 'Asks for a pick, then words',
    input = { prompt = 'Why: ', choices = function() return { { id = 'one', name = 'The first' }, { id = 'two', name = 'The second' } } end },
    run = function(ctx) T.picked = { ctx.item, ctx.choice, ctx.text } end },
  { id = 'rowstest.here', group = 'Review', name = "The editor's own", key = 'z', on = 'test-rows', remote = false,
    about = 'Never in the pop-out', run = function() T.here = true end },
})

-- The rows of T.names, the last under a heading of its own; the strip is the two lines inside the box at the end.
local function render(view, width)
  local lines, items = { ' Rows', '', ' ── first ──' }, {}
  local function row(name)
    lines[#lines + 1] = '   ○ ' .. name
    items[#items + 1] = { key = 'row:' .. name, kind = 'row', line = #lines, name_col = 3, x = 0, w = width,
      spans = { { #lines, 0, #lines[#lines] } }, name = name, ref = name, strip = { ' │ ' .. name, ' │ about ' .. name } }
  end
  for i = 1, #T.names - 1 do row(T.names[i]) end
  vim.list_extend(lines, { '', ' ── second ──' })
  row(T.names[#T.names])
  vim.list_extend(lines, { '', ' ╭──' })
  local strip = #lines + 1
  vim.list_extend(lines, { ' │', ' │', ' ╰──' })
  return { title = 'rows', state = view.pinned and 'PINNED' or 'following', lines = lines, marks = { { 3, 0, 4, 'DeskCallGraphHead' } },
    hl = { 'DeskCallGraphHead' }, items = items, strip = strip, footer = { { ids = { 'rowstest.open' }, words = 'open' } } }
end

P.kind({ name = 'rows', title = 'rows', surface = 'test-rows', about = 'A list of rows, for the test', render = render,
  open = function() T.opens = (T.opens or 0) + 1 end,
  ctx_for = function() local ctx = A.context(); ctx.surface = 'test-rows'; return ctx end,
  attach = function(view) T.attached = view.id end,
  close = function(view) T.closed = view.id end })
