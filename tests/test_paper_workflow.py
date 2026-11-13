"""Exercise Paper workflow styles on an isolated unresolved Git fixture."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
RENDER=ROOT/'src/desk-render/desk-render-fast'
PLUGINS=Path.home()/'.local/share/nvim/lazy'


@unittest.skipUnless(RENDER.is_file() and shutil.which('nvim') and shutil.which('git'), 'renderer, Neovim and Git required')
class PaperWorkflow(unittest.TestCase):
    def test_existing_plugins_and_native_workflows(self):
        if not all((PLUGINS/name).is_dir() for name in ('nvim-dap','diffview.nvim','nvim-spectre','plenary.nvim')):
            self.skipTest('local workflow plugins not installed')
        with tempfile.TemporaryDirectory(prefix='paper-workflow-') as temp:
            work=Path(temp);project=work/'project';project.mkdir()
            env=os.environ|{'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1',
                            'PAPER_WORKFLOW_INIT':str(work/'rendered/init.lua'),
                            'PAPER_WORKFLOW_PROJECT':str(project),'XDG_STATE_HOME':str(work/'state'),
                            'XDG_CACHE_HOME':str(work/'cache'),'NVIM_LOG_FILE':str(work/'nvim.log')}
            def git(*args, data=None):
                return subprocess.run(['git',*args],cwd=project,env=env,input=data,text=True,check=True,capture_output=True).stdout.strip()
            git('init','-q')
            note=project/'note.py';note.write_text('bookmark = 1\n\nprint(bookmark)\n')
            git('add','note.py')
            git('-c','user.name=Paper Test','-c','user.email=paper@example.invalid','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','-qm','base')
            base=git('hash-object','-w','--stdin',data='bookmark = 1\n')
            ours=git('hash-object','-w','--stdin',data='bookmark = 2\n')
            theirs=git('hash-object','-w','--stdin',data='bookmark = 3\n')
            git('update-index','--index-info',data=f'0 {"0"*40}\tnote.py\n100644 {base} 1\tnote.py\n100644 {ours} 2\tnote.py\n100644 {theirs} 3\tnote.py\n')
            before=note.read_bytes();index_before=git('ls-files','-s')
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(work/'rendered')],check=True,capture_output=True)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_workflow.lua')],cwd=project,env=env,text=True,capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_WORKFLOW_OK',result.stdout+result.stderr)
            self.assertEqual(note.read_bytes(),before)
            self.assertEqual(git('ls-files','-s'),index_before)


if __name__=='__main__':unittest.main()
