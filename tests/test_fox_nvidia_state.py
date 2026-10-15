#!/usr/bin/env python3
"""Test for shared/bin/fox-nvidia-state — the one "can nvidia-smi be asked?" answer the GPU bar modules share.

A fake nvidia-smi (its mismatch text as an NVIDIA update without a reboot printed it, 2026-10-15) and a fake NVML
library link; every nvidia-smi call is counted. Checks: the mismatch answer and its versions; one call per boot, then
none; asked again when the library changes (the update); "ok" kept; "none" without nvidia-smi; another failure is not
a mismatch; gpu-stats.sh says "reboot" without asking nvidia-smi (when this machine has an active NVIDIA GPU), and both
modules consult the state before their nvidia-smi calls.

Run directly (`python3 tests/test_fox_nvidia_state.py`) or via `make test` (the test-scripts target).
Exit 0 = pass, 1 = fail. Dependency-free.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "shared/bin/fox-nvidia-state"
GPU_STATS = ROOT / "shared/waybar_scripts/gpu-stats.sh"
OVERWATCH = ROOT / "shared/waybar_scripts/hw_overwatch.sh"

fails = []
def check(name, cond):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


# not /tmp: it may be mounted noexec, and the fake nvidia-smi must run
cache_home = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
TMP = Path(tempfile.mkdtemp(prefix="fox-nvstate-test-", dir=cache_home if os.path.isdir(cache_home) else None))
try:
    log = TMP / "smi.log"
    smi = TMP / "bin" / "nvidia-smi"
    smi.parent.mkdir()
    smi.write_text(
        "#!/bin/sh\n"
        f'echo "$*" >> "{log}"\n'
        'case "$FAKE_SMI" in\n'
        '  mismatch) printf "Failed to initialize NVML: Driver/library version mismatch\\nNVML library version: 615.78\\n"; exit 18;;\n'
        '  broken) echo "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver."; exit 9;;\n'
        '  *) case "$1" in -L) echo "GPU 0: NVIDIA T1200 Laptop GPU (UUID: GPU-0)";; *) echo "45, 3";; esac;;\n'
        "esac\n")
    smi.chmod(0o755)
    libdir = TMP / "lib"
    libdir.mkdir()
    for v in ("615.71.09", "615.78.08"):
        (libdir / f"libnvidia-ml.so.{v}").write_text("")
    link = libdir / "libnvidia-ml.so.1"
    link.symlink_to("libnvidia-ml.so.615.71.09")
    version = TMP / "version"
    version.write_text("NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build  (root@)\n")
    run_dir = TMP / "run"
    run_dir.mkdir()

    def helper(mode, smi_path=None):
        env = dict(os.environ, FOX_NVIDIA_SMI=str(smi_path or smi), FOX_NVML_LIB=str(link),
                   FOX_NVIDIA_VERSION=str(version), XDG_RUNTIME_DIR=str(run_dir), FAKE_SMI=mode)
        r = subprocess.run(["bash", str(HELPER)], env=env, capture_output=True, text=True, timeout=30)
        return r.stdout.strip(), r.returncode

    def calls():
        return len(log.read_text().splitlines()) if log.exists() else 0

    # 1 · the update without a reboot
    out, rc = helper("mismatch")
    check(f"mismatch → the module and library versions (got {out!r})", out == "mismatch 615.71.09 615.78" and rc == 0)
    check("…asked nvidia-smi once (the cheapest call, -L)", calls() == 1 and log.read_text().strip() == "-L")
    for _ in range(3):
        out, _ = helper("mismatch")
    check(f"…and never again: 3 more answers, no more calls (got {calls()} call(s), {out!r})",
          calls() == 1 and out == "mismatch 615.71.09 615.78")
    # 2 · another update replaces the library file: asked again at once
    link.unlink()
    link.symlink_to("libnvidia-ml.so.615.78.08")
    out, _ = helper("mismatch")
    check(f"a changed NVML library is asked again (got {calls()} calls)", calls() == 2 and out.startswith("mismatch"))
    # 3 · after the reboot (the runtime dir is empty again), all well: "ok", kept
    shutil.rmtree(run_dir)
    run_dir.mkdir()
    out, _ = helper("ok")
    out2, _ = helper("ok")
    check(f"after a reboot: ok, asked once (got {out!r}, {out2!r}, {calls()} calls)", out == out2 == "ok" and calls() == 3)
    check("the state file is written whole (no temporary left)",
          sorted(p.name for p in (run_dir / "foxml-waybar").iterdir()) == ["nvidia-state"])
    # 4 · no nvidia-smi at all
    out, _ = helper("ok", smi_path=TMP / "bin" / "no-such-nvidia-smi")
    check(f"no nvidia-smi → none (got {out!r})", out == "none")
    # 5 · another failure is the caller's to handle, not a mismatch
    shutil.rmtree(run_dir)
    run_dir.mkdir()
    out, _ = helper("broken")
    check(f"a driver-comms failure is not a mismatch (got {out!r})", out == "ok")

    # 6 · the modules: both consult the state before nvidia-smi
    g = GPU_STATS.read_text()
    o = OVERWATCH.read_text()
    check("gpu-stats.sh answers a mismatch before its nvidia-smi stats call",
          0 < g.find("fox-nvidia-state") < g.find("nvidia-smi --query-gpu"))
    check("hw_overwatch.sh skips its GPU scan on a mismatch",
          0 < o.find("fox-nvidia-state") < o.find("nvidia-smi --query-compute-apps") and "!= mismatch" in o)
    # …and gpu-stats.sh, run for real where this machine has an active NVIDIA display GPU (its sysfs check)
    active = False
    for dev in Path("/sys/bus/pci/devices").glob("*/"):
        try:
            if (dev / "vendor").read_text().strip() == "0x10de" and (dev / "class").read_text().startswith("0x03"):
                active = (dev / "power/runtime_status").read_text().strip() == "active"
                break
        except OSError:
            continue
    if active:
        shutil.rmtree(run_dir)
        run_dir.mkdir()
        before = calls()
        env = dict(os.environ, PATH=f"{smi.parent}:{os.environ['PATH']}", FOX_NVIDIA_STATE=str(HELPER),
                   FOX_NVIDIA_SMI=str(smi), FOX_NVML_LIB=str(link), FOX_NVIDIA_VERSION=str(version),
                   XDG_RUNTIME_DIR=str(run_dir), FAKE_SMI="mismatch")
        r = subprocess.run(["bash", str(GPU_STATS)], env=env, capture_output=True, text=True, timeout=30)
        check(f"gpu-stats.sh on a mismatch: the reboot notice, amber (got {r.stdout.strip()[:90]!r})",
              "⚠ reboot" in r.stdout and '"class":"warning"' in r.stdout)
        check("…having asked nvidia-smi only the helper's one -L (no stats query)",
              calls() == before + 1 and log.read_text().splitlines()[-1] == "-L")
    else:
        print("  skip gpu-stats.sh run: no active NVIDIA display GPU here (its own sysfs check would stop first)")
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall checks passed")
sys.exit(1 if fails else 0)
