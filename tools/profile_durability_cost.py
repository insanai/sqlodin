#!/usr/bin/env python3
"""Linux attribution experiment: unchanged FULL barriers, timed syscall counts, matched SQLite build."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/durability-cost'
SOURCE = ROOT / 'bench/durability_cost'


def run(argv, **options):
    return subprocess.run(list(map(str, argv)), check=True, text=True, timeout=300, **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--durability-report', type=Path,
                        default=ROOT / 'benchmarks/results/linux-candidate-v3-durability.json')
    parser.add_argument('--transaction-batches', action='store_true',
                        help='also compare retry-safe requests with proposal batches of 1 and 16')
    parser.add_argument('--individual-journal', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Linux':
        raise SystemExit('Linux required; diagnostic counters are intentionally single-threaded.')
    evidence = json.loads(args.durability_report.read_text())
    current = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in ROOT.glob('src/**/*.odin')}
    if any(evidence.get('source_sha256', {}).get(p) != digest for p, digest in current.items()):
        raise SystemExit('Durability report source snapshot differs; run current disk checks first')
    if len(evidence.get('checks', [])) < 22 or not all(c['passed'] for c in evidence['checks']):
        raise SystemExit('Current application/journal-group crash checks are incomplete')
    if evidence.get('journal_group_commit') != (not args.individual_journal):
        raise SystemExit('Durability evidence uses a different journal-group configuration')
    if evidence.get('filesystem', {}).get('filesystems', [{}])[0].get('fstype') in (None, 'tmpfs', 'ramfs'):
        raise SystemExit('Durability evidence must identify persistent disk storage')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output = args.output or ROOT / f'benchmarks/results/linux-durability-cost-{stamp}.json'
    if output.exists():
        raise SystemExit(f'Refusing to overwrite existing evidence: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    library = WORK / 'libsync_profile.so'
    binary = WORK / 'probe'
    run(['cc', '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', SOURCE / 'sync_profile.c', '-ldl', '-o', library])
    group_flag = f'-define:SQLODIN_JOURNAL_GROUP_COMMIT={str(not args.individual_journal).lower()}'
    run(['odin', 'build', SOURCE, '-o:speed', '-vet', '-strict-style', group_flag, f'-out:{binary}'])
    directory = WORK / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    directory.mkdir()
    report = {'schema_version': 1, 'complete': False,
              'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'instrumented diagnostic, 256-byte insert rows; all fsync/fdatasync calls forwarded unchanged; '
                       'timed region excludes setup, warmup, verification and close; '
                       'SQLite batch-32 changes transaction granularity and is only an amortization reference; '
                       'all replicas execute serially in one process; no maximum-throughput or mixed-SQL claim',
              'host': platform.platform(), 'rows': 480, 'warmup_rows': 96, 'repeats': 3,
              'journal_group_commit': not args.individual_journal,
              'native': json.loads((ROOT / 'build/native/build.json').read_text()),
              'durability_report': str(args.durability_report),
              'durability_report_sha256': hashlib.sha256(args.durability_report.read_bytes()).hexdigest(),
              'filesystem': run(['findmnt', '-T', directory, '-o', 'SOURCE,FSTYPE,OPTIONS'], capture_output=True).stdout,
              'paxos_pin': run(['git', '-C', ROOT / 'deps/paxos-odin', 'rev-parse', 'HEAD'], capture_output=True).stdout.strip(),
              'run_directory': str(directory), 'samples': []}
    sources = [*ROOT.glob('src/**/*.odin'), *SOURCE.glob('*'), Path(__file__)]
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sorted(sources) if p.is_file()}
    report['binary_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (binary, library)}
    environment = {**os.environ, 'LD_PRELOAD': str(library)}
    for repeat in range(3):
        modes = ['sqlite_full_1', 'sqlite_full_32', 'durable_1', 'durable_3']
        if args.transaction_batches:
            modes += ['transaction_1', 'transaction_1_batch16',
                      'transaction_3', 'transaction_3_batch16']
        random.Random(20260922 + repeat).shuffle(modes)
        for mode in modes:
            print(f'repeat={repeat+1} mode={mode}', flush=True)
            case = directory / f'{repeat+1}-{mode}'
            case.mkdir()
            result = run([binary, mode, case, report['rows'], report['warmup_rows']],
                         env=environment, capture_output=True)
            sample = json.loads(result.stdout)
            if not sample['verified'] or sample['sync']['calls'] == 0:
                raise RuntimeError('Verification or sync interposition failed')
            sample['repeat'] = repeat+1
            report['samples'].append(sample)
            output.write_text(json.dumps(report, indent=2) + '\n')
    report.update(complete=True, finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
