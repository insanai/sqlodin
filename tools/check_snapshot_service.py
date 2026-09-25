#!/usr/bin/env python3
"""Bounded native distributed snapshot capture/certification; does not claim trimming."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from check_network_service import Cluster, ROOT
from check_majority import ready


def wait_sealed(c, target, nodes=(1, 2, 3)):
    deadline = time.monotonic() + 60
    states = {}
    while time.monotonic() < deadline:
        for node in nodes:
            with c.connect((node,), timeout=5) as db:
                states[node] = db.status()
                assert not states[node].get('snapshot_error'), states
        if all(s.get('snapshot_sealed', 0) >= target for s in states.values()):
            return states
        time.sleep(.02)
    raise TimeoutError(f'No certified snapshot for {target}: {states}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    p.add_argument('--operations', type=int, default=30)
    args = p.parse_args()
    if args.operations < 3 or args.output.exists():
        p.error('Use at least three operations and a new evidence path')
    report = dict(complete=False, passed=False, checks=[],
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  scope='format-5 online capture, authenticated quorum receipts and chosen certificate; no trim')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)
    try:
        scratch = ROOT / 'build/snapshot-work'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(
                    ['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, args.binary.resolve(), args.openssl, storage_format=5)
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT)')
                    db.execute("INSERT INTO items VALUES(1,'before')")
                    target = db.request_snapshot()
                for i in range(args.operations):
                    with c.connect((i % 3 + 1,)) as db:
                        db.execute('INSERT INTO items VALUES(?,?)', (i + 2, f'after-{i}'))
                report['first'] = wait_sealed(c, target)
                record('quorum_snapshot_certified_while_all_voters_continue_writes')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.status()['snapshot_sealed'] >= target
                        assert db.query('SELECT count(*) FROM items').scalar() == args.operations + 1
                record('chosen_certificate_and_all_acknowledged_writes_survive_full_restart')
                c.stop(3)
                with c.connect((1, 2)) as db:
                    second = db.request_snapshot()
                    db.execute("UPDATE items SET value='survives' WHERE id=1")
                report['second'] = wait_sealed(c, second, nodes=(1, 2))
                record('two_survivors_capture_and_certify_without_third_voter')
                c.start(3)
                ready(c, 3)
                with c.connect((3,)) as db:
                    assert db.query('SELECT value FROM items WHERE id=1').scalar() == 'survives'
                record('returning_voter_catches_up_after_certificate')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {f.name: f.read_text()[-8000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
