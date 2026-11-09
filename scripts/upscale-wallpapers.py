#!/usr/bin/env python3
"""Prepare exact 4K wallpaper bases with installed local tools; retain source originals."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WALLS = ROOT/'shared/wallpapers'


def dimensions(path):
    return tuple(map(int, subprocess.check_output(['magick', 'identify', '-format', '%w %h', str(path)], text=True).split()))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pencil_paper(source, output, target, folder):
    """Keep the original hatching, then add graphite tooth and warm paper fibers."""
    size = f'{target[0]}x{target[1]}'
    pencil = folder/'pencil.png'
    multiplied = folder/'multiplied.png'
    mask = folder/'art-mask.png'
    clean = folder/'pencil-art.png'
    enlarged = folder/'enlarged.png'
    grain = folder/'tooth.png'
    fibers = folder/'fibers.png'
    textured = folder/'textured.png'
    if source.stem != 'foxml_paper_quiet':
        subprocess.run(['magick', str(source), '-colorspace', 'gray', '-seed', '42', '-sketch', '0x6+135', str(pencil)], check=True)
        subprocess.run(['magick', str(source), str(pencil), '-compose', 'Multiply', '-composite', str(multiplied)], check=True)
        subprocess.run(['magick', str(source), '-fuzz', '7%', '-transparent', '#f0ede7', '-alpha', 'extract', '-blur', '0x0.5', str(mask)], check=True)
        subprocess.run(['magick', str(source), str(multiplied), str(mask), '-compose', 'Over', '-composite', str(clean)], check=True)
    else:
        clean = source
    subprocess.run(['magick', str(clean), '-filter', 'Lanczos', '-resize', size+'^', '-gravity', 'center', '-extent', size, str(enlarged)], check=True)
    subprocess.run(['magick', '-size', size, 'xc:gray50', '-seed', '314159', '+noise', 'Gaussian',
                    '-colorspace', 'Gray', '-evaluate', 'Subtract', '50%', '-evaluate', 'Multiply', '0.12',
                    '-evaluate', 'Add', '99.5%', str(grain)], check=True)
    subprocess.run(['magick', '-size', '768x432' if target[0] > target[1] else '432x768', 'xc:gray50',
                    '-seed', '271828', '+noise', 'Gaussian', '-colorspace', 'Gray', '-motion-blur', '0x2+12',
                    '-resize', size+'!', '-evaluate', 'Subtract', '50%', '-evaluate', 'Multiply', '0.16',
                    '-evaluate', 'Add', '99.8%', str(fibers)], check=True)
    subprocess.run(['magick', str(enlarged), str(grain), '-compose', 'Multiply', '-composite', str(fibers),
                    '-compose', 'Multiply', '-composite', str(textured)], check=True)
    command = ['magick', str(textured)]
    if source.stem not in {'foxml_paper_quiet', 'foxml_paper_soft'}:
        font = 'DejaVu-Sans-Oblique'
        if shutil.which('fc-match'):
            found = subprocess.check_output(['fc-match', '-f', '%{file}', 'MonaspiceRn Nerd Font:style=Italic'], text=True).strip()
            if found and Path(found).is_file():
                font = found
        # Small sketchbook marks live in the margins; the reading area stays clear.
        command += ['-font', font, '-pointsize', '46', '-fill', 'rgba(94,81,72,0.40)', '-gravity', 'NorthWest',
                    '-annotate', '+150+170', 'field notes', '-fill', 'none', '-stroke', 'rgba(113,131,103,0.32)',
                    '-strokewidth', '1.4', '-draw', 'path "M 151,235 C 235,229 310,241 398,233"',
                    '-stroke', 'rgba(94,81,72,0.20)', '-strokewidth', '1.1',
                    '-draw', 'path "M 150,265 L 245,264 M 150,282 L 207,284 M 111,169 L 110,208"']
    command += ['-strip', '-depth', '8', '-define', 'png:color-type=2', '-define', 'png:compression-level=9', str(output)]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--paper-sketch', action='store_true', help='reprocess Paper from untouched originals with pencil and fibrous paper texture')
    parser.add_argument('--apply', action='store_true', help='write separate source originals and replace processed bases')
    args = parser.parse_args()
    if not shutil.which('magick'):
        parser.error('ImageMagick is not installed')
    planned = []
    for path in sorted(WALLS.iterdir()):
        if path.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.webp'} or re.search(r'_(?:\d+x\d+|portrait)$', path.stem):
            continue
        original = WALLS/'source'/path.name
        input_path = original if args.paper_sketch and original.exists() and path.stem.startswith('foxml_paper_') else path
        width, height = dimensions(input_path)
        target = (3840, 2160) if width >= height else (2160, 3840)
        sketch = args.paper_sketch and path.stem.startswith('foxml_paper_')
        if not sketch and width >= target[0] and height >= target[1]:
            continue
        method = 'realesrgan-x4plus + Lanczos' if path.stem.startswith('foxml_paper_') and path.stem != 'foxml_paper_quiet' else 'Lanczos'
        if sketch:
            method = 'pencil hatching + paper fibers + Lanczos 4K'
        planned.append((path, (width, height), target, method))
    print(json.dumps([{'file': p.name, 'source': source, 'target': target, 'method': method}
                      for p, source, target, method in planned], indent=2), flush=True)
    if not args.apply:
        return
    if any('realesrgan' in item[3] for item in planned) and not shutil.which('realesrgan-ncnn-vulkan'):
        parser.error('The local Real-ESRGAN executable is required for the illustrated originals')
    manifest_path = WALLS/'4k-processing.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {'processing': 'Local upscaling, not native 4K generation', 'files': {}}
    for path, source, target, method in planned:
        original = WALLS/'source'/path.name
        # Some older photographic sources predate the processed base. Preserve
        # those too; a new source copy is made only when none was archived.
        if not original.exists():
            original.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, original)
        before = digest(original)
        # Always read the base that was reviewed when planning. The archived
        # original may be older artwork; never rewrite it or upscale in place.
        with tempfile.TemporaryDirectory(prefix='foxml-local-4k-') as temp:
            intermediate = Path(temp)/'reconstructed.png'
            source_path = path
            if method.startswith('pencil'):
                output = Path(temp)/path.name
                pencil_paper(original, output, target, Path(temp))
            elif 'realesrgan' in method:
                log = Path(temp)/'realesrgan.log'
                with log.open('w') as stream:
                    result = subprocess.run(['realesrgan-ncnn-vulkan', '-i', str(path), '-o', str(intermediate),
                                             '-n', 'realesrgan-x4plus', '-s', '4', '-t', '256', '-j', '1:2:1'],
                                            stdout=stream, stderr=subprocess.STDOUT)
                if result.returncode:
                    raise RuntimeError('Local reconstruction failed for '+path.name+': '+log.read_text()[-1000:])
                source_path = intermediate
            output = Path(temp)/path.name
            if not method.startswith('pencil'):
                size = f'{target[0]}x{target[1]}'
                command = ['magick', str(source_path), '-filter', 'Lanczos', '-resize', size+'^',
                           '-gravity', 'center', '-extent', size, '-strip', '-depth', '8']
                if path.suffix.lower() in {'.jpg', '.jpeg'}:
                    command += ['-quality', '95']
                subprocess.run(command+[str(output)], check=True)
            assert dimensions(output) == target
            assert digest(original) == before, 'Archived original changed'
            shutil.copy2(output, path)
        manifest['files'][path.name] = {'source_size': source, 'output_size': target, 'method': method,
                                        'original': str(original.relative_to(ROOT)), 'original_sha256': before,
                                        'output_sha256': digest(path)}
        manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
        print('Prepared', path.name, 'at', f'{target[0]}×{target[1]}', 'using', method, flush=True)


if __name__ == '__main__':
    main()
