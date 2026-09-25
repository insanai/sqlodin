#!/usr/bin/env python3
"""Repeatable verification of the SQLodin toolchain and library; requires Odin and Python 3.

Runs, in a temporary directory so stale binaries can never mask a failure:
style (the Zen constraints, vet, strict style), unit tests in debug and optimized builds,
compiler and durability contracts, seeded fault simulations across node topologies,
the multi-master SQLite vector/FTS example, benchmark smoke runs, and CLI error propagation.
"""
import argparse
import json
import hashlib
import time
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PACKAGES = ('tests', 'sim', 'bench', 'cli', 'internal/durability_probe', 'internal/process_probe', 'bench/realworld', 'service', 'transport/mtls')
PIN = 'c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seeds', type=int, default=10)
parser.add_argument('--steps', type=int, default=5000)
parser.add_argument('--durability-output', type=Path,
                    help='write Linux crash evidence to this new report path')
parser.add_argument('--mixed-output', type=Path, help='write mixed-SQL correctness evidence')
parser.add_argument('--process-output', type=Path, help='write independent-process cluster evidence')
parser.add_argument('--dependency-manifest', type=Path, help='Verified source pin for a Git-free checkout')
parser.add_argument('--output', type=Path, help='Preserve commands and complete unit-test reports')
args = parser.parse_args()
if args.output and args.output.exists():
    parser.error('Preserve earlier evidence; choose a new output path')
report = dict(complete=False, pin=PIN, commands=[], tests=[], simulations=[], benchmarks=[],
              harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
if sys.platform == 'linux':
    disk_tmp = ROOT / 'build/test-tmp'
    disk_tmp.mkdir(parents=True, exist_ok=True)
    os.environ['TMPDIR'] = str(disk_tmp)
    tempfile.tempdir = str(disk_tmp)
if args.seeds < 1 or args.steps < 1:
    parser.error('seeds and steps must be positive')


def run(command, **options):
    entry = dict(command=list(map(str,command)))
    report['commands'].append(entry)
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=ROOT, check=True, timeout=600, **options)
        entry['exit_code'] = result.returncode
        return result
    except BaseException as exc:
        entry['error'] = repr(exc)
        raise
    finally:
        entry['seconds'] = time.monotonic()-started


def checked_odin_test(package, binary, *flags):
    # Some Odin releases return zero even when individual tests fail. A fresh
    # machine-readable report, not only the subprocess status, is authoritative.
    test_report = binary.with_suffix('.json')
    test_report.unlink(missing_ok=True)
    run([ODIN, 'test', package, *flags, f'-out:{binary}',
         f'-define:ODIN_TEST_JSON_REPORT={test_report}'])
    result = json.loads(test_report.read_text())
    report['tests'].append(dict(package=package,flags=list(flags),result=result))
    if result.get('total', 0) <= 0 or result.get('success') != result['total']:
        raise RuntimeError(f'Odin tests failed or ran no tests: {test_report}')


def check_style():
    run([sys.executable, 'tools/check_style.py'])
    run([sys.executable, 'tools/test_compare_three_hosts.py'])
    for package in PACKAGES:
        flags = ['-no-entry-point'] if package in ('tests', 'service', 'transport/mtls') else []
        run([ODIN, 'check', package, '-vet', '-strict-style', *flags])
    run([ODIN, 'check', 'examples/multimaster_search.odin', '-file', '-vet', '-strict-style'])
    print('PASS style: Zen constraints, vet, strict style', flush=True)


try:
    with tempfile.TemporaryDirectory(prefix='sqlodin-check-') as work:
        work = Path(work)
        dependency = ROOT / 'deps/paxos-odin'
        if not (dependency / 'src/paxos.odin').is_file():
            raise SystemExit('Missing paxos-odin. Run: git submodule update --init --recursive')
        if args.dependency_manifest:
            manifest = json.loads(args.dependency_manifest.read_text())
            actual = {str(p.relative_to(dependency)):hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in dependency.rglob('*.odin')}
            if manifest['pin'] != PIN or actual != manifest['odin_sources']:
                raise SystemExit('Dependency source copy differs from the published pin')
            report['dependency_manifest_sha256'] = hashlib.sha256(args.dependency_manifest.read_bytes()).hexdigest()
        else:
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
            checked_odin_test('tests', work / 'tests', profile)
            print(f'PASS unit tests ({profile})', flush=True)
            checked_odin_test('deps/paxos-odin/tests', work / 'paxos-tests', profile)
            print(f'PASS pinned upstream tests ({profile})', flush=True)

        if sys.platform == 'linux':
            checked_odin_test('tests', work / 'reference-tests', '-o:speed',
                             '-define:SQLODIN_APPLICATION_GROUP_COMMIT=false',
                             '-define:SQLODIN_JOURNAL_GROUP_COMMIT=false')
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
                report['simulations'].append(dict(command=command, exit_code=result.returncode,
                                                   output=result.stdout+result.stderr))
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
                report['benchmarks'].append(sample)
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
        report['cli_failure'] = dict(exit_code=failure.returncode, stdout=failure.stdout, stderr=failure.stderr)
        assert failure.returncode != 0 and 'Hint:' in failure.stderr
        print('PASS CLI propagates subprocess failure with recovery hint', flush=True)

    print('All SQLodin checks passed.')
    report['complete'] = True
except BaseException as exc:
    report['error'] = repr(exc)
    raise
finally:
    if args.output:
        report['source_sha256'] = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                  for folder in ('src','service','transport','cli','tests','sim')
                                  for p in (ROOT/folder).rglob('*.odin')}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report,indent=2)+'\n')
