#!/usr/bin/env python3
"""Select CI work from a Git diff; unknown source paths receive native checks."""
import argparse
from pathlib import Path
import subprocess


def classify(paths):
    native = python = formal = upstream = False
    for path in paths:
        if not path:
            continue
        if path.startswith('languages/python/'):
            python = True
        elif path == 'tools/check_formal.py' or (
            path.startswith('specs/') and path.endswith(('.tla', '.cfg'))
        ):
            formal = True
        elif path.startswith(('docs/', 'specs/', 'benchmarks/results/', '.github/ISSUE_TEMPLATE/')) or (
            path in {'README.md', 'CONTRIBUTING.md', 'LICENSE', '.gitignore',
                     '.github/PULL_REQUEST_TEMPLATE.md', '.github/release-notes.md'}
        ):
            continue
        else:
            native = python = True
        if path == 'deps/paxos-odin' or path == '.gitmodules':
            upstream = True
    return dict(native=native, python=python, formal=formal, upstream=upstream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.all or not args.base or set(args.base) == {'0'}:
        selected = dict.fromkeys(('native', 'python', 'formal', 'upstream'), True)
    else:
        diff = subprocess.check_output(['git', 'diff', '--name-only', '-z', args.base, args.head])
        selected = classify(diff.decode().split('\0'))
    with args.output.open('a') as output:
        for key, value in selected.items():
            print(f'{key}={str(value).lower()}', file=output)
            print(f'{key}: {value}')


if __name__ == '__main__':
    main()
