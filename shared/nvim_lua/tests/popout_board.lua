-- A stand-in for symdeps' board in the pop-out, for test_popout.lua, loaded in the main editor only, as fox-symdeps is
-- (the pop-out never loads it): its surface declared with no module (actions.surface), its rows on it as symdeps' adapter
-- adds them (id 'symdeps.<row>', remote) and its view kind. Its keys: Enter (open), c (compare), n (asks for words), f
-- (the pop-out's own key there, so only in the menu), w (drawn: needs the module), z (the editor's only), h (fold), l
-- and <Left> (the second keys of open and fold: rows in no menu or key list, as fox-symdeps adds one row per key an
-- action has) and j (the editor's board moves on it; in the pop-out j is its own row move, so never bound there).
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
  { id = 'symdeps.open-l', group = 'symdeps', name = 'Open the card', key = 'l', on = 'symdeps', remote = true, menu = false,
    doc = false, about = 'The card of the selected row, in the editor', run = function(ctx) T.opened = ctx.item end },
  { id = 'symdeps.fold', group = 'symdeps', name = 'Fold the card', key = 'h', on = 'symdeps', remote = true,
    about = 'The selected row folded, in the editor', run = function(ctx) T.folded = ctx.item end },
  { id = 'symdeps.fold-left', group = 'symdeps', name = 'Fold the card', key = '<Left>', on = 'symdeps', remote = true,
    menu = false, doc = false, about = 'The selected row folded, in the editor', run = function(ctx) T.folded = ctx.item end },
  { id = 'symdeps.down', group = 'symdeps', name = 'The row below', key = 'j', on = 'symdeps', remote = true,
    about = "The editor's board moves on it", run = function() T.moved = true end },
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
  -- What fox-symdeps' ctx_for gives (its popout.lua M.ctx_for: { win, origin, sel }): no surface of its own; the
  -- pop-out's editor side puts the kind's on it (2026-11-17: with this stand-in naming it, its keys were tested where
  -- the real plugin's did nothing).
  ctx_for = function(_, ref) return { sel = ref } end,
  open = function(view) T.live = view end,
  attach = function(view) if T.live == view then T.attached = view.id end end,
  close = function(view) T.closed, T.live = view.id, nil end })
