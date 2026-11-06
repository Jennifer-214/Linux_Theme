"""Volume keys dispatch to Paper's slip or the notification fallback with fake services."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class VolumeSlip(unittest.TestCase):
    def exercise(self, paper, muted, available):
        with tempfile.TemporaryDirectory(prefix='.volume-slip-',dir=ROOT/'tests') as temp:
            root=Path(temp); bin=root/'bin';bin.mkdir(); log=root/'calls'
            config=root/'config/hypr/modules';config.mkdir(parents=True)
            (config/'border_colors.sh').write_text('C_LITTLE_DETAILS='+('fox-little-details-on' if paper else 'off')+'\n')
            for name in ['wpctl','quickshell','notify-send']:
                fake=bin/name
                fake.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['VOLUME_TEST_LOG'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='wpctl' and sys.argv[1]=='get-volume':print('Volume: 0.67'+(' [MUTED]' if os.environ['VOLUME_TEST_MUTED']=='1' else ''))
if name=='quickshell':sys.exit(int(os.environ['VOLUME_TEST_UNAVAILABLE']))
''');fake.chmod(0o755)
            env=os.environ|{'XDG_CONFIG_HOME':str(root/'config'),'PATH':str(bin)+':'+os.environ['PATH'],
                'VOLUME_TEST_LOG':str(log),'VOLUME_TEST_MUTED':str(int(muted)),'VOLUME_TEST_UNAVAILABLE':str(int(not available))}
            subprocess.run(['bash',str(ROOT/'shared/hyprland_scripts/osd.sh'),'volume','up'],env=env,check=True,capture_output=True)
            return [json.loads(line) for line in log.read_text().splitlines()]

    def test_paper_volume_and_mute_use_the_slip(self):
        for muted in [False,True]:
            calls=self.exercise(True,muted,True)
            self.assertIn(['quickshell','-c','foxml','ipc','call','volume','present','67',str(muted).lower()],calls)
            self.assertFalse(any(call[0]=='notify-send' for call in calls))

    def test_missing_service_and_other_themes_keep_notifications(self):
        for paper in [False,True]:
            calls=self.exercise(paper,False,False)
            self.assertTrue(any(call[0]=='notify-send' for call in calls))
            self.assertEqual(any(call[0]=='quickshell' for call in calls),paper)

if __name__=='__main__':unittest.main()
