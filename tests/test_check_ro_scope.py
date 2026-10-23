#!/usr/bin/env python3
"""check_ro scope guard (installer batch 3a, 2026-10-23). Two promises, checked in the source on every `make test`:
1. Every sh::check_ro call starts with a form shell.cpp's is_read_only() accepts (systemctl [--user] is-active|is-enabled,
   grep -q …) — so no call site can depend on the runtime refusal.
2. No red-zone module uses check_ro: batch 3a changed no check inside fstab / PAM / bootloader / greetd / mount / sysctl
   / firewall code — those conversions are batch 3b, behind a VM test (plans/2026-10-23-installer-batch3.md)."""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODS = ROOT / "src/fox-install/modules"
RED_ZONE = ["greetd", "greetd_fingerprint", "fprint", "fprint_pam", "sudo_fingerprint", "hyprlock_pam", "ufw", "security",
            "noexec_tmp", "hidepid", "iommu", "lockdown_heal", "nvidia", "perf", "boot_sync", "recovery_entry",
            "foxml_health_boot", "ssh_harden", "privacy"]
fails = []
calls = []
for f in sorted((ROOT / "src").rglob("*.cpp")):
    if "tests" in f.parts:   # a test may call a refused form on purpose (test_check_ro.cpp does)
        continue
    text = f.read_text(errors="replace")
    for m in re.finditer(r"sh::check_ro\(\{\s*((?:\"[^\"]*\"\s*,\s*)*\"[^\"]*\")", text):
        lits = re.findall(r"\"([^\"]*)\"", m.group(1))
        calls.append((f, lits))
        ok = (lits[0] == "systemctl" and (lits[1:2] in (["is-active"], ["is-enabled"]) or lits[1:3] in (["--user", "is-active"], ["--user", "is-enabled"]))) \
            or (lits[0] == "grep" and "-q" in lits)
        if not ok:
            fails.append(f"{f.relative_to(ROOT)}: check_ro form not in the read-only list: {lits[:3]}")
for name in RED_ZONE:
    f = MODS / f"{name}.cpp"
    if f.exists() and "sh::check_ro(" in f.read_text(errors="replace"):
        fails.append(f"{f.relative_to(ROOT)}: a red-zone module uses check_ro — batch 3b, behind the VM test")
if not calls:
    fails.append("no sh::check_ro calls found — the scan is broken")
for x in fails:
    print("FAIL", x)
print(f"check_ro scope: {'OK' if not fails else f'{len(fails)} FAILED'} ({len(calls)} call sites)")
sys.exit(1 if fails else 0)
