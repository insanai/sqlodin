#!/usr/bin/env python3
"""Finite R6 coverage matrix; preserve every sample and unmet provisional target."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def matrix():
    cases = []
    def add(clients, reads, payload=256, statements=1, rows=1, skew=False, rate=0, seed=20260925):
        cases.append(dict(clients=clients, reads=reads, payload=payload, statements=statements,
                          rows=rows, skew=skew, rate=rate, seed=seed))
    for clients in (1, 8, 32, 64):
        for reads in (70, 50, 95, 0):
            add(clients, reads)
    for clients in (8, 64):
        for statements, rows in ((1,1), (4,2), (8,4)):
            add(clients, 70, 4096, statements, rows)
    for reads in (70, 50, 95, 0):
        add(32, reads, 4096, 8, 4, skew=True)
    for seed in (20260926, 20260927):
        for reads in (70, 0):
            add(64, reads, seed=seed)
    add(64, 70, rate=3000)
    add(64, 0, rate=1000)
    random.Random(20260925).shuffle(cases)
    return cases


def run_bounded(command, timeout):
    started = time.monotonic()
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
        return dict(exit_code=child.returncode, seconds=time.monotonic()-started, output=output)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            output, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            output, _ = child.communicate(timeout=5)
        return dict(exit_code=child.returncode, seconds=time.monotonic()-started,
                    output=output, error='bounded case watchdog expired')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--io-profile-library', type=Path, required=True)
    p.add_argument('--operations', type=int, default=80)
    p.add_argument('--fixture-only', action='store_true')
    args = p.parse_args()
    assert not args.output.exists() and 10 <= args.operations <= 1000
    cases = matrix()
    if args.fixture_only:
        cases = [dict(clients=8, reads=70, payload=4096, statements=8, rows=4,
                      skew=True, rate=100, seed=20260925)]
    samples = args.output.with_suffix('')
    samples.mkdir(parents=True, exist_ok=False)
    report = dict(complete=False, fixture_only=args.fixture_only, cases=[], planned=len(cases),
                  scope='coverage matrix, not a full factorial; on-disk FULL, all-voter entry, bounded grouping',
                  originals=dict(mixed_tps=3000, write_tps=1000, read_p99_ms=20, write_p99_ms=50,
                                 sqlite_fraction=.25),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  harness_sha256={name:hashlib.sha256((ROOT/'tools'/name).read_bytes()).hexdigest()
                                  for name in ('qualify_native_workloads.py','calibrate_native_mixed.py',
                                               'sqlite_group_reference.py','sqlite_reference_worker.py')},
                  io_library_sha256=hashlib.sha256(args.io_profile_library.read_bytes()).hexdigest())
    def save():
        temp = args.output.with_suffix('.tmp')
        temp.write_text(json.dumps(report, indent=2)+'\n')
        temp.replace(args.output)
    try:
        for number, case in enumerate(cases):
            output = samples/f'case-{number:02d}.json'
            command = [sys.executable, str(ROOT/'tools/calibrate_native_mixed.py'),
                       '--binary', str(args.binary.resolve()), '--output', str(output.resolve()),
                       '--sqlite-group', '16', '--io-profile-library', str(args.io_profile_library.resolve()),
                       '--operations', str(args.operations)]
            for name, value in case.items():
                if name == 'skew':
                    if value:
                        command.append('--skew')
                else:
                    command.extend(['--'+name, str(value)])
            entry = dict(parameters=case, command=command, sample=str(output))
            report['cases'].append(entry)
            entry['execution'] = run_bounded(command, timeout=900)
            entry['passed'] = False
            if output.exists():
                raw = json.loads(output.read_text())
                entry['sample_sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
                entry['passed'] = raw.get('complete',False) and entry['execution']['exit_code'] == 0
                if entry['passed']:
                    result = raw['cases'][0]
                    native, reference = result['sqlodin'], result['sqlite']
                    entry['summary'] = dict(native_tps=native['per_second'], sqlite_tps=reference['per_second'],
                        sqlite_fraction=native['per_second']/reference['per_second'],
                        latency=native['latency_ms'], latency_basis=native['latency_basis'],
                        completed=native['completed'], offered=native['offered'], errors=native['errors'],
                        resolved_unknown=native['resolved_unknown'])
            print(f"{'PASS' if entry['passed'] else 'FAIL'} matrix case {number+1}/{len(cases)} {case}", flush=True)
            save()
        report['complete'] = all(c['passed'] for c in report['cases'])
        report['targets_evaluated_separately'] = True
    finally:
        save()
    if not report['complete']:
        raise SystemExit('Workload matrix contains failed samples; inspect retained evidence')


if __name__ == '__main__':
    main()
