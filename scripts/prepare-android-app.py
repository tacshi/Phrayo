#!/usr/bin/env python3
"""Fetch checksum-pinned Android runtime artifacts."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

if __name__ == '__main__':
    target = ROOT / 'build/android-deps'
    target.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / 'native/android-voice/dependencies.json').read_text())
    for name, entry in lock['android_artifacts'].items():
        file = target / name
        if file.exists() and hashlib.sha256(file.read_bytes()).hexdigest() == entry['sha256']:
            continue
        staged = file.with_suffix('.partial')
        with urllib.request.urlopen(entry['url'], timeout=60) as response, staged.open('wb') as output:
            shutil.copyfileobj(response, output)
        if hashlib.sha256(staged.read_bytes()).hexdigest() != entry['sha256']:
            staged.unlink()
            raise SystemExit(f'Checksum mismatch: {name}')
        staged.replace(file)
    subprocess.run([str(ROOT / 'scripts/build-android-voice-native.sh')], check=True)
    subprocess.run([str(ROOT / 'scripts/prepare-android-voice-assets.sh')], check=True)
