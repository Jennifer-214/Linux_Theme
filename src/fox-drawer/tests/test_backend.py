#!/usr/bin/env python3
"""Exercise the JSON/argv boundary using only disposable, fake desktop services."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = Path(os.environ.get("FOX_DRAWER_BINARY", Path(__file__).resolve().parents[1] / "fox-drawer"))

FAKE_COMMAND = r'''
import base64
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['DRAWER_TEST_CALLS'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
state = json.loads(Path(os.environ['DRAWER_TEST_STATE']).read_text())
if name == 'setsid' and state.get('inspect_fds'):
    inherited = {}
    for descriptor in Path('/proc/self/fd').iterdir():
        try:
            inherited[descriptor.name] = os.readlink(descriptor)
        except OSError:
            pass
    Path(os.environ['DRAWER_TEST_FDS']).write_text(json.dumps(inherited))
key = '\x1f'.join([name, *args])
response = state.get('exact', {}).get(key, state.get('commands', {}).get(name))
if response is not None and response.get('hang'):
    import time
    time.sleep(30)
if response is not None:
    sys.stdout.buffer.write(base64.b64decode(response['base64']) if 'base64' in response else response.get('stdout', '').encode())
    sys.stderr.write(response.get('stderr', ''))
    sys.exit(response.get('exit', 0))
if name == 'quickshell' and 'pick' in args:
    request = Path(args[-1])
    payload = json.loads(request.read_text())
    import stat
    assert stat.S_IMODE(request.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(request.stat().st_mode) == 0o600
    assert stat.S_IMODE((request.parent/'response.json').stat().st_mode) == 0o600
    Path(os.environ['DRAWER_TEST_CLIPBOARD']).write_text(json.dumps(payload))
    (request.parent/'response.json').write_text(json.dumps(state.get('picker_reply', {'index': 1})))
if name == 'hyprctl' and args[:1] == ['hyprsunset']:
    if not state.get('nightlight_running'):
        print('cannot connect to hyprsunset socket'); sys.exit(1)
    if args[1:] == ['identity', 'get']:
        print('true' if state.get('nightlight_identity', True) else 'false')
    elif state.get('nightlight_reject'):
        print('invalid command')
    elif args[1:] == ['identity']:
        state['nightlight_identity'] = True
        Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state)); print('ok')
    elif args[1:] == ['temperature', '3500']:
        state['nightlight_identity'] = False
        state['nightlight_temperature'] = 3500
        Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state)); print('ok')
    else:
        print('invalid command'); sys.exit(1)
    sys.exit(0)
elif name == 'setsid' and args[1:] == ['hyprsunset', '--identity']:
    if not state.get('nightlight_start_fails'):
        state['nightlight_running'] = True; state['nightlight_identity'] = True
        Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state))
    sys.exit(0)
def save(): Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state))
if name == 'wpctl'  and args[:1] == ['get-volume']:
    print('Volume: 0.42' + (' [MUTED]' if state.get('muted', {}).get(args[1]) else ''))
elif name == 'wpctl' and args[:1] == ['set-mute'] and args[2:] == ['toggle']:
    state.setdefault('muted', {})[args[1]] = not state.get('muted', {}).get(args[1]); save()
elif name == 'brightnessctl':
    if '-m' in args or '--machine-readable' in args:
        print('intel_backlight,backlight,42,42%,100')
    elif 'get' in args or '-g' in args:
        print('42')
    elif 'max' in args or '-m' in args:
        print('100')
elif name == 'hyprctl' and 'clients' in args:
    print(json.dumps(state.get('windows', [{'address':'0xabc123', 'title':'A safe window', 'class':'kitty', 'workspace':{'id':1}}])))
elif name == 'tmux':
    if state.get('agent_append') and args[:1] == ['has-session']:
        queue = Path(os.environ['XDG_RUNTIME_DIR'])/'foxml-agent-queue.jsonl'
        with queue.open('a') as stream: stream.write(json.dumps(state.pop('agent_append'))+'\n')
        Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state))
    if args[:1] == ['list-clients']:
        print(state.get('tmux_clients', '123\t/dev/pts/fixture\t99999999\tpaper'))
    elif args[:1] == ['list-panes']:
        print(state.get('panes', ''))
    elif args[:1] == ['display-message']:
        pane = args[args.index('-t') + 1] if '-t' in args else ''
        print(state.get('pane_targets', {}).get(pane, '99999999'))
elif name == 'pactl' and 'sinks' in args:
    print(json.dumps([{'index':1, 'name':'desk.output', 'description':'Desk speakers', 'state':'RUNNING', 'mute':False}]))
elif name == 'pactl' and 'get-default-sink' in args:
    print('desk.output')
elif name == 'nmcli' and args[:2] == ['radio', 'wifi']:
    if args[2:] in (['on'], ['off']): state['radio'] = args[2] == 'on'; save()
    else: print('enabled' if state.get('radio', True) else 'disabled')
elif name == 'nmcli':
    if 'wifi' in args and 'list' in args:
        print(state.get('wifi', '*:Friendly Network:85:WPA2'))
    elif 'connection' in args and 'show' in args:
        print(state.get('connections', 'Friendly Network:01234567-1234-1234-1234-0123456789ab:802-11-wireless'))
elif name == 'bluetoothctl':
    if 'devices' in args or 'paired-devices' in args:
        print('Device AA:BB:CC:DD:EE:FF Desk headphones')
    elif 'info' in args:
        print('Device AA:BB:CC:DD:EE:FF\n\tName: Desk headphones\n\tPaired: yes\n\tConnected: no')
    elif 'show' in args:
        print('Controller 00:11:22:33:44:55\n\tPowered: ' + ('yes' if state.get('bt_power', True) else 'no'))
    elif args[:1] == ['power']:
        state['bt_power'] = args[1:] == ['on']; save()
elif name == 'cliphist':
    if args[:1] == ['list']:
        print(state.get('clipboard', '17\ta little note\n18\t[[ binary data 8 B png 1x1 ]]'))
    elif args[:1] == ['decode']:
        sys.stdout.buffer.write(base64.b64decode(state.get('clipboard_data', 'bm90ZQo=')))
elif name == 'wl-copy':
    Path(os.environ['DRAWER_TEST_CLIPBOARD']).write_bytes(sys.stdin.buffer.read())
elif name == 'powerprofilesctl' and args[:1] == ['get']:
    print('balanced')
elif name == 'makoctl' and args[:1] == ['mode']:
    if args[1:] == ['-t', 'do-not-disturb']: state['dnd'] = not state.get('dnd'); save()
    else: print('default\ndo-not-disturb' if state.get('dnd') else 'default')
elif name == 'makoctl' and args[:1] in (['history'], ['list']):
    print(json.dumps(state.get('mako_' + args[0], [])))
elif name == 'dunstctl' and args[:1] == ['is-paused']:
    print('false')
elif name == 'pgrep':
    sys.exit(0 if (args[-1:] == ['hyprsunset'] and state.get('nightlight_running'))
             or (args[-1:] == ['hypridle'] and state.get('hypridle_running')) else 1)
elif name == 'lsblk':
    print(json.dumps(state.get('drives', {'blockdevices': []})))
elif name == 'xdg-user-dir':
    print(state.get('download_dir', str(Path.home() / 'Downloads')))
elif name == 'udisksctl' and args[:1] == ['mount'] and state.get('after_mount'):
    state['drives'] = state['after_mount']
    Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state))
'''


REPO = Path(__file__).resolve().parents[3]


def item_icons(source):
    """Every string literal in the icon (fifth) argument of each item(...) call in the backend."""
    import re
    found = set()
    for m in re.finditer(r'(?<![A-Za-z0-9_])item\(', source):
        i, depth, quote, args, cur = m.end(), 1, None, [], ''
        while i < len(source) and depth:
            c = source[i]
            if quote:
                cur += c
                if c == '\\':
                    cur += source[i + 1]; i += 1
                elif c == quote:
                    quote = None
            elif c in '"\'':
                quote = c; cur += c
            elif c in '({[':
                depth += 1; cur += c
            elif c in ')}]':
                depth -= 1
                if depth:
                    cur += c
            elif c == ',' and depth == 1:
                args.append(cur.strip()); cur = ''
            else:
                cur += c
            i += 1
        args.append(cur.strip())
        if len(args) >= 5:
            icon = args[4]
            while re.search(r'[A-Za-z_]\w*\([^()]*\)', icon):  # a lookup like text(row, "icon") names no icon
                icon = re.sub(r'[A-Za-z_]\w*\([^()]*\)', '', icon)
            found.update(re.findall(r'"([^"]*)"', icon))
    return found


def js_object_keys(source, name):
    """The keys of `var NAME = { ... };` in DrawerLogic.js."""
    import re
    start = source.index("var " + name + " = {")
    body = source[start:source.index("};", start)]
    return set(re.findall(r'(?:^|[{,\s])"?([a-z][a-z-]*)"?\s*:', body))


class BackendTests(unittest.TestCase):
    def setUp(self):
        # /tmp is intentionally noexec on FoxML; fake executables belong beside the test.
        self.temp = tempfile.TemporaryDirectory(prefix=".fox-drawer-tests-", dir=Path(__file__).parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home.mkdir()
        self.config = self.root / "menus.json"
        self.calls_path = self.root / "calls.jsonl"
        self.state_path = self.root / "state.json"
        self.clipboard_path = self.root / "clipboard.bin"
        self.fds_path = self.root / "descriptors.json"
        self.state = {}
        self.state_path.write_text("{}")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "PATH": str(self.bin),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_DATA_DIRS": str(self.root / "system-data"),
            "XDG_RUNTIME_DIR": str(self.root / "runtime"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "DRAWER_TEST_CALLS": str(self.calls_path),
            "DRAWER_TEST_STATE": str(self.state_path),
            "DRAWER_TEST_CLIPBOARD": str(self.clipboard_path),
            "DRAWER_TEST_FDS": str(self.fds_path),
        })
        Path(self.env["XDG_RUNTIME_DIR"]).mkdir()
        for name in (
            "wpctl", "brightnessctl", "hyprctl", "pactl", "nmcli", "bluetoothctl", "cliphist", "wl-copy",
            "gio", "setsid", "kitty", "sudo", "bash", "systemctl", "loginctl", "pkill", "pgrep", "hyprsunset", "makoctl",
            "dunstctl", "powerprofilesctl", "playerctl", "hyprpicker", "awww", "notify-send", "tmux", "fox-hl", "pass", "fox-password-copy", "quickshell", "fox-desktop-menu",
            "checkupdates", "informant", "fox-wallpaper", "fox-lock", "fox-clean", "fox", "hypridle", "lsblk", "udisksctl", "xdg-open", "xdg-user-dir", "fox-work",
        ):
            fake = self.bin / name
            fake.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
            fake.chmod(0o755)
        self.write_config()

    def write_config(self, groups=None):
        if groups is None:
            groups = [{"id": "sound", "label": "Sound", "icon": "music", "description": "Make it cozy", "items": [
                {"id": "volume", "label": "Volume", "kind": "slider"},
                {"id": "volume-mute", "label": "Mute speakers", "kind": "toggle"},
                {"id": "audio-page", "label": "Audio outputs", "kind": "page", "page": "audio-outputs"},
            ]}]
        self.config.write_text(json.dumps({"groups": groups}))

    def invoke(self, *args, expect=0):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run([str(BINARY), "--config", str(self.config), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expect, result.stderr + result.stdout)
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"stdout must contain exactly one JSON document: {result.stdout!r}; stderr={result.stderr!r}")
        self.assertIsInstance(data, dict)
        return data

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def away(self, *args):
        self.state_path.write_text(json.dumps(self.state))
        return subprocess.run([str(BINARY), "--config", str(self.config), *args], env=self.env, capture_output=True, text=True, timeout=10)

    def test_while_you_were_away_says_what_happened_once_and_stays_quiet_for_a_short_break(self):
        now = int(time.time())
        jobs = [dict(id='a'*32, command='make -j8', title='Build the engine', state='passed', ended=now - 30, root='/x'),
                dict(id='b'*32, command='make test', state='failed', ended=now - 9000, root='/x')]
        self.state = {'commands': {'fox-work': {'stdout': json.dumps(jobs)}}}
        self.assertEqual(self.away('away-start').returncode, 0)
        stamp = Path(self.env['XDG_RUNTIME_DIR']) / 'foxml/away.json'
        self.assertEqual(stamp.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.away('away-summary').returncode, 0)
        self.assertFalse([c for c in self.calls() if c[0] == 'notify-send'], 'a short break needs no note')
        self.assertFalse(stamp.exists(), 'the stamp is used once')
        stamp.write_text(json.dumps({'at': now - 600, 'busy': []}))
        self.away('away-summary')
        notes = [c for c in self.calls() if c[0] == 'notify-send']
        self.assertEqual(len(notes), 1)
        self.assertIn('while you were away', notes[0])
        self.assertEqual(notes[0][-1], 'Build the engine passed', 'only what happened while away, by its title')
        self.away('away-summary')
        self.assertEqual(len([c for c in self.calls() if c[0] == 'notify-send']), 1, 'no stamp, no second note')

    def test_last_nights_notes_lead_today_and_open_by_name_only(self):
        notes = Path(self.env['XDG_STATE_HOME']) / 'foxml/goodnight'
        notes.mkdir(parents=True)
        (notes / 'Linux_Theme.md').write_text('# where we left off\nnext: finish the lock slip\n- did the drawer\n')
        (notes / 'old.md').write_text('next: ancient\n')
        os.utime(notes / 'old.md', (time.time() - 40 * 3600, time.time() - 40 * 3600))
        today = self.invoke('view', 'root').get('today', {})
        self.assertEqual(today.get('lastNight'), [{'name': 'Linux_Theme', 'next': 'finish the lock slip', 'hasNext': True}])
        (self.bin / 'nvim').write_text(f"#!{sys.executable}\n" + FAKE_COMMAND); (self.bin / 'nvim').chmod(0o755)
        self.assertTrue(self.invoke('run', 'goodnight-open', 'Linux_Theme')['ok'])
        self.assertIn(str(notes / 'Linux_Theme.md'), [c for c in self.calls() if c[0] == 'setsid'][-1])
        self.failed('run', 'goodnight-open', '../secrets')

    def test_jobs_results_review_tray_and_next_steps_share_work_records(self):
        job = dict(id='a'*32, command='make test', root='/code/paper', state='failed', elapsed=63,
                   activity=int(time.time()), exit=1, pane='%4', testRun=True, stale=True,
                   tests=dict(passed=128, failed=2, failures=[]))
        overview = dict(jobs=[job], running=0, finished=1, failed=1, reviews=[], tasks=[dict(id='b'*32, root='/code/paper', text='rerun the sanitizer')])
        self.state={'commands':{'fox-work':{'stdout':json.dumps(overview)}}}
        rows=self.invoke('view','jobs')['items']
        self.assertEqual([r['id'] for r in rows],['work-open','work-jump','work-compare','work-ask'])
        self.assertIn('128 passed',rows[0]['detail'])
        self.assertIn('exit 1',rows[0]['detail'])
        results=self.invoke('view','test-results')['items']
        self.assertEqual(results[0]['id'],'work-tests')
        self.assertIn('stale',results[0]['detail'])
        today=self.invoke('view','root')['today']
        self.assertEqual((today['jobsFinished'],today['jobsFailed'],today['nextStep']),(1,1,'rerun the sanitizer'))
        steps=self.invoke('view','next-steps')['items']
        self.assertEqual([r['id'] for r in steps],['work-task-draft','work-task-toggle'])
        self.assertFalse(steps[1]['close'])
        self.invoke('run','work-ask','a'*32)
        self.assertEqual(self.calls()[-1],['setsid','-f','fox-work','open','--action','ask','--id','a'*32])
        self.invoke('run','work-open','../../bad',expect=1)
        self.assertNotIn(['setsid','-f','fox-work','open','--action','log','--id','../../bad'],self.calls())

    def test_failed_user_services_offer_logs_and_a_draft_without_restarting(self):
        self.state={'commands':{'fox-work':{'stdout':json.dumps(dict(jobs=[],reviews=[],tasks=[]))},
                                'systemctl':{'stdout':'example.service loaded failed failed Example\n'}}}
        rows=self.invoke('view','failures')['items']
        self.assertEqual([r['id'] for r in rows],['service-log','service-ask'])
        self.invoke('run','service-ask','example.service')
        self.assertEqual(self.calls()[-1],['setsid','-f','fox-work','open','--action','ask-service','--id','example.service'])
        self.assertFalse(any(c[0]=='systemctl' and 'restart' in c for c in self.calls()))

    def test_media_artwork_metadata_and_playback_keep_the_same_action(self):
        self.write_config([dict(id='sound', label='Sound', items=[
            dict(id='media-play-pause', label='Play / pause', kind='action', detail='Your current music or media'),
            dict(id='media-next', label='Next track', kind='action')])])
        title='Quiet "hours"; $(literal)'
        self.state={'commands':{'playerctl':{'stdout':'\x1f'.join([title,'Pencil ensemble','Playing','file:///tmp/quiet%20hours.png'])+'\n'}}}
        rows=self.invoke('view','sound')['items']
        self.assertEqual(rows[0]['label'],title)
        self.assertEqual(rows[0]['detail'],'Pencil ensemble · Playing')
        self.assertEqual(rows[0]['artwork'],'file:///tmp/quiet%20hours.png')
        self.assertEqual(rows[0]['presentation'],'media')
        self.assertEqual(rows[0]['id'],'media-play-pause')
        self.assertNotIn('artwork',rows[1])
        self.assertEqual(len([c for c in self.calls() if c[0]=='playerctl']),1)
        self.assertTrue(self.invoke('run','media-play-pause')['ok'])
        self.assertEqual(self.calls()[-1],['playerctl','play-pause'])
        for value in ['https://example.test/cover.jpg','http://example.test/cover.jpg','data:image/png,invalid','javascript:invalid','']:
            with self.subTest(artwork=value):
                self.state['commands']['playerctl']['stdout']='\x1f'.join(['A track','','Paused',value])+'\n'
                row=self.invoke('view','sound')['items'][0]
                self.assertEqual(row['detail'],'Paused')
                self.assertEqual('artwork' in row,value.startswith(('https://','http://')))
        for response in [{'exit':1},{'stdout':'broken metadata'},{'stdout':'title\x1fartist\x1funknown\x1fimage'},{'stdout':'extra\x1ftitle\x1fartist\x1fPlaying\x1fimage'}]:
            self.state['commands']['playerctl']=response
            row=self.invoke('view','sound')['items'][0]
            self.assertEqual(row['label'],'Play / pause')
            self.assertTrue(row['enabled'])
            self.assertNotIn('artwork',row)

    def failed(self, *args):
        data = self.invoke(*args, expect=1)
        if args[0] == "run":
            self.assertFalse(data["ok"])
            self.assertTrue(data.get("message"))
        else:
            self.assertTrue(data.get("error"))
        return data

    def test_picker_literal_selection_index_prompt_and_cancellation(self):
        for flags, reply, expected in [([], {"index": 1}, "$(literal); two\n"),
                                        (["--index"], {"index": 1}, "1\n"),
                                        (["--prompt"], {"text": "hjkl $literal"}, "hjkl $literal\n"),
                                        ([], {"cancel": True}, ""),
                                        ([], {"index": 200}, "")]:
            with self.subTest(flags=flags, reply=reply):
                self.state_path.write_text(json.dumps({"picker_reply": reply}))
                result = subprocess.run([str(BINARY), "pick", "--title", "Literal title", *flags],
                                        input="first\n$(literal); two\n", text=True, capture_output=True, env=self.env, timeout=5)
                self.assertEqual(result.returncode, 0 if expected else (1 if reply.get("cancel") else 2), result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(list(Path(self.env["XDG_RUNTIME_DIR"]).glob("foxml-picker-*")), [])
                payload = json.loads(self.clipboard_path.read_text())
                self.assertEqual(payload["items"], [] if "--prompt" in flags else ["first", "$(literal); two"])

    def test_password_listing_reads_names_only_and_copy_uses_pass(self):
        store = self.home / ".password-store"
        (store / "work").mkdir(parents=True)
        name = "work/a literal $(entry)"
        (store / (name + ".gpg")).write_text("ciphertext must never appear in JSON")
        (store / "alias.gpg").symlink_to(store / (name + ".gpg"))
        (store / ".hidden.gpg").write_text("hidden")
        self.assertEqual(self.invoke("run", "vault")["page"], "passwords")
        page = self.invoke("view", "passwords")
        self.assertEqual([row["label"] for row in page["items"]], [name])
        self.assertNotIn("ciphertext", json.dumps(page))
        self.assertFalse(any(call[0] == "pass" for call in self.calls()))
        self.assertTrue(self.invoke("run", "password-copy", name)["close"])
        self.assertIn(["fox-password-copy", name], self.calls())
        before = len(self.calls())
        self.failed("run", "password-copy", "../elsewhere")
        self.assertEqual(len(self.calls()), before)

    def test_nightlight_reads_filter_state_instead_of_daemon_presence(self):
        self.write_config([{"id":"comfort","label":"Comfort","items":[{"id":"nightlight","label":"Night light","kind":"toggle"}]}])
        self.state.update(nightlight_running=True, nightlight_identity=True)
        self.assertFalse(self.invoke("view","comfort")["items"][0]["checked"])
        self.state["nightlight_identity"]=False
        self.assertTrue(self.invoke("view","comfort")["items"][0]["checked"])
        self.state.update(nightlight_running=False)
        self.assertFalse(self.invoke("view","comfort")["items"][0]["checked"])

    def test_nightlight_cold_start_and_on_off_keep_the_daemon(self):
        on=self.invoke("run","nightlight")
        self.assertTrue(on["ok"])
        self.assertFalse(on["close"])
        self.assertIn(["setsid","-f","hyprsunset","--identity"],self.calls())
        self.assertIn(["hyprctl","hyprsunset","temperature","3500"],self.calls())
        self.state=json.loads(self.state_path.read_text())
        self.assertFalse(self.state["nightlight_identity"])
        off=self.invoke("run","nightlight")
        self.assertTrue(off["ok"])
        self.assertIn(["hyprctl","hyprsunset","identity"],self.calls())
        after=json.loads(self.state_path.read_text())
        self.assertTrue(after["nightlight_identity"] and after["nightlight_running"])
        self.assertFalse(any(call[0]=="pkill" or 'wlsunset' in call for call in self.calls()))

    def test_nightlight_failed_start_is_reported_without_claiming_enabled(self):
        self.state["nightlight_start_fails"]=True
        data=self.failed("run","nightlight")
        self.assertIn("did not become ready",data["message"])
        self.assertFalse(any(call[1:]==["hyprsunset","temperature","3500"] for call in self.calls()))

    def test_nightlight_rejected_ipc_change_is_an_error(self):
        self.state.update(nightlight_running=True,nightlight_identity=True,nightlight_reject=True)
        data=self.failed("run","nightlight")
        self.assertIn("rejected",data["message"])

    def test_nightlight_invalid_state_disables_the_switch(self):
        self.write_config([{"id":"comfort","label":"Comfort","items":[{"id":"nightlight","label":"Night light","kind":"toggle"}]}])
        self.state.update(nightlight_running=True, exact={"\x1f".join(["hyprctl","hyprsunset","identity","get"]):{"stdout":"not a state\n","exit":0}})
        row=self.failed("view","comfort")["items"][0]
        self.assertFalse(row["enabled"])
        self.assertNotIn("checked",row)

    def test_agent_note_jumps_directly_and_preserves_new_arrivals(self):
        self.env.pop("TMUX",None)
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        old={"source":"fixture","project":"paper","tmux":"paper:1.2","message":"older note"}
        newer=old|{"message":"newer note","tmux":"paper:1.3"}  # another pane: a pane shows only its newest note
        arrival=old|{"message":"arrived while routing"}
        queue.write_text(json.dumps(old)+"\n"+json.dumps(newer)+"\n")
        rows=self.invoke("view","agents")["items"]
        self.assertEqual([row["id"] for row in rows],["agent-jump","agent-jump","agent-clear"])
        key=rows[1]["argument"]
        self.assertEqual(key,hashlib.sha256(json.dumps(old).encode()).hexdigest())
        self.assertNotIn("older note",key)
        self.state["agent_append"]=arrival
        self.assertTrue(self.invoke("run","agent-jump",key)["close"])
        self.assertEqual([json.loads(line) for line in queue.read_text().splitlines()],[newer,arrival])
        self.assertIn(["tmux","switch-client","-c","/dev/pts/fixture","-t","paper:1.2"],self.calls())
        self.assertFalse(any(call[0] in ("setsid","fox-picker") for call in self.calls()))
        before=list(self.calls())
        self.failed("run","agent-jump",key)
        self.assertEqual(self.calls(),before)

    def test_agent_notes_keep_each_panes_newest_and_let_old_ones_go(self):
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        now=int(time.time())
        stale={"project":"stale","tmux":"a:1.1","pane":"%1","event":"stop","epoch":now-13*3600}
        working={"project":"trader","tmux":"b:1.1","pane":"%2","event":"subagent","epoch":now-60}
        waiting=working|{"event":"stop","epoch":now-30,"message":"ready"}
        asking={"project":"foxtag","tmux":"c:1.1","event":"notification","ts":time.strftime("%Y-%m-%dT%H:%M:%S%z",time.localtime(now-10))[:-2]+":"+time.strftime("%z")[-2:]}
        old_by_ts=asking|{"tmux":"d:1.1","ts":"2026-01-01T08:00:00-06:00"}
        twin={"project":"trader","tmux":"e:1.1","event":"stop","epoch":now-90}
        same_place={"project":"trader","tmux":"e:1.1","pane":"%5","event":"subagent","epoch":now-80}  # e:1.1's newest: working
        second={"project":"trader","tmux":"f:1.1","event":"stop","epoch":now-70}
        queue.write_text("\n".join(json.dumps(n) for n in (stale,working,twin,same_place,second,waiting,asking,old_by_ts))+"\n")
        rows=self.invoke("view","agents")["items"]
        self.assertEqual([row["label"] for row in rows[:-1]],["Agent · foxtag","Agent · trader","Agent · trader","Agent · trader"],
                         "newest first; the stale, the replaced and the same pane under its old name gone")
        today=self.invoke("view","root")["today"]
        self.assertEqual(today["notes"],4)
        self.assertEqual([(w["project"],w["asking"],w["count"]) for w in today["waiting"]],[("foxtag",True,1),("trader",False,2)],
                         "one tag per project; a pane still working is not waiting")
        self.assertEqual(today["waiting"][1]["argument"],rows[1]["argument"],"the tag goes to the project's newest waiting pane")
        self.assertEqual(queue.read_text().count("\n"),8,"reading never rewrites the queue")

    def test_claude_sessions_feed_the_bar_pill_the_agents_page_and_today(self):
        self.env.pop("TMUX",None)
        sessions=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-claude"
        sessions.mkdir()
        now=int(time.time())
        def put(name,data): (sessions/name).write_text(json.dumps(data))
        put("a1.json",{"model":"Opus 5.5","context":41,"five":{"used":22,"resets":now+3600},"week":{"used":83,"resets":now+86400},
                       "project":"/code/Linux_Theme","pane":"%3","epoch":now-5})
        put("a1.state",{"state":"working","pane":"%3","epoch":now})
        put("b2.json",{"model":"Opus 5.5","context":12,"five":{"used":None,"resets":None},"week":{"used":None,"resets":None},
                       "project":"","cwd":"/code/FoxML_Trader_v2/","pane":"%4","epoch":now})
        put("b2.state",{"state":"needs","pane":"%4","epoch":now,"title":"Ledger tidy"})
        put("c3.state",{"state":"working","pane":"%5","epoch":now})          # its pane is back at a shell: gone
        put("d4.state",{"state":"working","pane":"%3","epoch":now-13*3600})  # twelve hours quiet: gone
        put("e5.state",{"state":"error","detail":"rate_limit","cwd":str(self.home),"epoch":now})  # outside tmux, in ~: kept, with nowhere to jump
        (sessions/"bad id.state").write_text(json.dumps({"state":"working","epoch":now}))
        for sub in ("edits","cards"):  # the paper mod's folders are never sessions
            (sessions/sub).mkdir(); (sessions/sub/"a1.json").write_text("{}")
        (sessions/"cards.state").mkdir()
        (sessions/"f6.state").write_text("not json")
        self.state.update(panes="%3\tclaude\n%4\tnode\n%5\tzsh",pane_targets={"%3":"paper:2.1"})
        self.state_path.write_text(json.dumps(self.state))
        result=subprocess.run([str(BINARY),"claude-bar"],env=self.env,capture_output=True,text=True,timeout=10)
        bar=json.loads(result.stdout)
        self.assertEqual(bar["text"],"✎ 1  ◇ 1  ! 1")
        self.assertEqual(bar["class"],["asking","berry","stopped"])
        self.assertEqual(bar["tooltip"].splitlines()[:3],["Linux_Theme · Opus 5.5 · 41% context · working","Ledger tidy · Opus 5.5 · 12% context · needs you","home · Claude · hit a limit"])
        self.assertTrue(bar["tooltip"].splitlines()[3].startswith("22% of this 5h · 83% this week · resets "),bar["tooltip"])
        rows=[row for row in self.invoke("view","agents")["items"] if row["id"]=="claude-jump"]
        self.assertEqual([(r["label"],r["claudeState"],r["context"],r["argument"],r["enabled"]) for r in rows],
                         [("Linux_Theme · Opus 5.5","working",41,"%3",True),("Ledger tidy · Opus 5.5","needs you",12,"%4",True),
                          ("home · Claude","hit a limit",-1,"",False)])
        self.assertTrue(rows[1]["detail"].startswith("FoxML_Trader_v2 · 12% of its context · waiting for your answer"),"a titled session still names its folder and says why it is waiting")
        self.assertIn("last activity",rows[1]["detail"])
        today=self.invoke("view","root")["today"]
        self.assertEqual((today["claudeWorking"],today["claudeBerry"]),(1,True))
        self.assertRegex(today["claudeUsage"],r"^17% of the week left · refills [a-z]{3}$","Today counts what is left")
        lock=subprocess.run([str(BINARY),"claude-lock-line"],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(lock.stdout,"1 still working ✎  ·  1 needs you\n")
        self.assertTrue(self.invoke("run","claude-jump","%3")["close"])
        self.assertIn(["tmux","switch-client","-c","/dev/pts/fixture","-t","paper:2.1"],self.calls())
        before=list(self.calls())
        for bad in ["paper:2.1","%3;rm","%"]:
            self.failed("run","claude-jump",bad)
        self.assertEqual(self.calls(),before,"a bad pane id never reaches tmux")
        put("a1.json",{"model":"Opus 5.5","context":41,"five":{"used":22,"resets":now-10},"week":{"used":61,"resets":now+86400},"pane":"%3","epoch":now})
        self.assertRegex(self.invoke("view","root")["today"]["claudeUsage"],r"^39% of the week left · refills [a-z]{3}$")
        put("a1.json",{"model":"Opus 5.5","context":41,"five":{"used":91,"resets":now+600},"week":{"used":61,"resets":now+86400},"pane":"%3","epoch":now})
        self.assertRegex(self.invoke("view","root")["today"]["claudeUsage"],r" · 9% of this 5h left$","the 5h shows once it runs low")
        for name in list(sessions.iterdir()): shutil.rmtree(name) if name.is_dir() else name.unlink()
        self.state_path.write_text(json.dumps(self.state))
        lock=subprocess.run([str(BINARY),"claude-lock-line"],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual((lock.returncode,lock.stdout),(0,"\n"),"nothing going on: the lock screen says nothing")
        result=subprocess.run([str(BINARY),"claude-bar"],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(json.loads(result.stdout),{"class":[],"text":"","tooltip":""},"no sessions: the pill folds away")

    def test_today_adds_up_the_time_with_claude_and_fills_the_teacup(self):
        self.env.pop("TMUX",None)
        sessions=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-claude"
        sessions.mkdir()
        now=int(time.time())
        (sessions/"t1.state").write_text(json.dumps({"state":"working","pane":"%1","epoch":now,"detail":"fresh"}))
        (sessions/"t1.json").write_text(json.dumps({"context":12,"week":{"used":24,"resets":now+86400},"pane":"%1","epoch":now}))
        self.state.update(panes="%1\tclaude"); self.state_path.write_text(json.dumps(self.state))
        day=time.strftime("%Y-%m-%d")
        (sessions/f"tally-{day}").write_text("\n".join([
            f"t0 working {now-7200}", f"t0 waiting {now-6000}",     # 20 minutes, done
            f"t0 working {now-5000}", f"t0 ended {now-4400}",       # 10 more, ended
            f"gone working {now-3000}",                            # never closed, no longer live: not counted
            "bad line", f"t1 waiting {now-900}", f"t1 working {now-600}"]) + "\n")  # 10 minutes and still going
        today=self.invoke("view","root")["today"]
        self.assertEqual((today["claudeMinutes"],today["claudeWeekLeft"]),(40,76))
        rows=[row for row in self.invoke("view","agents")["items"] if row["id"]=="claude-jump"]
        self.assertTrue(rows[0]["fresh"],"a page tidied a moment ago sparkles")
        (sessions/"t1.json").write_text(json.dumps({"context":12,"pane":"%1","epoch":now}))
        self.assertEqual(self.invoke("view","root")["today"]["claudeWeekLeft"],-1,"no reading, no teacup")

    def test_stay_awake_is_calm_when_auto_lock_is_off(self):
        self.write_config([{"id":"comfort","label":"Comfort","items":[{"id":"idle","label":"Stay awake","kind":"toggle"}]}])
        page=self.invoke("view","comfort")
        self.assertNotIn("error",page,"auto-lock off is a choice, not a failure")
        row=page["items"][0]
        self.assertEqual((row["enabled"],row["checked"],row["detail"]),(False,False,"Auto-lock is off, so the screen already stays awake"))
        self.assertEqual(self.failed("run","idle")["message"],"Auto-lock is off, so the screen already stays awake")
        self.assertNotIn("toggle_dpms.sh"," ".join(" ".join(c) for c in self.calls()),"nothing is paused when there is nothing to pause")
        self.state.update(hypridle_running=True); self.state_path.write_text(json.dumps(self.state))
        row=self.invoke("view","comfort")["items"][0]
        self.assertEqual((row["enabled"],row["checked"]),(True,False),"with auto-lock on, the switch works as before")
        (Path(self.env["XDG_RUNTIME_DIR"])/"hypridle_paused").write_text("")
        self.state.update(hypridle_running=False); self.state_path.write_text(json.dumps(self.state))
        row=self.invoke("view","comfort")["items"][0]
        self.assertEqual((row["enabled"],row["checked"]),(True,True),"paused by this switch: it reads as on")

    def test_the_bar_says_all_done_when_the_last_session_stops(self):
        self.env.pop("TMUX",None)
        sessions=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-claude"
        sessions.mkdir()
        now=int(time.time())
        def bar(state):
            (sessions/"d1.state").write_text(json.dumps({"state":state,"pane":"%1","epoch":now}))
            self.state.update(panes="%1\tclaude"); self.state_path.write_text(json.dumps(self.state))
            return json.loads(subprocess.run([str(BINARY),"claude-bar"],env=self.env,capture_output=True,text=True,timeout=10).stdout)
        self.assertEqual(bar("waiting")["text"],"◇ 1","nothing finished yet")
        self.assertEqual(bar("working")["text"],"✎ 1")
        done=bar("waiting")
        self.assertEqual((done["text"],"done" in done["class"]),("✓ all done  ◇ 1",True))
        self.assertEqual(bar("waiting")["text"],"✓ all done  ◇ 1","every bar's poll sees the same moment")
        memo=json.loads((sessions/".bar-memo").read_text())
        (sessions/".bar-memo").write_text(json.dumps({"busy":0,"doneUntil":memo["doneUntil"]-60}))
        self.assertEqual(bar("waiting")["text"],"◇ 1","and then it folds away")
        self.assertEqual((sessions/".bar-memo").stat().st_mode & 0o777,0o600)

    def test_the_next_waiting_session_comes_round_in_turn(self):
        self.env.pop("TMUX",None)
        sessions=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-claude"
        sessions.mkdir()
        now=int(time.time())
        for sid,state,pane,age in (("w1","waiting","%1",30),("n2","needs","%2",5),("w3","waiting","%3",60),("b4","working","%4",1)):
            (sessions/f"{sid}.state").write_text(json.dumps({"state":state,"pane":pane,"epoch":now-age}))
        def jump(here):
            self.state.update(panes="%1\tclaude\n%2\tclaude\n%3\tclaude\n%4\tclaude", tmux_clients="123\t/dev/pts/fixture\t99999999\ts",
                              pane_targets={"":here,"%1":"s:1.1","%2":"s:2.1","%3":"s:3.1","%4":"s:4.1"})
            self.state_path.write_text(json.dumps(self.state))
            out=subprocess.run([str(BINARY),"claude-next"],env=self.env,capture_output=True,text=True,timeout=10)
            return out.returncode,[c[-1] for c in self.calls() if c[:2]==["tmux","switch-client"]][-1:]
        self.assertEqual(jump("%9"),(0,["s:2.1"]),"the one asking goes first")
        self.assertEqual(jump("%2"),(0,["s:3.1"]),"then the longest waiting")
        self.assertEqual(jump("%3"),(0,["s:1.1"]))
        self.assertEqual(jump("%1"),(0,["s:2.1"]),"and round again; a working session is never picked")
        for name in list(sessions.iterdir()): name.unlink()
        out=subprocess.run([str(BINARY),"claude-next"],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual((out.returncode,json.loads(out.stdout)["message"]),(1,"No session is waiting on you"))

    def test_agent_focuses_the_client_window_instead_of_an_arbitrary_kitty(self):
        self.env.pop("TMUX",None)
        pid=os.getpid()
        self.state.update(tmux_clients=f"123\t/dev/pts/selected\t{pid}\tpaper",windows=[
            {"address":"0x11","pid":99999999,"class":"kitty"},
            {"address":"0x22","pid":pid,"class":"kitty"}])
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        queue.write_text(json.dumps({"tmux":"paper:1.2","source":"fixture"})+"\n")
        key=self.invoke("view","agents")["items"][0]["argument"]
        self.assertTrue(self.invoke("run","agent-jump",key)["ok"])
        self.assertIn(["setsid","-f","/bin/sh","-c",'sleep 0.35; exec fox-hl dispatch "$1" "$2"',"sh","hl.dsp.focus({ window = 'address:0x22' })","focuswindow address:0x22"],self.calls(),"focused after the drawer lets go of the keyboard")
        self.assertFalse(any('class:kitty' in argument for call in self.calls() for argument in call))

    def test_a_jump_goes_to_the_window_already_showing_that_session(self):
        self.env.pop("TMUX",None)
        pid=os.getpid()
        # The most recently used terminal shows session "main" (the main screen); "paper" is in another window.
        self.state.update(tmux_clients=f"900\t/dev/pts/main\t99999999\tmain\n100\t/dev/pts/side\t{pid}\tpaper",windows=[
            {"address":"0x11","pid":99999999,"class":"kitty"},
            {"address":"0x22","pid":pid,"class":"kitty"}])
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        queue.write_text(json.dumps({"tmux":"paper:1.2","source":"fixture"})+"\n")
        key=self.invoke("view","agents")["items"][0]["argument"]
        self.assertTrue(self.invoke("run","agent-jump",key)["ok"])
        switches=[c for c in self.calls() if c[:2]==["tmux","switch-client"]]
        self.assertEqual(switches,[["tmux","switch-client","-c","/dev/pts/side","-t","paper:1.2"]],"the main screen's terminal is left alone")
        self.assertIn(["setsid","-f","/bin/sh","-c",'sleep 0.35; exec fox-hl dispatch "$1" "$2"',"sh","hl.dsp.focus({ window = 'address:0x22' })","focuswindow address:0x22"],self.calls(),"focused after the drawer lets go of the keyboard")

    def test_a_session_nobody_shows_gets_its_own_terminal(self):
        self.env.pop("TMUX",None)
        self.state.update(tmux_clients="900\t/dev/pts/main\t99999999\tmain")
        self.state_path.write_text(json.dumps(self.state))
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        queue.write_text(json.dumps({"tmux":"paper:1.2","source":"fixture"})+"\n")
        key=self.invoke("view","agents")["items"][0]["argument"]
        self.assertTrue(self.invoke("run","agent-jump",key)["ok"])
        self.assertFalse([c for c in self.calls() if c[:2]==["tmux","switch-client"]],"never takes over the terminal you are in")
        self.assertTrue(any("attach-session" in c for c in self.calls()),"a terminal of its own")

    def test_agent_failed_route_keeps_note_and_clear_requires_confirmation(self):
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        note={"source":"fixture","tmux":"paper:1.2","message":"keep this"}
        raw=json.dumps(note)+"\n";queue.write_text(raw)
        key=self.invoke("view","agents")["items"][0]["argument"]
        self.state["exact"]={"\x1f".join(["tmux","has-session","-t","=paper"]):{"exit":1}}
        self.failed("run","agent-jump",key)
        self.assertEqual(queue.read_text(),raw)
        self.failed("run","agent-clear")
        self.assertEqual(queue.read_text(),raw)
        self.assertTrue(self.invoke("run","agent-clear","--confirm")["ok"])
        self.assertEqual(queue.read_text(),"")

    def test_config_root_and_group(self):
        root = self.invoke("view", "root")
        self.assertEqual(root["id"], "root")
        group = next(x for x in root["items"] if x.get("page") == "sound")
        self.assertEqual((group["label"], group["kind"]), ("Sound", "page"))
        sound = self.invoke("view", "sound")
        volume = next(x for x in sound["items"] if x["id"] == "volume")
        self.assertEqual(volume["value"], 42)
        self.assertTrue(volume.get("enabled", True))

    def test_unknown_page_and_action_do_not_execute(self):
        self.failed("view", "not-a-real-page")
        self.failed("run", "not-a-real-action", "$(touch should-not-exist)")
        self.assertEqual(self.calls(), [])

    def test_invalid_config_shapes(self):
        for raw in ("{", "[]", '{"groups":42}', '{"groups":[{"id":"bad","label":"Bad","items":42}]}'):
            with self.subTest(raw=raw):
                self.config.write_text(raw)
                self.failed("view", "root")

    def test_duplicate_group_ids_rejected(self):
        group = {"id": "same", "label": "First", "items": []}
        self.write_config([group, dict(group, label="Second")])
        self.failed("view", "root")

    def test_untrusted_config_cannot_execute_commands(self):
        target = self.root / "injected"
        self.write_config([{"id": "unsafe", "label": "Unsafe", "items": [
            {"id": "evil", "label": "Evil", "kind": "action", "command": f"touch {target}"},
        ]}])
        self.failed("run", "evil")
        self.assertFalse(target.exists())
        self.assertEqual(self.calls(), [])

    def test_ranges_reject_injection_and_invalid_values(self):
        for action in ("volume", "brightness"):
            for value in ("-1", "101", "nan", "inf", "50;touch injected", "$(touch injected)", "20%"):
                with self.subTest(action=action, value=value):
                    self.failed("run", action, value)
        self.assertEqual(self.calls(), [])

    def test_power_requires_backend_confirmation(self):
        for action in ("suspend", "reboot", "poweroff", "logout"):
            with self.subTest(action=action):
                self.failed("run", action)
                self.failed("run", action, "yes")
        self.assertEqual(self.calls(), [])

    def test_confirmed_power_uses_fixed_argv(self):
        data = self.invoke("run", "reboot", "--confirm")
        self.assertTrue(data["ok"])
        self.assertTrue(any(call[:2] == ["systemctl", "reboot"] for call in self.calls()))

    def test_volume_state_failure_is_visible(self):
        self.state["commands"] = {"wpctl": {"exit": 1, "stderr": "PipeWire unavailable\n"}}
        data = self.invoke("view", "sound", expect=1)
        volume = next(x for x in data["items"] if x["id"] == "volume")
        self.assertFalse(volume.get("enabled", True))
        self.assertNotEqual(volume.get("value"), 0)

    def test_command_failure_returns_json_error(self):
        argv = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "55%"]
        self.state["exact"] = {"\x1f".join(argv): {"exit": 1, "stderr": "PipeWire rejected the operation\n"}}
        self.failed("run", "volume", "55")
        self.assertIn(argv, self.calls())

    def test_failed_clipboard_writer_returns_error_not_sigpipe(self):
        self.state["clipboard_data"] = base64.b64encode(b"\x89PNG\x00\xff" * 16384).decode()
        self.state["commands"] = {"wl-copy": {"exit": 1, "stderr": "Wayland unavailable\n"}}
        self.failed("run", "clipboard-restore", "18")
        self.assertFalse(self.clipboard_path.exists())
        self.assertIn(["wl-copy"], self.calls())

    def test_wifi_escaped_colon_and_shell_characters_stay_literal(self):
        ssid = 'Desk:$(touch INJECTED);wifi'
        self.state["wifi"] = ':Desk\\:$(touch INJECTED);wifi:85:WPA2'
        data = self.invoke("view", "wifi")
        network = next(x for x in data["items"] if x["id"] == "wifi-connect")
        self.assertEqual(network["argument"], ssid)
        self.assertTrue(self.invoke("run", "wifi-connect", ssid)["ok"])
        expected = ["setsid", "-f", "kitty", "-e", "nmcli", "--ask", "device", "wifi", "connect", "--", ssid]
        self.assertIn(expected, self.calls())

    def test_window_title_is_data_and_address_is_validated(self):
        title = 'Notes "$(touch INJECTED)"; <script>'
        self.state["windows"] = [{"address": "0xabc123", "title": title, "class": "kitty", "workspace": {"id": 2}}]
        data = self.invoke("view", "windows")
        self.assertEqual(data["items"][0]["label"], title)
        self.assertTrue(self.invoke("run", "window-focus", "0xabc123")["ok"])
        self.assertIn(["fox-hl", "dispatch", "hl.dsp.focus({ window = 'address:0xabc123' })", "focuswindow address:0xabc123"], self.calls())

    def test_root_summary_and_favorite_use_live_volume(self):
        config = json.loads(self.config.read_text())
        config["favorites"] = ["sound/volume"]
        self.config.write_text(json.dumps(config))
        data = self.invoke("view", "root")
        self.assertEqual(data["items"][1]["summary"], "42% · speakers")
        self.assertEqual(data["favorites"][0]["id"], "volume")
        self.assertEqual(data["favorites"][0]["value"], 42)
        self.assertEqual(data["favorites"][0]["group"], "sound")

    def test_unavailable_summary_does_not_fabricate_zero(self):
        self.state = {"commands": {"wpctl": {"exit": 1}}}
        data = self.invoke("view", "root")
        self.assertEqual(data["items"][1]["summary"], "Audio unavailable")
        self.assertEqual(data["favorites"], [])

    def test_unknown_or_duplicate_favorites_are_rejected(self):
        config = json.loads(self.config.read_text())
        for references in (["missing/action"], ["sound/volume", "sound/volume"], [42]):
            config["favorites"] = references
            self.config.write_text(json.dumps(config))
            self.assertFalse(self.invoke("view", "root", expect=1)["ok"])

    def test_explicit_empty_favorites_remain_empty(self):
        config = json.loads(self.config.read_text())
        config["favorites"] = []
        self.config.write_text(json.dumps(config))
        self.assertEqual(self.invoke("view", "root")["favorites"], [])

    def test_project_cards_and_opening_preserve_literal_paths(self):
        project = self.home / "code" / "Paper $(touch injected) project"
        (project / ".git").mkdir(parents=True)
        (project / "CMakeLists.txt").write_text("project(Paper)\n")
        config = json.loads(self.config.read_text())
        config["project_editor"] = ["kitty", "--title", "Project"]
        self.config.write_text(json.dumps(config))
        cards = self.invoke("view", "projects", "paper")["items"]
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]["presentation"], "project")
        self.assertEqual(cards[0]["argument"], str(project.resolve()))
        self.assertIn("C++", cards[0]["detail"])
        self.assertTrue(self.invoke("run", "project-open", str(project.resolve()))["ok"])
        self.assertIn(["setsid", "-f", "kitty", "--title", "Project", str(project.resolve())], self.calls())
        self.assertTrue(self.invoke("run", "project-terminal", str(project.resolve()))["ok"])
        self.assertIn(["setsid", "-f", "kitty", "--directory", str(project.resolve())], self.calls())
        self.assertFalse((self.root / "injected").exists())

    def test_projects_exclude_unmarked_hidden_and_symlink_folders(self):
        code = self.home / "code"
        code.mkdir()
        (code / "unmarked").mkdir()
        (code / ".hidden" / ".git").mkdir(parents=True)
        outside = self.root / "outside"
        (outside / ".git").mkdir(parents=True)
        (code / "linked").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.invoke("view", "projects")["items"], [])
        self.assertFalse(self.invoke("run", "project-open", str(outside), expect=1)["ok"])

    def test_custom_project_roots_and_invalid_configuration(self):
        root = self.home / "projects"
        project = root / "Notes"
        project.mkdir(parents=True)
        (project / "pyproject.toml").write_text("[project]\n")
        config = json.loads(self.config.read_text())
        config["project_roots"] = ["~/projects", str(root)]
        self.config.write_text(json.dumps(config))
        self.assertEqual(len(self.invoke("view", "projects")["items"]), 1)
        config["project_roots"] = ["relative/path"]
        self.config.write_text(json.dumps(config))
        self.assertFalse(self.invoke("view", "projects", expect=1)["ok"])

    def test_valid_volume_set_and_json_stdout(self):
        data = self.invoke("run", "volume", "55")
        self.assertTrue(data["ok"])
        calls = self.calls()
        self.assertTrue(any(call[0] == "wpctl" and "set-volume" in call and "55%" in call for call in calls), calls)

    def test_updates_launch_explicit_apply_modes_without_reopening_a_menu(self):
        helper = self.home / '.config/hypr/scripts/updates_menu.sh'
        helper.parent.mkdir(parents=True)
        helper.write_text('#!/bin/bash\nexit 0\n')
        for action, mode in [('updates-terminal','--apply-terminal'),('updates-silent','--apply-silent')]:
            self.assertTrue(self.invoke('run',action)['ok'])
            self.assertIn(['setsid','-f','bash',str(helper),mode],self.calls())
        self.assertFalse(any(call[0]=='rofi' or 'FOXML_MENU_LEGACY=1' in call for call in self.calls()))

    def test_scrapbook_lists_only_pictures_and_encodes_literal_paths(self):
        folder = self.home / 'Pictures/Screenshots'; folder.mkdir(parents=True)
        older = folder / 'older.png'; older.write_bytes(b'old'); os.utime(older, (100, 100))
        picture = folder / 'a #picture?; $(nope).PNG'; picture.write_bytes(b'png image'); os.utime(picture, (200, 200))
        (folder / 'notes.txt').write_text('not a photo')
        (folder / '.hidden.png').write_bytes(b'hidden')
        outside = self.home / 'outside.png'; outside.write_bytes(b'outside')
        (folder / 'linked.png').symlink_to(outside)
        rows = self.invoke('view', 'screenshots')['items']
        self.assertEqual([row['label'] for row in rows], [picture.name, older.name])
        self.assertEqual(rows[0]['image'], picture.as_uri())
        self.assertEqual(rows[0]['presentation'], 'screenshot')
        self.assertTrue(self.invoke('run', 'screenshot-copy', str(picture))['ok'])
        self.assertEqual(self.clipboard_path.read_bytes(), b'png image')
        self.assertIn(['wl-copy', '--type', 'image/png'], self.calls())
        self.assertTrue(self.invoke('run', 'screenshot-open', str(picture))['ok'])
        self.assertIn(['setsid', '-f', 'xdg-open', str(picture)], self.calls())
        self.failed('run', 'screenshot-copy', str(outside))
        self.failed('run', 'screenshot-open', str(folder / 'linked.png'))
        picture.unlink()
        self.failed('run', 'screenshot-copy', str(picture))

    def test_scrapbook_directory_override_and_missing_folder(self):
        self.assertEqual(self.invoke('view', 'screenshots')['items'], [])
        folder = self.home / 'Custom shots'; folder.mkdir(); (folder / 'image.jpg').write_bytes(b'jpeg')
        config = json.loads(self.config.read_text()); config['screenshots_directory'] = '~/Custom shots'
        self.config.write_text(json.dumps(config))
        rows = self.invoke('view', 'screenshots')['items']; self.assertEqual(len(rows), 1)
        self.assertTrue(self.invoke('run', 'screenshot-copy', rows[0]['argument'])['ok'])
        self.assertIn(['wl-copy', '--type', 'image/jpeg'], self.calls())
        config['screenshots_directory'] = 'relative'; self.config.write_text(json.dumps(config))
        self.failed('view', 'screenshots')

    def test_incoming_tray_filters_temporary_files_and_orders_by_modified_time(self):
        folder = self.home / 'Downloads'
        folder.mkdir()
        for name, modified in [('Older.pdf', 100), ('Newer.md', 200), ('.hidden.txt', 400), ('unfinished.crdownload', 500), ('unfinished.part', 600)]:
            file = folder / name
            file.write_text('private fixture contents')
            os.utime(file, (modified, modified))
        (folder / 'a directory').mkdir()
        (folder / 'link.txt').symlink_to(folder / 'Newer.md')
        rows = self.invoke('view','downloads')['items']
        self.assertEqual([row['label'] for row in rows], ['Newer.md','Older.pdf'])
        self.assertEqual(rows[0]['presentation'], 'download')
        self.assertIn('Note', rows[0]['detail'])
        self.assertIn('PDF', rows[1]['detail'])
        self.assertTrue(all('stamp' in row for row in rows))
        self.assertTrue(all('modifiedAt' in row for row in rows))
        self.assertRegex(rows[0]['modifiedAt'], r'^\d{4}-\d{2}-\d{2} \d\d:\d\d:\d\d ')
        self.assertNotIn('ago', rows[0]['detail'].lower())
        self.assertEqual([call[0] for call in self.calls()], ['xdg-user-dir'])
        self.assertEqual((folder / 'Newer.md').read_text(), 'private fixture contents')

    def test_incoming_tray_opens_literal_file_or_folder_and_refuses_stale_paths(self):
        folder = self.home / 'Downloads'
        folder.mkdir()
        file = folder / 'Notes; $(touch should-not-exist).txt'
        file.write_text('note')
        self.assertTrue(self.invoke('run','download-open',str(file))['ok'])
        self.assertIn(['setsid','-f','xdg-open',str(file)], self.calls())
        self.assertTrue(self.invoke('run','download-folder',str(file))['ok'])
        self.assertIn(['setsid','-f','xdg-open',str(folder)], self.calls())
        self.failed('run','download-open',str(self.home / 'outside.txt'))
        file.unlink()
        self.failed('run','download-open',str(file))
        self.assertEqual(sum(call[0] == 'setsid' for call in self.calls()), 2)
        self.assertFalse((folder / 'should-not-exist').exists())

    def test_incoming_tray_respects_xdg_override_and_disabled_download_folder(self):
        folder = self.home / 'Incoming papers'
        folder.mkdir()
        (folder / 'hello.txt').write_text('hello')
        self.state['download_dir'] = str(folder)
        self.assertEqual(len(self.invoke('view','downloads')['items']), 1)
        self.state['download_dir'] = str(self.home)
        self.assertEqual(self.invoke('view','downloads')['items'], [])
        config = json.loads(self.config.read_text())
        config['downloads_directory'] = '~/Incoming papers'
        self.config.write_text(json.dumps(config))
        self.assertEqual(len(self.invoke('view','downloads')['items']), 1)
        config['downloads_directory'] = 'relative/folder'
        self.config.write_text(json.dumps(config))
        self.failed('view','downloads')

    def test_incoming_tray_limits_recent_files_and_filters_names_and_types(self):
        self.assertEqual(self.invoke('view','downloads')['items'], [])
        folder = self.home / 'Downloads'
        folder.mkdir()
        for number in range(70):
            file = folder / f'Note-{number:02d}.txt'
            file.write_text('note')
            os.utime(file, (number + 100, number + 100))
        rows = self.invoke('view','downloads')['items']
        self.assertEqual(len(rows), 64)
        self.assertEqual(rows[0]['label'], 'Note-69.txt')
        self.assertEqual(rows[-1]['label'], 'Note-06.txt')
        filtered = self.invoke('view','downloads','Note-68')['items']
        self.assertEqual([row['label'] for row in filtered], ['Note-68.txt'])

    def make_project(self, name="Paper notes"):
        project = self.home / "code" / name
        project.mkdir(parents=True)
        (project / ".git").mkdir()
        return str(project)

    def test_bookmark_ribbons_persist_and_appear_on_home(self):
        project = self.make_project('Notes; $(touch nope)')
        self.assertTrue(self.invoke("run", "project-bookmark", project)["ok"])
        state = Path(self.env['XDG_STATE_HOME']) / 'foxml/project-bookmarks.json'
        self.assertEqual(json.loads(state.read_text()), [project])
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        for page in ("projects", "bookmarks"):
            row = self.invoke("view", page)["items"][0]
            self.assertTrue(row['bookmarked'])
            self.assertEqual(row['argument'], project)
        self.assertEqual(self.invoke("view", "root")['favorites'][0]['argument'], project)
        self.assertTrue(self.invoke("run", "project-bookmark", project)["ok"])
        self.assertEqual(json.loads(state.read_text()), [])
        self.assertEqual(json.loads(state.with_suffix('.json.bak').read_text()), [project])
        self.assertEqual(self.invoke("view", "bookmarks")['items'], [])
        self.assertFalse(any(call[0] in ('setsid','kitty') for call in self.calls()))

    def test_bookmarks_reject_corruption_outside_roots_and_overflow(self):
        project = self.make_project()
        self.failed("run", "project-bookmark", str(self.home / "outside"))
        state = Path(self.env['XDG_STATE_HOME']) / 'foxml/project-bookmarks.json'
        state.parent.mkdir(parents=True)
        state.write_text('{broken')
        self.failed("run", "project-bookmark", project)
        self.assertEqual(state.read_text(), '{broken')
        state.write_text(json.dumps([f"/old/{i}" for i in range(16)]))
        self.failed("run", "project-bookmark", project)
        self.assertEqual(len(json.loads(state.read_text())), 16)

    def test_removed_project_bookmark_can_be_cleared_without_opening_it(self):
        project = self.make_project()
        self.invoke('run','project-bookmark',project)
        Path(project, '.git').rmdir()
        Path(project).rmdir()
        row = self.invoke('view','bookmarks')['items'][0]
        self.assertIn('Unavailable', row['detail'])
        self.failed('run','project-open',project)
        self.assertTrue(self.invoke('run','project-bookmark',project)['ok'])
        self.assertEqual(self.invoke('view','bookmarks')['items'], [])

    def test_concurrent_bookmark_writes_preserve_both_ribbons(self):
        paths = [self.make_project(name) for name in ('One','Two')]
        processes = [subprocess.Popen([str(BINARY),'--config',str(self.config),'run','project-bookmark',path],
                                     env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for path in paths]
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertTrue(json.loads(stdout)['ok'])
        self.assertEqual({row['argument'] for row in self.invoke('view','bookmarks')['items']}, set(paths))

    def removable_drive(self, mounted=True):
        return dict(name='sda', path='/dev/sda', type='disk', tran='usb', rm=False,
                    size=64*1024**3, label=None, fstype=None, mountpoints=[], children=[
                        dict(name='sda1', path='/dev/sda1', type='part', size=32*1024**3,
                             label='Notes; $(touch nope)', fstype='exfat', mountpoints=['/run/media/me/Paper notes'] if mounted else [])])

    def test_library_is_read_only_and_only_lists_removable_non_system_volumes(self):
        usb = self.removable_drive()
        internal = dict(usb, path='/dev/nvme0n1', tran='nvme')
        boot = dict(usb, path='/dev/sdb', children=[dict(usb['children'][0], mountpoints=['/'])])
        swap = dict(usb, path='/dev/sdc', children=[dict(usb['children'][0], fstype='swap', mountpoints=['[SWAP]'])])
        encrypted = dict(usb, path='/dev/sdd', children=[dict(usb['children'][0], fstype='crypto_LUKS')])
        self.state['drives'] = {'blockdevices': [internal, usb, boot, swap, encrypted]}
        rows = self.invoke('view','library')['items']
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['argument'], '/dev/sda1')
        self.assertEqual(rows[0]['ejectArgument'], '/dev/sda')
        self.assertTrue(rows[0]['mounted'])
        self.assertIn('32.0 GiB', rows[0]['detail'])
        self.assertEqual([call[0] for call in self.calls()], ['lsblk'])

    def test_library_mount_open_and_literal_mountpoint(self):
        self.state['drives'] = {'blockdevices': [self.removable_drive(False)]}
        self.state['after_mount'] = {'blockdevices': [self.removable_drive()]}
        self.assertTrue(self.invoke('run','drive-open','/dev/sda1')['ok'])
        self.assertIn(['udisksctl','mount','--block-device','/dev/sda1','--no-user-interaction'], self.calls())
        self.assertIn(['setsid','-f','xdg-open','/run/media/me/Paper notes'], self.calls())

    def test_library_eject_requires_confirmation_and_unmounts_whole_disk(self):
        drive = self.removable_drive()
        drive['children'].append(dict(drive['children'][0], path='/dev/sda2'))
        self.state['drives'] = {'blockdevices':[drive]}
        self.failed('run','drive-eject','/dev/sda')
        self.assertFalse(any(call[0] == 'udisksctl' for call in self.calls()))
        self.assertTrue(self.invoke('run','drive-eject','/dev/sda','--confirm')['ok'])
        operations = [call for call in self.calls() if call[0] == 'udisksctl']
        self.assertEqual(operations, [
            ['udisksctl','unmount','--block-device','/dev/sda1','--no-user-interaction'],
            ['udisksctl','unmount','--block-device','/dev/sda2','--no-user-interaction'],
            ['udisksctl','power-off','--block-device','/dev/sda','--no-user-interaction']])

    def test_library_busy_disappeared_or_internal_drive_never_powers_off(self):
        self.state['drives'] = {'blockdevices':[self.removable_drive()]}
        self.state['exact'] = {'\x1f'.join(['udisksctl','unmount','--block-device','/dev/sda1','--no-user-interaction']):{'exit':1}}
        self.failed('run','drive-eject','/dev/sda','--confirm')
        self.assertFalse(any('power-off' in call for call in self.calls()))
        self.failed('run','drive-eject','/dev/nvme0n1','--confirm')
        self.failed('run','drive-open','/dev/sda1; touch nope')
        self.state['drives'] = {'blockdevices':[]}
        self.failed('run','drive-eject','/dev/sda','--confirm')
        self.assertFalse(any('power-off' in call for call in self.calls()))

    def test_library_missing_services_and_mount_failure(self):
        self.state['drives'] = {'blockdevices':[self.removable_drive(False)]}
        self.state['commands'] = {'udisksctl':{'exit':1}}
        self.failed('run','drive-open','/dev/sda1')
        self.assertFalse(any(call[0] == 'setsid' for call in self.calls()))
        (self.bin / 'udisksctl').unlink()
        self.assertFalse(self.invoke('view','library')['items'][0]['enabled'])
        self.state['commands']['lsblk'] = {'exit':1}
        self.failed('view','library')

    def test_hostile_desktop_filename_stays_one_argument(self):
        directory = self.home / ".local/share/applications"
        directory.mkdir(parents=True)
        desktop = directory / 'nice $(touch injected); app.desktop'
        desktop.write_text("[Desktop Entry]\nType=Application\nName=A lovely app\nExec=true\nIcon=accessories-text-editor\n")
        results = self.invoke("view", "search", "lovely")["items"]
        self.assertTrue(any(row["id"] == "app-launch" and row.get("argument") == str(desktop) for row in results))
        data = self.invoke("view", "apps", "lovely")
        self.assertEqual(len(data["items"]), 1)
        self.assertIn("lovely", data["items"][0]["label"].lower())
        launched = self.invoke("run", "app-launch", str(desktop))
        self.assertTrue(launched["ok"])
        self.assertTrue(any("gio" in call and "launch" in call and str(desktop) in call for call in self.calls()))
        self.assertFalse((self.root / "injected").exists())

    def test_find_anything_includes_project_device_and_latest_screenshot(self):
        project = self.home/'code'/'Little Paper'
        (project/'.git').mkdir(parents=True)
        captures = self.home/'Pictures'/'Screenshots'
        captures.mkdir(parents=True)
        (captures/'capture.png').write_bytes(b'preview')
        rows = self.invoke('view','search','Little Paper')['items']
        self.assertTrue(any(row['id']=='project-open' and row['argument']==str(project) for row in rows))
        rows = self.invoke('view','search','headphones')['items']
        self.assertTrue(any(row['id']=='bluetooth-connect' and row['argument']=='AA:BB:CC:DD:EE:FF' for row in rows))
        rows = self.invoke('view','search','last screenshot')['items']
        self.assertTrue(any(row['id']=='screenshot-open' and row['argument']==str(captures/'capture.png') for row in rows))

    def test_hidden_desktop_file_not_offered(self):
        directory = self.home / ".local/share/applications"
        directory.mkdir(parents=True)
        for name, field in (("hidden", "Hidden=true"), ("nodisplay", "NoDisplay=true")):
            (directory / f"{name}.desktop").write_text(f"[Desktop Entry]\nType=Application\nName={name}\nExec=true\n{field}\n")
        self.assertEqual(self.invoke("view", "apps")["items"], [])

    def test_detached_application_does_not_inherit_json_pipe(self):
        directory = self.home / ".local/share/applications"
        directory.mkdir(parents=True)
        desktop = directory / "sample.desktop"
        desktop.write_text("[Desktop Entry]\nType=Application\nName=Sample\nExec=true\n")
        self.state["inspect_fds"] = True
        self.assertTrue(self.invoke("run", "app-launch", str(desktop))["ok"])
        descriptors = json.loads(self.fds_path.read_text())
        leaked = {fd: target for fd, target in descriptors.items() if int(fd) > 2 and target.startswith("pipe:[")}
        self.assertEqual(leaked, {}, f"detached application kept the backend JSON pipe open: {leaked}")

    def real(self, *names):
        for name in names:
            (self.bin / name).unlink(missing_ok=True)
            (self.bin / name).symlink_to(shutil.which(name))

    def test_stopped_bluetooth_offers_the_service_and_never_waits_on_bluetoothctl(self):
        self.state["exact"] = {"systemctl\x1fis-active\x1f--quiet\x1fbluetooth": {"exit": 3}}
        page = self.invoke("view", "bluetooth")
        self.assertEqual([row["id"] for row in page["items"]], ["bluetooth-service"])
        self.assertFalse(page.get("error"))
        self.assertFalse([call for call in self.calls() if call[0] == "bluetoothctl"])
        self.assertIn("off", self.invoke("run", "bluetooth-toggle", expect=1)["message"])
        self.assertEqual(self.invoke("run", "bluetooth-service")["close"], True)
        self.assertIn(["sudo", "systemctl", "enable", "--now", "bluetooth"], [call[-5:] for call in self.calls()])

    def test_a_hung_command_cannot_hold_a_page(self):
        self.real("timeout")
        self.state["commands"] = {"bluetoothctl": {"hang": True}}
        started = time.monotonic()
        page = self.invoke("view", "bluetooth", expect=1)
        self.assertLess(time.monotonic() - started, 7)
        self.assertEqual(page["error"], "Bluetooth devices are unavailable")

    def test_fox_tools_is_a_page_that_runs_only_listed_commands(self):
        tools = self.home / ".local/bin"
        tools.mkdir(parents=True)
        (tools / "fox-doctor").write_text("#!/bin/bash\n# fox-doctor — check the machine\n")
        (tools / "fox-menu").write_text("#!/bin/bash\n# fox-menu — hidden\n")
        (tools / "fox-binary").write_bytes(b"\x7fELF\x00\n")
        (tools / "unrelated").write_text("#!/bin/bash\n")
        for tool in tools.iterdir():
            tool.chmod(0o755)
        sections = {row["page"]: row for row in self.invoke("view", "tools")["items"]}
        self.assertEqual(set(sections), {"tools-system", "tools-other", "tools-all"})
        self.assertTrue(all(row["kind"] == "page" for row in sections.values()))
        self.assertEqual([row["label"] for row in self.invoke("view", "tools-system")["items"]], ["fox-doctor"])
        rows = {row["label"]: row["detail"] for row in self.invoke("view", "tools-all")["items"]}
        self.assertEqual(rows, {"fox-binary": "Opens in a terminal", "fox-doctor": "Check the machine"})
        self.assertEqual([row["label"] for row in self.invoke("view", "tools-other")["items"]], ["fox-binary"])
        self.assertTrue(any(row.get("argument") == "fox-doctor" for row in self.invoke("view", "search", "fox-doctor")["items"]))
        self.assertEqual(self.invoke("run", "tools")["page"], "tools")
        self.failed("run", "tool-run", "unrelated")
        self.assertTrue(self.invoke("run", "tool-run", "fox-doctor")["close"])
        launched = [call for call in self.calls() if call[0] == "setsid"][-1]
        self.assertEqual(launched[-2:], ["--", str(tools / "fox-doctor")])
        self.assertIn("--hold", launched)

    def test_usage_page_shows_tracked_spend_by_project_model_and_day(self):
        helper = self.bin/'fox-credits'
        helper.write_text('#!'+sys.executable+'\n'+FAKE_COMMAND)
        helper.chmod(0o755)
        snapshot = {'headline':'$2.10 tracked of $200.00', 'short':'API ~$197.90 left',
                    'detail':'Tracked runs only · renews Dec 1', 'status':'tracked', 'source':'local',
                    'remaining_usd':'197.90', 'remaining_percent':98.9, 'projects':[]}
        usage = {'snapshot': snapshot,
                 'projects': [{'id':'trader','label':'Trader','spent_usd':'2.00','runs':2,'average_usd':'1.0000'},
                              {'id':'theme','label':'Linux_Theme','spent_usd':'0.00075','runs':2,'average_usd':'0.00036080000000000004'}],
                 'models': [{'model':'claude-opus-5-5','spent_usd':'1.50','runs':1,'average_usd':'1.5000','input_tokens':12000,'output_tokens':3000}],
                 'days': [{'day':'2026-11-0'+str(n),'spent_usd':'0.10','runs':1} for n in range(1,10)],
                 'top': [{'id':'b','project':'trader','model':'claude-opus-5-5','cost_usd':'1.50','at':'2026-11-09T01:00:00Z','label':'Why is the book slow?'}]}
        self.state['commands'] = {'fox-credits':{'stdout':json.dumps(usage)}}
        page = self.invoke('view','api-credits')
        self.assertEqual(page['title'], 'API')
        headings = [r['label'] for r in page['items'] if r['kind'] == 'heading']
        self.assertEqual(headings, ['spend', 'settings'], 'no projects or earlier asks here, so only these two')
        self.assertFalse(any(r['enabled'] for r in page['items'] if r['kind'] == 'heading'), 'headings are never selectable')
        self.assertEqual(page['credits'], snapshot)
        labels = [r['label'] for r in page['items']]
        nested = {r['label'] for r in page['items'] if r.get('nested')}
        self.assertTrue({'Trader', 'claude-opus-5-5', 'Why is the book slow?'} <= nested, 'entries sit beneath their heading')
        self.assertNotIn('By project', nested)
        self.assertFalse([l for l in labels if l.startswith(' ')], 'indent is the nested flag, never spaces')
        self.assertEqual(len([l for l in labels if l.startswith('2026-11-0')]), 7, 'only the last seven days')
        by_label = {r['label']: r['detail'] for r in page['items']}
        self.assertIn('12k in / 3k out', by_label['claude-opus-5-5'])
        self.assertIn('$2.00 · 2 runs · about $1.00 each', by_label['Trader'])
        self.assertIn('<$0.01 · 2 runs · about <$0.01 each', by_label['Linux_Theme'], 'no float noise, no fractions of a cent')
        self.assertNotIn('2026-11-09T', by_label['Why is the book slow?'])
        ids = [r['id'] for r in page['items']]
        self.assertNotIn('credits-sync', ids)
        self.assertEqual([c for c in self.calls() if c[0]=='fox-credits'], [['fox-credits','usage']])
        self.failed('run','credits-sync')
        self.assertTrue(self.invoke('run','credits-setup')['ok'])
        self.assertTrue(any(call[-2:]==['fox-credits','setup'] for call in self.calls()))
        self.assertEqual(self.invoke('view','api-tasks')['title'], 'API', 'the old page name opens the one API page')

    def test_api_tasks_list_configured_projects_and_explain_only_their_failures(self):
        helper = self.bin/'fox-claude-api'
        helper.write_text('#!'+sys.executable+'\n'+FAKE_COMMAND)
        helper.chmod(0o755)
        projects = [dict(id='trader', label='Trader', root='/code/trader', available=True, budget_usd='1.00',
                         model='claude-sonnet-5-5', credits='$12.00 left this month'),
                    dict(id='theme', label='Linux_Theme', root='/code/theme', available=False, budget_usd='1.00',
                         credits='$12.00 left this month')]
        mine = dict(id='a'*32, command='make test', title='Run the trader tests', root='/code/trader/sub', state='failed', elapsed=3, exit=2)
        other = dict(id='b'*32, command='make test', root='/code/other', state='failed', elapsed=3, exit=2)
        saved = [dict(id='c'*32, project='trader', label='Trader', title='Why is the book slow?', status='completed',
                      model='claude-opus-5-5', cost_usd='0.42',
                      finished_at=time.strftime('%Y-%m-%dT%H:%M:%S.123456+00:00', time.gmtime(time.time() - 60)))]
        self.state = {'commands': {'fox-work': {'stdout': json.dumps(dict(jobs=[mine, other], reviews=[], tasks=[]))}},
                      'exact': {'fox-claude-api\x1fprojects': {'stdout': json.dumps(projects)},
                                'fox-claude-api\x1fhistory': {'stdout': json.dumps(saved)},
                                'fox-work\x1ftests\x1f--id\x1f'+'a'*32: {'stdout': json.dumps(mine)},
                                'fox-work\x1flog\x1f--id\x1f'+'a'*32: {'stdout': 'assertion failed: boom\n'}}}
        rows = self.invoke('view','api-tasks')['items']
        self.assertEqual([r['id'] for r in rows], ['credits-summary', 'section-ask'] + ['api-task-ask','api-task-review','api-task-pi']*2
                         + ['section-earlier-asks', 'api-task-open', 'api-task-follow',
                            'section-settings', 'credits-setup', 'credits-console', 'api-task-settings'])
        self.assertIn('claude-sonnet-5-5', rows[2]['detail'])
        self.assertFalse(any(r['enabled'] for r in rows[5:8]), 'a missing project folder should not be askable')
        self.assertEqual(rows[9]['label'], 'Why is the book slow?')
        self.assertIn('claude-opus-5-5 · $0.42 · today ', rows[9]['detail'])
        self.assertTrue(rows[10].get('nested') and rows[10]['label'] == 'Follow up', 'a follow-up sits under its answer')
        failures = self.invoke('view','failures')['items']
        self.assertIn('Run the trader tests', [r['label'] for r in failures], 'a job reads by its title, not its command')
        explain = [r for r in failures if r['id']=='api-task-failure']
        self.assertEqual([r['argument'] for r in explain], ['a'*32], 'only failures inside an API project get the row')
        self.failed('run','api-task-ask','nope')
        self.failed('run','api-task-failure','../../bad')
        self.assertTrue(self.invoke('run','api-task-failure','a'*32)['ok'])
        launched = [c for c in self.calls() if c[0]=='setsid'][-1]
        question = Path(launched[-1])
        self.assertEqual(launched[2:-1], ['kitty','-e','fox-claude-api','ask','--project','trader','--root','/code/trader/sub','--question-file'])
        self.assertEqual(question.parent, Path(self.env['XDG_RUNTIME_DIR'])/'foxml/api-questions')
        self.assertEqual(question.stat().st_mode & 0o777, 0o600)
        self.assertIn('Command: make test', question.read_text())
        self.assertIn('assertion failed: boom', question.read_text())
        self.assertTrue(self.invoke('run','api-task-open','c'*32)['ok'], 'a saved result could not be reopened')
        self.assertEqual([c for c in self.calls() if c[0]=='setsid'][-1][2:], ['kitty','-e','fox-claude-api','open','c'*32])
        for action, tail in (('api-task-ask', ['ask','--project','trader']),
                             ('api-task-review', ['ask','--project','trader','--review-changes']),
                             ('api-task-pi', ['pi','--project','trader'])):
            self.assertTrue(self.invoke('run', action, 'trader')['ok'])
            self.assertEqual([c for c in self.calls() if c[0]=='setsid'][-1][5:], tail)
        self.assertTrue(self.invoke('run','api-task-follow','c'*32)['ok'])
        self.assertEqual([c for c in self.calls() if c[0]=='setsid'][-1][5:], ['ask','--project','trader','--follow','c'*32])
        self.failed('run','api-task-follow','d'*32)
        self.failed('run','api-task-pi','nope')

    def displays_fixture(self):
        modules = self.home/'.config/hypr/modules'
        modules.mkdir(parents=True)
        conf = ('monitor = eDP-1, preferred, 0x0, 1\n'
                'monitor = DP-2, preferred, -1440x-740, 1.5, transform, 3\n'
                'monitor = HDMI-A-1,1920x1080@60,1920x-420,1,transform,3,supports_hdr,-1\n'
                '\n# Catch-all\nmonitor = , preferred, auto, 1\n')
        lua = ('hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.00 })\n'
               'hl.monitor({ output = "DP-2", mode = "preferred", position = "-1440x-740", scale = 1.5, transform = 3 })\n'
               'hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@60", position = "1920x-420", scale = 1, transform = 3, supports_hdr = -1 })\n'
               '\n-- Catch-all\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })\n')
        (modules/'monitors.conf').write_text(conf)
        (modules/'monitors.lua').write_text(lua)
        layout = self.home/'.config/foxml/monitor-layout.conf'
        layout.parent.mkdir(parents=True, exist_ok=True)
        layout.write_text('PRIMARY="eDP-1"\n')
        monitors = [dict(name='DP-2', model='Acer', width=3840, height=2160, x=-1440, y=-740, scale=1.5, transform=3),
                    dict(name='HDMI-A-1', model='Side', width=1920, height=1080, x=1920, y=-420, scale=1.0, transform=3),
                    dict(name='eDP-1', model='Laptop', width=1920, height=1080, x=0, y=0, scale=1.0, transform=0)]
        self.state = {'exact': {'hyprctl\x1fmonitors\x1f-j': {'stdout': json.dumps(monitors)}}}
        return modules, conf, lua

    def test_displays_rescale_moves_neighbours_and_go_back_unless_kept(self):
        modules, conf, lua = self.displays_fixture()
        rows = self.invoke('view','displays')['items']
        heads = {r['label'].split(' · ')[0]: r for r in rows if r['id']=='display-edit' and ' · ' in r['label']}
        self.assertIn('scale 1.5', heads['DP-2']['detail'])
        self.assertIn('left of eDP-1', heads['DP-2']['detail'])
        self.assertIn('Scale 1.5 → 1.25', [r for r in rows if r['id']=='display-scale-down' and r['argument']=='DP-2'][0]['detail'])
        self.assertNotIn('display-side', [r['id'] for r in rows if r.get('argument')=='eDP-1'], 'the main screen has no side')

        done = self.invoke('run','display-scale-down','DP-2')
        self.assertIn('goes back in 15s', done['message'])
        self.assertFalse(done['close'])
        new_lua, new_conf = (modules/'monitors.lua').read_text(), (modules/'monitors.conf').read_text()
        self.assertIn('"DP-2", mode = "preferred", position = "-1728x-996", scale = 1.25, transform = 3 })', new_lua)
        self.assertIn('monitor = DP-2, preferred, -1728x-996, 1.25, transform, 3\n', new_conf)
        self.assertIn('position = "1920x-420", scale = 1, transform = 3, supports_hdr = -1', new_lua, 'a neighbour on the other side moved')
        self.assertEqual((modules/'monitors.lua.foxml-prev').read_text(), lua)
        self.assertEqual((modules/'monitors.conf.foxml-prev').read_text(), conf)
        pending = Path(self.env['XDG_RUNTIME_DIR'])/'foxml/display-pending'
        token = pending.read_text().strip()
        self.assertIn(['hyprctl','reload'], self.calls())
        self.assertIn(['setsid','-f',str(BINARY),'display-revert',token], self.calls())
        self.assertEqual(self.invoke('view','displays')['items'][0]['id'], 'display-keep')

        self.invoke('run','display-side','HDMI-A-1')
        self.assertEqual((modules/'monitors.lua.foxml-prev').read_text(), lua, 'a second change overwrote the saved layout')
        self.assertIn('"HDMI-A-1", mode = "1920x1080@60", position = "420x-1920"', (modules/'monitors.lua').read_text())

        self.assertTrue(self.invoke('run','display-keep')['ok'])
        self.assertFalse(pending.exists())
        self.failed('run','display-keep')
        self.assertTrue(self.invoke('run','display-undo')['ok'])
        self.assertEqual((modules/'monitors.lua').read_text(), lua)
        self.assertEqual((modules/'monitors.conf').read_text(), conf)
        self.failed('run','display-rotate','NOPE-1')

    def test_display_timer_goes_back_only_for_its_own_change(self):
        modules, conf, lua = self.displays_fixture()
        self.invoke('run','display-rotate','eDP-1')
        self.assertIn('"eDP-1", mode = "preferred", position = "0x0", scale = 1, transform = 3 })', (modules/'monitors.lua').read_text())
        pending = Path(self.env['XDG_RUNTIME_DIR'])/'foxml/display-pending'
        token = pending.read_text().strip()
        env = dict(self.env, FOXML_DISPLAY_REVERT_SECONDS='0')
        stale = subprocess.run([str(BINARY),'display-revert','f'*32], env=env, capture_output=True, timeout=10)
        self.assertEqual(stale.returncode, 0)
        self.assertNotEqual((modules/'monitors.lua').read_text(), lua, 'an older timer undid a newer change')
        timer = subprocess.run([str(BINARY),'display-revert',token], env=env, capture_output=True, timeout=10)
        self.assertEqual(timer.returncode, 0, timer.stderr)
        self.assertEqual((modules/'monitors.lua').read_text(), lua)
        self.assertFalse(pending.exists())
        self.assertTrue(any(c[0]=='notify-send' and 'Display layout went back' in c for c in self.calls()))

    def test_pointer_size_steps_save_one_block_and_apply_live(self):
        modules, _, _ = self.displays_fixture()
        self.env['XCURSOR_SIZE'] = '30'
        self.assertFalse(self.invoke('run','cursor-size-up')['close'])
        self.assertTrue(any(c[:2]==['hyprctl','setcursor'] and c[-1]=='36' for c in self.calls()))
        self.invoke('run','cursor-size-up')
        local = (modules/'local.lua').read_text()
        self.assertEqual(local.count('foxml:cursor-size-begin'), 1)
        self.assertIn('hl.env("XCURSOR_SIZE", "42")', local)
        self.assertIn('Pointer size 42 → 48', [r for r in self.invoke('view','displays')['items'] if r['id']=='cursor-size-up'][0]['detail'])

    def test_shortcut_reference_reads_tables_and_copies_only_known_keys(self):
        document = self.home / ".local/share/foxml/KEYBINDS.md"
        document.parent.mkdir(parents=True)
        document.write_text("## Desk\n### Windows\n| Key | Action |\n|-----|--------|\n| `ALT + /` | **Find** a `shortcut` |\nProse\n")
        rows = self.invoke("view", "cheatsheet")["items"]
        self.assertEqual([(row["label"], row["detail"]) for row in rows], [("ALT + /", "Find a shortcut · Desk · Windows")])
        self.assertEqual(self.invoke("run", "cheatsheet-copy", "ALT + /")["message"], "Copied: ALT + /")
        self.assertFalse(self.invoke("run", "cheatsheet-copy", "ALT + /")["close"])
        self.failed("run", "cheatsheet-copy", "not a shortcut")

    def test_sandbox_page_runs_fixed_commands(self):
        for name in ("fox-sandbox", "firefox", "chromium", "yazi", "less"):
            fake = self.bin / name
            fake.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
            fake.chmod(0o755)
        (self.bin / "chromium").unlink()
        rows = {row["argument"]: row for row in self.invoke("view", "sandbox")["items"]}
        self.assertFalse(rows["chromium"]["enabled"])
        self.assertTrue(rows["firefox"]["enabled"])
        self.assertTrue(self.invoke("run", "sandbox-launch", "yazi")["close"])
        self.assertEqual([call for call in self.calls() if call[0] == "setsid"][-1][-4:], ["fox-sandbox", "kitty", "-e", "yazi"])
        self.failed("run", "sandbox-launch", "chromium")
        self.failed("run", "sandbox-launch", "rm -rf")

    def test_failures_read_as_failures(self):
        self.state["commands"] = {"wpctl": {"exit": 1}}
        self.state["exact"] = {"wpctl\x1fget-volume\x1f@DEFAULT_AUDIO_SINK@": {"stdout": "Volume: 0.42\n"}}
        self.assertEqual(self.invoke("run", "volume-mute", expect=1)["message"], "Could not toggle mute")

    def test_every_page_answers_quickly_with_well_formed_rows(self):
        import re
        pages = subprocess.run([str(BINARY), "pages"], capture_output=True, text=True, timeout=5).stdout.split()
        self.assertGreaterEqual(len(pages), 20)
        source = (REPO / "src/fox-drawer/main.cpp").read_text()
        takes = set(re.findall(r'"([a-z-]+)"', source[source.index("argument_actions{"):source.index("};", source.index("argument_actions{"))]))
        for page in pages:
            with self.subTest(page=page):
                self.state_path.write_text(json.dumps(self.state))
                began = time.monotonic()
                out = subprocess.run([str(BINARY), "--config", str(self.config), "view", page], env=self.env,
                                     capture_output=True, text=True, timeout=10)
                self.assertLess(time.monotonic() - began, 2.0, "a page must not keep the drawer waiting")
                data = json.loads(out.stdout)
                if out.returncode != 0:
                    self.assertTrue(data.get("error"), "a page that fails says why")
                    continue
                self.assertFalse(data.get("error"))
                self.assertIsInstance(data.get("items"), list)
                for row in data["items"]:
                    self.assertTrue(row.get("id") and row.get("label") and row.get("kind"), row)
                    if "argument" in row and row.get("kind") == "action" and row.get("enabled", True):
                        self.assertIn(row["id"], takes, f"{row['id']} has an argument but no action takes one")

    def test_the_menu_names_real_pages_and_every_icon_has_a_drawing(self):
        pages = set(subprocess.run([str(BINARY), "pages"], capture_output=True, text=True, timeout=5).stdout.split())
        menu = json.loads((REPO / "shared/quickshell/foxml/menus.json").read_text())
        for group in menu["groups"]:
            for entry in group.get("items", []):
                if entry.get("kind") == "page":
                    self.assertIn(entry.get("page"), pages, f"menu item {entry.get('id')} opens a page the backend doesn't have")
        logic = (REPO / "shared/quickshell/foxml/DrawerLogic.js").read_text()
        drawn = js_object_keys(logic, "semantic")
        for icon in item_icons((REPO / "src/fox-drawer/main.cpp").read_text()):
            if icon and icon.isascii() and icon != "app-launch":
                self.assertIn(icon, drawn, f'icon "{icon}" has no paper drawing, so it shows a text glyph or a system icon')
        import re
        art = REPO / "templates/quickshell/foxml"
        for name in set(re.findall(r':\s*"([a-z-]+)"', logic[logic.index("var semantic = {"):logic.index("};", logic.index("var semantic = {"))])):
            self.assertTrue((art / f"paper-icon-{name}.svg").exists(), f"paper-icon-{name}.svg is missing")

    def test_models_page_switches_the_agent_and_removes_a_model_for_good(self):
        gguf = self.home / ".local/share/fox-llm/gguf"; gguf.mkdir(parents=True)
        for name, size in (("big:35b", 3000), ("small:4b", 2000), ("spare:9b", 1000)):
            (gguf / f"{name}.gguf").write_bytes(b"x" * size)
        llm = self.home / ".config/foxml/llm"; llm.mkdir(parents=True)
        (llm / "roles.conf").write_text("# roles\nagent big:35b llama ctx=131072\nquick small:4b llama\n")
        (llm / "llama-presets.ini").write_text("[big:35b]\n[small:4b]\n")
        rows = self.invoke("view", "models")["items"]
        use = {r["label"]: r for r in rows if r["id"] == "model-agent"}
        self.assertEqual(list(use), ["big:35b", "small:4b", "spare:9b"], "largest first")
        self.assertFalse(use["big:35b"]["enabled"])
        self.assertIn("the quick model", use["small:4b"]["detail"])
        self.assertIn("no role · not served", use["spare:9b"]["detail"])
        self.failed("run", "model-agent", "spare:9b")  # no confirmation
        self.assertTrue(self.invoke("run", "model-agent", "spare:9b", "--confirm")["ok"])
        self.assertEqual((llm / "roles.conf").read_text(), "# roles\nagent spare:9b llama\nquick small:4b llama\n", "the server kept, the old ctx dropped")
        self.assertTrue(list(llm.glob("roles.conf.bak-*")), "the old roles file is kept")
        remove = {r["argument"]: r for r in self.invoke("view", "models")["items"] if r["id"] == "model-remove" and "argument" in r}
        self.assertFalse(remove["small:4b"]["enabled"], "a role uses it")
        self.assertEqual(self.failed("run", "model-remove", "small:4b", "--confirm")["message"], "A role uses small:4b; give that role another model first")
        self.failed("run", "model-remove", "big:35b")  # no confirmation
        self.assertTrue(self.invoke("run", "model-remove", "big:35b", "--confirm")["ok"])
        self.assertFalse((gguf / "big:35b.gguf").exists())
        self.assertTrue((llm / "gguf-models.txt").read_text().endswith("-big:35b\n"), "skipped by the nightly update")
        self.failed("run", "model-remove", "../../etc/passwd", "--confirm")

    def test_backups_page_restores_only_what_has_a_script_and_prunes_old_ones(self):
        root = self.home / ".local/state/foxml"
        for i in range(12):
            folder = root / f"theme-backup-202611{i+1:02d}-120000-try{i}"; folder.mkdir(parents=True)
            (folder / "kitty.conf").write_text("x")
        good = root / "theme-backup-20261130-120000"; good.mkdir()
        (good / "manifest").write_text("restore|/x\n"); (good / "restore.sh").write_text("#!/bin/bash\n")
        rows = self.invoke("view", "backups")["items"]
        self.assertEqual(rows[0]["id"], "backup-prune")
        self.assertEqual((rows[1]["id"], rows[1]["label"], rows[1]["confirm"]), ("backup-restore", "theme", True), "newest first; it can be restored")
        self.assertEqual(rows[2]["id"], "backup-open", "a plain copy only opens")
        self.failed("run", "backup-restore", "theme-backup-20261101-120000-try0", "--confirm")
        self.failed("run", "backup-restore", "../../../etc", "--confirm")
        self.assertTrue(self.invoke("run", "backup-prune", "--confirm")["ok"])
        left = sorted(p.name for p in root.iterdir())
        self.assertEqual(len(left), 10)
        self.assertIn("theme-backup-20261130-120000", left)
        self.assertNotIn("theme-backup-20261101-120000-try0", left, "the oldest go")

    def test_startup_page_switches_off_your_own_and_only_lists_the_system(self):
        listing = "fox-pulse.service enabled enabled\nfox-tripwire.service enabled enabled\n"
        self.state["exact"] = {
            "systemctl\x1f--user\x1flist-unit-files\x1f--state=enabled\x1f--type=service,timer\x1f--no-legend\x1f--plain": {"stdout": listing},
            "systemctl\x1f--user\x1fis-active\x1ffox-pulse.service": {"stdout": "active\n"},
            "systemctl\x1flist-unit-files\x1f--state=enabled\x1f--type=service\x1f--no-legend\x1f--plain": {"stdout": "greetd.service enabled enabled\n"},
        }
        auto = self.home / ".config/autostart"; auto.mkdir(parents=True)
        (auto / "blueman.desktop").write_text("[Desktop Entry]\nName=Blueman\nExec=blueman-applet\n")
        rows = self.invoke("view", "startup")["items"]
        by = {(r["id"], r["label"]): r for r in rows}
        self.assertEqual(by[("startup-user", "fox-pulse.service")]["detail"], "running")
        self.assertIn("security watcher", by[("startup-user", "fox-tripwire.service")]["detail"])
        self.assertFalse(by[("startup-system", "greetd.service")]["enabled"], "system services are listed, never switched here")
        self.failed("run", "startup-system", "greetd.service", "--confirm")
        self.failed("run", "startup-user", "fox-pulse.service")
        self.assertTrue(self.invoke("run", "startup-user", "fox-pulse.service", "--confirm")["ok"])
        self.assertIn(["systemctl", "--user", "disable", "--now", "fox-pulse.service"], self.calls())
        self.assertTrue(self.invoke("run", "startup-autostart", "blueman.desktop", "--confirm")["ok"])
        self.assertIn("Hidden=true", (auto / "blueman.desktop").read_text())
        self.assertNotIn(("startup-autostart", "Blueman"), {(r["id"], r["label"]) for r in self.invoke("view", "startup")["items"]})

    def test_storage_page_measures_in_the_background_and_reads_the_result(self):
        self.real("timeout")
        self.env["DRAWER_TEST_REAL_DU"] = shutil.which("du")
        du = self.bin / "du"
        # Keep real measurements inside the fixture. The production scan also
        # visits / and system caches, which can take minutes on a CI runner.
        du.write_text(f"#!{sys.executable}\n" + r'''
import json
import os
from pathlib import Path
import sys

with open(os.environ['DRAWER_TEST_CALLS'], 'a') as log:
    log.write(json.dumps(['du', *sys.argv[1:]]) + '\n')
target = Path(sys.argv[-1]).resolve()
if target.is_relative_to(Path.home().resolve()):
    os.execv(os.environ['DRAWER_TEST_REAL_DU'], [os.environ['DRAWER_TEST_REAL_DU'], *sys.argv[1:]])
print('0\t' + str(target))
''')
        du.chmod(0o755)
        for name, size in [(".cache/pip/wheel", 60_000_000), (".local/share/Trash/files/old", 70_000_000)]:
            path = self.home / name
            path.parent.mkdir(parents=True)
            with path.open("wb") as stream:
                stream.truncate(size)  # du -b measures apparent size; no large writes needed.
        self.env["XDG_CACHE_HOME"] = str(self.home / ".cache")
        rows = self.invoke("view", "storage")["items"]
        self.assertEqual(rows[0]["label"], "Measure the disk")
        out = subprocess.run([str(BINARY), "storage-scan"], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(["du", "-sxb", "/"], self.calls(), "the whole-disk probe uses the fixture too")
        measured = json.loads((self.home / ".cache/foxml/storage.json").read_text())
        by_kind = {kind["id"]: kind for kind in measured["kinds"]}
        self.assertGreaterEqual(by_kind["dev"]["bytes"], 60_000_000)
        self.assertGreaterEqual(by_kind["trash"]["bytes"], 70_000_000)
        rows = self.invoke("view", "storage")["items"]
        labels = [r["label"] for r in rows]
        self.assertIn("free of", labels[0])
        # Only disposable home folders contribute to the measured categories.
        self.assertLess(labels.index("Trash"), labels.index("Language and build caches"), "largest first")
        trash = next(r for r in rows if r["label"] == "Trash")
        self.assertEqual((trash["id"], trash["confirm"]), ("storage-empty-trash", True))
        self.failed("run", "storage-empty-trash")
        self.assertTrue(self.invoke("run", "storage-empty-trash", "--confirm")["ok"])
        self.assertIn(["gio", "trash", "--empty"], self.calls())
        self.failed("run", "storage-open", "/etc")
        self.assertFalse((Path(self.env["XDG_RUNTIME_DIR"]) / "foxml-storage-scan.lock").exists())

    def test_updates_that_touch_boot_login_or_graphics_come_first(self):
        cache = Path(self.env["XDG_RUNTIME_DIR"]) / "foxml-waybar"
        cache.mkdir(parents=True)
        (cache / "updates.list").write_text("python-regex 1 -> 2\nlinux 6.1 -> 6.2\nopencode 2.2.5-1 -> 2.2.6-1\n"
                                            "nvidia-open-dkms 590 -> 595\npam 1.7 -> 1.8\nhyprland 0.57 -> 0.58\n\n")
        rows = [r for r in self.invoke("view", "updates")["items"] if r["id"] == "updates-terminal" and r.get("enabled") is False]
        self.assertEqual(rows[0]["label"], "4 updates need a little care")
        careful = [r["label"].split()[0] for r in rows if r.get("careful")]
        self.assertEqual(careful, ["linux", "nvidia-open-dkms", "pam", "hyprland"], "in the order listed, before the rest")
        self.assertIn("reboot after", rows[1]["detail"])
        self.assertIn("keep a terminal open", next(r for r in rows if r["label"].startswith("pam"))["detail"])
        self.assertEqual([r["label"].split()[0] for r in rows[-2:]], ["python-regex", "opencode"])
        self.assertEqual(next(r for r in rows if r["label"].startswith("opencode"))["detail"], "Pending package")

    def test_project_cards_show_dirty_and_unpushed_work(self):
        self.real("git", "timeout")
        environment = {**os.environ, "HOME": str(self.home), "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_AUTHOR_NAME": "Me", "GIT_AUTHOR_EMAIL": "me@example.test",
                       "GIT_COMMITTER_NAME": "Me", "GIT_COMMITTER_EMAIL": "me@example.test"}
        git = lambda where, *argv: subprocess.run(["git", "-C", str(where), *argv], check=True, capture_output=True, env=environment)
        remote = self.home / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True, env=environment)
        for name in ("clean", "dirty", "ahead"):
            repo = self.home / "code" / name
            repo.mkdir(parents=True)
            git(repo, "init", "-q", "-b", "main")
            (repo / "a.txt").write_text("a\n")
            git(repo, "add", "a.txt"); git(repo, "commit", "-q", "-m", "a")
        git(self.home / "code/ahead", "remote", "add", "origin", str(remote))
        git(self.home / "code/ahead", "push", "-q", "-u", "origin", "main")
        git(self.home / "code/ahead", "commit", "-q", "--allow-empty", "-m", "not pushed yet")
        (self.home / "code/dirty/a.txt").write_text("changed\n")
        (self.home / "code/clean/new-untracked.txt").write_text("untracked files don't count\n")
        cards = {row["label"]: row for row in self.invoke("view", "projects")["items"]}
        self.assertEqual(cards["dirty"].get("git"), "✎ dirty")
        self.assertEqual(cards["ahead"].get("git"), "↑1 unpushed")
        self.assertNotIn("git", cards["clean"])
        self.assertTrue(cards["dirty"]["detail"].endswith(" · ✎ dirty"))
        self.assertFalse((self.home / "code/dirty/.git/index.lock").exists())

    def test_commit_days_counts_my_commits_in_that_month(self):
        self.real("git", "timeout")
        project = self.home / "code/notebook"
        project.mkdir(parents=True)
        (project / ".git").mkdir()
        environment = {**os.environ, "HOME": str(self.home)}
        run = lambda *argv, **extra: subprocess.run(["git", "-C", str(project), *argv], check=True, capture_output=True, env={**environment, **extra})
        (project / ".git").rmdir()
        run("init", "-q")
        run("config", "user.email", "me@example.test")
        run("config", "user.name", "Me")
        for day, email in (("2026-10-31", "me@example.test"), ("2026-11-03", "me@example.test"), ("2026-11-03", "me@example.test"),
                           ("2026-11-04", "someone@example.test"), ("2026-12-01", "me@example.test")):
            stamp = day + "T12:00:00"
            run("commit", "-q", "--allow-empty", "-m", day, f"--author=Me <{email}>", GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp)
        self.assertEqual(self.invoke("commit-days", "2026-11")["days"], [3])
        self.assertEqual(self.invoke("commit-days", "2026-12")["days"], [1])
        self.assertEqual(self.invoke("commit-days", "2026-13", expect=1)["ok"], False)

    def test_commit_garden_counts_a_year_of_days_written(self):
        import datetime
        self.real("git", "timeout")
        project = self.home / "code/notebook"
        project.mkdir(parents=True)
        environment = {**os.environ, "HOME": str(self.home)}
        run = lambda *argv, **extra: subprocess.run(["git", "-C", str(project), *argv], check=True, capture_output=True, env={**environment, **extra})
        run("init", "-q")
        run("config", "user.email", "me@example.test")
        run("config", "user.name", "Me")
        today = datetime.date.today()
        def commit(day, subject, email="me@example.test", committed=None):
            stamp = day.isoformat() + "T12:00:00"
            run("commit", "-q", "--allow-empty", "-m", subject, f"--author=Me <{email}>",
                GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=(committed or day).isoformat() + "T12:30:00")
        # in date order, as histories are: git's --since stops at the first commit older than the cutoff
        commit(today - datetime.timedelta(days=400), "long ago")
        commit(today - datetime.timedelta(days=1), "yesterday")
        run("checkout", "-q", "-b", "rebased")
        # a rebase: the same commit again, written yesterday, committed today on another branch
        commit(today - datetime.timedelta(days=1), "yesterday", committed=today)
        run("checkout", "-q", "-")
        for n in range(3): commit(today, f"today {n}")
        commit(today, "not mine", email="someone@example.test")
        garden = self.invoke("view", "garden")
        self.assertEqual((garden["title"], garden["garden"]["counts"][-2:]), ("Commit garden", [1, 3]))
        start = datetime.date.fromisoformat(garden["garden"]["start"])
        self.assertEqual(start.weekday(), 6, "the garden starts on a Sunday")
        self.assertEqual(len(garden["garden"]["counts"]) - 1, (today - start).days)
        self.assertGreaterEqual((today - start).days, 364)
        self.assertEqual(sum(garden["garden"]["counts"]), 4, "others' commits, old ones and rebased copies stay out")
        self.assertEqual(self.invoke("commit-days", today.strftime("%Y-%m"))["today"], 3)
        self.assertEqual(garden["garden"]["green"], [])
        now = int(time.time())
        self.state = {"commands": {"fox-work": {"stdout": json.dumps([
            dict(state="passed", testRun=True, failedBefore=3, ended=now),
            dict(state="passed", testRun=True, failedBefore=1, ended=now - 86400),
            dict(state="passed", testRun=False, failedBefore=4, ended=now - 86400)])}}}
        green = self.invoke("view", "garden")["garden"]["green"]
        self.assertEqual(green, [len(garden["garden"]["counts"]) - 1], "only a test that failed twice or more and then passed")

    def test_search_rows_show_live_values(self):
        self.state["commands"] = {"wpctl": {"stdout": "Volume: 0.42\n"}}
        self.write_config([{"id": "sound", "label": "Sound", "icon": "music", "description": "", "items": [{"id": "volume", "label": "Volume", "kind": "slider"}]}])
        self.assertEqual(self.invoke("view", "search", "volume")["items"][0]["value"], 42)

    def test_today_leads_the_top_level_list_with_the_day(self):
        (self.home / ".todo").write_text("\n  water the fern  \nthen rest\n")
        data = self.invoke("view", "root")
        self.assertEqual((data["items"][0]["id"], data["items"][0]["page"]), ("today", "root"))
        self.assertEqual(data["today"]["todo"], "water the fern")
        self.assertEqual(data["today"]["notes"], 0)

    def test_invalid_dynamic_arguments_fail_without_mutations(self):
        for action, argument in (
            ("window-focus", "0xabc;exec touch injected"),
            ("window-focus", "0xdeadbeef"),
            ("bluetooth-connect", "AA:BB:CC:DD:EE:FF;touch injected"),
            ("clipboard-restore", "17;touch injected"),
            ("clipboard-restore", "-1"),
            ("theme-set", "../../evil"),
            ("app-launch", "/tmp/not-an-application.desktop"),
            ("audio-output", "--server=bad"),
        ):
            with self.subTest(action=action):
                self.failed("run", action, argument)
        for call in self.calls():
            self.assertFalse(call[0] in ("setsid", "gio", "wl-copy", "systemctl"), call)
            self.assertFalse(call[0] == "hyprctl" and "dispatch" in call, call)
            self.assertFalse(call[0] == "bluetoothctl" and "connect" in call, call)
            self.assertFalse(call[0] == "pactl" and "set-default-sink" in call, call)

    def test_clipboard_binary_is_not_shell_or_text_decoded(self):
        binary = b"\x89PNG\r\n\x1a\n\x00\xff$(touch injected)\x00\n"
        self.state["clipboard_data"] = base64.b64encode(binary).decode()
        result = self.invoke("run", "clipboard-restore", "18")
        self.assertTrue(result["ok"])
        self.assertEqual(self.clipboard_path.read_bytes(), binary)
        self.assertFalse((self.root / "injected").exists())

    def test_clipboard_image_preview_preserves_bytes_and_metadata_is_data(self):
        encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
        metadata = "[[ binary data 68 B png 1x1 $(touch INJECTED); ]]"
        self.state["clipboard"] = "17\ta note\n18\t" + metadata
        self.state["clipboard_data"] = encoded
        images = self.invoke("view", "clipboard-images")["items"]
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["argument"], "18")
        self.assertEqual(images[0]["detail"], metadata)
        prefix, data = images[0]["image"].split(",", 1)
        self.assertEqual(prefix, "data:image/png;base64")
        self.assertEqual(base64.b64decode(data), base64.b64decode(encoded))
        self.assertIn(["cliphist", "decode", "18"], self.calls())
        self.assertFalse(any(call[0] in ("setsid", "wl-copy") for call in self.calls()))

    # ── Polish round 3: regrouped menu, search words, keys, shortcut order, warm toggles, notes, thumbnails ──

    def shipped_menu(self):
        return json.loads((REPO / "shared/quickshell/foxml/menus.json").read_text())

    def test_the_shipped_menu_has_a_workbench_and_every_page_opens(self):
        self.config.write_text((REPO / "shared/quickshell/foxml/menus.json").read_text())
        menu = self.shipped_menu()
        groups = {g["id"]: [i["id"] for i in g["items"]] for g in menu["groups"]}
        self.assertEqual(list(groups)[:2], ["desk", "workbench"])
        self.assertLessEqual(len(groups["desk"]), 10, "the desk keeps only everyday things")
        for moved in ("projects", "worktrees", "agents", "jobs", "test-results", "reviews", "next-steps", "failures", "models", "api-credits", "garden"):
            self.assertIn(moved, groups["workbench"])
        self.assertNotIn("api-tasks", [i for ids in groups.values() for i in ids], "asking lives on the one API page")
        for look in ("wallpapers", "themes", "wallpaper-next", "wallpaper-sync", "earlier-notes", "brightness", "displays"):
            self.assertIn(look, groups["comfort"])
        self.assertIn("calendar", groups["desk"])
        self.assertIn("color-picker", groups["desk"], "picking a colour collects it, like the clipboard")
        for group in menu["groups"]:
            if group["id"] in ("desk", "workbench", "comfort", "system"):
                sections = [i.get("section") for i in group["items"]]
                self.assertTrue(all(sections), group["id"] + ": every shipped row names its heading")
                runs = [s for n, s in enumerate(sections) if n == 0 or sections[n - 1] != s]
                self.assertEqual(len(runs), len(set(runs)), group["id"] + ": each heading's rows sit together")
        system = self.invoke("view", "system")["items"]
        self.assertEqual([r["label"] for r in system if r["kind"] == "heading"], ["upkeep", "power", "safety", "help"])
        self.assertEqual(system[0]["kind"], "heading")
        self.assertFalse([r for r in self.invoke("view", "system", "upd")["items"] if r["kind"] == "heading"], "a search reads as a plain list")
        root = self.invoke("view", "root")
        self.assertEqual([r["page"] for r in root["items"][1:]], list(groups))
        self.assertEqual(next(r for r in root["items"] if r["id"] == "workbench")["summary"], "all quiet on the bench")
        for group in menu["groups"]:
            with self.subTest(group=group["id"]):
                data = subprocess.run([str(BINARY), "--config", str(self.config), "view", group["id"]], env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(json.loads(data.stdout)["title"], group["label"])
        for entry in (i for g in menu["groups"] for i in g["items"] if i["kind"] == "page"):
            with self.subTest(page=entry["page"]):
                data = json.loads(subprocess.run([str(BINARY), "--config", str(self.config), "view", entry["page"]], env=self.env,
                                                 capture_output=True, text=True, timeout=10).stdout)
                self.assertNotEqual(data.get("error"), "Unknown drawer page")
        opened = self.invoke("run", "calendar")
        self.assertEqual((opened["ok"], opened["page"]), (True, "calendar"))
        for favorite in menu["favorites"]:
            group, item = favorite.split("/")
            self.assertIn(item, groups[group])

    def test_every_menu_icon_and_group_icon_has_a_paper_drawing(self):
        if not shutil.which("node"):
            self.skipTest("node is not installed")
        script = ("const fs=require('fs'),vm=require('vm');const c=vm.createContext({});"
                  "vm.runInContext(fs.readFileSync(process.argv[1],'utf8').replace(/^\\.pragma library\\s*/,''),c);"
                  "const m=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));"
                  "console.log(JSON.stringify([...m.groups,...m.groups.flatMap(g=>g.items)].map(e=>[e.id,c.paperIcon(e)])))")
        out = subprocess.run(["node", "-e", script, str(REPO / "shared/quickshell/foxml/DrawerLogic.js"), str(REPO / "shared/quickshell/foxml/menus.json")],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stderr)
        for entry, icon in json.loads(out.stdout):
            with self.subTest(id=entry):
                self.assertTrue(icon, f"{entry} has no paper drawing")
                self.assertTrue((REPO / "templates/quickshell/foxml" / icon).exists(), icon)

    def test_keys_must_be_short_text_and_keywords_a_list_of_words(self):
        base = {"id": "connections", "label": "Connections", "items": [{"id": "wifi", "label": "Wi-Fi", "kind": "page", "page": "wifi"}]}
        for bad in ({"keys": ["alt"]}, {"keys": "x" * 80}, {"keywords": "wifi"}, {"keywords": [1]}, {"keywords": [""]}):
            with self.subTest(bad=bad):
                group = json.loads(json.dumps(base)); group["items"][0].update(bad)
                self.write_config([group])
                self.assertIn("error", self.invoke("view", "connections", expect=1))

    def test_search_finds_rows_by_keyword_id_and_hyphenless_words(self):
        self.write_config([
            {"id": "connections", "label": "Connections", "items": [
                {"id": "wifi", "label": "Wi-Fi", "detail": "Find a network nearby", "kind": "page", "page": "wifi", "keys": "alt ⇧ n", "keywords": ["wireless", "internet"]}]},
            {"id": "comfort", "label": "Comfort", "items": [
                {"id": "dnd", "label": "Do not disturb", "kind": "toggle", "keywords": ["notifications", "quiet"]}]},
            {"id": "system", "label": "System", "items": [
                {"id": "displays", "label": "Displays", "kind": "page", "page": "displays", "keywords": ["monitor", "resolution", "pointer"]}]}])
        found = lambda q: [r["id"] for r in self.invoke("view", "search", q)["items"] if r["id"] in ("wifi", "dnd", "displays")]
        for query, expected in (("wireless", ["wifi"]), ("WiFi", ["wifi"]), ("wi-fi", ["wifi"]), ("dnd", ["dnd"]), ("Notifications", ["dnd"]),
                                ("monitor", ["displays"]), ("pointer", ["displays"]), ("alt ⇧ n", ["wifi"]), ("nothing like it", [])):
            with self.subTest(query=query):
                self.assertEqual(found(query), expected)
        row = next(r for r in self.invoke("view", "search", "wireless")["items"] if r["id"] == "wifi")
        self.assertEqual(row["keys"], "alt ⇧ n")
        self.assertEqual(self.invoke("view", "connections")["items"][0]["keys"], "alt ⇧ n")
        self.assertEqual([r["id"] for r in self.invoke("view", "comfort", "quiet")["items"]], ["dnd"])

    def test_search_finds_an_app_by_its_desktop_keywords(self):
        apps = self.root / "system-data/applications"; apps.mkdir(parents=True)
        (apps / "paper.desktop").write_text("[Desktop Entry]\nType=Application\nName=Paper Reader\nGenericName=Web Browser\nKeywords=internet;www;\nExec=true\n")
        for query in ("www", "browser"):
            self.assertIn("Paper Reader", [r["label"] for r in self.invoke("view", "search", query)["items"] if r["id"] == "app-launch"])

    def keybinds(self, text):
        document = self.home / ".local/share/foxml/KEYBINDS.md"
        document.parent.mkdir(parents=True, exist_ok=True)
        document.write_text(text)

    def test_shortcut_reference_puts_the_desktop_first_and_leaves_stock_vim_out(self):
        table = "| Key | Action |\n|-----|--------|\n"
        self.keybinds("## Paper notebook details\n" + table + "| `ma` | Set bookmark a |\n### Quickshell drawers\n" + table + "| `j` / `k` | Move down / up |\n"
                      "## Core Vim\n### Movement\n" + table + "| `h/j/k/l` | Left / Down / Up / Right |\n"
                      "## Custom Keymaps (init.lua)\n### Telescope\n" + table + "| `Space ff` | Find files |\n"
                      "## Hyprland (ALT = mainMod)\n### Applications\n" + table + "| `ALT + Shift + N` | Wi-Fi networks |\n"
                      "## Tmux (Ctrl+a prefix)\n" + table + "| `Ctrl+a c` | New window |\n")
        rows = self.invoke("view", "cheatsheet")["items"]
        labels = [r["label"] for r in rows]
        self.assertEqual(labels[0], "ALT + Shift + N")
        self.assertLess(labels.index("ALT + Shift + N"), labels.index("Ctrl+a c"))
        self.assertLess(labels.index("Ctrl+a c"), labels.index("Space ff"))
        self.assertLess(labels.index("Ctrl+a c"), labels.index("ma"))
        self.assertEqual((labels[1], rows[1]["detail"]), ("j / k", "Move down / up · Paper notebook details · Quickshell drawers"),
                         "the drawer's own keys come straight after the desktop, a key pair in one cell read as one")
        self.assertNotIn("h/j/k/l", labels)
        found = self.invoke("view", "search", "wi-fi networks")["items"]
        self.assertIn(("cheatsheet-copy", "ALT + Shift + N"), [(r["id"], r["label"]) for r in found])
        self.assertFalse(any(r["id"] == "cheatsheet-copy" and r["label"] == "Space ff" for r in self.invoke("view", "search", "find files")["items"]),
                         "search offers the desktop's binds, not every editor key")
        self.assertTrue(self.invoke("run", "cheatsheet-copy", "ALT + Shift + N")["ok"])

    def kept(self, *args):
        """invoke, keeping what the fake services remember between runs."""
        data = self.invoke(*args)
        self.state = json.loads(self.state_path.read_text())
        return data

    def test_toggles_say_which_way_they_went(self):
        self.write_config([{"id": "sound", "label": "Sound", "items": [{"id": "volume-mute", "label": "Mute", "kind": "toggle"}]}])
        for action, said in (("volume-mute", "sound muted · a little quiet"), ("volume-mute", "sound is back"),
                             ("mic-mute", "microphone muted · just for you"), ("mic-mute", "microphone is listening again"),
                             ("wifi-toggle", "wi-fi off · resting the radio"), ("wifi-toggle", "wi-fi on"),
                             ("bluetooth-toggle", "bluetooth off"), ("bluetooth-toggle", "bluetooth on"),
                             ("dnd", "shh… notifications paused"), ("dnd", "notifications are back"),
                             ("power-profile", "balanced · as usual")):
            with self.subTest(action=action, said=said):
                self.assertEqual(self.kept("run", action)["message"], said)
        self.state["nightlight_running"] = True
        self.assertEqual(self.kept("run", "nightlight")["message"], "night light on · a warmer glow")
        self.assertEqual(self.kept("run", "nightlight")["message"], "night light off")

    def note(self, id, summary="Claude · paper", body="Turn complete", app="Claude", urgency="normal"):
        return {"id": id, "app_name": app, "app_icon": None, "category": None, "desktop_entry": None,
                "summary": summary, "body": body, "urgency": urgency, "actions": {}}

    def test_coming_back_from_quiet_counts_the_notes_that_arrived(self):
        self.state["mako_history"] = [self.note(5)]
        self.assertEqual(self.kept("run", "dnd")["message"], "shh… notifications paused")
        self.state["mako_history"] = [self.note(8, app="fox-osd"), self.note(7), self.note(5)]
        self.state["mako_list"] = [self.note(9, summary="still showing")]
        self.assertEqual(self.kept("run", "dnd")["message"], "notifications are back · 2 notes while you were quiet")
        notices = [c for c in self.calls() if c[0] == "notify-send"]
        self.assertEqual(len(notices), 1, "one gentle notice, not every note again")
        self.assertIn("2 notes while you were quiet", notices[0])
        self.kept("run", "dnd")
        self.assertEqual(self.kept("run", "dnd")["message"], "notifications are back", "nothing new, nothing said")
        self.assertEqual(len([c for c in self.calls() if c[0] == "notify-send"]), 1)

    def test_earlier_notes_list_newest_first_and_open_or_clear(self):
        body = '<span foreground="#353238">Turn complete &amp; ready</span>\n<span font_size="smaller">tmux: paper:1.2</span>'
        self.state["mako_history"] = [self.note(4, summary="Saved", body="a <b>little</b> file", app="foxml"),
                                      self.note(9, body=body), self.note(6, app="fox-osd", summary="42%"),
                                      self.note(7, summary="Battery low", app="", urgency="critical")]
        self.assertEqual(subprocess.run([str(BINARY), "note-arrived", "9"], env=self.env, timeout=5).returncode, 0)
        self.assertNotEqual(subprocess.run([str(BINARY), "note-arrived", "9;rm"], env=self.env, timeout=5).returncode, 0)
        rows = self.invoke("view", "earlier-notes")["items"]
        self.assertEqual([r["argument"] for r in rows[:-1]], ["9", "7", "4"])
        self.assertEqual(rows[0]["label"], "Claude · paper")
        self.assertTrue(rows[0]["detail"].startswith("Claude · Turn complete & ready · today "), rows[0]["detail"])
        self.assertTrue(rows[1]["careful"])
        self.assertEqual(rows[2]["detail"], "foxml · a little file")
        self.assertEqual(rows[-1]["id"], "note-clear")
        notes = Path(self.env["XDG_RUNTIME_DIR"]) / "foxml/notes.json"
        self.assertEqual(notes.stat().st_mode & 0o777, 0o600)
        self.invoke("run", "note-open", "4")
        self.assertEqual([c for c in self.calls() if c[0] == "notify-send"][-1], ["notify-send", "-a", "foxml", "-u", "normal", "--", "Saved", "a <b>little</b> file"])
        self.invoke("run", "note-open", "9")
        self.assertIn(["tmux", "select-pane", "-t", "paper:1.2"], self.calls())
        self.failed("run", "note-open", "6")
        self.failed("run", "note-open", "12")
        self.assertEqual(self.invoke("run", "note-clear")["message"], "tucked away.")
        self.assertEqual(self.invoke("view", "earlier-notes")["items"], [])
        self.state["mako_history"].append(self.note(10, summary="new after the clear"))
        self.assertEqual([r["argument"] for r in self.invoke("view", "earlier-notes")["items"][:-1]], ["10"])
        self.state["mako_history"] = [self.note(2, summary="mako started again")]
        self.assertEqual([r["label"] for r in self.invoke("view", "earlier-notes")["items"][:-1]], ["mako started again"],
                         "a mako restart counts ids from one again, so an old clear no longer hides them")

    def test_clipboard_thumbnails_are_made_once_and_go_with_their_entry(self):
        fake = self.bin / "magick"; fake.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND); fake.chmod(0o755)
        thumb = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
        self.state["commands"] = {"magick": {"base64": base64.b64encode(thumb).decode()}}
        self.state["clipboard"] = "17\ta note\n18\t[[ binary data 68 B png 1x1 ]]\n19\t[[ binary data 9 B txt ]]"
        self.state["clipboard_data"] = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"pixels").decode()
        first = self.invoke("view", "clipboard-images")["items"]
        second = self.invoke("view", "clipboard-images")["items"]
        self.assertEqual(first, second)
        self.assertEqual(base64.b64decode(second[0]["image"].split(",", 1)[1]), thumb)
        decodes = [c for c in self.calls() if c[0] == "cliphist" and c[1] == "decode"]
        self.assertEqual(sorted(c[2] for c in decodes), ["18", "19"], "each entry is decoded once, then read from the cache")
        self.assertEqual(len([c for c in self.calls() if c[0] == "magick"]), 2)
        cache = Path(self.env["XDG_RUNTIME_DIR"]) / "foxml/clip-thumbs"
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        self.assertEqual({f.name: f.stat().st_mode & 0o777 for f in cache.iterdir()}, {"18.thumb": 0o600, "19.thumb": 0o600})
        self.state["clipboard"] = "20\t[[ binary data 68 B png 1x1 ]]"
        self.invoke("view", "clipboard-images")
        self.assertEqual(sorted(f.name for f in cache.iterdir()), ["20.thumb"])

    def test_windows_say_their_workspace_and_screen(self):
        monitors = [{"id": 0, "name": "eDP-1", "width": 1920, "height": 1080, "x": 0, "y": 0, "scale": 1.0, "transform": 0},
                    {"id": 1, "name": "HDMI-A-1", "width": 2560, "height": 1440, "x": -2560, "y": 0, "scale": 1.0, "transform": 0}]
        (self.home / ".config/foxml").mkdir(parents=True)
        (self.home / ".config/foxml/monitor-layout.conf").write_text('PRIMARY="eDP-1"\n')
        self.state["exact"] = {"hyprctl\x1fmonitors\x1f-j": {"stdout": json.dumps(monitors)}}
        self.state["windows"] = [
            {"address": "0xa1", "title": "notes", "class": "kitty", "workspace": {"id": 3, "name": "3"}, "monitor": 1},
            {"address": "0xa2", "title": "web", "class": "firefox", "workspace": {"id": 1, "name": "1"}, "monitor": 0},
            {"address": "0xa3", "title": "tucked", "class": "kitty", "workspace": {"id": -98, "name": "special:scratch"}, "monitor": 0}]
        rows = self.invoke("view", "windows")["items"]
        self.assertEqual([r["detail"] for r in rows], ["kitty · workspace 3 · left screen", "firefox · workspace 1 · main screen",
                                                      "kitty · tucked in the scratchpad · main screen"])
        self.assertIn("workspace 3 · left screen", next(r for r in self.invoke("view", "search", "notes")["items"] if r["id"] == "window-focus")["detail"])
        self.state["exact"] = {"hyprctl\x1fmonitors\x1f-j": {"stdout": json.dumps(monitors[:1])}}
        self.assertEqual(self.invoke("view", "windows")["items"][0]["detail"], "kitty · workspace 3", "one screen needs no words")


if __name__ == "__main__":
    unittest.main()
