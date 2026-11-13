-- nvim --headless --clean -l shared/nvim_lua/tests/test_claude.lua : foxml.claude's pure parts.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = here .. "../?.lua;" .. package.path
-- Neovim looks in the runtime path (the installed copy under ~/.config/nvim) before package.path: load the repo's.
table.insert(package.loaders, 2, function(name)
  local file = here .. "../" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then return loadfile(file) end
end)
local C = require("foxml.claude")
local passed, failed = 0, 0
local function eq(got, want, what)
  if vim.deep_equal(got, want) then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want)) end
end

local NOW = 1800000000
local files = {
  ["/rt/a.json"] = vim.json.encode({ project = "/code/paper" }),
  ["/rt/edits/a.json"] = vim.json.encode({ edits = { { path = "/code/paper/x.lua", at = (NOW - 180) * 1000 } },
                                          all = { { path = "/code/paper/x.lua", at = 1 }, { path = "/code/paper/y.lua", at = 2 } } }),
  ["/rt/b.json"] = vim.json.encode({ cwd = "/code/other" }),
}
local live = C.with_ledgers({
  { id = "a", name = "Ledger tidy", project = "paper", state = "waiting", busy = false, pane = "%4" },
  { id = "b", name = "docs", project = "other", state = "needs you", busy = false, pane = "" },
  { id = "../x", name = "bad" },
}, "/rt", function(p) return files[p] end)
eq(#live, 2, "a bad session id is dropped")
eq(live[1].root, "/code/paper", "the session's folder comes from its look file")

local fp = C.footprint("/code/paper/x.lua", NOW * 1000, live)
eq(C.footprint_text(fp, NOW * 1000), "✎ Ledger tidy · 3m", "a recent edit leaves a footprint")
eq(fp.pane, "%4", "the footprint knows the pane")
eq(C.footprint("/code/paper/x.lua", (NOW + 16 * 60) * 1000, live), nil, "after 15 minutes it fades")

eq(C.gate_text("/code/paper", live, "a 2026-11-07\n"), "gate open ✓", "the gate open for the session here")
eq(C.gate_text("/code/paper", live, "zzz 2026\n"), "plan first ✎", "the session here is not approved")
eq(C.gate_text("/code/paper", live, nil), "", "no gate file, nothing shown")
eq(C.gate_text("/code/nowhere", live, "a\n"), "", "no session in this repo, nothing shown")
eq(C.needs_text(live), "● docs", "who needs you")

eq(C.note(" look here ", "/code/paper/x.lua", 3, 5, "int x;"),
   { from = "nvim", text = "look here", file = "/code/paper/x.lua", lines = "3-5", code = "int x;" }, "a note with a selection")
eq(C.note("hi", nil, 7, 7, nil).lines, "7", "one line")

local log = "\30" .. table.concat({ "aaaa1111", "aaaa111", "pppp", tostring(NOW - 7200), "Caramel", "feat: drawer pages",
  "https://claude.ai/code/session_X", "Claude Opus <noreply@anthropic.com>" }, "\31") .. "\n\nREADME.md\nsrc/a.cpp\n"
  .. "\30" .. table.concat({ "bbbb2222", "bbbb222", "", tostring(NOW - 90000), "Caramel", "fix kitty padding", "", "" }, "\31") .. "\n\nkitty.conf\n"
local commits = C.parse_log(log)
eq(#commits, 2, "two commits")
eq(commits[1].files, { "README.md", "src/a.cpp" }, "files of a commit")
eq(commits[2].parent, nil, "a root commit has no parent")
local names = C.parse_names('{"url":"https://claude.ai/code/session_X","title":"Linux_Theme","at":1}\nbroken\n')
eq(C.commit_label(commits[1], names, "Caramel", NOW), "✿ aaaa111  Linux_Theme · 2h · feat: drawer pages  2 files", "a Claude commit, named")
eq(C.commit_label(commits[2], names, "Caramel", NOW), "● bbbb222  you · yesterday · fix kitty padding  1 file", "your commit")
eq(C.who({ claude = true, url = "https://unknown" }, names, "me"), "✿", "an unknown session is still Claude's")

eq(C.live_files(live[1], { ["/code/paper/y.lua"] = true }), { "/code/paper/y.lua" }, "only files still uncommitted")
eq(C.live_label(live[1], { "/a" }), "✎ Ledger tidy · waiting · 1 file, not committed", "a live row")

eq(C.blame_text({ sha = "aaaa", author = "Caramel", author_time = NOW - 120, summary = "feat: x" },
  { claude = true, url = "https://claude.ai/code/session_X" }, names, "Caramel", NOW), "  ✿ Linux_Theme · 2m · feat: x", "blame names the session")
eq(C.blame_text({ sha = "bbbb", author = "Caramel", author_time = NOW - 120, summary = "fix" }, { claude = false }, names, "Caramel", NOW),
  "  ● you · 2m · fix", "blame on your line")
eq(C.blame_text({ sha = "0000000", author = "Not Committed Yet" }, {}, names, "Caramel", NOW), "  ○ not committed yet", "uncommitted")
eq(C.blame_text({ sha = "aaaa", author = "Caramel", author_time = NOW - 120, summary = "feat: x" },
  { claude = true, url = "https://claude.ai/code/session_X" }, names, "Caramel", NOW, { title = "Plan: Queue refactor", step = "step 2" }),
  "  ✿ Linux_Theme · 2m · feat: x · ⌑ Queue refactor · step 2", "blame names the plan and the step the commit was made under")
eq(C.blame_text({ sha = "bbbb", author = "Caramel", author_time = NOW - 120, summary = "fix" }, { claude = false }, names, "Caramel", NOW, { title = "" }),
  "  ● you · 2m · fix", "no plan recorded: the line is as before")

-- A note lands where the mod reads it, whole, named as it expects.
local dir = vim.fn.tempname()
eq(C.write_note(dir, "abc", C.note("hello", nil, nil, nil, nil)), true, "the note is written")
local box = vim.fn.readdir(dir .. "/inbox/abc")
eq(#box == 1 and box[1]:match("^[%w_-]+%.json$") ~= nil, true, "one .json note, no temp file left")
eq(vim.json.decode(C.read(dir .. "/inbox/abc/" .. box[1])).text, "hello", "its text")
eq(vim.uv.fs_stat(dir .. "/inbox/abc").mode % 512, tonumber("700", 8), "the inbox is private")
eq(C.write_note(dir, "../x", C.note("hi")), false, "a bad session id writes nothing")
vim.fn.delete(dir, "rf")

-- Neo-tree's mark: one session, two sessions sharing a file, none.
local shared_live = {
  { id = "a", name = "Ledger tidy", ledger = { edits = { { path = "/code/paper/x.lua", at = (NOW - 60) * 1000 } } } },
  { id = "b", name = "docs", ledger = { edits = { { path = "/code/paper/x.lua", at = (NOW - 30) * 1000 }, { path = "/code/paper/y.lua", at = (NOW - 30) * 1000 } } } },
  { id = "c", name = "old", ledger = { edits = { { path = "/code/paper/z.lua", at = (NOW - 3600) * 1000 } } } },
}
eq(C.tree_mark("/code/paper/y.lua", NOW * 1000, shared_live), { text = "✎", hl = "FoxTreeClaude", who = "docs" }, "one session: a pencil")
eq(C.tree_mark("/code/paper/x.lua", NOW * 1000, shared_live), { text = "✎2", hl = "FoxTreeClaudeShared", who = "Ledger tidy, docs" },
   "two sessions on one file: the overlap shows")
eq(C.tree_mark("/code/paper/z.lua", NOW * 1000, shared_live), nil, "an edit older than the window: no mark")
eq(C.tree_signature(NOW * 1000, shared_live) == C.tree_signature(NOW * 1000, shared_live), true, "the signature is stable")



print(string.format("test_claude: %d passed%s", passed, failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
