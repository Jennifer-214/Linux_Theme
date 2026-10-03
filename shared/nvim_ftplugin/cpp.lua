-- Fallback for C/C++ when nothing more specific applies: init.lua's per-file detection (.editorconfig >
-- the file's own indentation > the project's clang-format style) overrides it. 4 spaces matches the trader.
vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true
