"""desk theme check end to end: a fake home, the real repo and stand-in commands.

Deployed (D14–D25) is sealed further: a folder stands in for / (DESK_THEME_CHECK_ROOT), so the check reads that
folder's /etc, /proc and /usr and never this machine's or its running sessions; PATH holds only stand-ins and the few
tools the check runs probes with."""
import ast
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "src/theme-check/theme-check"
RENDER = ROOT / "src/desk-render/desk-render-fast"
DESK_WORK = ROOT / "src/desk-work/desk-work"
INSTALLER_MODULES = ROOT / "src" / "desk-install" / "modules"


@unittest.skipUnless(CHECK.exists() and RENDER.exists(), "build theme-check and desk-render-fast first")
class ThemeCheck(unittest.TestCase):
    def setUp(self):
        # Beside the test, not in /tmp: stand-in commands must be executable, and /tmp may be noexec.
        self.tmp = Path(tempfile.mkdtemp(prefix=".fox-theme-check-tests-", dir=Path(__file__).parent))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.rendered = self.tmp / "rendered"
        subprocess.run([str(RENDER), str(ROOT / "themes/Paper/palette.sh"), str(ROOT / "templates"), str(self.rendered)],
                       check=True, capture_output=True)

    def shim(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def deploy(self, src, dest, text=None):
        target = self.home / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text if text is not None else (self.rendered / src).read_text())

    def run_check(self, *args, extra_env=None):
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "FOXML_REPO": str(ROOT),
               "XDG_RUNTIME_DIR": str(self.tmp / "run")} | (extra_env or {})
        return subprocess.run([str(CHECK), "--theme", "Paper", *args], env=env, text=True, capture_output=True, timeout=120)

    def test_drift_tells_a_changed_file_from_this_machines_own(self):
        self.deploy("kitty/kitty.conf", ".config/kitty/kitty.conf")
        self.deploy("tmux/.tmux.conf", ".tmux.conf", (self.rendered / "tmux/.tmux.conf").read_text().replace("set -g", "set -gq", 1))
        lock = (self.rendered / "hyprlock/hyprlock.conf").read_text().replace("    monitor =\n", "    monitor = eDP-1\n")
        self.deploy("hyprlock/hyprlock.conf", ".config/hypr/hyprlock.conf", lock)
        zshrc = (self.rendered / "zsh/.zshrc").read_text() + "\nexport MINE=1\n"
        self.deploy("zsh/.zshrc", ".zshrc", zshrc)
        out = self.run_check("--only", "D1", "--verbose")
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("differs: ~/.tmux.conf", out.stdout)
        self.assertNotIn("differs: ~/.config/kitty/kitty.conf", out.stdout, "an exact copy matches")
        self.assertNotIn("differs: ~/.config/hypr/hyprlock.conf", out.stdout, "a lock screen pinned to a panel is this machine's")
        self.assertNotIn("differs: ~/.zshrc", out.stdout)
        self.assertIn("1 match with lines of your own added", out.stdout, "your own line keeps .zshrc yours")
        self.assertIn("missing: ", out.stdout, "files the fake home never got are listed")
        self.assertFalse(list(Path(tempfile.gettempdir()).glob(f"fox-theme-check-{os.getpid()}*")), "nothing left behind")

    def test_services_hyprland_and_exit_codes(self):
        self.shim("systemctl", 'case "$3" in fox-pulse.service) [ "$2" = is-enabled ] && echo enabled || echo active ;;'
                               ' foxml-focus-pulse.service) [ "$2" = is-active ] && echo active || echo enabled ;;'
                               ' *) echo inactive ;; esac')
        out = self.run_check("--only", "D9")
        self.assertIn("foxml-focus-pulse.service still runs beside desk-pulse", out.stdout)
        self.assertEqual(out.returncode, 1, "a warning")
        self.shim("systemctl", 'case "$3" in fox-pulse.service) [ "$2" = is-enabled ] && echo enabled || echo active ;; *) echo inactive ;; esac')
        self.assertEqual(self.run_check("--only", "D9").returncode, 0)

        self.shim("hyprctl", 'echo "config error in rules.conf line 3"')
        out = self.run_check("--only", "D2", extra_env={"HYPRLAND_INSTANCE_SIGNATURE": "test"})
        self.assertIn("rules.conf line 3", out.stdout)
        self.assertEqual(out.returncode, 3, "a broken Hyprland config is a high failure")
        self.shim("hyprctl", "echo 'no errors'")
        self.assertEqual(self.run_check("--only", "D2", extra_env={"HYPRLAND_INSTANCE_SIGNATURE": "test"}).returncode, 0)
        self.assertIn("not in a Hyprland session", self.run_check("--only", "D2", "--verbose").stdout)

    def test_the_drawer_and_bar_are_asked_for_real(self):
        menus = self.home / ".config/quickshell/desk/menus.json"
        menus.parent.mkdir(parents=True)
        menus.write_text(json.dumps({"groups": [{"id": "comfort", "items": [{"id": "x", "kind": "page", "page": "slow"}]}]}))
        drawer = self.home / ".local/bin/desk-drawer"
        drawer.parent.mkdir(parents=True)
        drawer.write_text('#!/bin/sh\n[ "$2" = slow ] && echo \'{"ok":false,"message":"broken"}\' && exit 1\necho \'{"items":[]}\'\n')
        drawer.chmod(0o755)
        out = self.run_check("--only", "D4")
        self.assertIn("slow (broken)", out.stdout)
        self.assertEqual(out.returncode, 1)
        bar = self.home / ".config/waybar/config"
        bar.parent.mkdir(parents=True)
        bar.write_text('// a comment waybar allows\n{"custom/good":{"exec":"echo \'{\\"text\\":\\"x\\"}\'","return-type":"json"},'
                       '"custom/bad":{"exec":"echo nope","return-type":"json"},"custom/gone":{"exec":"exit 4"}}')
        out = self.run_check("--only", "D5")
        self.assertIn("custom/bad (not JSON)", out.stdout)
        self.assertIn("custom/gone (exit 4)", out.stdout)
        self.assertNotIn("custom/good", out.stdout)

    def test_gtk_firefox_cursor_and_the_lock_panel(self):
        self.shim("gsettings", 'case "$3" in color-scheme) echo "\'prefer-dark\'" ;; cursor-theme) echo "\'foxml-paper-cursors\'" ;; esac')
        out = self.run_check("--only", "D10")
        self.assertIn("the theme is light but color-scheme is prefer-dark", out.stdout)
        self.assertEqual(out.returncode, 1)
        self.shim("gsettings", 'case "$3" in color-scheme) echo "\'default\'" ;; cursor-theme) echo "\'foxml-paper-cursors\'" ;; esac')
        self.assertEqual(self.run_check("--only", "D10").returncode, 0)

        out = self.run_check("--only", "D12")
        self.assertIn("foxml-paper-cursors is not installed", out.stdout)
        (self.home / ".local/share/icons/foxml-paper-cursors/cursors").mkdir(parents=True)
        self.assertEqual(self.run_check("--only", "D12").returncode, 0)

        ff = self.home / ".config/mozilla/firefox"
        (ff / "abc.default-release").mkdir(parents=True)
        (ff / "profiles.ini").write_text("[Install4F96D1932A9F858E]\nDefault=abc.default-release\nLocked=1\n")
        prefs = ('user_pref("ui.textHighlightBackground", "#e2a4ba");\nuser_pref("ui.textHighlightForeground", "#202024");\n'
                 'user_pref("ui.textSelectAttentionBackground", "#e2a4ba");\n')
        (ff / "abc.default-release/user.js").write_text(prefs)
        out = self.run_check("--only", "D11")
        self.assertIn("ui.textSelectAttentionForeground", out.stdout)
        (ff / "abc.default-release/user.js").write_text(prefs + 'user_pref("ui.textSelectAttentionForeground", "#202024");\n')
        self.assertEqual(self.run_check("--only", "D11").returncode, 0)

        lock = self.home / ".config/hypr/hyprlock.conf"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("label {\n    monitor = eDP-1\n}\n")
        session = {"HYPRLAND_INSTANCE_SIGNATURE": "test"}
        out = self.run_check("--only", "D13", extra_env=session)
        self.assertIn("lock-panel is not installed", out.stdout)
        moved = self.tmp / "moved.conf"
        moved.write_text("label {\n    monitor = DP-2\n}\n")
        chooser = self.home / ".local/bin/lock-panel"
        chooser.parent.mkdir(parents=True, exist_ok=True)
        chooser.write_text(f"#!/bin/sh\necho {moved}\n")
        out = self.run_check("--only", "D13", "--verbose", extra_env=session)
        self.assertIn("locking now would put it on DP-2", out.stdout)
        self.assertEqual(out.returncode, 0)


