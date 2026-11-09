"""Exercise the API runner with a fake Claude executable; never make paid calls."""
from decimal import Decimal
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('claude_api', str(ROOT/'shared/bin/fox-claude-api'))
spec = importlib.util.spec_from_loader(loader.name, loader)
api = importlib.util.module_from_spec(spec)
loader.exec_module(api)

# Stream-json lines as the Claude Code docs describe them: system/init, assistant tool_use blocks, then result.
FAKE = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
question=sys.stdin.read()
key=os.environ.get('ANTHROPIC_API_KEY','')
audit=Path(os.environ['TEST_API_AUDIT'])
with audit.open('a') as f:
    f.write(json.dumps({'args':sys.argv[1:],'cwd':os.getcwd(),'question':question,
      'key_present':bool(key),'other_auth':any(k in os.environ for k in ['ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','CLAUDE_CODE_USE_BEDROCK'])})+'\n')
mode=os.environ.get('TEST_API_MODE','ok')
model=sys.argv[sys.argv.index('--model')+1]
print(json.dumps({'type':'system','subtype':'init','model':model,'tools':['Read','Glob','Grep']}))
print('not json, ignored')
print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Looking.'},
      {'type':'tool_use','id':'t1','name':'Read','input':{'file_path':'a.cpp'}},
      {'type':'tool_use','id':'t2','name':'Grep','input':{'pattern':'unchanged'}}]}}))
value={'type':'result','subtype':'error_during_execution' if mode=='fail' else 'success','is_error':mode=='fail',
       'num_turns':3,'duration_ms':4200,
       'usage':{'input_tokens':1200,'output_tokens':300,'cache_read_input_tokens':800,'cache_creation_input_tokens':40},
       'modelUsage':{model:{'costUSD':0.12,'inputTokens':1200},'claude-haiku-5-5':{'costUSD':0.005}}}
