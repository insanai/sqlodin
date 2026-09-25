#!/usr/bin/env python3
"""Check unbounded host-seam induction proofs with the reviewed TLAPS distribution."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = 'tlapm-1.6.0-pre-x86_64-linux-gnu.tar.gz'
SHA256 = 'a2860384bc89c4c5b2c73ec367e29f44d829e4d4a2698ab295139f829219331c'
VERSION = '7824dab'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tools', type=Path, required=True, help='Directory containing pinned archive and unpacked tlapm/')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--case', choices=('DurableHistoryProof', 'PrefixRecoveryProof', 'OwnedSkipProof'), default='DurableHistoryProof')
    args = p.parse_args()
    if args.output.exists() or args.timeout < 1: p.error('Choose a new output path and positive timeout')
    if hashlib.sha256((args.tools / ARCHIVE).read_bytes()).hexdigest() != SHA256:
        p.error('Proof checker distribution checksum mismatch')
    executable = (args.tools/'tlapm/bin/tlapm').resolve()
    version = subprocess.check_output([str(executable), '--version'], text=True).strip()
    if version != VERSION: p.error(f'Unexpected proof checker revision: {version}')
    source = ROOT/'specs'/f'{args.case}.tla'
    report = dict(complete=False, passed=False, scope='unbounded durable-history/prefix seam and owned no-op determinacy; not a full consensus/refinement proof',
                  model=args.case,
                  tool_revision=version, distribution_sha256=SHA256,
                  executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                  source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-proof-') as work:
            shutil.copy2(source, Path(work)/source.name)
            result = subprocess.run([str(executable), '--threads', '2', source.name], cwd=work,
                                    capture_output=True, text=True, timeout=args.timeout)
            output = result.stdout + result.stderr
            report.update(output=output, exit_code=result.returncode)
            expected = {'DurableHistoryProof': 12, 'PrefixRecoveryProof': 36, 'OwnedSkipProof': 41}[args.case]
            counts = re.findall(r'All (\d+) obligations proved\.', output)
            if result.returncode != 0 or counts != [str(expected)]:
                raise RuntimeError('The full set of proof obligations was not discharged')
            report.update(complete=True, passed=True, obligations=expected)
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['seconds'] = time.monotonic() - started
        args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(f'PASS {expected} unbounded {args.case} proof obligations')


if __name__ == '__main__': main()
