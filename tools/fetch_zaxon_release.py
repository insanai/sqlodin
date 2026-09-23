#!/usr/bin/env python3
"""Fetch the pinned official Linux x86_64 Zaxonlite release, with checksum verification."""
import hashlib
import io
import json
from pathlib import Path
import platform
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TAG = 'v0.7.0'
ASSET = 'zaxon-0.7.0-x86_64-linux-musl.tar.gz'
SHA256 = '6e13ea5fe25f41675fea3f4148447555570d8510f0887c454b7e9090676752e4'
BASE = f'https://github.com/insanai/zaxonlite/releases/download/{TAG}'


def main():
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise SystemExit('This pin targets Linux x86_64')
    data = urllib.request.urlopen(f'{BASE}/{ASSET}', timeout=120).read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit('Release archive checksum mismatch')
    sums = urllib.request.urlopen(f'{BASE}/SHA256SUMS', timeout=60).read().decode()
    if not any(line.split() == [SHA256, ASSET] for line in sums.splitlines()):
        raise SystemExit('Pinned digest differs from the published SHA256SUMS')
    archive = tarfile.open(fileobj=io.BytesIO(data), mode='r:gz')
    candidates = [m for m in archive.getmembers() if m.isfile() and Path(m.name).name == 'zaxon']
    if len(candidates) != 1:
        raise SystemExit('Expected exactly one regular zaxon executable')
    binary_data = archive.extractfile(candidates[0]).read()
    if binary_data[:4] != b'\x7fELF':
        raise SystemExit('Expected Linux ELF executable')
    out = ROOT / 'build/comparison-tools/zaxon-release'
    out.mkdir(parents=True, exist_ok=True)
    binary = out / 'zaxon'
    binary.write_bytes(binary_data)
    binary.chmod(0o755)
    version = subprocess.check_output([str(binary), 'version'], text=True).strip()
    metadata = {'repository': 'https://github.com/insanai/zaxonlite', 'tag': TAG,
                'asset_url': f'{BASE}/{ASSET}', 'archive_sha256': SHA256,
                'binary_sha256': hashlib.sha256(binary_data).hexdigest(),
                'version': version, 'published_checksums': sums}
    (out / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(binary, version)


if __name__ == '__main__':
    main()
