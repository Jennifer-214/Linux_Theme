#!/usr/bin/env python3
"""foxml-fail2ban-notify (shared/bin) runs as root on every fail2ban ban. Until 2026-11-16 it appended to, chmodded and
chowned ~/.local/share/foxml/threat-log.txt as root, following links: a link planted there handed its target (say
/etc/shadow) to the user at the next ban, and a linked folder got chmod 700.

Runs the real script as root of a user namespace (bwrap --uid 0 keeping root's capabilities inside it), sealed (no
network, no D-Bus, a read-only system), with stand-ins on PATH: getent names a scratch home, curl and whois answer
without the network, and runuser and sudo drop every capability before running their command, as a real switch to the
user drops root's. A file with no write bits stands for a file only root may write: root writes it anyway (it ignores
file modes), the user cannot.
- a ban appends one row to the log, written as the user (a new folder 0700, a new log 0600), and alerts as the user;
- a link at threat-log.txt to a root-only file is never written through, and that file keeps its mode;
- a linked ~/.local/share/foxml keeps its mode;
- the alert still goes out in both.
Skips without bwrap's uid-0 mapping or setpriv."""
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NOTIFY = ROOT / "shared/bin/foxml-fail2ban-notify"
ME = pwd.getpwuid(os.getuid()).pw_name
AS_ROOT = ["--unshare-user", "--uid", "0", "--gid", "0", "--cap-add", "ALL"]
DROP = "setpriv --bounding-set -all --inh-caps -all --ambient-caps -all --"


def _works():
    return bool(shutil.which("bwrap")) and bool(shutil.which("setpriv")) and subprocess.run(
        ["bwrap", "--ro-bind", "/", "/", "--unshare-all", "--die-with-parent", *AS_ROOT, "true"],
        capture_output=True).returncode == 0


SEALED = _works()


def script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


@unittest.skipUnless(SEALED, "needs bwrap with a uid-0 mapping and setpriv")
class Notify(unittest.TestCase):
    def setUp(self):
        cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        cache.mkdir(parents=True, exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="f2b-notify-test-", dir=cache))
        self.addCleanup(shutil.rmtree, self.work, True)
        w = self.work
        self.bin, self.home = w / "bin", w / "home"
        self.share = self.home / ".local/share/foxml"
        script(self.bin / "getent", f'[ "$1" = passwd ] && [ "$2" = "{ME}" ] && echo "{ME}:x:1000:1000::{self.home}:/bin/sh"\nexit 0')
        script(self.bin / "curl", "echo '{\"country\":\"Nowhere\",\"city\":\"Testville\"}'")
        script(self.bin / "whois", "printf 'country: ZZ\\nnetname: TEST-NET\\n'")
        # As the user: root's capabilities dropped, so file modes bind (bwrap's root is this user, owner of every file).
        script(self.bin / "runuser", f'printf "%s\\n" "$*" >> "{w}/runuser.log"\n'
                                     f'[ "$1" = -u ] && [ "$2" = "{ME}" ] && [ "$3" = -- ] || exit 9\nshift 3\nexec {DROP} "$@"')
        script(self.bin / "sudo", f'printf "%s\\n" "$*" >> "{w}/sudo.log"\n'
                                  f'[ "$1" = -u ] && [ "$2" = "{ME}" ] || exit 9\nshift 2\nexec {DROP} env "$@"')
        script(self.home / ".local/bin/desk-dispatch",
               f'for a in "$@"; do printf "%s\\n" "$a"; done >> "{w}/dispatch.log"\n'
               f'grep CapEff /proc/self/status >> "{w}/dispatch-caps.log"')

    def ban(self):
        for name in ("runuser", "sudo", "dispatch", "dispatch-caps"):
            (self.work / f"{name}.log").unlink(missing_ok=True)
        argv = ["bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--tmpfs", "/run",
                "--bind", str(self.work), str(self.work), "--unshare-all", "--die-with-parent", "--new-session", *AS_ROOT,
                "/usr/bin/env", "-i", f"PATH={self.bin}:/usr/bin:/bin", "bash", str(NOTIFY), "203.0.113.9", "sshd", "5", ME]
        ran = subprocess.run(argv, cwd=self.work, capture_output=True, text=True, timeout=60)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        read = lambda name: (self.work / f"{name}.log").read_text().splitlines() if (self.work / f"{name}.log").exists() else []
        return {name: read(name) for name in ("runuser", "sudo", "dispatch", "dispatch-caps")}

    def assert_alerted(self, got):
        self.assertEqual(got["dispatch"][:1], ["ssh-brute"], got)
        self.assertIn("203.0.113.9 banned (sshd, 5 failures) geo=", got["dispatch"][1])
        self.assertEqual(got["dispatch-caps"], ["CapEff:\t0000000000000000"], "the alert runs with none of root's capabilities")

    def test_a_ban_is_logged_and_alerted_as_the_user(self):
        got = self.ban()
        log = self.share / "threat-log.txt"
        rows = log.read_text().splitlines()
        self.assertEqual(len(rows), 1, rows)
        fields = rows[0].split("\t")
        self.assertEqual(fields[1:4], ["203.0.113.9", "sshd", "5 failures"])
        self.assertIn("Testville", fields[4])
        self.assertEqual(fields[5], "whois=country: ZZ|netname: TEST-NET|")
        self.assertEqual((self.share.stat().st_mode & 0o777, log.stat().st_mode & 0o777), (0o700, 0o600))
        self.assertTrue(any(line.startswith(f"-u {ME} -- ") for line in got["runuser"]), "the row is written as the user")
        self.assert_alerted(got)
        self.ban()
        self.assertEqual(len(log.read_text().splitlines()), 2, "a second ban appends")

    def test_a_link_at_the_log_is_never_written_through(self):
        victim = self.work / "shadow"
        victim.write_text("ROOT-ONLY\n")
        victim.chmod(0o444)
        self.share.mkdir(parents=True, mode=0o700)
        (self.share / "threat-log.txt").symlink_to(victim)
        got = self.ban()
        self.assertEqual(victim.read_text(), "ROOT-ONLY\n", "root wrote through the link")
        self.assertEqual(victim.stat().st_mode & 0o777, 0o444, "the link's target was chmodded")
        self.assert_alerted(got)

    def test_a_linked_folder_keeps_its_mode(self):
        elsewhere = self.work / "elsewhere"
        elsewhere.mkdir(mode=0o755)
        elsewhere.chmod(0o755)
        self.share.parent.mkdir(parents=True)
        self.share.symlink_to(elsewhere)
        got = self.ban()
        self.assertEqual(elsewhere.stat().st_mode & 0o777, 0o755, "the linked folder was chmodded")
        self.assert_alerted(got)


if __name__ == "__main__":
    unittest.main(verbosity=2)
