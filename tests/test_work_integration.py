"""One disposable request/edit/test/review workflow, projected through the real backend, editor, drawer and notebook."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import select
import subprocess
import tempfile
import time
import unittest
from fixture_process import start as start_fixture, stop as stop_fixture

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'src/desk-work/desk-work'
DRAWER = ROOT/'src/desk-drawer/desk-drawer'

class Workflow(unittest.TestCase):
    def test_shared_lifecycle_and_owned_watcher_recovery(self):
        self.need(shutil.which('nvim') and shutil.which('claude') and WORK.exists() and DRAWER.exists(),
                  'build the work/drawer backends and install Neovim and Claude Code')
        try:
            import msgpack
        except ImportError:
            self.need(False, 'install Python msgpack for the editor integration fixture')
        with tempfile.TemporaryDirectory(prefix='work-integration-') as folder:
            base = Path(folder); projects = base/'projects'; repo = projects/'sample'; repo.mkdir(parents=True)
            runtime = base/'runtime'; runtime.mkdir()
            env = os.environ | {'HOME':str(base/'home'), 'XDG_STATE_HOME':str(base/'state'), 'XDG_CONFIG_HOME':str(base/'config'),
                'XDG_RUNTIME_DIR':str(runtime), 'XDG_CACHE_HOME':str(base/'cache'), 'CLAUDE_CONFIG_DIR':str(base/'claude'),
                'NVIM_LOG_FILE':str(base/'nvim.log'), 'FOXML_WORK_NOTIFY':'0',
                'GIT_CONFIG_GLOBAL':'/dev/null', 'GIT_CONFIG_NOSYSTEM':'1', 'PATH':str(WORK.parent)+os.pathsep+os.environ['PATH']}
            def run(*args, input=None):
                result = subprocess.run(list(map(str,args)), input=input, cwd=repo, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout[-1500:] + result.stderr[-1500:])
                return result.stdout
            def work(*args): return json.loads(run(WORK, *args, '--root', repo))
            for args in [('init','-q'), ('config','user.name','Fixture'), ('config','user.email','fixture@example.invalid')]: run('git',*args)
            source = repo/'sample.cpp'; source.write_text('int value = 1;\n')
            run('git','add','.'); run('git','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','-qm','base')
            menu = json.loads((ROOT/'shared/quickshell/foxml/menus.json').read_text()); menu['project_roots']=[str(projects)]
            config = base/'menu.json'; config.write_text(json.dumps(menu))
            child = start_fixture(['nvim','--headless','--embed','--clean'], cwd=repo, env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            unpacker = msgpack.Unpacker(raw=False); serial = 0
            def lua(code):
                nonlocal serial
                serial += 1
                child.stdin.write(msgpack.packb([0,serial,'nvim_exec_lua',[code,[]]])); child.stdin.flush()
                deadline = time.monotonic() + 30
                while True:
                    for message in unpacker:
                        if message[0] == 1 and message[1] == serial:
                            self.assertIsNone(message[2], str(message[2])); return message[3]
                    self.assertLess(time.monotonic(), deadline, 'the fixture editor did not answer its RPC')
                    if not select.select([child.stdout], [], [], min(1, max(0, deadline - time.monotonic())))[0]: continue
                    data = os.read(child.stdout.fileno(),65536)
                    self.assertTrue(data,'the disposable editor ended unexpectedly'); unpacker.feed(data)
            snapshots=[]
            def snapshot(name):
                state=work('notebook','--session','reader')
                attention=work('attention')
                self.assertEqual(state['attention'],attention)
                for page in ['attention','reviews']:
                    view=json.loads(run(DRAWER,'--config',config,'view',page))
                    expected=[item for item in attention if page=='attention' or item['kind'] in ['commit','request','changed']]
                    ids=[json.loads(row['argument'])['id'] for row in view['items'] if row.get('id')=='work-attention']
                    self.assertEqual(ids,[item['id'] for item in expected])
                snapshots.append({'name':name,'state':state})
            try:
                lua("package.path="+json.dumps(str(ROOT/'shared/nvim_lua')+'/?.lua;')+"..package.path; vim.opt.autoread=true; vim.opt.hidden=true; require('foxml.sync').setup(); vim.cmd.edit('sample.cpp'); return true")
                work('review-request','--file','sample.cpp','--name','Pi fixture','--sid','pi-fixture','--text','Please adjust this')
                snapshot('request waiting')
                temporary=repo/'sample.cpp.new'; temporary.write_text('int value = 2;\n'); temporary.replace(source)
                work('agent-update','--agent','pi','--session','pi-fixture','--state','working','--pid',os.getpid(),'--file','sample.cpp')
                self.assertTrue(lua("return vim.wait(6000,function() return vim.api.nvim_buf_get_lines(0,0,1,false)[1]=='int value = 2;' end,20)"))
                snapshot('ready after observed edit')
                run(WORK,'run','--root',repo,'--','python3','-c',"print('1 passed')")
                snapshot('tests passed for this content')
                lua("local C=require('foxml.claude'); C.open_review({kind='live',sid='reader',name='fixture',short='fixture',files={"+json.dumps(str(source))+"}},"+json.dumps(str(repo))+"); local R=require('foxml.review'); R.refresh_requests(true); R.mark(); return true")
                lua("return vim.wait(3000,function() local r=vim.system({'desk-work','review-requests','--root',"+json.dumps(str(repo))+"},{text=true}):wait(); return #vim.json.decode(r.stdout)==0 end,20)")
                snapshot('review settled')
                self.assertEqual(snapshots[-1]['state']['requests'],[])
                self.assertEqual(snapshots[-1]['state']['attention'],[])
                self.assertTrue(lua("local events=require('foxml.work_events'); local state=events.roots["+json.dumps(str(repo))+"]; local pid=state.job.pid; state.job:kill(15); return vim.wait(6000,function() return state.job.pid~=pid and not state.watch_failed end,20)"))
                snapshot('after watcher recovery')
                self.assertEqual(snapshots[-1]['state']['attention'],[])
            finally:
                # This fixture owns this embedded editor and every child it started.
                stop_fixture(child)
            spec=importlib.util.spec_from_file_location('paper_fixture',ROOT/'tests/test_claude_mod.py')
            module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            case=module.PaperMod('test_the_code_holds_no_template_tokens')
            try:
                mod=case.stage('Paper')
                (mod/'tests/lifecycle.test.tsx').write_text('''import { test, expect } from 'claude-code/testing'
import { engine, opened, PANE } from './kit'
const snapshots = '''+json.dumps(snapshots)+'''
for (const snapshot of snapshots) test('shared lifecycle: '+snapshot.name, async ($, on) => {
  engine(on, { projectWork: snapshot.state })
  await opened($)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  for (const item of snapshot.state.attention) expect(await ui.find({ key: 'attention-'+item.id })).toBeDefined()
  await ui.press({ key: 'page-timeline' })
  for (const event of snapshot.state.timeline.slice(0,20)) expect(await ui.find({ key: 'event-'+event.id })).toBeDefined()
  await ui.unmount()
})
''')
                result=subprocess.run(['claude','plugin','test',str(mod)], cwd=mod.parent, env=env, capture_output=True,text=True,timeout=300)
                report='\n'.join(line for line in (result.stdout+result.stderr).splitlines() if not line.startswith('@@PREVIEW'))
                failed='\n'.join(report.splitlines()[max(0,next((i for i,line in enumerate(report.splitlines()) if '(fail)' in line),0)-12):])
                self.assertEqual(result.returncode,0,failed[:5000])
                self.assertIn(' 0 fail',report)
            finally: case.doCleanups()

    def need(self, condition, reason):
        if not condition:
            if os.environ.get('FOXML_REQUIRE_INTEGRATION_TESTS')=='1': self.fail(reason)
            self.skipTest(reason)

if __name__=='__main__': unittest.main()
