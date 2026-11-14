"""Required work-integration checks, shared by CI and local validation. Missing tools fail."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from test_claude_mod import ROOT, sdk_fixture


def preflight():
    required = ('make','g++','git','nvim','claude','tsc','node','quickshell')
    missing = [tool for tool in required if not shutil.which(tool)]
    if importlib.util.find_spec('msgpack') is None: missing.append('Python msgpack')
    if missing: raise RuntimeError('Required work checks cannot run; missing: '+', '.join(missing))
    fixture, pins = sdk_fixture()
    def version(command):
        output = subprocess.run(command, capture_output=True,text=True,check=True,timeout=30)
        found = re.search(r'\d+\.\d+\.\d+',output.stdout+output.stderr)
        if not found: raise RuntimeError('Could not read the version of '+command[0])
        return found[0]
    if version(['claude','--version']) != pins['claude']:
        raise RuntimeError('Required checks use Claude '+pins['claude']+'; update the engine pin and generated SDK fixture together')
    if version(['tsc','--version']) != pins['typescript']:
        raise RuntimeError('Required checks use TypeScript '+pins['typescript'])
    if tuple(map(int,version(['nvim','--version']).split('.'))) < (0,10,0):
        raise RuntimeError('Required checks need Neovim 0.10 or newer')
    if int(version(['node','--version']).split('.')[0]) < 22:
        raise RuntimeError('Required Pi adapter checks need Node 22 or newer')
    return fixture, pins


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight',action='store_true')
    parser.add_argument('--output',type=Path)
    parser.add_argument('--claude', type=Path, default=os.environ.get('CLAUDE_TEST_BIN'), help='Use a pinned local Claude executable without changing the installed CLI')
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='foxml-work-tools-') as tools_folder:
        if args.claude:
            executable=Path(args.claude).expanduser().resolve(strict=True)
            (Path(tools_folder)/'claude').symlink_to(executable)
            os.environ['PATH']=tools_folder+os.pathsep+os.environ.get('PATH','')
        return run_checks(args)


def run_checks(args):
    try: fixture,pins=preflight()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error),file=sys.stderr); return 2
    print('Required work checks: Claude '+pins['claude']+' · TypeScript '+pins['typescript'],flush=True)
    if args.preflight: return 0
    output=args.output or Path(tempfile.mkdtemp(prefix='foxml-work-checks-'))
    output.mkdir(parents=True,exist_ok=True)
    env=os.environ|{'FOXML_REQUIRE_MOD_CHECKS':'1','FOXML_REQUIRE_INTEGRATION_TESTS':'1','CLAUDE_TYPES_DIR':str(fixture), 'FOXML_WORK_NOTIFY':'0',
        'DISABLE_AUTOUPDATER':'1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1',
        'PATH':os.pathsep.join(str(ROOT/'src'/tool) for tool in ('desk-work','desk-drawer','desk-install'))+os.pathsep+os.environ.get('PATH','')}
    commands=[]
    for tool in ('desk-render','desk-work','desk-drawer','theme-check','desk-install'):
        commands.append(('build-'+tool,['make','--no-print-directory','-C','src/'+tool,'-j2']))
    for tool in ('desk-work','desk-drawer','desk-install'):
        commands.append(('native-'+tool,['make','--no-print-directory','-C','src/'+tool,'test']))
    for test in ('test_fixture_process','test_claude_mod','test_work_integration','test_nvim_review','test_nvim_sync','test_nvim_workspace','test_work_nvim',
                 'test_drawer_qml','test_tucked_drawer_qml','test_fox_notify','test_installer_input','test_deploy_lists','test_work_ci'):
        commands.append((test,[sys.executable,'-B','tests/'+test+'.py']))
    for name,command in commands:
        with (output/(name+'.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
        print(('PASS ' if result.returncode==0 else 'FAIL ')+name,flush=True)
        if result.returncode:
            lines=[line for line in (output/(name+'.log')).read_text(errors='replace').splitlines() if '@@PREVIEW' not in line]
            print('\n'.join(line[:500] for line in lines[-24:])); print('Logs: '+str(output)); return result.returncode
    print(str(len(commands))+' required groups passed; logs: '+str(output)); return 0


if __name__=='__main__': sys.exit(main())
