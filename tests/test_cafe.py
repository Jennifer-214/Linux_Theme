#!/usr/bin/env python3
"""Café mode (shared/bin/desk-cafe). Its NetworkManager dispatcher runs as root, so it must never source or run what the
user can write: before 2026-11 it sourced ~/.config/foxml/cafe.conf and ran ~/.local/bin/fox-firewall as root.

Generates the real dispatcher with its settings file and PATH pointed at this test's copies and stand-ins, and runs it
the way NetworkManager does: interface and action as arguments, a fresh environment carrying CONNECTION_UUID. Untrusted
Wi-Fi gets what `desk firewall lockdown` applies plus an alert run as the user; trusted Wi-Fi the alert only; settings
that are not plain data, or that someone else could change, are ignored whole; nothing planted in the home folder runs.
Sealed with bwrap where it can make namespaces (no network, no D-Bus, a read-only system), so no real ufw, nmcli or
sudo is in reach; the setup checks also need its uid-0 mapping and skip without it.
"""
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CAFE = ROOT / "shared/bin/desk-cafe"
FIREWALL = ROOT / "shared/bin/desk-firewall"
BASH = shutil.which("bash") or "/bin/bash"
ME = pwd.getpwuid(os.getuid()).pw_name
UUID = "0b7a5f0e-6c2d-4a51-9d3e-2f4c8e1a7b90"
LOCKDOWN = ["allow out 53", "allow out 80/tcp", "allow out 443/tcp", "allow out 22/tcp", "allow out 123/udp",
            "allow out 67/udp", "allow out 68/udp", "allow out on lo", "default deny outgoing"]
VALID = "AUTO_LOCKDOWN=yes\nAUTO_VPN=no\nTRUSTED_SSID=home-wifi\nTRUSTED_SSID=work guest\n"


def _works(*args):
    return bool(shutil.which("bwrap")) and subprocess.run(
        ["bwrap", "--ro-bind", "/", "/", *args, "true"], capture_output=True).returncode == 0


SEAL = _works("--unshare-all", "--die-with-parent")
UID0 = _works("--unshare-user", "--uid", "0", "--gid", "0")


def sealed(argv, work, uid0=False):
    if not SEAL:
        return argv
    as_root = ["--unshare-user", "--uid", "0", "--gid", "0"] if uid0 else []
    return ["bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--tmpfs", "/run",
            "--bind", str(work), str(work), "--unshare-all", "--die-with-parent", "--new-session", *as_root, *argv]


def script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


def lines(path):
    return path.read_text().splitlines() if path.exists() else []


