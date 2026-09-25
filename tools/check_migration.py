#!/usr/bin/env python3
"""Bounded on-disk three-voter CLI migration and native mTLS recovery regression."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from check_network_service import Cluster, ROOT
from check_majority import ready


def hashes(directory):
    return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
            for name in ('node.db', 'node.db-wal') if (directory / name).exists()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--old-binary', type=Path, help='Retained compatible source-format binary for preactivation rollback')
    p.add_argument('--operations', type=int, default=18)
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = p.parse_args()
    if args.operations < 6 or args.output.exists():
        p.error('Use at least six operations and a new evidence file')
    report = dict(complete=False, passed=False, checks=[], operations=args.operations,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.old_binary:
        report['old_binary_sha256'] = hashlib.sha256(args.old_binary.read_bytes()).hexdigest()
    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)
    def migrate(root, node, destination):
        return subprocess.run([str(args.binary.resolve()), 'migrate',
                               str(root / f'node{node}.json'), str(destination)],
                              capture_output=True, text=True, timeout=120)
    try:
        scratch = ROOT / 'build/migration-work'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(
                    ['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, (args.old_binary or args.binary).resolve(), args.openssl)
            original = {node: (root / f'node{node}.json').read_text() for node in (1, 2, 3)}
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE migration_items(id INTEGER PRIMARY KEY, value TEXT)')
                for i in range(args.operations):
                    with c.connect((i % 3 + 1,)) as db:
                        db.execute('INSERT INTO migration_items VALUES(?,?)', (i, f'item-{i}'))
                live = migrate(root, 1, root / 'refused-live')
                assert live.returncode == 1 and 'Locked' in live.stderr, live
                record('live_source_refused')
                for node in (1, 2, 3): c.stop(node)
                if args.old_binary:
                    # These private copies are never activated and become stale after rollback.
                    for node in (1, 2, 3):
                        before = hashes(root / f'data{node}')
                        result = migrate(root, node, root / f'abandoned-format5-{node}')
                        assert result.returncode == 0, result.stderr
                        assert hashes(root / f'data{node}') == before
                        assert (root / f'node{node}.json').read_text() == original[node]
                    for node in (1, 2, 3): c.start(node)
                    for node in (1, 2, 3):
                        ready(c, node)
                        with c.connect((node,)) as db:
                            assert db.query('SELECT count(*) FROM migration_items').scalar() == args.operations
                            db.execute('UPDATE migration_items SET value=? WHERE id=?', (f'rollback-{node}', node-1))
                    for node in (1, 2, 3): c.stop(node)
                    record('preactivation_rollback_runs_retained_binary_and_source_with_new_acknowledged_writes')
                c.binary = args.binary.resolve()
                for node in (1, 2, 3):
                    before = hashes(root / f'data{node}')
                    destination = root / f'format5-{node}'
                    result = migrate(root, node, destination)
                    assert result.returncode == 0, result.stderr
                    assert hashes(root / f'data{node}') == before
                    cfg = json.loads((destination / 'node.json').read_text())
                    assert cfg['storage_format'] == 5 and cfg['data'] == str(destination)
                    (root / f'node{node}.json').write_text(json.dumps(cfg))
                record('all_voters_migrated_source_database_and_wal_unchanged')
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        rows = db.query('SELECT id,value FROM migration_items ORDER BY id')
                        assert [(r['id'], r['value']) for r in rows] == [
                            (i, f'rollback-{i+1}' if args.old_binary and i < 3 else f'item-{i}')
                            for i in range(args.operations)]
                for node in (1, 2, 3):
                    with c.connect((node,)) as db:
                        db.execute('INSERT INTO migration_items VALUES(?,?)', (10000 + node, 'new'))
                record('migrated_voters_serve_exact_data_and_accept_writes_on_every_node')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT count(*) FROM migration_items').scalar() == args.operations + 3
                record('second_full_restart_preserves_old_and_new_writes')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {f.name: f.read_text()[-6000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
