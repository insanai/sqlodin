#!/usr/bin/env python3
"""Check changed bounded models; reserve the full model matrix for an explicit run."""
import argparse
from pathlib import Path
import subprocess
import sys
from check_formal import CASES

SMOKE = {'JournalCache', 'QuorumRead', 'QuorumReadReconnect', 'DurableEffects'}


def select(paths):
    models = set(SMOKE)
    known = {model for model, _, _ in CASES}
    configs = {config: model for model, config, _ in CASES}
    for name in paths:
        path = Path(name)
        if path.parent != Path('specs'):
            continue
        if path.suffix == '.cfg' and path.stem in configs:
            models.add(configs[path.stem])
        elif path.suffix == '.tla' and path.stem in known:
            models.add(path.stem)
        elif path.suffix in ('.tla', '.cfg'):
            raise SystemExit(f'{name} has no bounded CI case. Register its model/config in '
                             'tools/check_formal.py or supply its separate proof-checking workflow.')
    return [config for model, config, _ in CASES if model in models]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--all', action='store_true')
    args = parser.parse_args()
    paths = []
    if args.base and set(args.base) != {'0'}:
        paths = subprocess.check_output(
            ['git', 'diff', '--name-only', args.base, 'HEAD'], text=True).splitlines()
    selected = [] if args.all else select(paths)
    command = [sys.executable, 'tools/check_formal.py', '--jar', 'build/tla2tools.jar',
               '--output', 'build/formal-ci.json', '--workers', '2', '--heap-mib', '2048',
               '--timeout', '180']
    for config in selected:
        command += ['--case', config]
    print('Formal configurations:', selected if selected else 'all', flush=True)
    subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
