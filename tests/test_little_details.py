#!/usr/bin/env python3
"""Paper's field-note greeting, lock-screen feedback and quiet prompt."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QML = ROOT / "shared/quickshell/foxml"


class LittleDetails(unittest.TestCase):
    def test_goodnight_is_a_paper_power_page_detail(self):
        shell = (QML / "shell.qml").read_text()
        self.assertIn('theme.paperDetails && root.page === "power" && Logic.isNight(new Date())', shell)

    def test_only_paper_changes_the_window_curve_and_lock_message(self):
        for palette in sorted((ROOT / "themes").glob("*/palette.sh")):
            text = palette.read_text()
            paper = palette.parent.name == "FoxML_Paper"
            self.assertRegex(text, rf"(?m)^HYPR_WIN_CURVE={'foxSettle' if paper else 'foxSnap'}$")
            message = re.search(r"(?m)^HYPRLOCK_FAIL_TEXT='(.*)'$", text)
            self.assertIsNotNone(message, palette.parent.name)
            self.assertIn("$FAIL", message.group(1), "the real reason must stay visible")
            self.assertNotIn("♡", message.group(1))
            if paper:
                self.assertEqual(message.group(1), "<i>try again · $FAIL</i>")

    def test_pencil_mark_follows_the_active_workspace_on_paper(self):
        bar = (QML / "BarWorkspaces.qml").read_text()
        self.assertIn("visible: tab.current && workspaces.theme.paperDetails", bar)

    def test_paper_password_uses_plain_dots(self):
        for palette in sorted((ROOT / "themes").glob("*/palette.sh")):
            style = re.search(r"^HYPRLOCK_DOTS_STYLE='?([^'\n]*)", palette.read_text(), re.M)
            if style:
                self.assertNotIn("♡", style.group(1), palette.parent.name)
            if palette.parent.name == "FoxML_Paper":
                self.assertEqual(style.group(1), "dots_text_format = •")


class TerminalNotes(unittest.TestCase):
    def render(self, tmp):
        renderer = ROOT / "src/desk-render/desk-render-fast"
        if not renderer.exists():
            self.skipTest("build desk-render-fast first")
        subprocess.run([str(renderer), str(ROOT / "themes/FoxML_Paper/palette.sh"), str(ROOT / "templates/zsh"), tmp],
                       check=True, capture_output=True)

    def welcome(self, hour):
        with tempfile.TemporaryDirectory() as tmp:
            self.render(tmp)
            script = f"""
COLUMNS=100 USER=fox HOME={tmp}
source <(sed '/^_caramel_welcome$/d' {tmp}/welcome.zsh)
date() {{ [[ $1 == +%-H ]] && print {hour} || command date "$@" }}
RANDOM=1
print MARK
_caramel_welcome_centered Friday 'November 6' '9:00 pm'
"""
            return subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, timeout=10, check=True).stdout.split("MARK")[-1]

    @unittest.skipUnless(shutil.which("zsh"), "zsh is required")
    def test_field_note_heading_keeps_the_day_and_date(self):
        out = self.welcome(9)
        self.assertIn("Friday", out)
        self.assertIn("November 6", out)
        self.assertIn("9:00 pm", out)
        self.assertNotIn("ᓚᘏᗢ", out)
        self.assertNotIn("♡", out)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is required")
    def test_failed_commands_keep_the_numeric_status_without_a_mascot(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.render(tmp)
            script = f"""
autoload -Uz add-zsh-hook
source {tmp}/caramel.zsh-theme
check() {{ _caramel_timer_start=0; (exit $1); caramel_precmd; print -r -- "$PROMPT_INDICATOR"; }}
check 1; check 130; check 148; check 0
"""
            out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, timeout=10)
            self.assertEqual(out.returncode, 0, out.stderr)
            lines = out.stdout.splitlines()
            self.assertEqual(len(lines), 4, out.stdout + out.stderr)
            for line, code in zip(lines, [1, 130, 148, 0]):
                self.assertIn("❯", line)
                if code:
                    self.assertIn(f"❯ {code}", line)
                else:
                    self.assertNotIn("❯ 0", line)
                self.assertNotIn("ω", line)


if __name__ == "__main__":
    unittest.main()
