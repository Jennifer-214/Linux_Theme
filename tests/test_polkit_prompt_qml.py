"""The paper polkit prompt, driven by a pretend request: no polkit, no session agent touched."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

SHELL = r'''
import QtQuick
import Quickshell
ShellRoot {
    id: root
    Theme { id: theme }
    QtObject {
        id: fakeFlow
        property string actionId: "org.freedesktop.login1.reboot-multiple-sessions"
        property string message: "Authentication is required to reboot the system."
        property string inputPrompt: "Password: "
        property bool responseVisible: false
        property bool isResponseRequired: true
        property string supplementaryMessage: ""
        property bool supplementaryIsError: false
        property var submitted: []
        property int cancelled: 0
        signal authenticationFailed()
        function submit(value) { submitted = submitted.concat([value]); }
        function cancelAuthenticationRequest() { cancelled++; }
    }
    PolkitPrompt { id: prompt; theme: theme }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        var kids = item.children || [];
        for (var i = 0; i < kids.length; i++) { var hit = find(kids[i], name); if (hit) return hit; }
        if (item.contentItem && item.contentItem !== item) return find(item.contentItem, name);
        return null;
    }
    Timer { interval: 200; running: true; onTriggered: {
        if (prompt.enabled) throw new Error("the prompt switched itself on outside a Hyprland session");
        if (prompt.agent !== null) throw new Error("an agent was created without a session");
        prompt.testFlow = fakeFlow;
    }}
    Timer { interval: 500; running: true; onTriggered: {
        var top = prompt.window.contentItem;
        var slip = root.find(top, "polkit-slip"), what = root.find(top, "polkit-what"), field = root.find(top, "polkit-field");
        var allow = root.find(top, "polkit-allow"), note = root.find(top, "polkit-note"), message = root.find(top, "polkit-message");
        if (!slip || !prompt.window.visible) throw new Error("a request did not show the slip");
        if (what.text !== "Something wants to restart the computer.") throw new Error("plain words: " + what.text);
        if (!message.visible || message.text.indexOf("reboot") < 0) throw new Error("polkit's own message is not under it");
        if (field.echoMode !== TextInput.Password || field.placeholderText !== "password") throw new Error("the field: " + field.placeholderText);
        if (allow.enabled) throw new Error("allow is offered with nothing typed");
        field.text = "hunter2";
        prompt.submit();
        if (JSON.stringify(fakeFlow.submitted) !== '["hunter2"]' || field.text !== "") throw new Error("submit: " + JSON.stringify(fakeFlow.submitted));
        field.text = "wrong"; fakeFlow.authenticationFailed();
        if (field.text !== "") throw new Error("a wrong password stayed in the field");
        fakeFlow.supplementaryMessage = "Sorry, try again."; fakeFlow.supplementaryIsError = true;
        if (!note.visible || note.color !== theme.error) throw new Error("the error note");
        fakeFlow.isResponseRequired = false;
        if (field.enabled) throw new Error("the field takes typing while polkit waits on a fingerprint");
        prompt.submit();
        if (fakeFlow.submitted.length !== 1) throw new Error("submitted while nothing was asked");
        prompt.cancel();
        if (fakeFlow.cancelled !== 1) throw new Error("cancel");
        fakeFlow.actionId = "com.example.unknown";
        if (what.text !== fakeFlow.message) throw new Error("an unknown request shows polkit's message: " + what.text);
        prompt.testFlow = null;
        if (prompt.window.visible) throw new Error("the slip stayed after the request");
        console.log("POLKIT_PROMPT_OK");
        Qt.quit();
    }}
}
'''


class PolkitPrompt(unittest.TestCase):
    def test_a_request_shows_in_plain_words_and_the_session_agent_is_never_touched(self):
        if not shutil.which("quickshell"):
            self.skipTest("quickshell is not installed")
        render = ROOT / "src/desk-render/desk-render-fast"
        if not render.exists():
            self.skipTest("build desk-render-fast first")
        with tempfile.TemporaryDirectory(prefix="polkit-prompt-") as work:
            qml = Path(work) / "qml"
            qml.mkdir()
            subprocess.run([str(render), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates/quickshell/foxml"), str(qml)],
                           check=True, capture_output=True)
            source = (ROOT / "shared/quickshell/foxml/PolkitPrompt.qml").read_text().replace("    PanelWindow {", "    FloatingWindow {")
            source = re.sub(r"^        (?:anchors \{.*|exclusionMode:.*|WlrLayershell\..*)\n", "", source, flags=re.M)
            (qml / "PolkitPrompt.qml").write_text(source)
            (qml / "shell.qml").write_text(SHELL)
            runtime = Path(work) / "runtime"
            runtime.mkdir(mode=0o700)
            env = os.environ | {"QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software", "XDG_RUNTIME_DIR": str(runtime),
                                "QS_NO_RELOAD_POPUP": "1"}
            # No FOXML_POLKIT_PROMPT=off: the Hyprland check alone must keep it off. With no session bus and a private
            # runtime dir, even a broken check could not reach this session's systemd or polkit.
            for name in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
                env.pop(name, None)
            shell = subprocess.Popen(["quickshell", "-p", str(qml), "--no-color"], env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True)
            try:
                log, _ = shell.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                shell.kill()
                log, _ = shell.communicate()
                self.fail("the prompt test never finished:\n" + log[-3000:])
            self.assertIn("POLKIT_PROMPT_OK", log, log[-3000:])
            self.assertNotIn("Error:", log, log[-3000:])
            self.assertFalse((runtime / "foxml-polkit-agent").exists(), "no marker without a registered agent")


if __name__ == "__main__":
    unittest.main()
