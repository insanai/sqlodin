#!/usr/bin/env python3
"""Short Linux PR checks; full qualification remains an explicit tools/check.py run."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/ci'


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True, timeout=600)


def tests(package, name):
    report = OUT / f'{name}.json'
    report.unlink(missing_ok=True)
    run('odin', 'test', package, '-debug', '-vet', '-strict-style', '-thread-count:4',
        '-define:ODIN_TEST_THREADS=4', f'-out:{OUT / name}',
        f'-define:ODIN_TEST_JSON_REPORT={report}')
    result = json.loads(report.read_text())
    if result.get('total', 0) <= 0 or result.get('success') != result['total']:
        raise SystemExit(f'Tests failed or ran no tests: {report}')


def main():
    if sys.platform != 'linux':
        raise SystemExit('Run CI tests on Linux')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream-only', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.upstream_only:
        tests('deps/paxos-odin/tests', 'paxos')
        return
    tests('tests', 'sqlodin')
    run(sys.executable, 'tools/check_contracts.py')
    simulator = str(OUT / 'sim')
    run('odin', 'build', 'sim', '-o:minimal', '-vet', '-strict-style', f'-out:{simulator}')
    for nodes in (1, 3, 5):
        run(simulator, f'--nodes={nodes}', '--seed=1', '--steps=1000')
    database = OUT / 'smoke.db'
    database.unlink(missing_ok=True)
    run(str(ROOT / 'bin/sqlodin'), 'local', str(database),
        'CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1); SELECT * FROM t;')


if __name__ == '__main__':
    main()
