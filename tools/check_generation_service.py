#!/usr/bin/env python3
"""Public CLI compaction and native generation startup across three local Linux voters."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from check_network_service import Cluster, ROOT
from check_majority import ready
from check_snapshot_service import wait_sealed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--operations', type=int, default=30)
    parser.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = parser.parse_args()
    if args.output.exists() or args.operations < 3:
        parser.error('Use a new evidence path and at least three operations')
    report = dict(complete=False, passed=False, checks=[], operations_per_cycle=args.operations,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  scope='two public CLI compaction cycles and native startup; peers already past each snapshot')
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    def compact(root, node):
        return subprocess.run([str(args.binary.resolve()), 'compact', str(root / f'node{node}.json')],
                              capture_output=True, text=True, timeout=120)

    try:
        scratch = ROOT / 'build/generation-service-work'
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
                for cycle in range(2):
                    for i in range(args.operations):
                        with c.connect((i % 3 + 1,)) as db:
                            db.execute('INSERT INTO items VALUES(?,?)',
                                       (cycle * args.operations + i, f'cycle-{cycle}-item-{i}'))
                    with c.connect() as db:
                        target = db.request_snapshot()
                    wait_sealed(c, target)
                    live = compact(root, 1)
                    assert live.returncode == 1 and 'Locked' in live.stderr, live
                    record(f'cycle_{cycle}_active_voter_compaction_refused')
                    for node in (1, 2, 3):
                        c.stop(node)
                        result = compact(root, node)
                        assert result.returncode == 0, result.stderr
                        assert 'Previous files retained' in result.stdout, result.stdout
                        c.start(node)
                        ready(c, node)
                        with c.connect((node,)) as db:
                            assert db.status()['generation_prefix'] >= target
                            assert db.query('SELECT count(*) FROM items').scalar() == (cycle + 1) * args.operations
                    record(f'cycle_{cycle}_each_voter_publishes_and_serves_certified_generation')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT count(*) FROM items').scalar() == 2 * args.operations
                for node in (1, 2, 3):
                    with c.connect((node,)) as db:
                        db.execute('INSERT INTO items VALUES(?,?)', (100000 + node, 'after-restart'))
                record('all_published_voters_restart_and_continue_multi_master_writes')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-10000:] for p in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
