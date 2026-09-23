#!/usr/bin/env python3
"""Reject shared SQLite, sqlite-vec or OpenSSL dependencies; record build provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    command = (['otool', '-L'] if platform.system() == 'Darwin' else ['readelf', '-d']) + [str(args.binary)]
    linkage = subprocess.check_output(command, text=True)
    if re.search(r'lib(?:sqlite[^\s/]*|ssl|crypto)[.\-](?:so|dylib|[0-9])', linkage, re.IGNORECASE):
        raise SystemExit('Unexpected shared database/TLS dependency:\n' + linkage)
    result = dict(complete=True, binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  platform=platform.platform(), linkage=linkage,
                  native=json.loads((ROOT / 'build/native/build.json').read_text()),
                  shell=json.loads((ROOT / 'build/native/shell-build.json').read_text()),
                  odin=subprocess.check_output(['odin', 'version'], text=True).strip(),
                  scope='Native SQLite/FTS5, sqlite-vec and OpenSSL are static; OS runtime may remain dynamic')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('PASS no shared SQLite/sqlite-vec/OpenSSL dependencies:', args.binary)


if __name__ == '__main__': main()
