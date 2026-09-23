#!/usr/bin/env python3
"""Small on-disk mixed-SQL correctness regression; not a capacity benchmark."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import compare_realworld

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    disk_tmp = ROOT / 'build/test-tmp'
    disk_tmp.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sqlodin-mixed-', dir=disk_tmp) as directory:
        work = Path(directory)
        manifest = work / 'workload.json'
        expected = compare_realworld.sqlodin_manifest(manifest, 60, 12, 20260922)
        binary = work / 'probe'
        subprocess.run([os.environ.get('ODIN', 'odin'), 'build', str(ROOT / 'bench/realworld'),
                        '-o:speed', '-vet', '-strict-style', f'-out:{binary}'],
                       check=True, timeout=600, cwd=ROOT)
        result = subprocess.run([str(binary), str(manifest), str(work)], check=False,
                                capture_output=True, text=True, timeout=120, cwd=ROOT)
        if result.returncode:
            raise RuntimeError(f'Mixed workload failed: {result.stdout}\n{result.stderr}')
        sample = json.loads(result.stdout)
        if not sample['verified'] or sample['operations'] != 60 or not sample['reads'] or not sample['writes']:
            raise RuntimeError('Mixed workload did not verify')
    sources = [*ROOT.glob('src/**/*.odin'), *ROOT.glob('bench/realworld/*.odin'),
               ROOT / 'benchmarks/vendor/zaxonlite/realworld_workload.py',
               ROOT / 'tools/compare_realworld.py', Path(__file__)]
    report = {'complete': True, 'run_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'correctness smoke: 3 on-disk embedded voters; aggregates, triggers, FK and restart; '
                       '60 operations after 12 warmup; no capacity or long-running service claim',
              'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(sources)},
              'expected': expected, 'sample': sample}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS mixed SQL: all three replicas verify order/ledger/stock invariants before and after restart')


if __name__ == '__main__':
    main()
