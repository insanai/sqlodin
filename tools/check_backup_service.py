#!/usr/bin/env python3
"""Public offline application backup while the surviving native quorum keeps serving."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

from check_network_service import Cluster, ROOT
from check_majority import ready


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
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    def command(*argv):
        return subprocess.run([str(binary), *map(str, argv)], capture_output=True, text=True, timeout=120)

    scratch = ROOT / 'build/backup-service-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, binary, args.openssl, storage_format=5)
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect((1,)) as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)')
                    db.execute("INSERT INTO items VALUES(1,'before backup')")
                    db.execute('CREATE VIRTUAL TABLE search USING fts5(body)')
                    db.execute("INSERT INTO search VALUES('durable text')")
                    assert db.query('SELECT count(*) FROM items').scalar() == 1
                backup = root / 'backup'
                rejected = command('backup', root / 'node1.json', backup)
                assert rejected.returncode == 1 and 'Locked' in rejected.stderr, rejected
                assert not backup.exists()
                record('backup_refuses_active_voter_without_creating_destination')
                c.stop(1)
                result = command('backup', root / 'node1.json', backup)
                assert result.returncode == 0, result.stderr
                report['backup_output'] = result.stdout
                before = hashlib.sha256((backup / 'application.db').read_bytes()).hexdigest()
                verified = command('verify-backup', backup)
                assert verified.returncode == 0, verified.stderr
                assert before == hashlib.sha256((backup / 'application.db').read_bytes()).hexdigest()
                assert command('backup', root / 'node1.json', backup).returncode == 1
                record('public_backup_verifies_without_rewriting_image_and_refuses_existing_destination')
                with c.connect((2, 3)) as db:
                    db.execute("INSERT INTO items VALUES(2,'after backup')")
                    assert db.query('SELECT count(*) FROM items').scalar() == 2
                with sqlite3.connect(f'file:{backup / "application.db"}?mode=ro&immutable=1', uri=True) as image:
                    assert image.execute('SELECT count(*) FROM items').fetchone() == (1,)
                    assert image.execute("SELECT count(*) FROM search WHERE search MATCH 'durable'").fetchone() == (1,)
                    assert image.execute('SELECT count(*) FROM _sqlodin_sessions').fetchone()[0] > 0
                    assert image.execute("SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_journal'").fetchone() == (0,)
                record('backup_cut_preserves_data_fts_and_retry_state_without_acceptor_tables')
                c.start(1)
                ready(c, 1)
                with c.connect((1,)) as db:
                    assert db.query('SELECT count(*) FROM items').scalar() == 2
                record('source_rejoins_and_recovers_writes_accepted_by_surviving_quorum')
                corrupt = root / 'corrupt'
                shutil.copytree(backup, corrupt)
                path = corrupt / 'application.db'
                with path.open('r+b') as image:
                    image.seek(-1, 2)
                    byte = image.read(1)
                    image.seek(-1, 2)
                    image.write(bytes([byte[0] ^ 1]))
                rejected = command('verify-backup', corrupt)
                assert rejected.returncode == 1 and 'BACKUP VERIFICATION FAILED' in rejected.stderr, rejected
                path.unlink()
                path.symlink_to(backup / 'application.db')
                assert command('verify-backup', corrupt).returncode == 1
                record('corrupt_and_symlinked_backup_images_are_rejected')
                report.update(complete=True, passed=True, image_sha256=before)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-10000:] for p in root.glob('*.log')}
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
