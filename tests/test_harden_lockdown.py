#!/usr/bin/env python3
"""`desk harden enable iommu` adds lockdown=integrity, which loads only signed kernel modules: on a machine with an
NVIDIA GPU or DKMS modules the GPU falls back to software rendering. It now asks the installer's question first
(mappings.sh: lockdown_blocks_modules, a copy of the iommu and lockdown_heal modules' has_nvidia ||
dkms_has_modules()) and refuses with nothing changed.

The copy answers tests/fixtures/lockdown_gate.cases, the cases src/desk-install/tests/test_lockdown_gate.cpp asks the
installer's own code, through the same lspci and dkms stand-ins. shared/bin/desk-harden runs with a sudo stand-in that
only records; the plain-machine run, which edits a boot entry, is sealed in bwrap over a scratch /boot (skipped
without bwrap), so the real /boot, sudo, lspci and dkms are never used.
"""
import glob
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CASES = ROOT / "tests/fixtures/lockdown_gate.cases"
HARDEN = ROOT / "shared/bin/desk-harden"
MAPPINGS = ROOT / "mappings.sh"
MODULES = Path(glob.glob(str(ROOT / "src/desk-ins*l/modules"))[0])
BASH = shutil.which("bash") or "/bin/bash"
ZSH = shutil.which("zsh")
INTEL = "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620 (rev 07)\n"
NVIDIA = INTEL + "01:00.0 3D controller: NVIDIA Corporation TU117GLM [T1200 Laptop GPU] (rev a1)\n"
SEAL = bool(shutil.which("bwrap")) and subprocess.run(
    ["bwrap", "--ro-bind", "/", "/", "--unshare-all", "--die-with-parent", "true"], capture_output=True).returncode == 0


def cases():
    out = []
    for line in CASES.read_text().splitlines():
        if line and not line.startswith("#"):
            f = line.split(" | ")
            assert len(f) == 6 and f[5] in ("block", "allow"), line
            out.append(f)
    return out


def gate_function():
    """mappings.sh's lockdown_blocks_modules on its own, for zsh (which cannot source the whole file)."""
    text = MAPPINGS.read_text()
    start = text.index("lockdown_blocks_modules() {")
    return text[start:text.index("\n}\n", start) + 3]


def printed(field):
    """As the C++ test: (nothing) is no output, \\n a new line, output ends in a newline."""
    return "" if field == "(nothing)" else field.replace("\\n", "\n") + "\n"


def stand_in(folder, name, status, out, only_for=None):
    if status == "-":
        return
    text = folder / f"{name}.out"
    text.write_text(out)
    guard = f'[ "$1" = {only_for} ] || exit 2\n' if only_for else ""
    (folder / name).write_text(f"#!/bin/sh\n{guard}/usr/bin/cat '{text}'\nexit {status}\n")
    (folder / name).chmod(0o755)