if mode=='fail': value['errors']=['Review of a.cpp:1 stopped. '+key]
else: value['result']='Review of a.cpp:1. '+key
if mode!='unknown':value['total_cost_usd']='NaN' if mode=='invalid' else 0.125
print(json.dumps(value),flush=True)
sys.exit(1 if mode=='fail' else 0)
'''


class ClaudeApi(unittest.TestCase):
    def setUp(self):
        # /tmp is noexec on FoxML; the fake claude must live where it can run.
        self.temp = tempfile.TemporaryDirectory(prefix='.claude-api-', dir=ROOT/'tests')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        bins = self.folder/'bin'
        bins.mkdir()
        (bins/'claude').write_text(FAKE)
        (bins/'claude').chmod(0o755)
        shutil.copy2(ROOT/'shared/bin/fox-credits', bins/'fox-credits')
        self.audit = self.folder/'audit.jsonl'
        self.env = dict(os.environ, PATH=str(bins)+os.pathsep+os.environ['PATH'],
                        XDG_CONFIG_HOME=str(self.folder/'config'), XDG_STATE_HOME=str(self.folder/'state'),
                        XDG_RUNTIME_DIR=str(self.folder/'runtime'),
                        TEST_API_AUDIT=str(self.audit), ANTHROPIC_AUTH_TOKEN='wrong-login',
                        ANTHROPIC_BASE_URL='https://wrong.invalid', CLAUDE_CODE_USE_BEDROCK='1')
        self.patcher = patch.dict(os.environ, self.env)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.assertEqual(shutil.which('claude'),str(bins/'claude'),
                         'Sandbox cannot execute the fixture; never fall back to an installed Claude CLI')
        self.project = self.folder/"trader ' project"
        self.project.mkdir()
        self.source = self.project/'a.cpp'
        self.source.write_text('int unchanged;\n')
        self.key = self.folder/'inference.key'
        self.key.write_text('test-inference-secret')
        self.key.chmod(0o600)
        self.cfg = api.config()
        self.cfg['key_file'] = str(self.key)
        for entry in self.cfg['projects'].values():
            entry['root'] = str(self.project)
        api.atomic(api.locations()[0], self.cfg)
        api.atomic(self.folder/'config/foxml/api-credits.json', {
            'budget_usd':'200', 'renewal_day':1, 'timezone':'UTC',
            'projects':{key:{'label':label} for key,(label,_) in api.PROJECTS.items()}})

    def execute(self, **changes):
        args = dict(project='trader',question='Explain this file',limit='1.00',context_file=str(self.source))
        args.update(changes)
        return api.execute(self.cfg, **args)

    def credit_status(self):
        return json.loads(subprocess.check_output(['fox-credits','status'], text=True))

    def calls(self):
        return [json.loads(line) for line in self.audit.read_text().splitlines()] if self.audit.exists() else []

    def test_run_uses_private_key_read_only_tools_budget_model_and_no_other_login(self):
        value = self.execute()
        self.assertEqual(value['status'], 'completed')
        audit = self.calls()[0]
        self.assertEqual(audit['cwd'],str(self.project))
        self.assertTrue(audit['key_present'])
        self.assertFalse(audit['other_auth'])
        argv = audit['args']
        self.assertEqual(argv[argv.index('--tools')+1],'Read,Glob,Grep')
        self.assertEqual(argv[argv.index('--max-budget-usd')+1],'1.00')
        self.assertEqual(argv[argv.index('--model')+1],'claude-sonnet-5-5')
        self.assertEqual(argv[argv.index('--output-format')+1],'stream-json')
        for flag in ('--bare','--no-session-persistence','--strict-mcp-config','--verbose'):
            self.assertIn(flag,argv)
        self.assertNotIn('--effort',argv)
        self.assertNotIn('--dangerously-skip-permissions',argv)
        self.assertNotIn(self.key.read_text(),json.dumps(argv))
        self.assertIn('Focus file: a.cpp',audit['question'])
        self.assertEqual(self.source.read_text(),'int unchanged;\n')

    def test_secret_files_are_denied_by_rule_not_only_by_prompt(self):
        self.execute()
        argv = self.calls()[0]['args']
        deny = json.loads(argv[argv.index('--settings')+1])['permissions']['deny']
        for rule in ('Read(**/.env)','Read(**/.env.*)','Read(**/*.key)','Read(**/*.pem)','Read(~/.ssh/**)',
                     'Read(~/.config/foxml/secrets/**)'):
            self.assertIn(rule, deny)
            self.assertIn(rule, argv[argv.index('--disallowedTools')+1])
        self.assertTrue(all(rule.startswith('Read(') for rule in deny), 'Grep/Glob rules do not match; Read covers them')

    def test_model_effort_and_fallback_come_from_settings_or_the_run(self):
        self.cfg.update(effort='high', fallback_model='claude-haiku-5-5')
        self.execute(model='claude-opus-5-5')
        argv = self.calls()[0]['args']
        self.assertEqual(argv[argv.index('--model')+1],'claude-opus-5-5')
        self.assertEqual(argv[argv.index('--effort')+1],'high')
        self.assertEqual(argv[argv.index('--fallback-model')+1],'claude-haiku-5-5')
        for bad in ({'model':'gpt; rm -rf'},{'effort':'extreme'}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.execute(**bad)

    def test_progress_shows_each_tool_call_and_details_are_recorded(self):
        steps = []
        value = self.execute(project='plugins', progress=steps.append)
        self.assertEqual(steps, ['Reading a.cpp','Searching for unchanged'])
        self.assertEqual((value['model'],value['input_tokens'],value['output_tokens'],value['cache_read_tokens'],
                          value['turns'],value['duration_ms']),('claude-sonnet-5-5',1200,300,800,3,4200))
        self.assertTrue(value['tracked'])
        usage = json.loads(subprocess.check_output(['fox-credits','usage'], text=True))
        self.assertEqual(usage['models'][0]['model'],'claude-sonnet-5-5')
        self.assertEqual(usage['top'][0]['label'],'Explain this file')
        self.assertEqual(Decimal(usage['projects'][0]['spent_usd']),Decimal('0.125'))
        self.assertEqual(usage['projects'][0]['id'],'plugins')

    def test_cost_is_tracked_and_record_retry_is_idempotent(self):
        value = self.execute(project='plugins')
        status = self.credit_status()
        self.assertEqual(status['short'],'API ~$199.88 left')
        self.assertEqual(Decimal(status['spent_usd']),Decimal('0.125'))
        self.assertTrue(api.record_cost(value))
        self.assertEqual(Decimal(self.credit_status()['spent_usd']),Decimal('0.125'))
        self.assertEqual(len(self.calls()),1)

    def test_unknown_or_invalid_cost_never_records_zero(self):
        for mode in ('unknown','invalid'):
            with self.subTest(mode=mode),patch.dict(os.environ,TEST_API_MODE=mode):
                value = self.execute()
                self.assertIsNone(value['cost_usd'])
                self.assertFalse(value['tracked'])
                self.assertEqual(Decimal(self.credit_status()['spent_usd']),0)

    def test_failed_task_keeps_its_error_and_still_records_known_cost(self):
        with patch.dict(os.environ,TEST_API_MODE='fail'):
            value = self.execute()
        self.assertEqual(value['status'],'failed')
        self.assertIn('stopped',value['result'])
        self.assertIn('[redacted]',value['result'])
        self.assertTrue(value['tracked'])

    def test_follow_up_carries_the_earlier_question_and_answer(self):
        first = self.execute(question='Why is a.cpp tiny?')
        second = self.execute(question='And what would you add?', follow=first['id'])
        sent = self.calls()[1]['question']
        self.assertIn('Earlier question:\nWhy is a.cpp tiny?',sent)
        self.assertIn('Your earlier answer:\nReview of a.cpp:1.',sent)
        self.assertTrue(sent.rstrip().endswith('And what would you add?'))
        self.assertEqual(second['parent'],first['id'])
        self.assertEqual(second['title'],'Follow-up: And what would you add?')
        with self.assertRaises(ValueError):
            self.execute(question='x', follow='0'*32)

    def test_review_changes_sends_the_diff_and_new_files(self):
        git = lambda *a: subprocess.run(['git','-C',str(self.project),*a],check=True,capture_output=True)
        git('init','-q'); git('add','.')
        git('-c','user.name=t','-c','user.email=t@t','commit','-qm','start')
        with self.assertRaisesRegex(ValueError,'No uncommitted changes'):
            self.execute(question='', review=True, context_file=None)
        self.source.write_text('int changed;\n')
        (self.project/'new.cpp').write_text('int added;\n')
        value = self.execute(question='', review=True, context_file=None)
        sent = self.calls()[-1]['question']
        self.assertIn(api.REVIEW, sent)
        self.assertIn('+int changed;', sent)
        self.assertIn('new.cpp', sent)
        self.assertEqual(value['title'],'Review uncommitted changes')

    def test_saved_results_are_private_redacted_and_history_has_no_prompt_or_answer(self):
        value = self.execute(question='Explain '+self.key.read_text())
        path = api.run_path(value['id'])
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777,0o700)
        self.assertNotIn(self.key.read_text(),path.read_text())
        row = api.history()[0]
        self.assertNotIn('question',row)
        self.assertNotIn('result',row)
        self.assertEqual(row['model'],'claude-sonnet-5-5')
        self.assertIn('[redacted]',value['result'])

    def test_result_markdown_names_project_model_cost_and_folder(self):
        value = self.execute()
        text = api.markdown(value)
        self.assertTrue(text.startswith('# Explain this file\n'))
        self.assertIn('folder: '+str(self.project), text)
        self.assertIn('claude-sonnet-5-5 · $0.125 estimated', text)
        self.assertIn('Review of a.cpp:1.', text)

    def test_invalid_scope_budget_and_prompt_are_rejected_before_launch(self):
        for change in ({'root':str(self.folder)}, {'context_file':str(self.key)},
                       {'limit':'0'},{'limit':'NaN'},{'limit':'201'},{'question':''},{'question':'x'*64001}):
            with self.subTest(change=str(change)[:100]),self.assertRaises(ValueError):
                self.execute(**change)
        self.assertFalse(self.audit.exists())

    def test_private_file_permissions_and_admin_keys_are_checked_before_launch(self):
        self.key.chmod(0o644)
        with self.assertRaises(ValueError):
            self.execute()
        self.key.chmod(0o600)
        self.key.write_text('sk-ant-admin01-test')
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(self.audit.exists())

    def test_budget_above_remaining_credit_is_refused_before_launch(self):
        subprocess.check_call(['fox-credits','record','--project','trader','--cost-usd','199.50',
                               '--id','earlier-run','--at','2026-11-02T00:00:00Z'])
        self.assertEqual(Decimal(api.credits()['remaining_usd']),Decimal('0.50'))
        self.assertIn('~$0.50 left',api.project_rows(self.cfg)[0]['credits'])
        with self.assertRaisesRegex(ValueError,'more than the ~\\$0.50 left'):
            self.execute(limit='1.00')
        self.assertFalse(self.audit.exists())
        self.assertEqual(self.execute(limit='0.25')['status'],'completed')

    def test_unset_renewal_day_leaves_remaining_unknown_and_allows_the_run(self):
        api.atomic(self.folder/'config/foxml/api-credits.json', {'budget_usd':'200','renewal_day':None,'timezone':'UTC'})
        self.assertIsNone(api.credits()['remaining_usd'])
        self.assertIn('unknown',api.credits()['text'])
        self.assertEqual(self.execute()['status'],'completed')

    def test_older_settings_files_gain_new_projects_and_model_settings(self):
        old = {k:v for k,v in self.cfg.items() if k not in ('model','effort','fallback_model')}
        old['projects'] = {k:v for k,v in self.cfg['projects'].items() if k!='theme'}
        api.atomic(api.locations()[0], old)
        loaded = api.config()
        self.assertIn('theme', loaded['projects'])
        self.assertEqual(loaded['model'],'claude-sonnet-5-5')

    def test_question_file_in_the_runtime_folder_is_read_once(self):
        folder = self.folder/'runtime/foxml/api-questions'
        folder.mkdir(parents=True)
        question = folder/'failure.txt'
        question.write_text('FAILED test_x: expected 2, got 3')
        self.assertIn('expected 2',api.question_file(question))
        self.assertFalse(question.exists())
        kept = self.folder/'notes.txt'
        kept.write_text('keep me')
        self.assertEqual(api.question_file(kept),'keep me')
        self.assertTrue(kept.exists(), 'a file outside the runtime folder was deleted')

    def test_pi_launcher_passes_the_key_only_by_environment(self):
        fake = self.folder/'bin/pi'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$ANTHROPIC_API_KEY" "$FOXML_API_CREDITS" "$FOXML_API_PROJECT" '
                        '"${ANTHROPIC_AUTH_TOKEN:-none}" "$@" > "$TEST_API_AUDIT.pi"\n')
        fake.chmod(0o755)
        result = subprocess.run([str(ROOT/'shared/bin/fox-claude-api'),'pi','--project','theme','--model','claude-opus-5-5'],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = Path(str(self.audit)+'.pi').read_text().splitlines()
        self.assertEqual(lines[:5], [str(self.project),'test-inference-secret','1','theme','none'])
        self.assertEqual(lines[5:], ['--provider','anthropic','--model','claude-opus-5-5'])

    def test_listing_projects_and_history_does_not_launch_claude(self):
        rows = api.project_rows(self.cfg)
        self.assertEqual([p['id'] for p in rows],['trader','plugins','theme'])
        self.assertEqual(rows[0]['model'],'claude-sonnet-5-5')
        self.assertIn('claude-opus-5-5',rows[0]['models'])
        self.assertEqual(api.history(),[])
        for bad in ('../secrets','not-an-id'):
            with self.assertRaises(ValueError):
                api.run_path(bad)
        self.assertFalse(self.audit.exists())


if __name__ == '__main__':
    unittest.main()