class Dispatcher(unittest.TestCase):
    def setUp(self):
        cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        cache.mkdir(parents=True, exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="cafe-test-", dir=cache))
        self.addCleanup(shutil.rmtree, self.work, True)
        w = self.work
        self.bin, self.home, self.etc = w / "bin", w / "home", w / "etc"
        self.etc.mkdir(mode=0o755)
        self.etc.chmod(0o755)
        self.conf = self.etc / "cafe.conf"
        log = lambda name: f'printf "%s\\n" "$*" >> "{w}/{name}.log"'
        script(self.bin / "ufw", log("ufw") + f'\n[ "$*" = "$(/usr/bin/cat "{w}/ufw-fails" 2>/dev/null)" ] && exit 1\nexit 0')
        script(self.bin / "nmcli", log("nmcli") + f'\n/usr/bin/cat "{w}/ssid" 2>/dev/null || exit 10')
        script(self.bin / "logger", log("logger"))
        script(self.bin / "runuser", log("runuser") + '\n[ "$1" = -u ] && [ "$3" = -- ] || exit 9\nshift 3\nexec "$@"')
        # The dispatcher's own tools, and what a payload needs to work: a test that cannot run `touch` sees no injection.
        for tool in ("stat", "timeout", "touch", "sh", "bash"):
            os.symlink(shutil.which(tool), self.bin / tool)
        script(self.home / ".local/bin/desk-dispatch", f'for a in "$@"; do printf "%s\\n" "$a"; done >> "{w}/dispatch.log"')
        # What the old dispatcher sourced or ran as root.
        (self.home / ".config/foxml").mkdir(parents=True)
        (self.home / ".config/foxml/cafe.conf").write_text(
            f'touch "{w}/PWNED_conf"\nTRUSTED_SSIDS="$(touch {w}/PWNED_sub)"\nAUTO_LOCKDOWN=yes\n')
        for name in ("fox-firewall", "desk-firewall"):
            script(self.home / ".local/bin" / name, f'touch "{w}/PWNED_{name}"')
        self.dispatcher = w / "99-foxml-cafe"
        made = subprocess.run([BASH, "-c", 'source "$1"; _dispatcher "$2" "$3" "$4" "$5"', "_", str(CAFE), ME,
                               str(self.home), str(self.conf), str(self.bin)],
                              env={"USER": ME, "HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertIn(f"PATH={self.bin}\nexport PATH\nCONF={self.conf}\n", made.stdout, "the test's PATH and settings")
        self.dispatcher.write_text(made.stdout)
        self.dispatcher.chmod(0o755)

    def settings(self, text, mode=0o644):
        self.conf.write_text(text)
        self.conf.chmod(mode)

    def run_dispatcher(self, ssid="Corner Cafe", iface="wlan0", action="up", uuid=UUID):
        for name in ("ufw", "nmcli", "logger", "runuser", "dispatch"):
            (self.work / f"{name}.log").unlink(missing_ok=True)
        ssid_file = self.work / "ssid"
        if ssid is None:
            ssid_file.unlink(missing_ok=True)
        else:
            ssid_file.write_bytes(ssid.encode())
        env = ["NM_DISPATCHER_ACTION=" + action, "DEVICE_IFACE=" + iface, "DEVICE_IP_IFACE=" + iface,
               "CONNECTION_ID=test"] + ([f"CONNECTION_UUID={uuid}"] if uuid is not None else [])
        ran = subprocess.run(sealed(["/usr/bin/env", "-i", *env, str(self.dispatcher), iface, action], self.work),
                             cwd=self.work, capture_output=True, text=True, timeout=60)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        w = self.work
        return {name: lines(w / f"{name}.log") for name in ("ufw", "nmcli", "logger", "runuser", "dispatch")}

    def assert_nothing_planted_ran(self):
        self.assertEqual(sorted(p.name for p in self.work.glob("PWNED*")), [], "a planted file ran")

    def test_untrusted_wifi_gets_the_lockdown_and_an_alert_run_as_the_user(self):
        self.settings(VALID)
        got = self.run_dispatcher("Corner Cafe")
        self.assertEqual(got["ufw"], LOCKDOWN)
        self.assertEqual(got["nmcli"], [f"--escape no -g 802-11-wireless.ssid connection show uuid {UUID}"])
        self.assertEqual(got["runuser"], [f"-u {ME} -- {self.home}/.local/bin/desk-dispatch cafe-mode "
                                          "entered cafe mode (untrusted: Corner Cafe)"])
        self.assertEqual(got["dispatch"], ["cafe-mode", "entered cafe mode (untrusted: Corner Cafe)"])
        self.assert_nothing_planted_ran()

    def test_trusted_wifi_and_lockdown_off_alert_only(self):
        self.settings(VALID)
        got = self.run_dispatcher("work guest")
        self.assertEqual((got["ufw"], got["dispatch"]), ([], ["cafe-mode", "left cafe mode (trusted: work guest)"]))
        self.settings(VALID.replace("AUTO_LOCKDOWN=yes", "AUTO_LOCKDOWN=no"))
        got = self.run_dispatcher("Corner Cafe")
        self.assertEqual((got["ufw"], got["dispatch"]), ([], ["cafe-mode", "entered cafe mode (untrusted: Corner Cafe)"]))

    def test_other_events_and_interfaces_do_nothing(self):
        self.settings(VALID)
        for iface, action in (("eth0", "up"), ("wlan0", "down"), ("wlan0", "dhcp4-change"), ("", "connectivity-change")):
            got = self.run_dispatcher(iface=iface, action=action)
            self.assertEqual(got, {k: [] for k in got}, (iface, action))

    def test_nothing_in_the_home_folder_runs(self):
        self.settings(VALID)
        self.assertEqual(self.run_dispatcher("Corner Cafe")["ufw"], LOCKDOWN)
        self.assert_nothing_planted_ran()
        self.assertNotIn(".config/foxml", self.dispatcher.read_text())
        self.assertNotIn("firewall", self.dispatcher.read_text().replace("desk firewall lockdown", ""))

    def test_settings_that_are_not_data_are_ignored_whole(self):
        m = self.work / "PWNED_line"
        for bad in (f'touch "{m}"', f"AUTO_LOCKDOWN=$(touch {m})", f"AUTO_LOCKDOWN=yes; touch {m}",
                    f"AUTO_VPN=`touch {m}`", 'TRUSTED_SSIDS="home-wifi"', "export AUTO_LOCKDOWN=no",
                    " AUTO_LOCKDOWN=yes", "TRUSTED_SSID=" + "x" * 33, "TRUSTED_SSID=", "TRUSTED_SSID=a\tb"):
            with self.subTest(bad=bad):
                self.settings(VALID + bad + "\n")
                got = self.run_dispatcher("Corner Cafe")
                self.assertEqual((got["ufw"], got["dispatch"]), ([], []))
                self.assertEqual(len(got["logger"]), 1)
                self.assertIn(f"ignored {self.conf}: line 5", got["logger"][0])
        self.assert_nothing_planted_ran()

    # SSIDs are 32 bytes at most, so these payloads name a file in the folder the dispatcher runs in.
    def test_a_command_in_a_value_is_only_text(self):
        self.settings(VALID + "TRUSTED_SSID=$(touch PWNED_v)\n")
        got = self.run_dispatcher("$(touch PWNED_v)")    # the network really has that name: trusted, nothing runs
        self.assertEqual(got["ufw"], [])
        self.assertEqual(got["dispatch"], ["cafe-mode", "left cafe mode (trusted: $(touch PWNED_v))"])
        self.assert_nothing_planted_ran()

    def test_settings_someone_else_could_change_are_ignored(self):
        good = self.work / "good.conf"
        good.write_text(VALID)
        for case in ("file writable by others", "folder writable by group", "a link"):
            with self.subTest(case=case):
                self.settings(VALID)
                if case == "file writable by others":
                    self.conf.chmod(0o666)
                elif case == "folder writable by group":
                    self.etc.chmod(0o775)
                else:
                    self.conf.unlink()
                    self.conf.symlink_to(good)
                got = self.run_dispatcher("Corner Cafe")
                self.etc.chmod(0o755)
                self.conf.unlink()
                self.assertEqual((got["ufw"], got["dispatch"]), ([], []))
                self.assertEqual(got["logger"], [f"-t foxml-cafe -- ignored {self.conf}: it is not a file only root can change"])

    def test_a_hostile_network_name_is_data_and_still_locked_down(self):
        self.settings(VALID)
        for ssid in ("x';touch PWNED_q;'", "$(touch PWNED_d)", "`touch PWNED_b`", "home-wifi\n", "home\x1bwifi"):
            with self.subTest(ssid=ssid):
                got = self.run_dispatcher(ssid)
                if ssid == "home-wifi\n":                 # $( ) drops the trailing newline: it reads as home-wifi
                    self.assertEqual(got["ufw"], [])
                    continue
                self.assertEqual(got["ufw"], LOCKDOWN)
                self.assertEqual(got["dispatch"][1], "entered cafe mode (untrusted: %s)" % ssid.replace("\x1b", "?"))
        self.assert_nothing_planted_ran()

    def test_no_name_or_no_connection_does_nothing(self):
        self.settings(VALID)
        got = self.run_dispatcher(None)                   # nmcli knows no such connection
        self.assertEqual((got["ufw"], got["dispatch"]), ([], []))
        for uuid in (None, "not-a-uuid", f"{UUID}; touch PWNED_u"):
            got = self.run_dispatcher(uuid=uuid)
            self.assertEqual((got["nmcli"], got["ufw"], got["dispatch"]), ([], [], []), uuid)
        self.assert_nothing_planted_ran()

    def generate(self, *args):
        """The dispatcher text _dispatcher writes for these arguments (user and home first)."""
        made = subprocess.run([BASH, "-c", 'source "$1"; printf "%s\\n" "$CONF"; shift; _dispatcher "$@"', "_", str(CAFE), *args],
                              env={"USER": ME, "HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(made.returncode, 0, made.stderr)
        return made.stdout.split("\n", 1)

    def test_the_real_dispatcher_reads_roots_file_with_system_programs(self):
        # The other tests point the dispatcher at their own settings and stand-ins; this is what --setup writes.
        conf, text = self.generate(ME, str(self.home))
        self.assertEqual(conf, "/etc/foxml/cafe.conf", "desk cafe keeps the settings in root's folder")
        self.assertIn("PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\nCONF=/etc/foxml/cafe.conf\n", text)
        self.assertEqual(text.count(str(self.home)), 1, "the home folder is named once, for the alert run as the user")
        self.assertIn(f"DISPATCH={self.home}/.local/bin/desk-dispatch\n", text)

    def test_settings_another_user_owns_are_ignored(self):
        # /etc/passwd: a plain file in a folder only its owner can change, owned by root, not by the test's user, who
        # runs the dispatcher here. Refused for its owner, before a line of it is read.
        other = Path("/etc/passwd")
        if os.getuid() == 0 or other.stat().st_uid == os.getuid():
            self.skipTest("needs a file another user owns")
        self.dispatcher.write_text(self.generate(ME, str(self.home), str(other), str(self.bin))[1])
        got = self.run_dispatcher("Corner Cafe")
        self.assertEqual((got["ufw"], got["dispatch"]), ([], []))
        self.assertEqual(got["logger"], [f"-t foxml-cafe -- ignored {other}: it is not a file only root can change"])

    def test_a_trusted_name_is_matched_whole_not_as_a_pattern(self):
        self.settings("AUTO_LOCKDOWN=yes\nTRUSTED_SSID=home*\nTRUSTED_SSID=[Cc]afe\nTRUSTED_SSID=?\n")
        for ssid in ("home-evil", "Cafe", "x"):
            with self.subTest(ssid=ssid):
                got = self.run_dispatcher(ssid)
                self.assertEqual(got["ufw"], LOCKDOWN, "a name that only fits a trusted one as a pattern is untrusted")
        self.assertEqual(self.run_dispatcher("home*")["ufw"], [], "the trusted name itself")

    def test_a_failed_allow_rule_never_denies_outgoing(self):
        self.settings(VALID)
        (self.work / "ufw-fails").write_text("allow out 443/tcp")
        got = self.run_dispatcher("Corner Cafe")
        self.assertEqual(got["ufw"], LOCKDOWN[:3])
        self.assertIn("-t foxml-cafe -- egress lockdown not applied: ufw failed", got["logger"])
        self.assertEqual(got["dispatch"], ["cafe-mode", "entered cafe mode (untrusted: Corner Cafe)"])

    def test_the_lockdown_is_what_desk_firewall_lockdown_applies(self):
        stubs = self.work / "fw-bin"
        script(stubs / "sudo", 'while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"')
        script(stubs / "ufw", f'printf "%s\\n" "$*" >> "{self.work}/fw-ufw.log"')
        ran = subprocess.run(sealed([BASH, str(FIREWALL), "lockdown"], self.work), input="y", capture_output=True,
                             text=True, timeout=30, env={"PATH": f"{stubs}:/usr/bin:/bin", "HOME": str(self.home)})
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertEqual(lines(self.work / "fw-ufw.log"), LOCKDOWN)


@unittest.skipUnless(SEAL and UID0, "needs bwrap with a uid-0 mapping")
class Setup(unittest.TestCase):
    """--setup, --disable and status, with root's two paths moved into a scratch folder and sudo a stand-in."""

    def setUp(self):
        cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        self.work = Path(tempfile.mkdtemp(prefix="cafe-setup-", dir=cache))
        self.addCleanup(shutil.rmtree, self.work, True)
        self.home, self.nm = self.work / "home", self.work / "nm"
        (self.home / ".config/foxml").mkdir(parents=True)
        self.nm.mkdir(mode=0o755)
        self.nm.chmod(0o755)
        self.bin = self.work / "bin"
        script(self.bin / "sudo", 'exec "$@"')
        script(self.bin / "nmcli", 'printf "no:Elsewhere\\nyes:Corner Cafe\\n"')
        self.conf, self.dispatcher = self.work / "etc/foxml/cafe.conf", self.nm / "99-foxml-cafe"

    def cafe(self, call, stdin=""):
        snippet = (f'source "$1"; CONF="$2"; DISPATCHER="$3"; {call}')
        return subprocess.run(sealed([BASH, "-c", snippet, "_", str(CAFE), str(self.conf), str(self.dispatcher)],
                                     self.work, uid0=True), input=stdin, capture_output=True, text=True, timeout=60,
                              env={"USER": ME, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin"})

    def plant_old(self):
        self.dispatcher.write_text('#!/bin/bash\n# foxml-managed — Café Mode trigger.\n. "$CONF"\n')
        (self.home / ".config/foxml/cafe.conf").write_text("TRUSTED_SSIDS=home\n")

    def test_old_dispatcher_is_named_then_replaced(self):
        self.plant_old()
        st = self.cafe("_status")
        self.assertEqual(st.returncode, 1)
        self.assertIn("the installed dispatcher is the old one", st.stdout)
        done = self.cafe("_setup", "home-wifi 'work guest'\nny")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.conf.read_text(), "# foxml-managed — written by `desk cafe --setup`; the café dispatcher "
                         "reads it as data.\nAUTO_LOCKDOWN=yes\nAUTO_VPN=no\nTRUSTED_SSID=home-wifi\nTRUSTED_SSID=work guest\n")
        self.assertEqual((self.conf.stat().st_mode & 0o7777, self.dispatcher.stat().st_mode & 0o7777), (0o644, 0o755))
        text = self.dispatcher.read_text()
        self.assertIn("# foxml-managed: cafe v2", text)
        self.assertIn(f"CONF={self.conf}\n", text)
        self.assertIn("PATH=/usr/sbin:/usr/bin:/sbin:/bin\n", text)
        self.assertFalse((self.home / ".config/foxml/cafe.conf").exists(), "the old user-side settings are removed")
        self.assertEqual(sorted(p.name for p in self.nm.iterdir()), ["99-foxml-cafe"], "no temporary left beside it")
        st = self.cafe("_status")
        self.assertEqual(st.returncode, 0, st.stdout)
        self.assertIn("cafe mode: armed", st.stdout)
        self.assertIn("trusted:        'home-wifi' 'work guest'", st.stdout)
        self.assertIn("current SSID:   Corner Cafe", st.stdout)
        off = self.cafe("_disable")
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertFalse(self.conf.exists() or self.dispatcher.exists())
        self.assertIn("not configured", self.cafe("_status").stdout)

    def test_a_failed_install_leaves_cafe_mode_off(self):
        self.plant_old()
        script(self.bin / "sudo", 'case "$*" in "mv -f "*99-foxml-cafe.new*) exit 1 ;; esac\nexec "$@"')
        done = self.cafe("_setup", "home-wifi\nny")
        self.assertEqual(done.returncode, 1)
        self.assertIn("café mode is off", done.stderr)
        self.assertEqual(list(self.nm.iterdir()), [], "the old dispatcher and the temporary are gone")

    def test_setup_checks_what_it_installed(self):
        # Root's copies are compared with what was meant: one that came out loose, or different, leaves café mode off.
        for case, sudo in (
                ("loose", 'if [ "$1 $2 $3" = "install -m 0644" ]; then shift 3; exec install -m 0666 "$@"; fi\nexec "$@"'),
                ("changed", 'if [ "$1 $2" = "mv -f" ] && [ "${3##*/}" = .cafe.conf.new ]; then\n'
                            '  "$@" && echo TRUSTED_SSID=evil >> "$4"; exit\nfi\nexec "$@"')):
            with self.subTest(case=case):
                script(self.bin / "sudo", sudo)
                done = self.cafe("_setup", "home-wifi\nny")
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                self.assertIn("café mode is off", done.stderr)
                self.assertFalse(self.dispatcher.exists(), "no dispatcher is left to read it")

    def test_typed_ssids(self):
        ok = self.cafe('_split_ssids "home-wifi \'work guest\' \\"dorm A\\" Café"; printf "<%s>" "${SSIDS[@]}"')
        self.assertEqual(ok.stdout, "<home-wifi><work guest><dorm A><Café>")
        bad = self.cafe("_setup", "home 'work\nny")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("unbalanced quotes", bad.stderr)
        long = self.cafe("_setup", "x" * 33 + "\nny")
        self.assertIn("not an SSID", long.stderr)
        self.assertFalse(self.conf.exists() or self.dispatcher.exists())
        sizes = self.cafe('for s in "$(printf "x%.0s" {1..32})" "ÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉÉ" ""; do cafe_ssid_ok "$s" && echo y || echo n; done')
        self.assertEqual(sizes.stdout.split(), ["y", "n", "n"], "32 bytes fit; 17 two-byte letters are 34 bytes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
