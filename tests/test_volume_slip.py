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
    def exercise(self, paper, muted, available, kind='volume'):
        with tempfile.TemporaryDirectory(prefix='.volume-slip-',dir=ROOT/'tests') as temp:
            root=Path(temp); bin=root/'bin';bin.mkdir(); log=root/'calls'
            config=root/'config/hypr/modules';config.mkdir(parents=True)
            (config/'border_colors.sh').write_text('C_LITTLE_DETAILS='+('fox-little-details-on' if paper else 'off')+'\n')
            for name in ['wpctl','brightnessctl','quickshell','notify-send']:
                fake=bin/name
                fake.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['VOLUME_TEST_LOG'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='wpctl' and sys.argv[1]=='get-volume':print('Volume: 0.67'+(' [MUTED]' if os.environ['VOLUME_TEST_MUTED']=='1' else ''))
if name=='brightnessctl' and sys.argv[1]=='-m':print('intel_backlight,backlight,240,25%,960')
if name=='quickshell':sys.exit(int(os.environ['VOLUME_TEST_UNAVAILABLE']))
''');fake.chmod(0o755)
            env=os.environ|{'XDG_CONFIG_HOME':str(root/'config'),'PATH':str(bin)+':'+os.environ['PATH'],
                'VOLUME_TEST_LOG':str(log),'VOLUME_TEST_MUTED':str(int(muted)),'VOLUME_TEST_UNAVAILABLE':str(int(not available))}
            subprocess.run(['bash',str(ROOT/'shared/hyprland_scripts/osd.sh'),kind,'up'],env=env,check=True,capture_output=True)
            return [json.loads(line) for line in log.read_text().splitlines()]

    def test_paper_volume_and_mute_use_the_slip(self):
        for muted in [False,True]:
            calls=self.exercise(True,muted,True)
            self.assertIn(['quickshell','-c','desk','ipc','call','volume','present','67',str(muted).lower()],calls)
            self.assertFalse(any(call[0]=='notify-send' for call in calls))

    def test_missing_service_and_other_themes_keep_notifications(self):
        for paper in [False,True]:
            calls=self.exercise(paper,False,False)
            self.assertTrue(any(call[0]=='notify-send' for call in calls))
            self.assertEqual(any(call[0]=='quickshell' for call in calls),paper)

    def test_paper_brightness_uses_the_light_slip(self):
        calls=self.exercise(True,False,True,'brightness')
        self.assertIn(['quickshell','-c','desk','ipc','call','brightness','present','25'],calls)
        self.assertFalse(any(call[0]=='notify-send' for call in calls))
        for paper in [False,True]:
            calls=self.exercise(paper,False,False,'brightness')
            self.assertTrue(any(call[0]=='notify-send' for call in calls))
            self.assertEqual(any(call[0]=='quickshell' for call in calls),paper)

FAKE_MEDIA = '''import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['MEDIA_TEST_LOG'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='quickshell':sys.exit(int(os.environ['MEDIA_TEST_UNAVAILABLE']))
if name=='playerctl':
    if os.environ['MEDIA_TEST_PLAYER']!='1':sys.exit(1)
    path=Path(os.environ['MEDIA_TEST_STATE']);s=json.loads(path.read_text())
    if 'play-pause' in sys.argv:s['status']='Playing' if s['status']!='Playing' else 'Paused'
    if 'next' in sys.argv:s['title']='Gymnopedie No. 1';s['artist']='Satie';s['status']='Playing'
    path.write_text(json.dumps(s))
    if 'metadata' in sys.argv:print('\\x1f'.join([s['title'],s['artist'],s['status'],s['art']]))
'''

class MediaSlip(unittest.TestCase):
    """Media keys run playerctl, then present the song slip, or a notification without Paper's Quickshell."""
    def exercise(self, action, paper=True, available=True, player=True, title='Clair de lune'):
        with tempfile.TemporaryDirectory(prefix='.media-slip-',dir=ROOT/'tests') as temp:
            root=Path(temp); bin=root/'bin';bin.mkdir(); log=root/'calls'; state=root/'state.json'
            state.write_text(json.dumps({'title':title,'artist':'Debussy','status':'Paused','art':'file:///covers/moon.png'}))
            config=root/'config/hypr/modules';config.mkdir(parents=True)
            (config/'border_colors.sh').write_text('C_LITTLE_DETAILS='+('fox-little-details-on' if paper else 'off')+'\n')
            for name in ['playerctl','quickshell','notify-send']:
                fake=bin/name
                fake.write_text('#!'+sys.executable+'\n'+FAKE_MEDIA);fake.chmod(0o755)
            env=os.environ|{'XDG_CONFIG_HOME':str(root/'config'),'PATH':str(bin)+':'+os.environ['PATH'],'MEDIA_TEST_LOG':str(log),
                'MEDIA_TEST_STATE':str(state),'MEDIA_TEST_UNAVAILABLE':str(int(not available)),'MEDIA_TEST_PLAYER':str(int(player))}
            result=subprocess.run(['bash',str(ROOT/'shared/hyprland_scripts/media.sh'),action],env=env,capture_output=True,text=True)
            return result.returncode,[json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def present(self, *fields):
        return ['quickshell','-c','desk','ipc','call','media','present','--',*fields]

    def test_play_pause_presents_the_new_state(self):
        code,calls=self.exercise('play-pause')
        self.assertEqual(code,0)
        self.assertIn(['playerctl','--no-messages','play-pause'],calls)
        self.assertIn(self.present('Clair de lune','Debussy','Playing','file:///covers/moon.png'),calls)
        self.assertFalse(any(call[0]=='notify-send' for call in calls))

    def test_next_waits_for_the_new_track_and_a_dash_title_stays_an_argument(self):
        code,calls=self.exercise('next',title='-intro-')
        self.assertIn(self.present('Gymnopedie No. 1','Satie','Playing','file:///covers/moon.png'),calls)
        code,calls=self.exercise('previous',title='-intro-')
        self.assertIn(self.present('-intro-','Debussy','Paused','file:///covers/moon.png'),calls)

    def test_no_player_still_answers(self):
        code,calls=self.exercise('play-pause',player=False)
        self.assertIn(self.present('','','',''),calls)

    def test_other_themes_and_a_missing_service_notify(self):
        for paper in [False,True]:
            code,calls=self.exercise('play-pause',paper=paper,available=False)
            self.assertEqual(code,0)
            notes=[call for call in calls if call[0]=='notify-send']
            self.assertEqual(len(notes),1)
            self.assertEqual(notes[0][-3:],['--','Playing','Clair de lune · Debussy'])
            self.assertEqual(any(call[0]=='quickshell' for call in calls),paper)
        code,calls=self.exercise('play-pause',paper=False,player=False)
        self.assertEqual([call for call in calls if call[0]=='notify-send'][0][-2:],['Nothing is playing',''])

    def test_unknown_action_is_refused(self):
        code,calls=self.exercise('stop-everything')
        self.assertEqual(code,2)
        self.assertEqual(calls,[])

if __name__=='__main__':unittest.main()
