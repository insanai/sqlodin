#!/usr/bin/env python3
"""Repeatable verification of the SQLodin toolchain and library; requires Odin and Python 3.

Runs, in a temporary directory so stale binaries can never mask a failure:
style (the Zen constraints, vet, strict style), unit tests in debug and optimized builds,
compiler and durability contracts, seeded fault simulations across node topologies,
the multi-master SQLite vector/FTS example, benchmark smoke runs, and CLI error propagation.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PACKAGES = ('tests', 'sim', 'bench', 'cli')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seeds', type=int, default=10)
parser.add_argument('--steps', type=int, default=5000)
args = parser.parse_args()
if args.seeds < 1 or args.steps < 1:
    parser.error('seeds and steps must be positive')


def run(command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, timeout=600, **options)


def check_style():
    run([sys.executable, 'tools/check_style.py', '--soft'])
    for package in PACKAGES:
        flags = ['-no-entry-point'] if package == 'tests' else []
        run([ODIN, 'check', package, '-vet', '-strict-style', *flags])
    run([ODIN, 'check', 'examples/multimaster_search.odin', '-file', '-vet', '-strict-style'])
    print('PASS style: Zen constraints, vet, strict style', flush=True)


with tempfile.TemporaryDirectory(prefix='sqlodin-check-') as work:
    work = Path(work)
    run([ODIN, 'version'])
    check_style()

    # 1. Unit Tests in both Debug and Optimized modes
    for profile in ('-debug', '-o:speed'):
        run([ODIN, 'test', 'tests', profile, f'-out:{work / "tests"}'])
        print(f'PASS unit tests ({profile})', flush=True)

    # 2. Compile-fail and Durability Gate Contracts
    run([sys.executable, 'tools/check_contracts.py'])

    # 3. Fault Simulator Chaos Verification
    simulator = work / 'sim'
    run([ODIN, 'build', 'sim', '-debug', f'-out:{simulator}'])
    runs = 0
    for nodes in (1, 3, 5):
        for seed in range(1, args.seeds + 1):
            command = [
                str(simulator),
                f'--nodes={nodes}',
                f'--seed={seed}',
                f'--steps={args.steps}',
            ]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise SystemExit(f'Simulation failed: {command}\n{result.stdout}{result.stderr}')
            runs += 1
    print(f'PASS {runs} simulations across 1, 3, and 5 nodes ({runs * args.steps} fault steps)', flush=True)

    # 4. Example verification
    example = work / 'example'
    run([ODIN, 'run', 'examples/multimaster_search.odin', '-file', f'-out:{example}'])
    print('PASS multi-master vector/FTS search example', flush=True)

    # 5. Benchmark smoke run
    benchmark = work / 'bench'
    run([ODIN, 'build', 'bench', '-o:speed', f'-out:{benchmark}'])
    bench_result = run([str(benchmark), '--iterations=2000'], capture_output=True, text=True)
    if 'Multi-Master Writes' not in bench_result.stdout:
        raise SystemExit(f'Benchmark output unexpected:\n{bench_result.stdout}')
    print('PASS benchmark smoke test', flush=True)

    # 6. CLI Failure Propagation Check
    cli = work / 'cli'
    run([ODIN, 'build', 'cli', f'-out:{cli}'])
    fake_odin = work / 'odin'
    fake_odin.write_text('#!/bin/sh\nexit 17\n')
    fake_odin.chmod(0o755)
    env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ.get('PATH', ''))
    failure = subprocess.run([str(cli), 'test'], cwd=ROOT, env=env, capture_output=True, text=True, timeout=10)
    assert failure.returncode != 0 and 'Hint:' in failure.stderr
    print('PASS CLI propagates subprocess failure with recovery hint', flush=True)

print('All SQLodin checks passed.')
