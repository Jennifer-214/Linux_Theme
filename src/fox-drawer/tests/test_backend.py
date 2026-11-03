#!/usr/bin/env python3
"""Exercise the JSON/argv boundary using only disposable, fake desktop services."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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
if name == 'wpctl'  and args[:1] == ['get-volume']:
    print('Volume: 0.42')
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
        print(state.get('tmux_clients', '123\t/dev/pts/fixture\t99999999'))
    elif args[:1] == ['display-message']:
        print('99999999')
elif name == 'pactl' and 'sinks' in args:
    print(json.dumps([{'index':1, 'name':'desk.output', 'description':'Desk speakers', 'state':'RUNNING', 'mute':False}]))
elif name == 'pactl' and 'get-default-sink' in args:
    print('desk.output')
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
        print('Controller 00:11:22:33:44:55\n\tPowered: yes')
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
    print('default')
elif name == 'dunstctl' and args[:1] == ['is-paused']:
    print('false')
elif name == 'pgrep':
    sys.exit(0 if args[-1:] == ['hyprsunset'] and state.get('nightlight_running') else 1)
elif name == 'lsblk':
    print(json.dumps(state.get('drives', {'blockdevices': []})))
elif name == 'xdg-user-dir':
    print(state.get('download_dir', str(Path.home() / 'Downloads')))
elif name == 'udisksctl' and args[:1] == ['mount'] and state.get('after_mount'):
    state['drives'] = state['after_mount']
    Path(os.environ['DRAWER_TEST_STATE']).write_text(json.dumps(state))
'''


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
            "gio", "setsid", "kitty", "bash", "systemctl", "loginctl", "pkill", "pgrep", "hyprsunset", "makoctl",
            "dunstctl", "powerprofilesctl", "playerctl", "hyprpicker", "awww", "notify-send", "tmux", "fox-hl", "pass", "fox-password-copy", "quickshell", "fox-desktop-menu",
            "checkupdates", "informant", "fox-wallpaper", "fox-lock", "fox-clean", "fox", "hypridle", "lsblk", "udisksctl", "xdg-open", "xdg-user-dir",
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
        newer=old|{"message":"newer note"}
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

    def test_agent_focuses_the_client_window_instead_of_an_arbitrary_kitty(self):
        self.env.pop("TMUX",None)
        pid=os.getpid()
        self.state.update(tmux_clients=f"123\t/dev/pts/selected\t{pid}",windows=[
            {"address":"0x11","pid":99999999,"class":"kitty"},
            {"address":"0x22","pid":pid,"class":"kitty"}])
        queue=Path(self.env["XDG_RUNTIME_DIR"])/"foxml-agent-queue.jsonl"
        queue.write_text(json.dumps({"tmux":"paper:1.2","source":"fixture"})+"\n")
        key=self.invoke("view","agents")["items"][0]["argument"]
        self.assertTrue(self.invoke("run","agent-jump",key)["ok"])
        self.assertIn(["fox-hl","dispatch","hl.dsp.focus({ window = 'address:0x22' })","focuswindow address:0x22"],self.calls())
        self.assertFalse(any('class:kitty' in argument for call in self.calls() for argument in call))

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
        self.assertEqual(data["items"][0]["summary"], "42% · speakers")
        self.assertEqual(data["favorites"][0]["id"], "volume")
        self.assertEqual(data["favorites"][0]["value"], 42)
        self.assertEqual(data["favorites"][0]["group"], "sound")

    def test_unavailable_summary_does_not_fabricate_zero(self):
        self.state = {"commands": {"wpctl": {"exit": 1}}}
        data = self.invoke("view", "root")
        self.assertEqual(data["items"][0]["summary"], "Audio unavailable")
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


if __name__ == "__main__":
    unittest.main()
