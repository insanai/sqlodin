#!/usr/bin/env python3
"""Linux process-crash durability checks; kills only child processes started here."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          capture_output=True, timeout=120).stdout.strip()


def kill_stopped(command):
    child = subprocess.Popen([str(a) for a in command], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if child.poll() is not None:
                out, err = child.communicate()
                raise RuntimeError(f'Probe exited before crash boundary: {out}\n{err}')
            state = Path(f'/proc/{child.pid}/status').read_text()
            if '\nState:\tT ' in state:
                child.kill()
                out, err = child.communicate(timeout=10)
                assert child.returncode == -signal.SIGKILL, (out, err)
                return
            time.sleep(.01)
        raise TimeoutError('Probe did not reach its crash boundary')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--individual-journal', action='store_true')
    args = parser.parse_args()
    if args.output and args.output.exists():
        parser.error('output exists; retain prior evidence and select a new report path')
    if platform.system() != 'Linux':
        raise SystemExit('Run these SIGKILL/proc checks on Linux')
    results = []
    disk_tmp = ROOT / 'build/test-tmp'
    disk_tmp.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sqlodin-crash-', dir=disk_tmp) as name:
        work = Path(name)
        filesystem = json.loads(run('findmnt', '--json', '-T', work,
                                   '-o', 'TARGET,FSTYPE,SOURCE,OPTIONS'))
        if filesystem['filesystems'][0]['fstype'] in ('tmpfs', 'ramfs'):
            raise SystemExit('Disk durability checks require the project build directory on persistent storage')
        binary = work / 'probe'
        run(os.environ.get('ODIN', 'odin'), 'build', ROOT / 'internal/durability_probe',
            '-o:speed', '-vet', '-strict-style',
            f'-define:SQLODIN_JOURNAL_GROUP_COMMIT={str(not args.individual_journal).lower()}',
            f'-out:{binary}')
        for boundary, expected in [('before', 0), ('journal', 1), ('application', 1), ('ack', 1)]:
            path = work / f'{boundary}.db'
            run(binary, path, 'init', '-')
            kill_stopped([binary, path, 'write', boundary])
            verification = run(binary, path, 'verify', expected)
            results.append({'case': boundary, 'passed': True, 'verification': verification})
        cluster = work / 'cluster'
        cluster.mkdir()
        kill_stopped([binary, cluster, 'cluster', '-'])
        verification = run(binary, cluster, 'cluster-verify', '-')
        results.append({'case': 'three_voters_killed_at_ack', 'passed': True,
                        'verification': verification})
        for rejected in (False, True):
            suffix = '-reject' if rejected else ''
            for boundary in ('before', 'journal', 'application', 'ack'):
                path = work / f'transaction{suffix}-{boundary}.db'
                run(binary, path, 'tx-init', '-')
                kill_stopped([binary, path, 'tx-write' + suffix, boundary])
                verification = run(binary, path, 'tx-verify' + suffix, boundary)
                results.append({'case': f'transaction{suffix}-{boundary}', 'passed': True,
                                'verification': verification})
        for boundary in ('before', 'journal', 'sql', 'application', 'ack'):
            path = work / f'group-{boundary}.db'
            run(binary, path, 'group-init', '-')
            kill_stopped([binary, path, 'group-write', boundary])
            verification = run(binary, path, 'group-verify', boundary)
            results.append({'case': f'application-group-{boundary}', 'passed': True,
                            'verification': verification})
        for boundary in ('before', 'journal', 'application', 'ack'):
            path = work / f'journal-group-{boundary}.db'
            run(binary, path, 'journal-init', '-')
            kill_stopped([binary, path, 'journal-write', boundary])
            verification = run(binary, path, 'journal-verify', boundary)
            results.append({'case': f'journal-group-{boundary}', 'passed': True,
                            'verification': verification})
    sources = [*ROOT.glob('src/**/*.odin'), *ROOT.glob('internal/durability_probe/*.odin')]
    report = {'schema_version': 1, 'run_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'journal_group_commit': not args.individual_journal,
              'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(sources)},
              'native_dependencies': json.loads((ROOT / 'build/native/build.json').read_text()), 'scope': 'process crash; not physical power-loss certification',
              'platform': platform.platform(), 'filesystem': filesystem, 'checks': results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
