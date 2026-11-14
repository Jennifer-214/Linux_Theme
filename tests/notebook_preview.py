#!/usr/bin/env python3
"""Print the Claude notebook as it would be drawn, with sample data, without installing anything.

The scenes are in shared/claude/mods/desk-notebook/tests/preview.test.tsx and go through the mod's real drawing code
under Claude Code's own test kit; this prints each drawn tree as coloured text.

Usage: tests/notebook_preview.py [--theme Paper] [--scene WORDS] [--plain]
"""
import importlib.util
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RENDER = ROOT / 'src/desk-render/desk-render-fast'


def colour(text, fg=None, bg=None, bold=False, plain=False):
    if plain or text == '' or not (fg or bg or bold):
        return text
    codes = []
    for value, lead in ((fg, 38), (bg, 48)):
        if isinstance(value, str) and len(value) == 7 and value.startswith('#'):
            codes.append(f'{lead};2;{int(value[1:3], 16)};{int(value[3:5], 16)};{int(value[5:7], 16)}')
    if bold:
        codes.append('1')
    return f'\x1b[{";".join(codes)}m{text}\x1b[0m' if codes else text


def inline(node, plain, fg=None, bg=None, bold=False, focused=False):
    """Text and Button content as one run of coloured text. A terminal inverts the focused Button, and the mod gives
    that one the reversed pair so it reads right; the same swap is made here."""
    if isinstance(node, str):
        return colour(node, bg if focused and bg else fg, fg if focused and bg else bg, bold, plain)
    if not isinstance(node, dict):
        return ''
    props = node.get('props') or {}
    kind = node.get('type')
    fg, bg = props.get('color', fg), props.get('backgroundColor', bg)
    bold = bold or props.get('weight') == 'bold' or props.get('bold') is True
    children = node.get('children') or []
    focused = focused or (kind == 'Button' and props.get('autoFocus') is True)
    if kind == 'Input':
        return colour('▏' + (props.get('value') or props.get('placeholder') or '') + ' ', fg, bg, bold, plain)
    if kind == 'Button' and not children:
        return colour(str(props.get('label', '')), fg, bg, bold, plain)
    return ''.join(inline(child, plain, fg, bg, bold, focused) for child in children)


def lines(node, plain):
    """Boxes stack their children (or run them along a row); everything else is a line of text."""
    if isinstance(node, dict) and node.get('type') == 'Box':
        props = node.get('props') or {}
        children = node.get('children') or []
        if props.get('flexDirection') == 'column':
            out = []
            for child in children:
                out.extend(lines(child, plain))
            return out
        return [''.join(''.join(lines(child, plain)) for child in children)]
    return inline(node, plain).split('\n')


def scenes(theme):
    spec = importlib.util.spec_from_file_location('mod_test', ROOT / 'tests/test_claude_mod.py')
    kit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kit)
    case = kit.PaperMod('test_the_code_holds_no_template_tokens')
    try:
        mod = case.stage(theme)
        ran = subprocess.run(['claude', 'plugin', 'test', str(mod)], capture_output=True, text=True, timeout=300, cwd=mod.parent)
    finally:
        case.doCleanups()
    found = [json.loads(line[len('@@PREVIEW '):]) for line in (ran.stdout + ran.stderr).splitlines() if line.startswith('@@PREVIEW ')]
    return found, ran


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--theme', default='Paper')
    parser.add_argument('--scene', default='')
    parser.add_argument('--plain', action='store_true')
    parser.add_argument('--colour', action='store_true')
    args = parser.parse_args(argv)
    if not shutil.which('claude'):
        print('Claude Code is not installed: the preview runs the mod under its test kit.')
        return 1
    if not RENDER.exists():
        print('Build first (make): the preview renders the theme colours.')
        return 1
    wanted = args.scene.lower()
    plain = args.plain or not sys.stdout.isatty() and not args.colour
    found, ran = scenes(args.theme)
    if ran.returncode != 0:
        report = '\n'.join(line for line in (ran.stdout + ran.stderr).splitlines() if not line.startswith('@@PREVIEW '))
        print('Notebook tests failed; the preview is incomplete.\n' + report[-3000:], file=sys.stderr)
        return 1
    if not found:
        print('No scene was drawn.\n' + (ran.stdout + ran.stderr)[-1500:])
        return 1
    if wanted and not any(wanted in scene['name'].lower() for scene in found):
        print('No scene matches ' + repr(args.scene), file=sys.stderr)
        return 2
    for scene in found:
        if wanted and wanted not in scene['name'].lower():
            continue
        print(colour(f"── {scene['name']} ", bold=True, plain=plain) + '─' * max(2, 44 - len(scene['name']) - 4))
        for line in lines(scene['tree'], plain):
            print(' ' + line)
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
