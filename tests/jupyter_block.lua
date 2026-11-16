-- The desk-jupyter block of an init.lua (the template or a rendered one), loaded on its own with the parts it reads:
-- the drawing style, the border and the palette. No plugins: what it registers is what a fresh start registers.
-- Used by tests/test_nvim_keys.py and tests/test_nvim_jupyter.py: `local J = dofile("tests/jupyter_block.lua")(path)`.
return function(path)
  -- The unrendered template's colours are {{TOKENS}}; any colour will do for reading its keys.
  local source = table.concat(vim.fn.readfile(path), "\n"):gsub('"#{{[%w_]+}}"', '"#000000"')
  local parts = {
    assert(source:match('(local DeskStyle = "[^"]*")'), "no DeskStyle"),
    assert(source:match("%-%- >>> desk%-border\n(.-)\n%-%- <<< desk%-border"), "no desk-border block"),
    assert(source:match("(local P = %b{})"), "no palette"),
    assert(source:match("%-%- >>> desk%-jupyter\n(.-)\n%-%- <<< desk%-jupyter"), "no desk-jupyter block"),
    "return Jupyter",
  }
  return assert(loadstring(table.concat(parts, "\n"), "desk-jupyter"))()
end
