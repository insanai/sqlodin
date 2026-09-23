#!/usr/bin/env python3
"""Matched Linux process runs: identical workload/driver, journal grouping on versus off."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess
import tempfile

from check_process_cluster import Cluster, exercise

ROOT = Path(__file__).resolve().parents[1]


def hashes():
    sources = [*ROOT.glob('src/**/*.odin'), *ROOT.glob('internal/process_probe/*.odin'),
               ROOT / 'tools/check_process_cluster.py', Path(__file__)]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(sources)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group-durability', type=Path, required=True)
    parser.add_argument('--reference-durability', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--operations', type=int, default=2400)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('Linux is required for this disk/resource comparison')
    if args.output.exists():
        parser.error('output exists; preserve prior evidence')
    if not 12 <= args.operations <= 10000 or not 1 <= args.repeats <= 10:
        parser.error('operations must be 12..10000 and repeats 1..10')
    source_hashes = hashes()
    proofs = {}
    for grouped, path in [(True, args.group_durability), (False, args.reference_durability)]:
        evidence = json.loads(path.read_text())
        if evidence.get('journal_group_commit') != grouped or len(evidence.get('checks', [])) < 22:
            parser.error(f'Wrong or incomplete durability configuration: {path}')
        if not all(c['passed'] for c in evidence['checks']):
            parser.error(f'Failed durability prerequisite: {path}')
        for name, digest in source_hashes.items():
            if name.startswith('src/') and evidence.get('source_sha256', {}).get(name) != digest:
                parser.error(f'Durability source mismatch: {path}: {name}')
        proofs[str(grouped)] = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    work_root = ROOT / 'build/process-comparisons'
    work_root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='journal-', dir=work_root))
    filesystem = json.loads(subprocess.check_output(
        ['findmnt', '--json', '-T', str(work), '-o', 'TARGET,FSTYPE,SOURCE,OPTIONS'], text=True))
    if filesystem['filesystems'][0]['fstype'] in ('tmpfs', 'ramfs'):
        parser.error('Persistent disk storage required')
    report = {'complete': False, 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'one Linux machine; three processes and disk directories per sample; '
                       'same mixed SQL, fresh fenced reads and controller scheduling; FULL durability; '
                       'journal-group flag is the sole build difference; not production service capacity',
              'source_sha256': source_hashes, 'filesystem': filesystem, 'run_directory': str(work),
              'operations': args.operations, 'repeats': args.repeats,
              'durability_evidence': proofs, 'platform': platform.platform(),
              'native_dependencies': json.loads((ROOT / 'build/native/build.json').read_text()),
              'binary_sha256': {}, 'samples': []}
    report['odin_version'] = subprocess.check_output(
        [os.environ.get('ODIN', 'odin'), 'version'], text=True).strip()
    report['cpu_affinity'] = sorted(os.sched_getaffinity(0))
    report['cpu_model'] = next((line.split(':', 1)[1].strip()
                                for line in Path('/proc/cpuinfo').read_text().splitlines()
                                if line.startswith('model name')), platform.machine())
    report['load_before'] = Path('/proc/loadavg').read_text().strip()
    report['cgroup_limits'] = {name: (Path('/sys/fs/cgroup') / name).read_text().strip()
                               for name in ('cpu.max', 'memory.max')
                               if (Path('/sys/fs/cgroup') / name).exists()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    binaries = {}
    for grouped in (False, True):
        binary = work / ('grouped' if grouped else 'reference')
        subprocess.run([os.environ.get('ODIN', 'odin'), 'build', str(ROOT / 'internal/process_probe'),
                        '-o:speed', '-vet', '-strict-style',
                        f'-define:SQLODIN_JOURNAL_GROUP_COMMIT={str(grouped).lower()}',
                        f'-out:{binary}'], check=True, cwd=ROOT, timeout=300)
        binaries[grouped] = binary
        report['binary_sha256'][binary.name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    if hashes() != source_hashes:
        raise RuntimeError('Sources changed during build; refusing inconsistent evidence')
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for repeat in range(args.repeats):
        modes = [False, True]
        random.Random(20260923 + repeat).shuffle(modes)
        seed = 20260922 + repeat
        for grouped in modes:
            label = 'grouped' if grouped else 'reference'
            print(f'repeat={repeat + 1} mode={label} seed={seed}', flush=True)
            directory = work / f'{repeat + 1}-{label}'
            directory.mkdir()
            cluster = Cluster(binaries[grouped], directory)
            try:
                sample = exercise(cluster, args.operations, seed, 'fenced')
                report['samples'].append({'repeat': repeat + 1, 'mode': label, 'seed': seed,
                                          'sample': sample, 'worker_pids': cluster.pids,
                                          'run_directory': str(directory)})
            finally:
                cluster.close()
            args.output.write_text(json.dumps(report, indent=2) + '\n')
    if hashes() != source_hashes:
        raise RuntimeError('Sources changed during measurement; report remains incomplete')
    report.update(complete=True, finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    report['load_after'] = Path('/proc/loadavg').read_text().strip()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(args.output, flush=True)


if __name__ == '__main__':
    main()
