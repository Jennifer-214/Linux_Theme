local source=table.concat(vim.fn.readfile(vim.env.PAPER_READING_INIT),'\n')
local palette=assert(source:match('(local P = %b{})'))
local block=assert(source:match('%-%- >>> fox%-paper%-details\n(.-)\n%-%- <<< fox%-paper%-details'))
local Paper=assert(loadstring('local map=vim.keymap.set\n'..palette..'\n'..block..'\nreturn Paper'))()
local socket=vim.env.PAPER_FOOTER_SOCKET
local old_tmux,old_pane=vim.env.TMUX,vim.env.TMUX_PANE
local function tmux(args)
 local result=vim.system(vim.list_extend({'tmux','-S',socket},args),{text=true}):wait(3000)
 assert(result.code==0,result.stderr);return vim.trim(result.stdout)
end
local ok,err=pcall(function()
 local info=tmux({'-f','/dev/null','new-session','-d','-P','-F','#{pane_id} #{pid}','-s','footer','sleep','30'})
 local pane,pid=info:match('^(%%%d+) (%d+)$');assert(pane and pid,info)
 vim.env.TMUX=socket..','..pid..',0';vim.env.TMUX_PANE=pane
 tmux({'set-option','-gw','pane-border-status','bottom'})
 local function footer()return tmux({'show-options','-wAv','-t',pane,'pane-border-status'})end
 local state=Paper.setup_tmux_footer();assert(state)
 state.refresh();assert(footer()=='off','single editor pane still has two footers')
 local split=tmux({'split-window','-d','-P','-F','#{pane_id}','-t',pane,'sleep','30'})
 state.refresh();assert(footer()=='bottom','split lanes disappeared')
 tmux({'kill-pane','-t',split});state.refresh();assert(footer()=='off','footer returned after closing the split')
 state.restore();assert(footer()=='bottom','exit did not restore inherited footer')
 assert(tmux({'show-options','-wqv','-t',pane,'pane-border-status'})=='','inherited footer became a local override')
 tmux({'set-option','-w','-t',pane,'pane-border-status','top'})
 state.refresh();assert(footer()=='off')
 state.restore();assert(footer()=='top','explicit previous footer position lost')
 state.refresh();tmux({'set-option','-w','-t',pane,'pane-border-status','bottom'})
 state.restore();assert(footer()=='bottom','manual change during editing was overwritten')
end)
vim.env.TMUX, vim.env.TMUX_PANE=old_tmux,old_pane
vim.system({'tmux','-S',socket,'kill-server'}):wait(3000)
assert(ok,err)
print('PAPER_TMUX_FOOTER_PASSED: single editor, splits, exit, inheritance and manual overrides')
vim.cmd('qa!')
