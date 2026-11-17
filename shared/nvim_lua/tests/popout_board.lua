-- A stand-in for symdeps' board in the pop-out, for test_popout.lua, loaded in the main editor only, as fox-symdeps is
-- (the pop-out never loads it): its surface declared with no module (actions.surface), its rows on it as symdeps' adapter
-- adds them (id 'symdeps.<row>', remote) and its view kind. Its keys: Enter (open), c (compare), n (asks for words), f
-- (the pop-out's own key there, so only in the menu), w (drawn: needs the module) and z (the editor's only).
-- _G.board_test says what ran.
local A = require('desk.actions')
local P = require('desk.popout')
_G.board_test = _G.board_test or { names = { 'Order', 'Book', 'Fill' } }
local T = _G.board_test
assert(A.surface('symdeps', "symdeps' board in the pop-out", nil))

A.add({
  { id = 'symdeps.open', group = 'symdeps', name = 'Open the card', key = '<CR>', on = 'symdeps', remote = true,
    about = 'The card of the selected row, in the editor', run = function(ctx) T.opened = ctx.item end },
  { id = 'symdeps.compare', group = 'symdeps', name = 'Compare the card', key = 'c', on = 'symdeps', remote = true,
    about = 'The card beside the one before it', run = function(ctx) T.compared = ctx.item end },
  { id = 'symdeps.note', group = 'symdeps', name = 'Note on the card', key = 'n', on = 'symdeps', remote = true,
    about = 'Asks for words, then keeps them with the card', input = { prompt = 'Note: ' },
    run = function(ctx) T.noted = { ctx.item, ctx.text } end },
  { id = 'symdeps.unit', group = 'symdeps', name = 'Go to the unit', key = 'f', on = 'symdeps', remote = true,
    about = "The card's unit in the code", run = function(ctx) T.unit = ctx.item end },
  { id = 'symdeps.wide', group = 'symdeps', name = 'Wider sections', key = 'w', on = 'symdeps', drawn = true,
    about = 'Drawn where the board is', run = function() T.wide = true end },
  { id = 'symdeps.here', group = 'symdeps', name = "The editor's own", key = 'z', on = 'symdeps', remote = false,
    about = 'Never in the pop-out', run = function() T.here = true end },
})

local function render()
  local lines, items = { " symdeps' board", '' }, {}
  for _, name in ipairs(T.names) do
    lines[#lines + 1] = '   ' .. name
    items[#items + 1] = { key = 'card:' .. name, kind = 'row', line = #lines, name_col = 3, spans = { { #lines, 0, #lines[#lines] } },
      name = name, ref = name }
  end
  return { title = "symdeps' board", state = '', lines = lines, marks = {}, hl = {}, items = items,
    footer = { { ids = { 'symdeps.compare' }, words = 'compare' } } }
end

P.kind({ name = 'symdeps', title = "symdeps' board", menu = "Pop out symdeps' board", surface = 'symdeps',
  about = "symdeps' board, its cards at the pop-out's width", render = render,
  ctx_for = function() local ctx = A.context(); ctx.surface = 'symdeps'; return ctx end,
  attach = function(view) T.attached = view.id end,
  close = function(view) T.closed = view.id end })
