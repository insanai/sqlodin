#!/usr/bin/env python3
"""Native expiry, compatibility, readiness and coordinated CA/credential renewal checks."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

from check_network_service import Cluster, ROOT, generate, sqlodin
from check_majority import ready
from check_mtls import run


class RenewalCluster(Cluster):
    credential_root = None

    def connect(self, nodes=(1, 2, 3), **options):
        credentials = self.credential_root or self.root
        endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in self.members if m['id'] in nodes]
        return sqlodin.connect(endpoints, cluster='network-qualification',
                               tls=sqlodin.TLS(credentials / 'ca.pem', credentials / 'client.pem',
                                               credentials / 'client.key'), **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new evidence path')
    binary = args.binary.resolve()
    report = dict(complete=False, passed=False, checks=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    def rejected_connection(c, tls):
        endpoint = sqlodin.Endpoint(c.members[0]['address'], c.members[0]['identity'])
        with sqlodin.connect(endpoint, cluster='network-qualification', tls=tls, timeout=.8) as db:
            try:
                db.status()
            except sqlodin.ConnectionError:
                return
        raise AssertionError('Rejected credential obtained a service response')

    def refused_start(path, reason):
        result = subprocess.run([str(binary), 'serve', str(path)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 1 and reason in result.stderr, result
        return result.stderr

    scratch = ROOT / 'build/certificate-lifecycle-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = RenewalCluster(root, binary, args.openssl, storage_format=5)
            original = {node: json.loads((root / f'node{node}.json').read_text()) for node in (1, 2, 3)}
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,visits INTEGER)')
                    db.execute('INSERT INTO items VALUES(1,0)')
                pending = sqlodin.PendingWrite('cd'*16, 1, 'UPDATE items SET visits=visits+1 WHERE id=1')
                with c.connect((1,), pending=pending) as db:
                    db.resolve_pending()
                rejected_connection(c, sqlodin.TLS(root / 'ca.pem', root / 'expired.pem', root / 'expired.key'))
                record('expired_client_certificate_rejected_by_native_service')
                c.stop(1)
                run([args.openssl, 'x509', '-req', '-in', root / 'node1.csr',
                     '-CA', root / 'ca.pem', '-CAkey', root / 'ca.key', '-set_serial', '9001',
                     '-days', '0', '-extfile', root / 'node1.ext', '-out', root / 'expired-node1.pem'])
                config = dict(original[1], certificate=str(root / 'expired-node1.pem'))
                (root / 'node1.json').write_text(json.dumps(config))
                report['expired_start_diagnostic'] = refused_start(root / 'node1.json', 'certificate dates')
                with c.connect((2, 3)) as db:
                    db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                record('expired_local_certificate_fails_startup_with_corrective_diagnostic_and_survivors_progress')
                config = json.loads(json.dumps(original[1]))
                config['members'][2]['id'] = 4
                (root / 'node1.json').write_text(json.dumps(config))
                refused_start(root / 'node1.json', 'Storage')
                mismatch = root / 'engine-mismatch'
                shutil.copytree(root / 'data1', mismatch)
                with sqlite3.connect(mismatch / 'consensus.db') as db:
                    db.execute("UPDATE _sqlodin_journal_meta SET identity=replace(identity,'sqlite=','sqlite=bad')")
                (root / 'node1.json').write_text(json.dumps(dict(original[1], data=str(mismatch))))
                refused_start(root / 'node1.json', 'Storage')
                (root / 'node1.json').write_text(json.dumps(original[1]))
                c.start(1)
                ready(c, 1)
                record('membership_and_engine_identity_mismatch_refuse_startup_without_replacing_source')
                # A stopped and isolated voter may listen, but must not pass a fresh-read readiness check.
                c.stop(2)
                c.stop(3)
                with c.connect((1,), timeout=.8) as db:
                    assert db.status()['node'] == 1
                    try:
                        db.query('SELECT 1')
                    except (sqlodin.ConnectionError, sqlodin.QueryError):
                        pass
                    else:
                        raise AssertionError('Minority reported quorum readiness')
                c.stop(1)
                record('listening_status_is_distinct_from_quorum_readiness')
                renewed = root / 'renewed'
                renewed.mkdir()
                generate(renewed, args.openssl)
                report['ca_sha256'] = [hashlib.sha256((path / 'ca.pem').read_bytes()).hexdigest()
                                       for path in (root, renewed)]
                assert report['ca_sha256'][0] != report['ca_sha256'][1]
                for node in (1, 2, 3):
                    config = dict(original[node], ca=str(renewed / 'ca.pem'),
                                  certificate=str(renewed / f'node{node}.pem'), key=str(renewed / f'node{node}.key'))
                    (root / f'node{node}.json').write_text(json.dumps(config))
                c.credential_root = renewed
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3): ready(c, node)
                rejected_connection(c, sqlodin.TLS(root / 'ca.pem', root / 'client.pem', root / 'client.key'))
                rejected_connection(c, sqlodin.TLS(renewed / 'ca.pem', root / 'client.pem', root / 'client.key'))
                with c.connect((3,), pending=pending) as db:
                    db.resolve_pending()
                    assert db.query('SELECT visits FROM items').scalar() == 2
                for node in (1, 2, 3):
                    with c.connect((node,)) as db:
                        db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                record('coordinated_ca_key_and_leaf_renewal_preserves_retry_fences_and_rejects_old_credentials')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT visits FROM items').scalar() == 5
                record('renewed_cluster_restarts_with_all_acknowledged_effects')
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-12000:] for p in root.glob('*.log')}
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
