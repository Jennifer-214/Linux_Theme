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
value={'result':'Review of a.cpp:1. '+key,'is_error':mode=='fail'}
if mode!='unknown':value['total_cost_usd']='NaN' if mode=='invalid' else 0.125
print(json.dumps(value))
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
            'budget_usd':'200', 'renewal_day':1, 'timezone':'UTC', 'key_file':'',
            'projects':{key:{'label':label,'workspace_ids':[],'api_key_ids':[]} for key,(label,_) in api.PROJECTS.items()}})

    def execute(self, **changes):
        args = dict(project='trader',question='Explain this file',limit='1.00',context_file=str(self.source))
        args.update(changes)
        return api.execute(self.cfg, **args)

    def credit_status(self):
        return json.loads(subprocess.check_output(['fox-credits','status'], text=True))

    def test_run_uses_private_key_read_only_tools_budget_and_no_subscription_or_gateway(self):
        value = self.execute()
        self.assertEqual(value['status'], 'completed')
        audit = json.loads(self.audit.read_text())
        self.assertEqual(audit['cwd'],str(self.project))
        self.assertTrue(audit['key_present'])
        self.assertFalse(audit['other_auth'])
        argv = audit['args']
        self.assertEqual(argv[argv.index('--tools')+1],'Read,Glob,Grep')
        self.assertEqual(argv[argv.index('--max-budget-usd')+1],'1.00')
        for flag in ('--bare','--no-session-persistence','--strict-mcp-config'):
            self.assertIn(flag,argv)
        self.assertNotIn('--dangerously-skip-permissions',argv)
        self.assertNotIn(self.key.read_text(),json.dumps(argv))
        self.assertIn('Focus file: a.cpp',audit['question'])
        self.assertEqual(self.source.read_text(),'int unchanged;\n')

    def test_cost_is_estimated_attributed_and_record_retry_is_idempotent(self):
        value = self.execute(project='plugins')
        self.assertTrue(value['tracked'])
        status = self.credit_status()
        self.assertEqual(status['source'],'local')
        self.assertEqual(Decimal(status['spent_usd']),Decimal('0.125'))
        self.assertIn('CLI cost estimates',status['detail'])
        rows = {p['id']:p for p in status['projects']}
        self.assertEqual(Decimal(rows['plugins']['spent_usd']),Decimal('0.125'))
        self.assertEqual(Decimal(rows['trader']['spent_usd']),0)
        self.assertTrue(api.record_cost(value))
        self.assertEqual(Decimal(self.credit_status()['spent_usd']),Decimal('0.125'))
        self.assertEqual(len(self.audit.read_text().splitlines()),1)

    def test_unknown_or_invalid_cost_never_records_zero(self):
        for mode in ('unknown','invalid'):
            with self.subTest(mode=mode),patch.dict(os.environ,TEST_API_MODE=mode):
                value = self.execute()
                self.assertIsNone(value['cost_usd'])
                self.assertFalse(value['tracked'])
                self.assertIsNone(self.credit_status()['spent_usd'])

    def test_failed_task_still_records_known_cost(self):
        with patch.dict(os.environ,TEST_API_MODE='fail'):
            value = self.execute()
        self.assertEqual(value['status'],'failed')
        self.assertTrue(value['tracked'])
        self.assertEqual(Decimal(self.credit_status()['spent_usd']),Decimal('0.125'))

    def test_saved_results_are_private_redacted_and_history_has_no_prompt_or_answer(self):
        value = self.execute(question='Explain '+self.key.read_text())
        path = api.run_path(value['id'])
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777,0o700)
        self.assertNotIn(self.key.read_text(),path.read_text())
        self.assertNotIn('question',api.history()[0])
        self.assertNotIn('result',api.history()[0])
        self.assertIn('[redacted]',value['result'])

    def test_invalid_scope_budget_and_prompt_are_rejected_before_launch(self):
        for change in ({'root':str(self.folder)}, {'context_file':str(self.key)},
                       {'limit':'0'},{'limit':'NaN'},{'limit':'201'},{'question':''},{'question':'x'*32001}):
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

    def test_missing_meter_keeps_result_for_cost_record_retry(self):
        real = shutil.which('claude')
        with patch.object(api.shutil,'which',side_effect=lambda name:real if name=='claude' else None):
            value = self.execute()
        self.assertEqual(value['status'],'completed')
        self.assertFalse(value['tracked'])
        self.assertIsNone(self.credit_status()['spent_usd'])
        self.assertTrue(api.record_cost(value))
        self.assertEqual(Decimal(self.credit_status()['spent_usd']),Decimal('0.125'))

    def test_budget_above_remaining_credit_is_refused_before_launch(self):
        subprocess.check_call(['fox-credits','record','--project','trader','--cost-usd','199.50',
                               '--id','earlier-run','--at','2026-11-02T00:00:00Z'])
        self.assertEqual(Decimal(api.credits()['remaining_usd']),Decimal('0.50'))
        self.assertIn('$0.50 left',api.project_rows(self.cfg)[0]['credits'])
        with self.assertRaisesRegex(ValueError,'more than the \\$0.50 left'):
            self.execute(limit='1.00')
        self.assertFalse(self.audit.exists())
        self.assertEqual(self.execute(limit='0.25')['status'],'completed')

    def test_unknown_remaining_credit_allows_the_run_and_says_so(self):
        self.assertIsNone(api.credits()['remaining_usd'])
        self.assertIn('unknown',api.credits()['text'])
        self.assertEqual(self.execute()['status'],'completed')

    def test_older_settings_files_gain_the_linux_theme_project(self):
        old = dict(self.cfg, projects={k:v for k,v in self.cfg['projects'].items() if k!='theme'})
        api.atomic(api.locations()[0], old)
        self.assertIn('theme', api.config()['projects'])
        self.cfg['projects']['theme']['root'] = str(self.project)
        value = self.execute(project='theme')
        self.assertTrue(value['tracked'], 'fox-credits did not accept the new project in an older config')
        rows = {p['id']:p for p in self.credit_status()['projects']}
        self.assertEqual(Decimal(rows['theme']['spent_usd']),Decimal('0.125'))

    def test_question_file_in_the_runtime_folder_is_read_once(self):
        runtime = self.folder/'runtime'
        folder = runtime/'foxml/api-questions'
        folder.mkdir(parents=True)
        question = folder/'failure.txt'
        question.write_text('FAILED test_x: expected 2, got 3')
        with patch.dict(os.environ,XDG_RUNTIME_DIR=str(runtime)):
            self.assertIn('expected 2',api.question_file(question))
        self.assertFalse(question.exists())
        kept = self.folder/'notes.txt'
        kept.write_text('keep me')
        with patch.dict(os.environ,XDG_RUNTIME_DIR=str(runtime)):
            self.assertEqual(api.question_file(kept),'keep me')
        self.assertTrue(kept.exists(), 'a file outside the runtime folder was deleted')

    def test_listing_projects_and_history_does_not_launch_claude(self):
        self.assertEqual([p['id'] for p in api.project_rows(self.cfg)],['trader','plugins','theme'])
        self.assertEqual(api.history(),[])
        for bad in ('../secrets','not-an-id'):
            with self.assertRaises(ValueError):
                api.run_path(bad)
        self.assertFalse(self.audit.exists())


if __name__ == '__main__':
    unittest.main()
