#!/usr/bin/env python3
"""Bounded fresh-namespace recovery after one voter loses its data directory."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from check_network_service import Cluster, ROOT, sqlodin
from check_majority import ready
from check_snapshot_service import wait_sealed


class RecoveryCluster(Cluster):
    namespace = 'network-qualification'

    def connect(self, nodes=(1, 2, 3), **options):
        endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in self.members if m['id'] in nodes]
        return sqlodin.connect(endpoints, cluster=self.namespace,
                               tls=sqlodin.TLS(self.root / 'ca.pem', self.root / 'client.pem',
                                               self.root / 'client.key'), **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new evidence path; earlier failures are retained')
    binary = args.binary.resolve()
    report = dict(complete=False, passed=False, checks=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  scope='coordinated fresh namespace; process/data-directory faults, not physical disk loss')
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    def command(*argv):
        result = subprocess.run([str(binary), *map(str, argv)], capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, (argv, result.returncode, result.stdout, result.stderr)
        return result.stdout

    def no_quorum(c, node):
        with c.connect((node,), timeout=.8) as db:
            try:
                db.query('SELECT 1')
            except sqlodin.ConnectionError:
                return
            except sqlodin.QueryError as exc:
                assert str(exc) in ('Timeout', 'Busy'), str(exc)
                return
        raise AssertionError('Incompatible voter served a fresh quorum read')

    scratch = ROOT / 'build/restore-service-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = RecoveryCluster(root, binary, args.openssl, storage_format=5)
            original = {node: (root / f'node{node}.json').read_text() for node in (1, 2, 3)}
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect((1,)) as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,visits INTEGER)')
                    db.execute('INSERT INTO items VALUES(1,0)')
                    db.execute('CREATE VIRTUAL TABLE search USING fts5(body)')
                    db.execute("INSERT INTO search VALUES('durable text')")
                    db.execute('CREATE TABLE vectors(id INTEGER PRIMARY KEY,embedding BLOB)')
                    db.execute('INSERT INTO vectors VALUES(?,?)', (1, sqlodin.Vector([1, 2])))
                c.stop(3)
                (root / 'data3').rename(root / 'lost-data3')
                pending = sqlodin.PendingWrite('ab'*16, 1, 'UPDATE items SET visits=visits+1 WHERE id=1')
                with c.connect((1,), pending=pending) as db:
                    db.resolve_pending()
                    assert db.query('SELECT visits FROM items').scalar() == 1
                c.stop(1)
                older, backup = root / 'older-backup', root / 'backup'
                command('backup', root / 'node1.json', older)
                c.start(1)
                ready(c, 1)
                with c.connect((2,)) as db:
                    db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                # All clients are quiescent; establish the acknowledged cut at the backup source.
                with c.connect((1,)) as db:
                    assert db.query('SELECT visits FROM items').scalar() == 2
                c.stop(1)
                command('backup', root / 'node1.json', backup)
                c.stop(2)
                record('survivors_establish_fresh_backup_cut_after_voter_directory_loss')
                c.namespace = 'recovered-' + root.name
                configs = {}
                for node in (1, 2, 3):
                    cfg = json.loads(original[node])
                    cfg.update(cluster=c.namespace, data=str(root / f'restored{node}'))
                    configs[node] = cfg
                    (root / f'node{node}.json').write_text(json.dumps(cfg))
                    command('restore', older if node == 3 else backup, root / f'node{node}.json', '--new-cluster')
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2): ready(c, node)
                no_quorum(c, 3)
                with c.connect((2,), pending=pending) as db:
                    db.resolve_pending()
                    assert db.query('SELECT visits FROM items').scalar() == 2
                record('mismatched_genesis_cannot_join_and_cross_voter_retry_has_no_duplicate_effect')
                c.stop(3)
                (root / 'lost-data3').rename(root / 'data3')
                (root / 'node3.json').write_text(original[3])
                c.start(3)
                no_quorum(c, 3)
                with c.connect((1, 2)) as db:
                    assert db.query('SELECT visits FROM items').scalar() == 2
                record('old_instance_cannot_rejoin_or_delay_the_new_quorum')
                c.stop(3)
                configs[3]['data'] = str(root / 'repaired3')
                (root / 'node3.json').write_text(json.dumps(configs[3]))
                command('restore', backup, root / 'node3.json', '--new-cluster')
                c.start(3)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                        assert db.query("SELECT count(*) FROM search WHERE search MATCH 'durable'").scalar() == 1
                        assert db.query('SELECT vec_distance_l2(embedding,?) FROM vectors',
                                        (sqlodin.Vector([1, 2]),)).scalar() == 0
                record('all_restored_voters_accept_writes_and_serve_fts_and_vectors')
                with c.connect((1,)) as db:
                    target = db.request_snapshot()
                wait_sealed(c, target)
                for node in (1, 2, 3):
                    c.stop(node)
                    command('compact', root / f'node{node}.json')
                    c.start(node)
                    ready(c, node)
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT visits FROM items').scalar() == 5
                with c.connect((3,), pending=pending) as db:
                    db.resolve_pending()
                    assert db.query('SELECT visits FROM items').scalar() == 5
                record('genesis_retry_fences_and_writes_survive_compaction_and_full_restart')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-16000:] for p in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for folder in ('src', 'service', 'cli', 'transport')
                             for p in (ROOT / folder).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
