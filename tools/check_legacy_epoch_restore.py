#!/usr/bin/env python3
"""Restore a genuine pre-epoch format-5 backup with its saved retry identity."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from check_network_service import ROOT, sqlodin
from check_restore_service import RecoveryCluster
from check_majority import ready


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--old-binary', type=Path, required=True)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.exists(): p.error('Use a new evidence path')
    report = dict(complete=False, passed=False, checks=[],
        old_binary_sha256=hashlib.sha256(args.old_binary.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
    scratch = ROOT/'build/legacy-epoch-work'
    scratch.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def command(binary, *argv):
        result = subprocess.run([str(binary.resolve()), *map(str, argv)], capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, (argv, result.stdout, result.stderr)

    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            c = RecoveryCluster(root, args.old_binary.resolve(), str(ROOT/'build/native/openssl'), storage_format=5)
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE legacy(v INTEGER)')
                    db.execute('INSERT INTO legacy VALUES(0)')
                saved = sqlodin.PendingWrite('ab'*16, 1, 'UPDATE legacy SET v=v+1')
                with c.connect((1,), pending=saved) as db:
                    db.resolve_pending()
                    assert db.query('SELECT v FROM legacy').scalar() == 1
                c.stop(1)
                command(args.old_binary, 'backup', root/'node1.json', root/'backup')
                command(args.binary, 'verify-backup', root/'backup')
                c.stop(2); c.stop(3)
                c.namespace, c.binary = 'epoch-upgraded-recovery', args.binary.resolve()
                for node in (1, 2, 3):
                    path = root/f'node{node}.json'
                    config = json.loads(path.read_text())
                    config.update(cluster=c.namespace, data=str(root/f'upgraded{node}'))
                    path.write_text(json.dumps(config))
                    command(args.binary, 'restore', root/'backup', path, '--new-cluster')
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3): ready(c, node)
                with c.connect((3,), pending=saved) as db:
                    db.resolve_pending()
                    assert db.query('SELECT v FROM legacy').scalar() == 1
                    assert db.retire_sessions(expected_epoch=0) == 1
                with c.connect((2,), pending=saved) as db:
                    try: db.resolve_pending()
                    except sqlodin.SessionError as exc: assert exc.code == 'Expired'
                    else: raise AssertionError('Old epoch request revived')
                with c.connect((1,)) as db:
                    db.execute('UPDATE legacy SET v=v+1')
                    assert db.query('SELECT v FROM legacy').scalar() == 2
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.session_epoch() == 1
                        assert db.query('SELECT v FROM legacy').scalar() == 2
                report.update(complete=True, passed=True)
                report['checks'].append(dict(name='legacy_backup_retry_epoch_conversion_retirement_and_restart', passed=True))
                print('PASS legacy_backup_retry_epoch_conversion_retirement_and_restart', flush=True)
            finally:
                c.close()
                report['logs'] = {f.name: f.read_text()[-8000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                             for d in ('src', 'service', 'cli') for f in (ROOT/d).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
