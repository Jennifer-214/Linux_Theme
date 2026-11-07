#!/usr/bin/env python3
"""Paper's small touches: the waking cat, workspace paw and lock-screen hearts."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QML = ROOT / "shared/quickshell/foxml"


class LittleDetails(unittest.TestCase):
    def test_cat_follows_the_idle_inhibitor_only_on_paper(self):
        module = (QML / "BarModule.qml").read_text()
        self.assertIn('catPill: name === "idle_inhibitor" && theme.paperDetails', module)
        self.assertIn("awake: module.dataSource.idleEnabled", module)
        self.assertIn("!module.catPill", module)
        cat = (QML / "CatNap.qml").read_text()
        self.assertRegex(cat, r"if \(!awake && !hungry\)")
        self.assertRegex(cat, r"if \(awake \|\| hungry\)")

    def test_hunger_and_music_stay_on_the_paper_cat(self):
        module = (QML / "BarModule.qml").read_text()
        self.assertIn('catHungry: name === "idle_inhibitor" && theme.paperDetails', module)
        self.assertIn('catListening: name === "idle_inhibitor" && theme.paperDetails', module)
        # The note drifts once per tick; an always-running animation would repaint the bar for a whole album.
        cat = (QML / "CatNap.qml").read_text()
        self.assertNotIn("loops: Animation.Infinite", cat)
        self.assertIn("running: cat.music", cat)

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
            self.assertEqual("♡" in message.group(1), paper)

    def test_paw_marks_only_the_active_workspace_on_paper(self):
        bar = (QML / "BarWorkspaces.qml").read_text()
        self.assertIn("visible: tab.current && workspaces.theme.paperDetails", bar)

    def test_only_paper_types_hearts(self):
        for palette in sorted((ROOT / "themes").glob("*/palette.sh")):
            style = re.search(r"^HYPRLOCK_DOTS_STYLE='?([^'\n]*)", palette.read_text(), re.M)
            hearts = bool(style) and "♡" in style.group(1)
            self.assertEqual(hearts, palette.parent.name == "FoxML_Paper", palette.parent.name)


class TerminalCat(unittest.TestCase):
    def render(self, tmp):
        renderer = ROOT / "src/fox-render/fox-render-fast"
        if not renderer.exists():
            self.skipTest("build fox-render-fast first")
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
    def test_greeting_and_eyes_follow_the_hour(self):
        for hour, greeting, sleepy in ((9, "good morning, fox", False), (13, "good afternoon, fox", False),
                                       (19, "good evening, fox", False), (22, "still up?", True), (4, "still up?", True)):
            with self.subTest(hour=hour):
                out = self.welcome(hour)
                self.assertIn(greeting, out)
                self.assertEqual("。" not in out, sleepy)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is required")
    def test_worried_face_shows_once_and_never_for_interrupts(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.render(tmp)
            script = f"""
autoload -Uz add-zsh-hook
source <(sed -n '/^_caramel_timer_start=0/,/^add-zsh-hook preexec/p;/^_fox_err=/p;/^typeset -gi _caramel_paper/,/^\[\[/p' {tmp}/caramel.zsh-theme)
source <(sed -n '/^function caramel_precmd/,/^  # ── Command execution time/p' {tmp}/caramel.zsh-theme; print '}}')
check() {{ _caramel_timer_start=$2; (exit $1); caramel_precmd; [[ $PROMPT_INDICATOR == *'(=;ω;=)'* ]] && print yes || print no; }}
check 1 5; check 1 0; check 130 5; check 148 5; check 0 5
"""
            out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, timeout=10)
            self.assertEqual(out.stdout.split(), ["yes", "no", "no", "no", "no"], out.stderr)


if __name__ == "__main__":
    unittest.main()
