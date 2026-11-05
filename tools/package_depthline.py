#!/usr/bin/env python3
"""Package only independently generated resources, with a provenance inventory."""
import hashlib
import json
import re
from collections import Counter
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_SOURCE = Path('remastered-assets/depthline-icon.png')
ICON_NAME = 'Depthline.icns'
TRANSLATIONS = ('ko', 'ja', 'fr', 'es', 'pt', 'ru', 'id', 'vi', 'th')


def build_app_icon(source, output):
    """Compile the five standard AppKit sizes at 1x and 2x from a single PNG."""
    with source.open('rb') as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
        raise ValueError(f'Invalid PNG icon source: {source}')
    width, height = struct.unpack('>II', header[16:24])
    if width != height or width < 1024:
        raise ValueError(f'The app icon must be square and at least 1024 px wide; got {width}×{height}')

    with tempfile.TemporaryDirectory(dir=output.parent) as work:
        iconset = Path(work) / 'Depthline.iconset'
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = str(points * scale)
                suffix = '@2x' if scale == 2 else ''
                variant = iconset / f'icon_{points}x{points}{suffix}.png'
                subprocess.run(['/usr/bin/sips', '-z', pixels, pixels, source, '--out', variant],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', '-o', output, iconset], check=True)


def package_resources(dest, icon):
    if dest.exists():
        shutil.rmtree(dest)  # Rebuildable output, never source or user saves.
    dest.mkdir(parents=True)
    scenes = ROOT / 'original-assets/scenes'
    audio = ROOT / 'original-assets/audio'
    sounds = json.loads((audio / 'manifest.json').read_text())['files']
    scene_files = ['scene.json', 'levels.json', 'heightmap.bin', 'collision.json', 'fragments.json',
                   'textures/TerrainDepthline.png', 'textures/OceanDepthline.png', 'textures/Glow.png']
    for sector, label in [('coast', 'field-coast'), ('interior', 'field-interior')]:
        for name in scene_files + (['wrecks.json'] if sector == 'coast' else []):
            target = dest / label / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(scenes / sector / name, target)
    for entry in sounds:
        name = Path(entry['path'])
        if name.is_absolute() or '..' in name.parts or name.suffix != '.wav' or name.parts[0] not in ('sounds', 'menu'):
            raise ValueError(f'Invalid audio manifest path: {name}')
        source = audio / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError(f'Audio does not match the manifest: {name}')
        targets = ([dest / sector / name for sector in ('field-coast', 'field-interior')]
                   if name.parts[0] == 'sounds' else [dest / 'launcher-assets' / name.relative_to('menu')])
        for target in targets:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    (dest / 'remastered-assets').mkdir()
    selected = ['sand', 'grass', 'rock', 'ocean', 'sky-day', 'sky-night', 'sky-clouds-depthline',
                'explosion-atlas', 'smoke-atlas', 'muzzle-atlas', 'menu-2000', 'menu-2002', 'menu-training']
    for name in selected:
        shutil.copy2(ROOT / 'remastered-assets' / f'{name}.png', dest / 'remastered-assets' / f'{name}.png')
    shutil.copyfile(icon, dest / ICON_NAME)
    (dest / 'credits').mkdir()
    for file_name in ('fourthbeam.png', 'codex.png'):
        shutil.copyfile(ROOT / 'native/credits' / file_name, dest / 'credits' / file_name)
    (dest / 'locales').mkdir()
    catalog_keys = None
    for tag in TRANSLATIONS:
        src = ROOT / 'native/locales' / f'{tag}.json'
        phrases = json.loads(src.read_text(encoding='utf-8'))
        if catalog_keys is None:
            catalog_keys = set(phrases)
        if set(phrases) != catalog_keys:
            raise ValueError(f'Mismatched translation keys in {src}')
        for key, value in phrases.items():
            slots = r'\{\d+\}'
            if not value.strip() or Counter(re.findall(slots, key)) != Counter(re.findall(slots, value)):
                raise ValueError(f'Invalid translated text or placeholders in {src}: {key}')
        shutil.copyfile(src, dest / 'locales' / src.name)
    for language in ['en', 'zh-Hans', 'zh-Hant', *TRANSLATIONS]:
        title = {'zh-Hans': '纵深防线', 'zh-Hant': '縱深防線'}.get(language, 'Depthline')
        localized = dest / f'{language}.lproj'
        localized.mkdir()
        (localized / 'InfoPlist.strings').write_text(
            f'"CFBundleDisplayName" = "{title}";\n"CFBundleName" = "{title}";\n', encoding='utf-8')

    inventory = []
    for path in sorted(dest.rglob('*')):
        if not path.is_file():
            continue
        name = str(path.relative_to(dest))
        entry = {'path': name, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        if name == ICON_NAME:
            entry.update(origin='Project-generated application artwork; macOS icon family compiled with sips and iconutil',
                         source=str(ICON_SOURCE), sourceSHA256=hashlib.sha256((ROOT / ICON_SOURCE).read_bytes()).hexdigest())
        elif name == 'credits/fourthbeam.png':
            entry.update(origin='FourthBeam mark supplied by the developer', source='native/credits/fourthbeam.png')
        elif name == 'credits/codex.png':
            entry.update(origin='Codex dark icon from the official OpenAI desktop app, resized for the producer credit',
                         source='https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app')
        elif name.startswith('locales/') or '.lproj/' in name:
            entry['origin'] = 'Project-authored interface localization'
        elif name.startswith('remastered-assets/'):
            entry['origin'] = 'Text-prompt generated image; project generation records retained in development source'
        else:
            entry['origin'] = 'Original programmatic synthesis, procedural scenery or newly authored mission data'
        inventory.append(entry)
    provenance = {'title': '纵深防线',
                  'sources': ['tools/generate_depthline_assets.py', 'tools/generate_original_audio.py',
                              'remastered-assets/manifest.json', 'original-assets/sky-generation.json',
                              'tools/package_depthline.py', str(ICON_SOURCE)],
                  'resources': inventory}
    (dest / 'ASSET-PROVENANCE.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2))

    report = {'title': '纵深防线', 'packagedResources': len(inventory), 'allowlistOnly': True}
    (ROOT / 'build/depthline-package-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('PASS: packaged', len(inventory), 'resources from the project allowlist')


if __name__ == '__main__':
    # Validate and compile the icon before touching an existing Resources directory.
    with tempfile.TemporaryDirectory() as work:
        icon = Path(work) / ICON_NAME
        build_app_icon(ROOT / ICON_SOURCE, icon)
        package_resources(ROOT / 'build/Depthline.app/Contents/Resources', icon)
