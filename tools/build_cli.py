#!/usr/bin/env python3
"""Build SQLodin with verified static native dependencies, without system installs."""
import argparse
import os
import shutil
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='bin/sqlodin')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--opt', choices=('minimal', 'speed'), default='speed',
                        help='Use minimal optimization for short CI builds; releases use speed')
    parser.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / 'tools/build_native.py'), '--jobs', str(args.jobs),
                    *(['--offline'] if args.offline else [])], check=True)
    subprocess.run([sys.executable, str(ROOT / 'tools/build_shell.py')], check=True)
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([os.environ.get('ODIN', 'odin'), 'build', 'cli', f'-o:{args.opt}', '-vet',
                    '-strict-style', f'-out:{output}'], cwd=ROOT, check=True)
    licenses = output.parent / 'licenses'
    licenses.mkdir(exist_ok=True)
    for source in [ROOT / 'LICENSE', ROOT / 'deps/licenses/sqlite-vec-MIT.txt',
                   ROOT / 'deps/paxos-odin/LICENSE', ROOT / 'build/native/OPENSSL-LICENSE.txt']:
        name = 'paxos-odin-LICENSE' if source.parent.name == 'paxos-odin' else source.name
        shutil.copy2(source, licenses / name)
    subprocess.run([sys.executable, str(ROOT / 'tools/check_native_linkage.py'), str(output),
                    '--output', str(output) + '.build.json'], check=True)


if __name__ == '__main__': main()
