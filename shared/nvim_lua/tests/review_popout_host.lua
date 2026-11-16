-- The main editor of test_review_popout.lua (started by it: nvim --headless --clean --listen … -c "luafile …"): a review
-- of one commit of the sandbox's repository, with a live Claude session to request changes from (a name only: its
-- inbox is a folder of the sandbox). _G.review_test says what was asked here.
local dir = assert(os.getenv('REVIEW_TEST'), 'started by test_review_popout.lua')
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. '/host.pid')
vim.o.columns, vim.o.lines = 160, 48
local R = require('desk.review')
local C = require('desk.claude')
local P = require('desk.popout')
P.PING_MS = 300
_G.review_test = { asked_here = 0, heard = {} }
local T = _G.review_test
vim.notify = function(text) table.insert(T.heard, tostring(text)) end
-- What R asks once a review is finished, here: counted, so a question the pop-out asked is never asked again here.
T.ask_after_finish = R.ask_after_finish   -- the editor's own question, kept: the test reads its keys
R.ask_after_finish = function() T.asked_here = T.asked_here + 1; return 'stay' end
-- c's own questions here (claude.send): counted the same way.
vim.ui.select = function(_, _, done) T.asked_here = T.asked_here + 1; done(nil) end
C.live = { { id = 'sess1', name = 'A session', state = 'waiting', project = 'project' } }
P.setup()
local root = os.getenv('REVIEW_ROOT')
local sha, parent = os.getenv('REVIEW_SHA'), os.getenv('REVIEW_PARENT')
vim.cmd.edit(vim.fn.fnameescape(root .. '/one.lua'))
C.open_review({ kind = 'commit', sha = sha, parent = parent, short = sha:sub(1, 7), subject = 'change', label = 'test commit' }, root)
T.ready = R.current ~= nil
