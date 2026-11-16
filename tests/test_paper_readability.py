"""Exercise palette rendering and native editor readability without loading user init."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import tomllib
import unittest

import sealed_env

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'


@unittest.skipUnless(RENDER.is_file(), 'build desk-render-fast')
class PaperReadability(unittest.TestCase):
    @unittest.skipUnless(shutil.which('nvim') and (Path.home()/'.local/share/nvim/lazy/nui.nvim').is_dir(), 'Neovim/NUI not installed')
    def test_rename_callback_cancel_and_footnote_code_exclusion(self):
        with tempfile.TemporaryDirectory(prefix='foxml-correction-') as temp:
            base=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(base/'rendered')],check=True,capture_output=True)
            # Sealed (tests/sealed_env.py); HOME stays: the Lua loads nui.nvim and the parsers from ~/.local/share/nvim.
            env=sealed_env.environment(base,keep_home=True,PAPER_DETAILS_INIT=base/'rendered/init.lua')
            self.addCleanup(sealed_env.stop,env)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_correction_slips.lua')],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_CORRECTIONS_AND_FOOTNOTES_OK',result.stdout+result.stderr)

    @unittest.skipUnless(shutil.which('tmux') and shutil.which('nvim'), 'tmux/Neovim not installed')
    def test_single_editor_footer_preserves_split_lanes(self):
        with tempfile.TemporaryDirectory(prefix='foxml-footer-') as temp:
            base=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(base/'rendered')],check=True,capture_output=True)
            # Sealed (tests/sealed_env.py): its tmux server asks no user manager for a scope over her bus.
            env=sealed_env.environment(base,PAPER_READING_INIT=base/'rendered/init.lua',PAPER_FOOTER_SOCKET=base/'tmux.sock')
            self.addCleanup(sealed_env.stop,env)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_tmux_footer.lua')],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_TMUX_FOOTER_PASSED',result.stdout+result.stderr)

    @unittest.skipUnless(shutil.which('nvim'), 'Neovim not installed')
    def test_conform_spec_reads_before_the_plugin_loads(self):
        with tempfile.TemporaryDirectory(prefix='foxml-conform-spec-') as temp:
            base=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(base/'rendered')],check=True,capture_output=True)
            env=sealed_env.environment(base,PAPER_READING_INIT=base/'rendered/init.lua')   # tests/sealed_env.py
            self.addCleanup(sealed_env.stop,env)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_conform_spec.lua')],env=env,capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_CONFORM_SPEC_PASSED',result.stdout+result.stderr)

    @unittest.skipUnless(shutil.which('ruff') and (Path.home()/'.local/share/nvim/lazy/conform.nvim').is_dir(), 'Ruff/Conform not installed')
    def test_native_python_and_json_format_on_save(self):
        with tempfile.TemporaryDirectory(prefix='foxml-formatting-') as temp:
            base=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(base/'rendered')],check=True,capture_output=True)
            # Sealed (tests/sealed_env.py); HOME stays: the Lua loads conform.nvim and mason's JSON server from ~/.local/share/nvim.
            env=sealed_env.environment(base,keep_home=True,PAPER_READING_INIT=base/'rendered/init.lua',PAPER_FORMATTING_ROOT=base)
            self.addCleanup(sealed_env.stop,env)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_formatting.lua')],env=env,capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_FORMATTING_PASSED',result.stdout+result.stderr)

    @unittest.skipUnless(shutil.which('yazi'), 'Yazi is not installed')
    def test_yazi_accepts_the_rendered_theme(self):
        import fcntl
        import pty
        import select
        import struct
        import termios
        with tempfile.TemporaryDirectory(prefix='foxml-reading-yazi-') as temp:
            base=Path(temp);config=base/'config/yazi';config.mkdir(parents=True)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/yazi'),str(config)],check=True,capture_output=True)
            master,slave=pty.openpty()
            fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,100,0,0))
            def terminal():
                os.setsid()
                fcntl.ioctl(0,termios.TIOCSCTTY,0)
            # Sealed (tests/sealed_env.py): its runtime folder is the test's, not hers.
            env=sealed_env.environment(base,TERM='xterm-256color',XDG_CONFIG_HOME=base/'config')
            self.addCleanup(sealed_env.stop,env)
            child=subprocess.Popen(['yazi',str(base)],stdin=slave,stdout=slave,stderr=slave,env=env,preexec_fn=terminal)
            os.close(slave);output=bytearray()
            try:
                deadline=time.monotonic()+2
                while time.monotonic()<deadline:
                    if select.select([master],[],[],.1)[0]:
                        try:output.extend(os.read(master,65536))
                        except OSError:break
                self.assertIsNone(child.poll(),output.decode(errors='replace'))
                self.assertNotIn('Theme load failed',output.decode(errors='replace'))
                self.assertNotIn('Failed to parse config',output.decode(errors='replace'))
            finally:
                if child.poll() is None:child.terminate()
                try:child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    child.kill();child.wait(timeout=5)
                os.close(master)

    def test_all_palettes_render_and_preserve_other_tab_styles(self):
        with tempfile.TemporaryDirectory(prefix='foxml-reading-palettes-') as temp:
            for palette in sorted((ROOT/'themes').glob('*/palette.sh')):
                with self.subTest(theme=palette.parent.name):
                    out=Path(temp)/palette.parent.name
                    subprocess.run([str(RENDER),str(palette),str(ROOT/'templates'),str(out)],check=True,capture_output=True)
                    values=dict(re.findall(r'^([A-Z0-9_]+)=([^\n]*)',palette.read_text(),re.M))
                    theme=tomllib.loads((out/'yazi/theme.toml').read_text())
                    paper=palette.parent.name=='Paper'
                    self.assertEqual(theme['tabs']['active']['fg'],'#'+values['FG' if paper else 'BG'])
                    self.assertEqual(theme['tabs']['active']['bg'],'#'+values['SELECTION' if paper else 'PRIMARY'])
                    feature=subprocess.check_output(['git','config','--file',str(out/'git/delta.gitconfig'),'--get','delta.features'],text=True).strip()
                    style=subprocess.check_output(['git','config','--file',str(out/'git/delta.gitconfig'),'--get',f'delta.{feature}.file-style'],text=True).strip()
                    self.assertIn('#'+values['FG' if paper else 'PRIMARY'],style)
                    if paper:self.assertIn('#'+values['SELECTION'],style)
                    mako=(out/'mako/config').read_text()
                    self.assertTrue(mako.rstrip().endswith('[mode=do-not-disturb]\ninvisible=1'))
                    for category in ('saved','copied','ready'):
                        self.assertIn('category=foxml.'+category,mako)
                    for file in out.rglob('*'):
                        if file.is_file():self.assertFalse(re.search(r'\{\{[A-Z][A-Z0-9_]*\}\}',file.read_text()),str(file))
                    if shutil.which('luac'):
                        subprocess.run(['luac','-p',str(out/'nvim/init.lua')],check=True,capture_output=True)

    @unittest.skipUnless(shutil.which('nvim'), 'Neovim is not installed')
    def test_native_diagnostics_whitespace_and_popup_focus(self):
        with tempfile.TemporaryDirectory(prefix='foxml-reading-editor-') as temp:
            base=Path(temp)
            subprocess.run([str(RENDER),str(ROOT/'themes/Paper/palette.sh'),str(ROOT/'templates/nvim'),str(base/'rendered')],check=True,capture_output=True)
            # Sealed (tests/sealed_env.py); HOME stays: the Lua loads nui.nvim and the parsers from ~/.local/share/nvim.
            env=sealed_env.environment(base,keep_home=True,PAPER_READING_INIT=base/'rendered/init.lua')
            self.addCleanup(sealed_env.stop,env)
            result=subprocess.run(['nvim','--clean','--headless','-l',str(ROOT/'tests/paper_readability.lua')],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PAPER_READING_PASSED',result.stdout+result.stderr)


if __name__=='__main__':unittest.main()