TICKS = os.sysconf("SC_CLK_TCK")
BOOT = 1_750_000_000              # the stand-in /proc's boot time
INSTALL = BOOT + 3600             # when the fixture's install wrote a file
BEFORE, AFTER = BOOT + 600, BOOT + 7200
OLD_HELP = "desk-work run [--root DIR] [--session ID] -- COMMAND [ARGS...]\ndesk-work notebook --root DIR\n"
# The café dispatcher before 2026-11-16, as `desk cafe --setup` wrote it (its head: root sources a file the user owns).
OLD_CAFE = ('#!/bin/bash\n# foxml-managed — Café Mode trigger.\nINTERFACE="$1"\nEVENT="$2"\n[[ "$EVENT" == "up" ]] || exit 0\n'
            'USER_HOME=$(getent passwd tester | cut -d: -f6)\nCONF="$USER_HOME/.config/foxml/cafe.conf"\n'
            '[[ -r "$CONF" ]] || exit 0\n. "$CONF"\n')
APPEARANCE = 'user_pref("layout.css.prefers-color-scheme.content-override", {});\n'


def cpp_string(header, name):
    """`inline constexpr const char* NAME = "…" "…";` from an installer header, joined as the compiler joins it."""
    source = (INSTALLER_MODULES / header).read_text()
    block = re.search(r"\b" + name + r'\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*)+);', source)
    return "".join(ast.literal_eval(part) for part in re.findall(r'"(?:[^"\\]|\\.)*"', block.group(1)))


