#!/usr/bin/env python3
"""Build the book and every SOD; propagate errors and replace outputs only on success."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', nargs='?', choices=('all', 'book', 'index', 'sod'), default='all')
    args = parser.parse_args()
    output = ROOT / 'docs/build'
    output.mkdir(parents=True, exist_ok=True)
    sources = []
    if args.target in ('all', 'book'):
        sources.append((ROOT / 'docs/book.typ', 'sqlodin-book'))
    if args.target in ('all', 'index'):
        sources.append((ROOT / 'docs/sod/index.typ', 'sod-index'))
    if args.target in ('all', 'sod'):
        sources.append((ROOT / 'docs/sod/bundle.typ', 'sod-bundle'))
        sources.extend((p, f'sod-{p.stem}') for p in sorted((ROOT / 'docs/sod/records').glob('*.typ')))
    for source, name in sources:
        temporary = output / f'.{name}.tmp.pdf'
        try:
            subprocess.run(['typst', 'compile', '--root', str(ROOT), str(source), str(temporary)], check=True)
            temporary.replace(output / f'{name}.pdf')
        finally:
            temporary.unlink(missing_ok=True)
        print(f'Generated docs/build/{name}.pdf', flush=True)


if __name__ == '__main__':
    main()
