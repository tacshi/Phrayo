#!/usr/bin/env python3
"""Build the pinned MLX kernels for the current iOS SDK; cache by actual inputs."""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MLX_REVISION = 'dc43e62d7055353c7f99fa071a4e71d29dfddc44'

def main():
    platform = os.environ.get('PLATFORM_NAME', '')
    if platform not in ('iphoneos', 'iphonesimulator'):
        raise SystemExit('Voice Metal build requires an iOS device or simulator SDK.')
    candidates = []
    if os.environ.get('MLX_SOURCE_PATH'):
        candidates.append(Path(os.environ['MLX_SOURCE_PATH']))
    candidates.append(ROOT / 'build/ios/SourcePackages/checkouts/mlx-swift')
    if os.environ.get('BUILD_DIR'):
        build = Path(os.environ['BUILD_DIR'])
        candidates += [build/'SourcePackages/checkouts/mlx-swift', build.parent.parent/'SourcePackages/checkouts/mlx-swift']
    checkout = None
    for path in candidates:
        if not path.is_dir():
            continue
        revision = subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if revision.returncode == 0 and revision.stdout.strip() == MLX_REVISION:
            checkout = path
            break
    if checkout is None:
        raise SystemExit('Pinned MLX checkout not found. Resolve Swift packages or set MLX_SOURCE_PATH.')
    source = checkout / 'Source/Cmlx/mlx'
    kernels = source / 'mlx/backend/metal/kernels'
    files = sorted(p for p in kernels.rglob('*.metal') if not p.name.endswith('_nax.metal'))
    if not files:
        raise SystemExit('No MLX Metal kernels found.')
    deployment = os.environ.get('IPHONEOS_DEPLOYMENT_TARGET', '26.0')
    triple = f'air64-apple-ios{deployment}' + ('-simulator' if platform == 'iphonesimulator' else '')
    flags = ['-x', 'metal', '-target', triple, '-fno-fast-math', '-Wno-c++17-extensions', '-Wno-c++20-extensions']
    digest = hashlib.sha256((MLX_REVISION + platform + str(flags)).encode())
    digest.update(subprocess.check_output(['xcrun', '-sdk', platform, 'metal', '--version']))
    digest.update(subprocess.check_output(['xcrun', '-sdk', platform, '--show-sdk-version']))
    for path in sorted(set(files) | set((source/'mlx').rglob('*.h'))):
        digest.update(str(path.relative_to(source)).encode())
        digest.update(path.read_bytes())
    cache = ROOT/'build/voice-metal'/platform/digest.hexdigest()
    library = cache/'mlx.metallib'
    cache.mkdir(parents=True, exist_ok=True)
    if not library.exists():
        print(f'Building {len(files)} MLX kernels for {platform}', flush=True)
        def compile_one(path):
            output = cache/(hashlib.sha256(str(path.relative_to(kernels)).encode()).hexdigest()[:16]+'.air')
            if not output.exists():
                command = ['xcrun', '-sdk', platform, 'metal', *flags, '-c', str(path),
                           '-I'+str(kernels), '-I'+str(source), '-o', str(output)]
                result = subprocess.run(command, capture_output=True, text=True)
                if result.returncode:
                    output.unlink(missing_ok=True)
                    raise RuntimeError(result.stderr)
            return output
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            objects = list(executor.map(compile_one, files))
        staged = cache/'mlx-building.metallib'
        subprocess.run(['xcrun', '-sdk', platform, 'metallib', *map(str, objects), '-o', str(staged)], check=True)
        staged.replace(library)
    target = Path(os.environ['TARGET_BUILD_DIR'])/os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']/'mlx.metallib'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(library, target)
    print(f'Packaged {platform} voice kernels: {target}', flush=True)

if __name__ == '__main__':
    main()