def enforced_prefs():
    """The prefs the installer holds user.js to (firefox_appearance.hpp's ENFORCED_PREFS), as user_pref lines."""
    source = (INSTALLER_MODULES / "firefox_appearance.hpp").read_text()
    block = source[source.index("ENFORCED_PREFS[]"):]
    pairs = re.findall(r'\{"([^"]+)", "([^"]+)"\}', block[:block.index("};")])
    return "".join(f'user_pref("{key}", {value});\n' for key, value in pairs)


@unittest.skipUnless(CHECK.exists() and RENDER.exists(), "build theme-check and desk-render-fast first")
class Deployed(unittest.TestCase):
    """D14–D25: a good deployment passes, and each bad one planted on it turns its check red."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=".fox-theme-check-tests-", dir=Path(__file__).parent))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home, self.root, self.bin = self.tmp / "home", self.tmp / "root", self.tmp / "bin"
        for folder in (self.home, self.bin, self.root / "proc", self.tmp / "systemctl"):
            folder.mkdir(parents=True)
        (self.root / "proc/stat").write_text(f"cpu  1 2 3 4\nbtime {BOOT}\n")
        for tool in ("sh", "timeout", "env", "cat"):
            (self.bin / tool).symlink_to(shutil.which(tool))

    def shim(self, name, body):
        path = self.bin / name
        path.unlink(missing_ok=True)  # never write through a link to a real program
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def put(self, rel, text, when=None, base=None):
        path = (base or self.home) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if when:
            os.utime(path, (when, when))
        return path

    def proc(self, pid, comm, started, args=None, ppid=1):
        """A process of hers in the stand-in /proc: stat (its start in clock ticks after boot), comm and cmdline."""
        folder = self.root / "proc" / str(pid)
        folder.mkdir(parents=True)
        (folder / "stat").write_text(f"{pid} ({comm}) S {ppid} " + "0 " * 17 + f"{(started - BOOT) * TICKS} 0 0\n")
        (folder / "comm").write_text(comm + "\n")
        (folder / "cmdline").write_bytes(("\0".join(args or [comm]) + "\0").encode())

    def render(self, theme, folder):
        out = self.tmp / "render" / theme / folder
        if not out.exists():
            subprocess.run([str(RENDER), str(ROOT / "themes" / theme / "palette.sh"), str(ROOT / "templates" / folder), str(out)],
                           check=True, capture_output=True, timeout=60)
        return out

    def desk_work(self, help_text=OLD_HELP, health=None):
        answer = f"health) cat <<'EOF'\n{json.dumps(health)}\nEOF\n;;\n" if health is not None else ""
        self.shim("desk-work", f"case \"$1\" in\nhelp) cat <<'EOF'\n{help_text}\nEOF\n;;\n{answer}*) exit 2 ;;\nesac")

    def systemctl(self, **answers):
        """systemctl --user is-active UNIT and show -p NeedDaemonReload --value UNIT, answered from files."""
        for name, value in answers.items():
            (self.tmp / "systemctl" / name).write_text(value + "\n")
        self.shim("systemctl", 'for unit; do :; done\ncase "$2" in show) ask=reload ;; *) ask=$2 ;; esac\n'
                               f'[ -f "{self.tmp}/systemctl/$ask-$unit" ] && cat "{self.tmp}/systemctl/$ask-$unit"\nexit 0')

    def check(self, ids, theme="Paper"):
        env = {"HOME": str(self.home), "PATH": str(self.bin), "FOXML_REPO": str(ROOT), "XDG_RUNTIME_DIR": str(self.tmp / "run"),
               "DESK_THEME_CHECK_ROOT": str(self.root)}
        return subprocess.run([str(CHECK), "--theme", theme, "--verbose", "--only", ids], env=env, text=True,
                              capture_output=True, timeout=120)

    def status(self, cid, theme="Paper"):
        out = self.check(cid, theme)
        self.assertEqual(out.stderr, "")
        found = re.search(rf"^(ok|warn|fail|skip) +{cid} ", out.stdout, re.M)
        self.assertIsNotNone(found, out.stdout)
        return found.group(1), out.stdout

    def red(self, cid, words, theme="Paper", state="warn"):
        got, said = self.status(cid, theme)
        self.assertEqual(got, state, said)
        self.assertIn(words, said)
        return said

    def green(self, cid, theme="Paper", words=None):
        got, said = self.status(cid, theme)
        self.assertEqual(got, "ok", said)
        if words:
            self.assertIn(words, said)
        return said

    def skipped(self, cid, words):
        got, said = self.status(cid)
        self.assertEqual(got, "skip", said)
        self.assertIn(words, said)

    def test_on_a_machine_with_none_of_it_each_says_what_it_needs(self):
        out = self.check(",".join(f"D{n}" for n in range(14, 26)))
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        for n in range(14, 26):
            self.assertRegex(out.stdout, rf"(?m)^skip D{n} ")
        for words in ("requires NetworkManager", "Firefox is not installed", "nvim is not installed", "desk-work is not installed",
                      "arch-audit is not installed", "requires desk-work", "kitty, tmux and zsh configs are not deployed"):
            self.assertIn(words, out.stdout)

    def test_cafe_the_old_dispatcher_is_a_critical_failure(self):
        dispatcher = self.root / "etc/NetworkManager/dispatcher.d/99-foxml-cafe"
        dispatcher.parent.mkdir(parents=True)
        self.green("D14", words="café mode is not set up")
        made = subprocess.run(["bash", "-c", 'source "$1"; _dispatcher tester /home/tester', "_", str(ROOT / "shared/bin/desk-cafe")],
                              env={"USER": "tester", "HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True, check=True)
        dispatcher.write_text(made.stdout)
        self.green("D14", words="the fixed dispatcher (cafe v2)")
        dispatcher.write_text(OLD_CAFE)
        said = self.red("D14", "desk sec cafe --disable", state="fail")
        self.assertIn("anything running as you can become root", said)
        self.assertEqual(self.check("D14").returncode, 2, "a way to root is a critical failure")
        if os.geteuid() != 0:
            dispatcher.chmod(0)
            self.red("D14", "cannot read /etc/NetworkManager/dispatcher.d/99-foxml-cafe")

    def test_firefox_the_profile_firefox_opens_has_the_themes_files(self):
        self.shim("firefox", "exit 0")
        base = self.home / ".config/mozilla/firefox"
        profile = base / "abc.default-release"
        # Firefox's own index names the profile it opens; the older one beside it is not looked at
        self.put("old.default/chrome/userContent.css", "/* an older profile */", base=base)
        self.put("profiles.ini", "[Profile1]\nName=old\nIsRelative=1\nPath=old.default\nDefault=1\n\n"
                                 "[Install4F96D1932A9F858E]\nDefault=abc.default-release\nLocked=1\n", base=base)
        retro, paper = self.render("retro-amber", "firefox"), self.render("Paper", "firefox")
        for name in ("userChrome.css", "userContent.css"):
            self.put(f"chrome/{name}", (retro / name).read_text(), INSTALL, base=profile)
        prefs = self.put("user.js", enforced_prefs() + APPEARANCE.format(0), INSTALL, base=profile)
        self.green("D15", "retro-amber", "abc.default-release")

        (profile / "chrome/userContent.css").write_text((paper / "userContent.css").read_text())
        self.red("D15", "chrome/userContent.css is not retro-amber's", "retro-amber")
        (profile / "chrome/userContent.css").write_text((retro / "userContent.css").read_text())
        (profile / "chrome/userChrome.css").unlink()
        self.red("D15", "chrome/userChrome.css is missing", "retro-amber")
        self.put("chrome/userChrome.css", (retro / "userChrome.css").read_text(), base=profile)
        prefs.write_text(enforced_prefs())
        self.red("D15", "its website appearance is not dark (user.js does not set it)", "retro-amber")
        prefs.write_text(enforced_prefs().replace("toolkit.legacyUserProfileCustomizations.stylesheets", "x") + APPEARANCE.format(0))
        self.red("D15", "user.js does not set toolkit.legacyUserProfileCustomizations.stylesheets", "retro-amber")

        # a theme that names no website appearance: retro-amber's dark must not stay behind
        for name in ("userChrome.css", "userContent.css"):
            self.put(f"chrome/{name}", (paper / name).read_text(), INSTALL, base=profile)
        prefs.write_text(enforced_prefs() + APPEARANCE.format(0))
        self.red("D15", "user.js still sets the website appearance to dark, from another theme")
        self.put("user.js", enforced_prefs() + APPEARANCE.format(2), INSTALL, base=profile)
        self.green("D15")
        # Firefox reads them at its start only
        self.proc(4100, "firefox", BEFORE)
        self.red("D15", "restart Firefox to load them")
        shutil.rmtree(self.root / "proc/4100")
        self.proc(4101, "firefox", AFTER)
        self.green("D15")

    def test_shift_enter_kitty_tmux_and_zsh_and_a_tmux_client_from_before(self):
        kitty = self.put(".config/kitty/kitty.conf", (self.render("Paper", "kitty") / "kitty.conf").read_text())
        tmux = self.put(".tmux.conf", (self.render("Paper", "tmux") / ".tmux.conf").read_text(), INSTALL)
        zsh = self.put(".zshrc", (self.render("Paper", "zsh") / ".zshrc").read_text())
        self.green("D16")
        good = {path: path.read_text() for path in (kitty, tmux, zsh)}
        kitty.write_text(good[kitty].replace("map --when-focus-on var:desk_tmux=1 shift+enter", "map shift+enter"))
        self.red("D16", "kitty.conf sends Shift+Enter as CSI u everywhere")
        kitty.write_text("\n".join(line for line in good[kitty].splitlines() if "shift+enter" not in line))
        self.red("D16", "kitty.conf has no Shift+Enter map for tmux")
        kitty.write_text(good[kitty])
        tmux.write_text("\n".join(line for line in good[tmux].splitlines() if "smcup" not in line))
        self.red("D16", "~/.tmux.conf does not tell kitty when tmux is in front")
        self.put(".tmux.conf", good[tmux], INSTALL)
        zsh.write_text(good[zsh].replace("accept-line", "self-insert"))
        self.red("D16", "~/.zshrc does not take Shift+Enter's CSI u as Enter")
        zsh.write_text(good[zsh])
        # a client keeps the smcup it attached with; the server's age alone says nothing
        self.proc(300, "tmux: server", BEFORE)
        self.proc(301, "tmux: client", AFTER, ppid=1)
        self.green("D16")
        self.proc(302, "tmux: client", BEFORE)
        said = self.red("D16", "tmux source-file ~/.tmux.conf, then detach and attach again")
        self.assertIn("pid 302", said)
        self.assertNotIn("pid 301", said)

    def test_popout_rule_in_both_twins(self):
        for name in ("rules.lua", "rules.conf"):
            self.put(f".config/hypr/modules/{name}", (ROOT / "shared/hyprland_modules" / name).read_text())
        self.green("D17", words="rules.lua and rules.conf")
        lua = self.home / ".config/hypr/modules/rules.lua"
        lua.write_text(lua.read_text().replace("desk-popout", "other-popout"))
        self.red("D17", "rules.lua has no desk-popout window rule")
        (self.home / ".config/hypr/modules/rules.conf").unlink()
        self.red("D17", "rules.conf is missing")

    def test_plugin_lock_each_clone_at_its_pinned_commit(self):
        self.shim("nvim", "exit 0")
        lock = json.loads((ROOT / "shared/nvim_lazy-lock.json").read_text())
        deployed = self.put(".config/nvim/lazy-lock.json", json.dumps(lock))
        lazy = self.home / ".local/share/nvim/lazy"
        for name, pin in lock.items():
            self.put(f"{name}/.git/HEAD", pin["commit"] + "\n", base=lazy)
        # clones on a branch: read through the ref file, and through packed-refs
        scrollbar, packed = lazy / "nvim-scrollbar/.git", lazy / "lazy.nvim/.git"
        (scrollbar / "HEAD").write_text("ref: refs/heads/v1\n")
        self.put("refs/heads/v1", lock["nvim-scrollbar"]["commit"] + "\n", base=scrollbar)
        (packed / "HEAD").write_text("ref: refs/heads/main\n")
        (packed / "packed-refs").write_text(f"# pack-refs with: peeled fully-peeled sorted\n{lock['lazy.nvim']['commit']} refs/heads/main\n")
        self.green("D18", words=f"{len(lock)} plugins at their pinned commits; nvim-scrollbar at f8e87b9 (v1)")

        old_main = "00fe857e7cd97ee5e556de643ee920b003a96b03"  # main's last v1 commit, which warns at every start
        (scrollbar / "refs/heads/v1").write_text(old_main + "\n")
        self.red("D18", "nvim-scrollbar is at 00fe857, the lock pins f8e87b9 (v1)")
        (packed / "packed-refs").write_text("0" * 40 + " refs/heads/main\n")
        self.red("D18", "lazy.nvim is at 0000000")
        (packed / "packed-refs").write_text(f"{lock['lazy.nvim']['commit']} refs/heads/main\n")
        # last night's lock deployed: the restore kept the warning
        deployed.write_text(json.dumps(dict(lock, **{"nvim-scrollbar": {"branch": "main", "commit": old_main}})))
        said = self.red("D18", "the deployed lock pins nvim-scrollbar at 00fe857, the repo's pins f8e87b9")
        self.assertIn("./install.sh  (it deploys the repo's lock", said)
        deployed.write_text(json.dumps(lock))
        shutil.rmtree(lazy / "nvim-scrollbar")  # not cloned yet: Neovim clones it at its next start
        self.green("D18")

    def test_notebooks_need_jupytext_and_ipykernel(self):
        self.shim("nvim", "exit 0")
        self.skipped("D19", "the theme's Neovim config is not deployed")
        self.put(".config/nvim/init.lua", "-- the theme's\n")
        jupytext = self.put(".local/bin/jupytext", "#!/bin/sh\nexit 0\n")
        jupytext.chmod(0o755)
        (self.root / "usr/bin").mkdir(parents=True)
        (self.root / "usr/bin/python3").symlink_to("python3.14")
        kernel = self.put("usr/lib/python3.14/site-packages/ipykernel/__init__.py", "", base=self.root)
        self.green("D19", words=str(jupytext))
        jupytext.write_text("#!/gone/python3.13\n")
        self.red("D19", "pipx reinstall-all")
        jupytext.unlink()
        self.red("D19", "jupytext is missing: an .ipynb opens as JSON")
        self.shim("jupytext", "exit 0")  # one on PATH counts as much as ~/.local/bin's
        self.green("D19")
        kernel.unlink()
        self.red("D19", "sudo pacman -S python-ipykernel")
        # a python3 that is no link: any python3.* with ipykernel
        (self.root / "usr/bin/python3").unlink()
        (self.root / "usr/bin/python3").write_text("")
        self.put("usr/lib/python3.13/site-packages/ipykernel/__init__.py", "", base=self.root)
        self.green("D19")

    @unittest.skipUnless(DESK_WORK.exists(), "build desk-work first")
    def test_desk_work_has_editor_and_tools(self):
        (self.bin / "desk-work").symlink_to(DESK_WORK)
        self.green("D20", words=str(self.bin / "desk-work"))
        self.desk_work(OLD_HELP)
        said = self.red("D20", "it has no desk-work editor and desk-work tools")
        self.assertIn("./install.sh --only integrations", said)
        self.desk_work(OLD_HELP + "desk-work tools list|show ID|run ID|result ID [--root DIR]\n")
        self.assertNotIn("and desk-work tools", self.red("D20", "it has no desk-work editor"))

    def test_retro_bar_table(self):
        self.skipped("D21", "the desk bar is not installed")
        shipped = (ROOT / "shared/quickshell/desk/BarLogic.js").read_text()
        logic = self.put(".config/quickshell/desk/BarLogic.js", shipped)
        self.green("D21")
        logic.write_text(shipped.replace("var retroModules", "var oldModules"))
        self.red("D21", "it has no retroModules table")
        logic.write_text(shipped + "\n// mine\n")
        self.red("D21", "BarLogic.js is not the repo's")
        logic.unlink()
        self.red("D21", "BarLogic.js is missing")

    def test_etcwatch_units_current_loaded_and_watching(self):
        units = ".config/systemd/user/"
        self.put(units + "fox-etcwatch.path", cpp_string("etcwatch_units.hpp", "ETCWATCH_PATH_UNIT"))
        service = self.put(units + "fox-etcwatch.service", cpp_string("etcwatch_units.hpp", "ETCWATCH_SERVICE_UNIT"))
        self.systemctl(**{"is-active-fox-etcwatch.path": "active", "reload-fox-etcwatch.service": "no",
                          "reload-fox-etcwatch.path": "no"})
        self.green("D22", words="watching")
        good = service.read_text()
        service.write_text(good.replace("StartLimitIntervalSec=0\n", ""))
        self.red("D22", "a burst of /etc writes switches the watcher off", state="warn")
        service.write_text(good)
        self.systemctl(**{"reload-fox-etcwatch.service": "yes"})
        self.red("D22", "systemctl --user daemon-reload")
        self.systemctl(**{"reload-fox-etcwatch.service": "no", "is-active-fox-etcwatch.path": "failed"})
        self.red("D22", "fox-etcwatch.path is failed")

    def test_arch_audit_units_run_flags_arch_audit_takes(self):
        units = ".config/systemd/user/"
        self.shim("arch-audit", "exit 0")
        self.skipped("D23", "not set up (./install.sh --only arch_audit)")
        service = self.put(units + "foxml-arch-audit.service", cpp_string("arch_audit_units.hpp", "ARCH_AUDIT_SERVICE"))
        timer = self.put(units + "foxml-arch-audit.timer", cpp_string("arch_audit_units.hpp", "ARCH_AUDIT_TIMER"))
        self.systemctl(**{"reload-foxml-arch-audit.service": "no"})
        self.green("D23")
        good = service.read_text()
        service.write_text(re.sub(r"(?m)^ExecStart=.*$",
                                  lambda _: "ExecStart=/bin/sh -c 'n=$(arch-audit -uf | wc -l); test $n -gt 0 && notify-send arch-audit'", good))
        self.red("D23", "it runs arch-audit -uf, which arch-audit refuses")
        service.write_text(good)
        timer.write_text(timer.read_text().replace("OnCalendar=daily", "OnCalendar=weekly"))
        self.red("D23", "its units are not the installer's")
        timer.write_text(cpp_string("arch_audit_units.hpp", "ARCH_AUDIT_TIMER"))
        self.systemctl(**{"reload-foxml-arch-audit.service": "yes"})
        self.red("D23", "systemctl --user daemon-reload")

    @unittest.skipUnless(DESK_WORK.exists(), "build desk-work first")
    def test_declared_tools_read_by_desk_works_own_parser(self):
        desk_d = self.home / ".config/foxml/desk.d"
        self.skipped("D24", "nothing declared there")
        checkout = self.tmp / "checkout"
        (checkout / ".git").mkdir(parents=True)
        tool = {"id": "dag", "gives": "graph", "format": "json", "argv": ["true"]}
        good = self.put("good.json", json.dumps({"version": 1, "root": str(checkout), "tools": [tool]}), base=desk_d)
        self.skipped("D24", "requires desk-work")
        (self.bin / "desk-work").symlink_to(DESK_WORK)
        self.green("D24", words="1 file, 1 tool")
        self.put("broken.json", "{ not json", base=desk_d)
        self.red("D24", "broken.json: not valid JSON")
        (desk_d / "broken.json").unlink()
        good.write_text(json.dumps({"version": 1, "root": str(checkout), "tools": [dict(tool, format="png")]}))
        self.red("D24", "good.json: tool dag: format must be")
        good.write_text(json.dumps({"version": 2, "root": str(checkout), "tools": [tool]}))
        self.red("D24", "good.json: version 2: this desk-work reads version 1")
        self.desk_work(OLD_HELP)  # one from before desk-work tools: D20 says so
        self.skipped("D24", "requires a desk-work with desk-work tools")

    def test_sessions_on_an_older_version_and_how_to_reload_each(self):
        self.put(".config/nvim/lua/desk/build.lua", "return { id = 'b2' }\n", INSTALL)
        self.put(".claude/mods/desk-notebook/hooks/build.ts", "export const BUILD_ID = 'b2'\n", INSTALL)
        # started after the install, or no session of hers: a UI's server, a headless probe, an orphaned server
        self.proc(500, "nvim", AFTER, ["nvim", "notes.md"])
        self.proc(501, "nvim", AFTER, ["nvim", "--embed"], ppid=500)
        self.proc(502, "nvim", BEFORE, ["nvim", "--embed"])
        self.proc(503, "nvim", BEFORE, ["nvim", "--headless", "+qa"])
        self.proc(600, "claude", AFTER)
        self.green("D25", words="none runs code from before the install")
        # with no record of them: a Neovim and a Claude Code that started before the last install
        self.proc(510, "nvim", BEFORE, ["nvim", "plan.md"])
        self.proc(511, "nvim", BEFORE, ["nvim", "--embed"], ppid=510)
        self.proc(610, "claude", BEFORE)
        said = self.red("D25", "Neovim (pid 510 since ")
        # Its old noice setup can stop :restart at a "Press any key" it does not show: quit and start, never :restart.
        self.assertRegex(said, r"Neovim \(pid 510 since [^)]*\) started before the last install \([^)]*\): quit it and start it again")
        self.assertNotIn(":restart", said)
        self.assertRegex(said, r"Claude Code \(pid 610 since [^)]*\) started before the last install \([^)]*\): /exit, then claude --continue")
        for pid in (500, 501, 502, 503, 511, 600):
            self.assertNotIn(f"pid {pid} ", said)
        # desk-work knows what each one it keeps loaded: its word for those, one line a session
        resume = "In that Claude pane: /exit, then claude --resume s-1. The conversation comes back with the new notebook."
        self.desk_work(health={"sessions": [
            {"client": "nvim", "pid": 511, "status": "current"},
            {"client": "notebook", "pid": 610, "status": "reload-pending", "root": "/home/x/code/Linux_Theme",
             "reload": "In that Claude pane: /exit, then claude --continue."},
            {"client": "notebook", "pid": 610, "status": "reload-pending", "session": "s-1", "reload": resume},
            {"client": "desktop", "pid": 700, "status": "reload-pending", "reload": "Run quickshell -c desk kill, then desktop-menu --start."}]})
        said = self.red("D25", "Quickshell (pid 700) runs older code: Run quickshell -c desk kill")
        self.assertIn("Claude Code (pid 610, Linux_Theme) runs older code: " + resume, said)
        self.assertEqual(said.count("pid 610"), 1, said)
        self.assertNotIn("Neovim", said, "the Neovim whose server desk-work knows runs the installed code")
        # a record whose loaded version desk-work cannot tell says nothing: the start time does
        self.desk_work(health={"sessions": [{"client": "nvim", "pid": 511, "status": "unverified"}]})
        self.red("D25", "Neovim (pid 510 since ")
        # Quickshell reloads changed files itself: its start time alone says nothing
        for pid in (510, 511, 610):
            shutil.rmtree(self.root / "proc" / str(pid))
        self.proc(800, "quickshell", BEFORE)
        self.desk_work(health={"sessions": []})
        self.green("D25")

    def test_services_still_running_a_replaced_program(self):
        # 2026-11-16: after an install desk-pulse and the bouncer ran the day before's code, deleted from disk; `enable
        # --now` starts only what is stopped. /proc names such a file "<path> (deleted)", and opening the link reads the
        # old copy (here a file of that name).
        local = self.home / ".local/bin"
        for unit in ("fox-pulse.service", "fox-bouncer.service", "fox-vault.service", "power-state-watcher.service"):
            self.put(f".config/systemd/user/{unit}", "[Service]\n")
        programs = {"desk-pulse": ("pulse v1", "pulse v2"), "desk-bouncer": ("#!/bin/bash\n# v1\n", "#!/bin/bash\n# v2\n"),
                    "desk-vault": ("vault v1", "vault v2"), "power_state_watcher.sh": ("#!/bin/bash\n", "#!/bin/bash\n")}
        for name, (old, new) in programs.items():
            self.put(f".local/bin/{name} (deleted)", old)
            self.put(f".local/bin/{name}", new).chmod(0o755)

        def service(pid, unit, exe, script=None):
            self.proc(pid, "x", AFTER)
            folder = self.root / "proc" / str(pid)
            (folder / "cgroup").write_text(f"0::/user.slice/user-1000.slice/user@1000.service/app.slice/{unit}\n")
            (folder / "exe").symlink_to(exe)
            (folder / "fd").mkdir()
            if script:
                (folder / "fd/255").symlink_to(script)

        service(900, "power-state-watcher.service", "/usr/bin/bash", local / "power_state_watcher.sh (deleted)")
        self.skipped("D25", "requires desk-work")   # the same bytes laid again: not a newer version
        service(901, "fox-pulse.service", local / "desk-pulse (deleted)")
        service(902, "fox-bouncer.service", "/usr/bin/bash", local / "desk-bouncer (deleted)")
        service(903, "fox-vault.service", local / "desk-vault (deleted)")
        service(904, "app-kitty@1.service", local / "desk-pulse (deleted)")   # a transient unit: not one of hers
        said = self.red("D25", "fox-pulse.service (pid 901) runs ~/.local/bin/desk-pulse from before it was replaced: "
                               "systemctl --user restart fox-pulse.service")
        self.assertIn("fox-bouncer.service (pid 902) runs ~/.local/bin/desk-bouncer from before it was replaced", said)
        self.assertIn("systemctl --user restart fox-vault.service (the vault then starts empty)", said)
        for quiet in ("power-state-watcher", "app-kitty", "pid 904"):
            self.assertNotIn(quiet, said)


@unittest.skipUnless(CHECK.exists(), "build theme-check first")
class Scheduled(unittest.TestCase):
    """The weekly timer runs what theme-check's own table marks Weekly, so a new check is scheduled by declaring it
    (the field sits before the check's function, so every entry has to say), never by editing the unit's command."""
    WEEKLY = {"D1", "D6", "D8", "D9", "D10", "D11", "D12", "D14", "D15", "D16", "D17", "D18", "D19", "D20", "D21",
              "D22", "D23", "D24", "D25"}
    LIVE = {"D2", "D3", "D4", "D5", "D7", "D13"}

    def ids(self, *args):
        with tempfile.TemporaryDirectory(prefix="theme-check-list-") as home:
            ran = subprocess.run([str(CHECK), *args, "--list"], capture_output=True, text=True, timeout=30,
                                 env={"PATH": "/usr/bin:/bin", "HOME": home})
        self.assertEqual(ran.returncode, 0, ran.stderr)
        return ran.stdout.split()

    def test_scheduled_runs_every_weekly_check_and_no_live_one(self):
        self.assertEqual(set(self.ids("--scheduled")), self.WEEKLY)

    def test_every_check_is_in_the_table_once(self):
        listed = self.ids()
        self.assertEqual(len(listed), len(set(listed)), listed)
        self.assertEqual(set(listed), self.WEEKLY | self.LIVE)

    def refused(self, *args):
        with tempfile.TemporaryDirectory(prefix="theme-check-refuse-") as home:
            ran = subprocess.run([str(CHECK), "--quiet", *args], capture_output=True, text=True, timeout=30,
                                 env={"PATH": "/usr/bin:/bin", "HOME": home})
        return ran

    def test_a_selection_that_checks_nothing_is_refused_not_clean(self):
        unknown = self.refused("--only", "D999")
        self.assertEqual(unknown.returncode, 64, "an unknown check id must not exit 0")
        self.assertIn("D999", unknown.stderr)
        self.assertEqual(self.refused("--only", "").returncode, 64, "an empty --only must not mean every check")
        self.assertEqual(self.refused("--only", "D2", "--scheduled").returncode, 64,
                         "filters that leave nothing must not look like a clean run")

    def test_the_weekly_unit_selects_by_the_table(self):
        unit = (ROOT / "shared/systemd_user/fox-theme-check.service").read_text()
        self.assertIn("--scheduled", unit)
        self.assertNotRegex(unit, r"--only\b", "a fixed --only list misses every check added after it")


if __name__ == "__main__":
    unittest.main()
