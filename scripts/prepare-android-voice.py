#!/usr/bin/env python3
"""Fetch only locked native sources and prepare the core-only build tree."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / 'build/android-native'


def prepare():
    lock = json.loads((ROOT / 'native/android-voice/dependencies.json').read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name, entry in lock['sources'].items():
        archive = CACHE / f'{name}.tar.gz'
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != entry['archive_sha256']:
            url = f"https://codeload.github.com/{entry['repository']}/tar.gz/{entry['revision']}"
            staged = archive.with_suffix('.partial')
            print(f'Downloading {name} @ {entry["revision"]}', flush=True)
            with urllib.request.urlopen(url, timeout=60) as response, staged.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(staged.read_bytes()).hexdigest() != entry['archive_sha256']:
                staged.unlink()
                raise RuntimeError(f'{name} archive checksum mismatch')
            staged.replace(archive)
        source = CACHE / entry['directory']
        if not source.exists():
            with tarfile.open(archive) as content:
                content.extractall(CACHE, filter='data')
        sources[name] = source

    source = sources['cosyvoice']
    pcre = source / 'vendor/pcre2'
    if pcre.is_dir() and not any(pcre.iterdir()):
        pcre.rmdir()
    if not pcre.exists():
        pcre.symlink_to(sources['pcre2'], target_is_directory=True)
    cmake = source / 'CMakeLists.txt'
    original = cmake.read_text()
    modified = original.replace('add_subdirectory(tools)',
        'if(NOT PHRAYO_CORE_ONLY)\n    add_subdirectory(tools)\nendif()')
    modified = modified.replace('include(cmake/Install.cmake)',
        'if(NOT PHRAYO_CORE_ONLY)\n    include(cmake/Install.cmake)\nendif()')
    # Apply once, without nesting the same guard on subsequent builds.
    if 'if(NOT PHRAYO_CORE_ONLY)' not in original:
        if modified == original:
            raise RuntimeError('Upstream core-only patch no longer applies')
        cmake.write_text(modified)
    print('Native sources ready', flush=True)


if __name__ == '__main__':
    prepare()
