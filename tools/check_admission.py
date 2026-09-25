#!/usr/bin/env python3
"""Bounded native client saturation and peer reconnect regression (R5.1)."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from check_network_service import Cluster, ROOT, sqlodin
from check_majority import ready
from sqlodin.transport import Transport


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = p.parse_args()
    if args.output.exists(): p.error('Use a new evidence path')
    report = dict(complete=False, passed=False, checks=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    scratch = ROOT / 'build/admission-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, args.binary.resolve(), args.openssl, storage_format=5)
            clients, stalled = {}, []
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                for node in (1, 2, 3):
                    clients[node] = []
                    for _ in range(24):
                        db = c.connect((node,))
                        assert db.status()['node'] == node
                        clients[node].append(db)
                    transport = Transport(sqlodin.TLS(root/'ca.pem', root/'client.pem', root/'client.key'))
                    try:
                        endpoint = sqlodin.Endpoint(c.members[node-1]['address'], c.members[node-1]['identity'])
                        response = transport.exchange(endpoint, dict(op='status', protocol=1,
                            cluster='network-qualification'), time.monotonic()+2)
                        assert response['status'] == 'error' and response['error'] == 'Busy', response
                    finally:
                        transport.close()
                record('24_clients_per_voter_and_explicit_busy_without_peer_eviction')
                clients[1][0].execute('CREATE TABLE admission_items(id INTEGER PRIMARY KEY)')
                for node in (1, 2, 3):
                    clients[node][0].execute('INSERT INTO admission_items VALUES(?)', (node,))
                record('all_voters_write_with_every_client_pool_full')
                # Raw stalled TLS handshakes consume only the separate pending budget.
                for node in (1, 2):
                    host, port = c.members[node-1]['address'].rsplit(':', 1)
                    for _ in range(4): stalled.append(socket.create_connection((host, int(port)), timeout=2))
                c.stop(3)
                started = time.monotonic()
                clients[1][0].execute('INSERT INTO admission_items VALUES(4)')
                clients[2][0].execute('INSERT INTO admission_items VALUES(5)')
                report['survivor_two_writes_seconds'] = time.monotonic()-started
                assert clients[2][0].query('SELECT count(*) FROM admission_items').scalar() == 5
                record('healthy_quorum_progress_with_full_clients_stalled_handshakes_and_one_crash')
                for sock in stalled: sock.close()
                stalled.clear()
                for db in clients[3]: db.close()
                clients[3].clear()
                c.start(3)
                ready(c, 3)
                with c.connect((3,)) as db:
                    assert db.query('SELECT count(*) FROM admission_items').scalar() == 5
                    db.execute('INSERT INTO admission_items VALUES(6)')
                for node in (1, 2):
                    assert clients[node][0].query('SELECT count(*) FROM admission_items').scalar() == 6
                record('restarted_peer_reconnects_and_catches_up_with_survivor_client_pools_full')
                clients[1].pop().close()
                with c.connect((1,)) as replacement:
                    assert replacement.query('SELECT count(*) FROM admission_items').scalar() == 6
                record('released_client_capacity_is_reusable')
                report.update(complete=True, passed=True)
            finally:
                for sock in stalled: sock.close()
                for group in clients.values():
                    for db in group: db.close()
                c.close()
                report['logs'] = {f.name: f.read_text()[-8000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                             for d in ('src', 'service', 'cli', 'transport') for f in (ROOT/d).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
