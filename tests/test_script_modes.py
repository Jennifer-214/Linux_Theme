#!/usr/bin/env python3
"""tests/test_script_modes.py — every script the installer copies is stored executable. A copy keeps the source's
mode, so a script stored 0644 deploys 0644 and the key that runs it does nothing (the volume and brightness keys,
2026-11). Read from git's index: that is the mode a fresh clone gets."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
listed = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-s', '--', 'shared/bin', 'shared/hyprland_scripts', 'shared/waybar_scripts'],
                        capture_output=True, text=True, check=True).stdout
stored_plain = []
for line in listed.splitlines():
    meta, path = line.split('\t', 1)
    if meta.split()[0] != '100644' or not (ROOT / path).is_file():
        continue
    with open(ROOT / path, 'rb') as f:
        if f.read(2) == b'#!':
            stored_plain.append(path)
if stored_plain:
    print('    scripts stored without the exec bit (git update-index --chmod=+x):\n      ' + '\n      '.join(stored_plain))
    sys.exit(1)
print('    script modes: every deployed script is stored executable')
