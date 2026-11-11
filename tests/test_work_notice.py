"""Notification choices route through literal argv; no live desktop is contacted."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WorkNotice(unittest.TestCase):
    def test_action_worker_does_not_keep_agent_output_pipes_open(self):
        with tempfile.TemporaryDirectory(prefix='.work-notice-pipes-', dir=ROOT/'tests') as temp:
            base = Path(temp)
            gate = base/'waiting'
            gate.touch()
            fake = base/'notify-send'
            fake.write_text('#!'+sys.executable+'\nimport os,time\nfrom pathlib import Path\n'
                            'while Path(os.environ["NOTICE_GATE"]).exists(): time.sleep(.02)\n')
            fake.chmod(0o755)
            env = os.environ | {'PATH':str(base)+os.pathsep+os.environ['PATH'], 'NOTICE_GATE':str(gate)}
            try:
                subprocess.run(['bash',str(ROOT/'shared/bin/work-notice'),'agent','pi','Ready','A result',str(base),'%7','stop'],
                               env=env,check=True,capture_output=True,timeout=1)
            finally:
                gate.unlink(missing_ok=True)

    def test_expiring_actions_keep_paths_literal_and_dismiss_does_nothing(self):
        with tempfile.TemporaryDirectory(prefix='.work-notice-', dir=ROOT/'tests') as temp:
            base = Path(temp)
            calls = base/'calls'
            project = base/'project $(touch injected)'
            project.mkdir()
            fake = ('#!'+sys.executable+'\nimport os,sys,json\n'
                    'from pathlib import Path\n'
                    'with open(os.environ["NOTICE_CALLS"],"a") as f: f.write(json.dumps([Path(sys.argv[0]).name,*sys.argv[1:]])+"\\n")\n'
                    'if Path(sys.argv[0]).name=="notify-send": print(os.environ.get("NOTICE_CHOICE",""))\n')
            for name in ('notify-send', 'desk-drawer', 'desk-work', 'desktop-menu', 'setsid'):
                path = base/name
                path.write_text(fake)
                path.chmod(0o755)
            env = os.environ | {'PATH':str(base)+os.pathsep+os.environ['PATH'], 'NOTICE_CALLS':str(calls)}
            command = ['bash',str(ROOT/'shared/bin/work-notice'),'--send-agent','Claude',
                       'Claude finished','A change to review',str(project),'%7','stop']
            def invoke(choice):
                calls.write_text('')
                subprocess.run(command,env=env|{'NOTICE_CHOICE':choice},check=True,timeout=5)
                return [json.loads(line) for line in calls.read_text().splitlines()]
            rows = invoke('default')
            self.assertIn('--expire-time=4000', rows[0])
            self.assertIn('--category=foxml.work', rows[0])
            self.assertIn('--hint=string:x-dunst-stack-tag:foxml-agent-7', rows[0])
            self.assertEqual(rows[-1], ['desk-drawer','run','claude-jump','%7'])
            self.assertEqual(invoke('review')[-1], ['desk-work','open','--root',str(project),'--action','reviews'])
            self.assertEqual(len(invoke('')), 1)
            self.assertFalse((base/'injected').exists())
            command[-2] = '%7;touch injected'
            self.assertEqual(invoke('default')[-1], ['desktop-menu','--open','agents'])
            command[2] = 'agent'
            calls.write_text('')
            subprocess.run(command,env=env,check=True,timeout=5)
            rows = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(rows[0][:3], ['setsid','-f','bash'])

if __name__ == '__main__': unittest.main()
