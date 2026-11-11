"""Run the notification launcher against fake binaries and an isolated home."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class NotificationLauncher(unittest.TestCase):
    def test_custom_and_stock_launchers_use_xdg_config_and_preserve_arguments(self):
        with tempfile.TemporaryDirectory(prefix='notification-launcher-') as temp:
            home=Path(temp);bin_dir=home/'bin';bin_dir.mkdir()
            custom=home/'.local/bin/desk-mako';custom.parent.mkdir(parents=True)
            script='#!/bin/sh\nprintf "%s\\n" "'+str(home)+'/" "$FOXML_MAKO_BANNER_STATE" "$FOXML_MAKO_BAR_GEOMETRY" "$@"\n'
            custom.write_text(script);custom.chmod(0o755)
            stock=bin_dir/'mako';stock.write_text('#!/bin/sh\nprintf "stock\\n"; printf "%s\\n" "$@"\n');stock.chmod(0o755)
            if not os.access(custom,os.X_OK) or not os.access(stock,os.X_OK):
                self.skipTest('temporary filesystem is noexec; set TMPDIR to an executable filesystem')
            config=home/'custom-config/mako/config';config.parent.mkdir(parents=True);config.write_text('text-alignment=center\n')
            legacy=home/'.mako/config';legacy.parent.mkdir();legacy.write_text('old config must not win\n')
            env=os.environ|{'HOME':str(home),'XDG_CONFIG_HOME':str(home/'custom-config'),
                            'XDG_RUNTIME_DIR':str(home/'runtime'),'PATH':str(bin_dir)+':'+os.environ.get('PATH','')}
            command=['sh',str(ROOT/'shared/bin/desk-notifications')]
            result=subprocess.run(command+['--config','caller-config','--font','paper font'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            lines=result.stdout.splitlines()
            self.assertEqual(lines[1:3],[str(home/'runtime/foxml-mako-banner'),str(home/'runtime/foxml-bar-geometry')])
            self.assertEqual(lines[3:],['--config',str(config),'--config','caller-config','--font','paper font'])
            custom.unlink()
            result=subprocess.run(command+['--font','paper font'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.splitlines(),['stock','--config',str(config),'--font','paper font'])


if __name__=='__main__':unittest.main()