class LockdownGate(unittest.TestCase):
    def setUp(self):
        cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))   # not /tmp: noexec
        cache.mkdir(parents=True, exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="harden-test-", dir=cache))
        self.addCleanup(shutil.rmtree, self.work, True)
        self.home = self.work / "home"
        (self.home / ".local/share/foxml").mkdir(parents=True)
        (self.home / ".local/share/foxml/.installed-version").write_text(f"script_dir={ROOT}\n")

    def test_the_copy_answers_every_case_as_the_installer_does(self):
        n = 0
        for name, lspci, lspci_out, dkms, dkms_out, want in cases():
            with self.subTest(name):
                folder = self.work / f"case{n}"
                folder.mkdir()
                n += 1
                stand_in(folder, "lspci", lspci, printed(lspci_out))
                stand_in(folder, "dkms", dkms, printed(dkms_out), "status")
                shells = [[BASH, "-c", 'source "$1"; lockdown_blocks_modules', "_", str(MAPPINGS)]]
                if ZSH:   # desk-doctor's hints have people source mappings.sh into their own shell
                    shells.append([ZSH, "-f", "-c", gate_function() + "lockdown_blocks_modules"])
                for argv in shells:
                    ran = subprocess.run(argv, env={"PATH": str(folder), "HOME": str(self.home)},   # the stand-ins only
                                         capture_output=True, text=True, timeout=30)
                    self.assertIn(ran.returncode, (0, 1), (argv[0], ran.stderr))
                    self.assertEqual("block" if ran.returncode == 0 else "allow", want, (argv[0], ran.stdout))
                    self.assertEqual(bool(ran.stdout.strip()), want == "block", "says what it found, only when it blocks")
        self.assertGreaterEqual(n, 8)

    def test_the_installer_still_asks_the_same_question(self):
        """When this fails, change mappings.sh's lockdown_blocks_modules and the cases file with the installer."""
        for module in ("iommu.cpp", "lockdown_heal.cpp"):
            self.assertIn("ctx.has_nvidia || dkms_has_modules()", (MODULES / module).read_text(), module)
        self.assertRegex((MODULES / "detect.cpp").read_text(), r'ctx\.has_nvidia\s*=\s*lspci_has\("nvidia"\);')
        iommu = (MODULES / "iommu.cpp").read_text()
        body = iommu[iommu.index("bool dkms_has_modules() {"):iommu.index("std::string build_iommu_args")]
        for line in ('if (!sh::have("dkms")) return false;', 'sh::capture({"dkms", "status"}, out);',
                     "if (!std::isspace(static_cast<unsigned char>(c))) return true;"):
            self.assertIn(line, body)

    def harden(self, lspci_out, dkms_out="", sudo=None, boot=None, argv=None):
        folder = self.work / "bin"
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir()
        stand_in(folder, "lspci", "0", lspci_out)
        stand_in(folder, "dkms", "0", dkms_out, "status")      # shadows a real dkms: it never runs
        log = self.work / "sudo.log"
        log.unlink(missing_ok=True)
        (folder / "sudo").write_text("#!/bin/sh\n" + (sudo or f'printf "%s\\n" "$*" >> "{log}"\nexit 1') + "\n")
        (folder / "sudo").chmod(0o755)
        argv = argv or [BASH, str(HARDEN), "enable", "iommu"]
        if SEAL:
            argv = ["bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--tmpfs",
                    "/run", "--bind", str(self.work), str(self.work), *(["--bind", str(boot), "/boot"] if boot else []),
                    "--unshare-all", "--die-with-parent", "--new-session", *argv]
        ran = subprocess.run(argv, env={"PATH": f"{folder}:/usr/bin:/bin", "HOME": str(self.home), "LANG": "C.UTF-8"},
                             capture_output=True, text=True, timeout=60)
        return ran, (log.read_text().splitlines() if log.exists() else [])

    def test_refuses_on_nvidia_and_on_dkms_with_nothing_changed(self):
        for lspci_out, dkms_out, found in ((NVIDIA, "", "an NVIDIA GPU (lspci)"),
                                           (INTEL, "zfs/2.3.4, 6.17.7-arch1-1, x86_64: installed\n", "DKMS modules")):
            with self.subTest(found):
                ran, sudo_calls = self.harden(lspci_out, dkms_out)
                out = ran.stdout + ran.stderr
                self.assertEqual(ran.returncode, 1, out)
                self.assertIn(f"refusing: this machine has {found}", out)
                self.assertIn("Nothing was changed.", out)
                self.assertNotIn("usage:", out, "a refusal is not a usage error")
                self.assertEqual(sudo_calls, [], "nothing was run as root")

    def test_disable_exits_with_the_layers_status_too(self):
        for argv, want in (([BASH, str(HARDEN), "disable", "nonsense"], "unknown: nonsense"),
                           ([BASH, str(HARDEN), "disable"], "usage: desk harden disable <layer>")):
            with self.subTest(argv[2:]):
                ran, sudo_calls = self.harden(INTEL, argv=argv)
                self.assertEqual(ran.returncode, 2, ran.stdout + ran.stderr)
                self.assertIn(want, ran.stdout)
                self.assertEqual(sudo_calls, [], "nothing was run as root")

    def test_a_check_that_fails_refuses_too(self):
        """Anything but a clear no refuses: here the check stops with status 2, as one a shell cannot run would."""
        ran, sudo_calls = self.harden(INTEL, argv=[BASH, "-c", 'source "$1"; lockdown_blocks_modules() { return 2; }; '
                                                   "install_iommu", "_", str(MAPPINGS)])
        self.assertEqual(ran.returncode, 1, ran.stdout + ran.stderr)
        self.assertIn("refusing: the check for an NVIDIA GPU or DKMS modules failed (status 2)", ran.stdout)
        self.assertEqual(sudo_calls, [], "nothing was run as root")

    @unittest.skipUnless(SEAL, "needs bwrap: the plain-machine run edits a boot entry")
    def test_a_plain_machine_still_gets_iommu_and_lockdown(self):
        cpu = Path("/proc/cpuinfo").read_text()
        vendor = "intel" if "GenuineIntel" in cpu else "amd" if "AuthenticAMD" in cpu else None
        if not vendor:
            self.skipTest("a CPU desk harden does not know")
        boot = self.work / "boot"
        entries = boot / "loader/entries"
        entries.mkdir(parents=True)
        entry = entries / "arch.conf"
        entry.write_text("title Arch\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=1234 rw quiet\n")
        ran, _ = self.harden(INTEL, sudo='exec "$@"', boot=boot)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertIn(f"options {vendor}_iommu=on iommu=pt lockdown=integrity root=UUID=1234 rw quiet\n", entry.read_text())
        self.assertTrue((entries / "arch.conf.foxml-bak").exists())
        before = entry.read_text()
        ran, _ = self.harden(INTEL, sudo='exec "$@"', boot=boot)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertIn("IOMMU already enabled", ran.stdout)
        self.assertEqual(entry.read_text(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
