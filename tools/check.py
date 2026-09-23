#!/usr/bin/env python3
"""Repeatable verification of the SQLodin toolchain and library; requires Odin and Python 3.

Runs, in a temporary directory so stale binaries can never mask a failure:
style (the Zen constraints, vet, strict style), unit tests in debug and optimized builds,
compiler and durability contracts, seeded fault simulations across node topologies,
the multi-master SQLite vector/FTS example, benchmark smoke runs, and CLI error propagation.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PACKAGES = ('tests', 'sim', 'bench', 'cli', 'internal/durability_probe', 'internal/process_probe', 'bench/realworld', 'service', 'transport/mtls')
PIN = 'a3e1fd78ec8f0429e5024710189ef77fc31961af'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seeds', type=int, default=10)
parser.add_argument('--steps', type=int, default=5000)
parser.add_argument('--durability-output', type=Path,
                    help='write Linux crash evidence to this new report path')
parser.add_argument('--mixed-output', type=Path, help='write mixed-SQL correctness evidence')
parser.add_argument('--process-output', type=Path, help='write independent-process cluster evidence')
args = parser.parse_args()
if sys.platform == 'linux':
    disk_tmp = ROOT / 'build/test-tmp'
    disk_tmp.mkdir(parents=True, exist_ok=True)
    os.environ['TMPDIR'] = str(disk_tmp)
    tempfile.tempdir = str(disk_tmp)
if args.seeds < 1 or args.steps < 1:
    parser.error('seeds and steps must be positive')


def run(command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, timeout=600, **options)


def check_style():
    run([sys.executable, 'tools/check_style.py', '--soft'])
    for package in PACKAGES:
        flags = ['-no-entry-point'] if package in ('tests', 'service', 'transport/mtls') else []
        run([ODIN, 'check', package, '-vet', '-strict-style', *flags])
    run([ODIN, 'check', 'examples/multimaster_search.odin', '-file', '-vet', '-strict-style'])
    print('PASS style: Zen constraints, vet, strict style', flush=True)


with tempfile.TemporaryDirectory(prefix='sqlodin-check-') as work:
    work = Path(work)
    dependency = ROOT / 'deps/paxos-odin'
    if not (dependency / 'src/paxos.odin').is_file():
        raise SystemExit('Missing paxos-odin. Run: git submodule update --init --recursive')
    revision = run(['git', '-C', str(dependency), 'rev-parse', 'HEAD'], capture_output=True,
                   text=True).stdout.strip()
    if revision != PIN:
        raise SystemExit(f'paxos-odin revision {revision} differs from tested pin {PIN}')
    if run(['git', '-C', str(dependency), 'status', '--porcelain'], capture_output=True,
           text=True).stdout.strip():
        raise SystemExit('paxos-odin has local modifications; verify against the clean pin')
    run([sys.executable, 'tools/build_native.py'])
    run([sys.executable, 'tools/build_shell.py'])
    run([ODIN, 'version'])
    check_style()

    # 1. Unit Tests in both Debug and Optimized modes
    for profile in ('-debug', '-o:speed'):
        run([ODIN, 'test', 'tests', profile, f'-out:{work / "tests"}'])
        print(f'PASS unit tests ({profile})', flush=True)
        run([ODIN, 'test', 'deps/paxos-odin/tests', profile, f'-out:{work / "paxos-tests"}'])
        print(f'PASS pinned upstream tests ({profile})', flush=True)

    if sys.platform == 'linux':
        run([ODIN, 'test', 'tests', '-o:speed', '-define:SQLODIN_APPLICATION_GROUP_COMMIT=false',
             '-define:SQLODIN_JOURNAL_GROUP_COMMIT=false',
             f'-out:{work / "reference-tests"}'])
        print('PASS individual-journal/application reference configuration', flush=True)
        output = ['--output', str(args.durability_output)] if args.durability_output else []
        run([sys.executable, 'tools/check_durability.py', *output])
        output = ['--output', str(args.mixed_output)] if args.mixed_output else []
        run([sys.executable, 'tools/check_mixed_workload.py', *output])
        process_output = args.process_output or work / 'process-cluster.json'
        run([sys.executable, 'tools/check_process_cluster.py', '--output', str(process_output)])

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
    for mode in ('multi', 'single', 'sqlite'):
        for batch in (1, 12):
            output = run([str(benchmark), '--json', f'--mode={mode}', f'--batch={batch}',
                          '--iterations=120', '--warmup=12'], capture_output=True, text=True)
            sample = json.loads(output.stdout)
            assert sample['verified'] and sample['iterations'] == 120
            assert sample['mode'] == mode and sample['batch'] == batch
    print('PASS benchmark smoke and six JSON profiles', flush=True)

    # 6. CLI Failure Propagation Check
    cli = work / 'cli'
    run([sys.executable, 'tools/build_cli.py', '--output', str(cli)])
    fake_odin = work / 'odin'
    fake_odin.write_text('#!/bin/sh\nexit 17\n')
    fake_odin.chmod(0o755)
    env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ.get('PATH', ''))
    failure = subprocess.run([str(cli), 'test'], cwd=ROOT, env=env, capture_output=True, text=True, timeout=10)
    assert failure.returncode != 0 and 'Hint:' in failure.stderr
    print('PASS CLI propagates subprocess failure with recovery hint', flush=True)

print('All SQLodin checks passed.')
