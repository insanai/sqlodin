#!/usr/bin/env python3
"""Public retry-epoch retirement, CLI state, compaction and restored-genesis checks."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from check_network_service import ROOT, sqlodin
from check_restore_service import RecoveryCluster
from check_majority import ready
from check_snapshot_service import wait_sealed


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--openssl', default=str(ROOT/'build/native/openssl'))
    args = p.parse_args()
    if args.output.exists(): p.error('Use a new evidence path')
    binary = args.binary.resolve()
    report = dict(complete=False, passed=False, checks=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    def command(*argv, success=True):
        result = subprocess.run([str(binary), *map(str, argv)], capture_output=True, text=True, timeout=120)
        assert (result.returncode == 0) == success, (argv, result.stdout, result.stderr)
        return result

    def expired(c, pending, node=2):
        with c.connect((node,), pending=pending) as db:
            try: db.resolve_pending()
            except sqlodin.SessionError as exc: assert exc.code == 'Expired'
            else: raise AssertionError('Retired request was not fenced')
            assert db.pending == pending

    scratch = ROOT/'build/session-retirement-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = RecoveryCluster(root, binary, args.openssl, storage_format=5)
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE items(v INTEGER)')
                    db.execute('INSERT INTO items VALUES(0)')
                old = sqlodin.PendingWrite('ca'*16, 1, 'UPDATE items SET v=v+1', epoch=0)
                with c.connect((1,), pending=old) as db: db.resolve_pending()
                c.stop(3)
                with c.connect((1,)) as db:
                    assert db.retire_sessions(expected_epoch=0) == 1
                    assert db.retire_sessions(expected_epoch=0) == 1
                expired(c, old)
                current = sqlodin.PendingWrite('ca'*16, 1, 'UPDATE items SET v=v+1', epoch=1)
                with c.connect((2,), pending=current) as db: db.resolve_pending()
                with c.connect((1,)) as db:
                    assert db.retire_sessions(expected_epoch=0) == 1
                with c.connect((1,), pending=current) as db: db.resolve_pending()
                with c.connect((2,)) as db:
                    db.execute('UPDATE items SET v=v+1')
                    assert db.query('SELECT v FROM items').scalar() == 3
                    assert db.retire_sessions(expected_epoch=1) == 2
                    try: db.retire_sessions(expected_epoch=0)
                    except sqlodin.SerializationError: pass
                    else: raise AssertionError('Stale retirement advanced the epoch')
                expired(c, current)
                record('absent_voter_retirement_old_retry_fence_new_epoch_and_idempotent_control')
                c.start(3)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.session_epoch() == 2
                        db.execute('UPDATE items SET v=v+1')
                with c.connect((1,)) as db: target = db.request_snapshot()
                wait_sealed(c, target, (1, 2, 3))
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): command('compact', root/f'node{node}.json')
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3): ready(c, node)
                expired(c, old, 3)
                expired(c, current, 3)
                with c.connect((3,)) as db:
                    # Advance only the active generation after publication. A preview
                    # opened on the retained root would now use the wrong revision.
                    db.execute('UPDATE items SET v=v')
                    revision = db._begin_optimistic()
                    preview = db._preview('UPDATE items SET v=v+1', (), revision, 'SELECT v FROM items')
                    assert preview['rows'][0][0]['integer'] == 7
                    assert db.query('SELECT v FROM items').scalar() == 6
                record('epoch_fences_survive_compaction_and_preview_uses_active_generation')
                member = c.members[0]
                config = root/'client.json'
                config.write_text(json.dumps(dict(cluster=c.namespace, address=member['address'],
                    identity=member['identity'], ca=str(root/'ca.pem'), certificate=str(root/'client.pem'),
                    key=str(root/'client.key'))))
                state = root/'old-client.db'
                command('connect', config, '--state', state, '-c', 'UPDATE items SET v=v+1')
                result = command('connect', config, '--state', state, '-c', '.retire-sessions 2 --quiesced')
                assert 'session epoch: 3' in result.stdout
                rejected = command('connect', config, '--state', state, '-c', 'UPDATE items SET v=v+1', success=False)
                assert 'SESSION RETIRED' in rejected.stderr and 'Do not relabel' in rejected.stderr
                command('connect', config, '--state', root/'new-client.db', '-c', 'UPDATE items SET v=v+1')
                kept = sqlodin.PendingWrite('de'*16, 1, 'UPDATE items SET v=v+1', epoch=3)
                with c.connect((1,), pending=kept) as db:
                    db.resolve_pending()
                    assert db.query('SELECT v FROM items').scalar() == 9
                record('cli_retirement_durable_old_state_rejection_and_fresh_epoch_discovery')
                c.stop(1)
                command('backup', root/'node1.json', root/'backup')
                c.stop(2); c.stop(3)
                c.namespace = 'recovered-session-retirement'
                for node in (1, 2, 3):
                    path = root/f'node{node}.json'
                    config = json.loads(path.read_text())
                    config.update(cluster=c.namespace, data=str(root/f'restored{node}'))
                    path.write_text(json.dumps(config))
                    command('restore', root/'backup', path, '--new-cluster')
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3): ready(c, node)
                expired(c, old)
                expired(c, current)
                with c.connect((3,), pending=kept) as db:
                    db.resolve_pending()
                    assert db.query('SELECT v FROM items').scalar() == 9
                    assert db.session_epoch() == 3
                record('backup_restore_preserves_epoch_and_current_retry_without_reviving_old_epochs')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {f.name: f.read_text()[-12000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                             for d in ('src', 'service', 'cli', 'transport') for f in (ROOT/d).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
