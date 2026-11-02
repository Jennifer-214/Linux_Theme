#!/usr/bin/env python3
"""Exercise the JSON/argv boundary using only disposable, fake desktop services."""

import base64
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
if name == 'wpctl' and args[:1] == ['get-volume']:
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
    sys.exit(1)
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
            "gio", "setsid", "kitty", "systemctl", "loginctl", "pkill", "pgrep", "wlsunset", "makoctl",
            "dunstctl", "powerprofilesctl", "playerctl", "hyprpicker", "awww", "notify-send", "rofi-pass",
            "checkupdates", "informant", "fox-wallpaper", "fox-lock", "fox-clean", "fox", "hypridle",
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
        self.assertIn(["hyprctl", "dispatch", "focuswindow", "address:0xabc123"], self.calls())

    def test_valid_volume_set_and_json_stdout(self):
        data = self.invoke("run", "volume", "55")
        self.assertTrue(data["ok"])
        calls = self.calls()
        self.assertTrue(any(call[0] == "wpctl" and "set-volume" in call and "55%" in call for call in calls), calls)

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
