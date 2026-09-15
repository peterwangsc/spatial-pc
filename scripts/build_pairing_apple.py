#!/usr/bin/env python3
"""Build pinned, unmodified BoringSSL crypto and the small PAKE wrapper.

Prerequisites: Xcode, CMake, Git. No global installs or binary downloads.
Usage: python3 scripts/build_pairing_apple.py macosx xros xrsimulator
Outputs stay under ignored .local/pairing/. Existing product sessions are untouched.
"""
import argparse
import json
from pathlib import Path
import subprocess
import shutil

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('platforms', nargs='+', choices=['macosx', 'xros', 'xrsimulator'])
    parser.add_argument('--source', type=Path, help='Existing clean checkout at the pinned commit')
    args = parser.parse_args()
    lock = json.loads((ROOT/'shared/pairing/boringssl.lock.json').read_text())
    source = (args.source or ROOT/'.local/dependencies/boringssl').resolve()
    if not source.exists():
        source.mkdir(parents=True)
        run('git', '-C', source, 'init')
        run('git', '-C', source, 'remote', 'add', 'origin', lock['repository'])
        run('git', '-C', source, 'fetch', '--depth', '1', 'origin', lock['commit'])
        run('git', '-C', source, 'checkout', '--detach', 'FETCH_HEAD')
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True)
    if commit != lock['commit'] or dirty:
        raise SystemExit('Dependency must be the clean pinned source; existing checkout was not modified.')
    for platform in args.platforms:
        output = ROOT/'.local/pairing'/platform
        build = output/'build'
        flags = ['-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF', '-DOPENSSL_NO_ASM=ON',
                 '-DCMAKE_MACOSX_BUNDLE=OFF', '-DBORINGSSL_PREFIX=SPATIALPC_BSSL', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                 f'-DCMAKE_OSX_SYSROOT={platform}']
        target = ['-arch', 'arm64']
        if platform != 'macosx':
            flags += ['-DCMAKE_SYSTEM_NAME=visionOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=2.0']
            target = ['-target', 'arm64-apple-xros2.0' + ('-simulator' if platform == 'xrsimulator' else '')]
        else:
            flags += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
            target += ['-mmacosx-version-min=15.0']
        run('cmake', '-S', source, '-B', build, *flags)
        run('cmake', '--build', build, '--target', 'crypto', '-j', '6')
        run('xcrun', '--sdk', platform, 'clang', *target, '-O2', '-fvisibility=hidden', '-DBORINGSSL_PREFIX=SPATIALPC_BSSL', '-c',
            ROOT/'shared/pairing/spatial_pake.c', '-I', source/'include', '-o', output/'spatial_pake.o')
        run('xcrun', 'libtool', '-static', '-o', output/'libspatial_pake.a',
            output/'spatial_pake.o', build/'libcrypto.a')
        shutil.copy2(build/'libcrypto.a', output/'libcrypto.a')
        (output/'build-metadata.json').write_text(json.dumps({**lock, 'platform': platform,
            'sourceDirectory': str(source), 'scope': 'pairing only; no TLS replacement'}, indent=2)+'\n')
    # SPM uses the header-only include directory plus this pinned dependency.
    (ROOT/'.local/pairing/source-path.txt').write_text(str(source)+'\n')

if __name__ == '__main__':
    main()
