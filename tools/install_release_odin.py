#!/usr/bin/env python3
"""Install the pinned release compiler in build/toolchains (no system changes)."""
import hashlib
from pathlib import Path
import platform
import subprocess
import tarfile
import urllib.request

VERSION = 'dev-2026-09'
DIGESTS = {
    ('Linux', 'x86_64'): ('linux-amd64', '167c3e1d7056419dad2e04bb3bd98715b7ff286d4c125f3c5a5ee337c6254283'),
    ('Darwin', 'x86_64'): ('macos-amd64', 'c1f6d6320218ec7e511093a87bdd599b72a8417a9d2a00de2c9691103562165b'),
    ('Darwin', 'arm64'): ('macos-arm64', '3e6cbc1f247d8d14fe02c3151272d0a5b8d6d77acb7219f5b62914e4d95d97f7'),
}


def main():
    target, digest = DIGESTS[(platform.system(), platform.machine())]
    root = Path(__file__).resolve().parents[1] / 'build/toolchains'
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f'odin-{target}-{VERSION}.tar.gz'
    urllib.request.urlretrieve(
        f'https://github.com/odin-lang/Odin/releases/download/{VERSION}/{archive.name}', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise SystemExit('Compiler archive checksum mismatch')
    destination = root / 'odin'
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter='data')
    binaries = [p for p in destination.rglob('odin') if p.is_file()]
    if len(binaries) != 1:
        raise SystemExit('Expected one compiler in the release archive')
    subprocess.run([str(binaries[0]), 'version'], check=True)
    print(binaries[0].parent)


if __name__ == '__main__':
    main()
