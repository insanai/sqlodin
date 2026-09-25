#!/usr/bin/env python3
"""Exercise the native service and installed Python API on three disk-backed voters."""
import argparse
import datetime
import hashlib
import concurrent.futures
import ssl
import struct
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'languages/python/src'))
import sqlodin
from check_mtls import certificates, run


def generate(directory, openssl):
    certificates(directory, openssl)
    for node in (1, 2, 3):
        name = f'node{node}'
        run([openssl, 'req', '-new', '-newkey', 'ed25519', '-noenc', '-subj', '/CN=' + name,
             '-keyout', directory / (name + '.key'), '-out', directory / (name + '.csr')])
        ext = directory / (name + '.ext')
        ext.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                       f'extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:{name}.sqlodin.test\n')
        run([openssl, 'x509', '-req', '-in', directory / (name + '.csr'),
             '-CA', directory / 'ca.pem', '-CAkey', directory / 'ca.key',
             '-set_serial', str(100 + node), '-days', '2', '-extfile', ext,
             '-out', directory / (name + '.pem')])
    for path in directory.glob('*.key'):
        path.chmod(0o600)


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Cluster:
    def __init__(self, root, binary, openssl, storage_format=4, maintenance='manual'):
        self.root, self.binary = root, binary
        self.processes, self.logs = {}, []
        generate(root, openssl)
        self.members = [dict(id=i, address=f'127.0.0.1:{port()}', identity=f'node{i}.sqlodin.test')
                        for i in (1, 2, 3)]
        for m in self.members:
            node = m['id']
            data = root / f'data{node}'
            data.mkdir()
            cfg = dict(storage_format=storage_format, maintenance=maintenance,
                       cluster='network-qualification', node=node, listen=m['address'], data=str(data),
                       certificate=str(root / f'node{node}.pem'), key=str(root / f'node{node}.key'),
                       ca=str(root / 'ca.pem'), members=self.members, clients=['node-2.test.sqlodin'])
            (root / f'node{node}.json').write_text(json.dumps(cfg))

    def start(self, node, create=False):
        log = open(self.root / f'node{node}.log', 'ab')
        self.logs.append(log)
        self.processes[node] = subprocess.Popen([str(self.binary), 'serve', str(self.root / f'node{node}.json'),
                                                *(['--create'] if create else [])], stdout=log, stderr=log,
                                               env=getattr(self, 'environment', None))
        time.sleep(0.15)
        assert self.processes[node].poll() is None, (self.root / f'node{node}.log').read_text()

    def stop(self, node):
        p = self.processes[node]
        if p.poll() is None:
            p.kill()
        p.wait(timeout=10)

    def connect(self, nodes=(1, 2, 3), **options):
        endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in self.members if m['id'] in nodes]
        return sqlodin.connect(endpoints, cluster='network-qualification',
                              tls=sqlodin.TLS(self.root / 'ca.pem', self.root / 'client.pem',
                                              self.root / 'client.key'), **options)

    def close(self):
        for node in self.processes:
            self.stop(node)
        for log in self.logs:
            log.close()


def checks(c, record):
    for node in (1, 2, 3):
        c.start(node, create=True)
    time.sleep(2)
    if not hasattr(c, 'remote_root'):
        cli_checks(c, record)
    with c.connect() as db:
        db.execute('CREATE TABLE account(id INTEGER PRIMARY KEY, amount INTEGER CHECK(amount>=0), name TEXT);')
        record('native_cluster_schema')
        try:
            db.execute('CREATE TABLE ambiguous(rowid,_rowid_,oid); INSERT INTO account VALUES(99,1,\'reject\')')
        except sqlodin.QueryError as exc:
            assert exc.code == 'Policy', exc
        else:
            raise AssertionError('Snapshot-incompatible schema was acknowledged')
        assert db.query("SELECT count(*) FROM sqlite_schema WHERE name='ambiguous'").scalar() == 0
        assert db.query('SELECT count(*) FROM account WHERE id=99').scalar() == 0
        assert db.status()['policy'] == 9
        record('schema_policy_rejects_complete_request_before_snapshot_failure')
        for node in (1, 2, 3):
            with c.connect((node,)) as writer:
                writer.execute('INSERT INTO account VALUES(?, ?, ?)', (node, 100, f'node-{node}'))
        rows = db.query('SELECT id, amount, name FROM account ORDER BY id')
        assert [r['id'] for r in rows] == [1, 2, 3]
        assert rows[1][2] == 'node-2'
        record('write_any_node_fenced_rows')
        row = db.query("SELECT ? AS txt, ? AS big, ? AS nil, ? AS real, X'00FF' AS blob",
                       ('a\x00b', 2**63 - 1, None, 1.25)).one()
        assert row.as_tuple() == ('a\x00b', 2**63 - 1, None, 1.25, b'\x00\xff'), row
        record('typed_parameters_and_results')
        with db.transaction() as tx:
            tx.execute('UPDATE account SET amount=amount-? WHERE id=?', (10, 1))
            tx.execute('UPDATE account SET amount=amount+? WHERE id=?', (10, 2))
        assert tx.result.changes == 2
        assert db.query('SELECT amount FROM account WHERE id=?', (1,)).scalar() == 90
        try:
            with db.transaction() as tx:
                tx.execute('UPDATE account SET amount=amount-? WHERE id=?', (1000, 1))
                tx.execute('UPDATE account SET amount=amount+? WHERE id=?', (1000, 2))
        except sqlodin.ConstraintError:
            pass
        else:
            raise AssertionError('Constraint should reject complete batch')
        assert db.query('SELECT SUM(amount) FROM account').scalar() == 300
        record('atomic_batch_rollback_and_next_sequence')
        for text in ('SELECT 1; SELECT 2;', 'DELETE FROM account', 'SELECT * FROM _sqlodin_sessions'):
            try:
                db.query(text)
            except sqlodin.QueryError:
                pass
            else:
                raise AssertionError('Read policy accepted ' + text)
        try:
            db.query('WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<5000) SELECT n FROM x')
        except sqlodin.QueryError as exc:
            assert exc.code == 'Query_Limit', exc
        else:
            raise AssertionError('Expected bounded result rejection')
        record('readonly_policy_and_result_limit')
    with c.connect() as db:
        for module in ('PrAgMa_data_version', 'PRAGMA_DATA_VERSION'):
            try:
                db.execute(f"INSERT INTO account(id,amount,name) SELECT 999,data_version,'local' FROM {module}")
            except sqlodin.QueryError as exc:
                assert exc.code == 'Policy', exc
            else:
                raise AssertionError('Mixed-case local pragma entered replicated data')
        try:
            db.execute("INSERT INTO account VALUES(999,1,'discarded') RETURNING id")
        except sqlodin.QueryError as exc:
            assert exc.code == 'Policy', exc
        else:
            raise AssertionError('Write API silently discarded RETURNING results')
        assert db.query('SELECT count(*) FROM account WHERE id=999').scalar() == 0
    record('mixed_case_local_pragma_cannot_mutate_replicated_state')
    security_checks(c, record)
    concurrent_checks(c, record)
    # Same immutable identity submitted to distinct masters changes the row once.
    pending = sqlodin.PendingWrite('1' * 32, 1, 'UPDATE account SET amount=amount+?1 WHERE id=?2', (7, 3))
    for node in (1, 2, 3):
        with c.connect((node,), pending=pending) as db:
            assert db.resolve_pending().changes == 1
    with c.connect() as db:
        assert db.query('SELECT amount FROM account WHERE id=3').scalar() == 107
    record('cross_master_durable_deduplication')
    # Prepare a stable identity while quorum is available, then submit under isolation.
    with c.connect((1,)) as db:
        epoch = db.session_epoch()
    isolated = sqlodin.PendingWrite('3'*32, 1,
        'UPDATE account SET amount=amount+?1 WHERE id=?2', (5, 1), epoch=epoch)
    # A single isolated voter cannot acknowledge a write or a fenced read.
    c.stop(2)
    c.stop(3)
    with c.connect((1,), timeout=0.8, pending=isolated) as db:
        try:
            db.resolve_pending()
        except sqlodin.UnknownOutcome as exc:
            saved = sqlodin.PendingWrite.from_json(exc.pending.to_json())
            assert saved == db.pending
        else:
            raise AssertionError('Minority write acknowledged')
        try:
            db.execute('DELETE FROM account')
        except sqlodin.PendingWriteError:
            pass
        else:
            raise AssertionError('Pending identity was abandoned')
        try:
            db.query('SELECT count(*) FROM account')
        except sqlodin.ConnectionError:
            pass
        else:
            raise AssertionError('Minority fenced read completed')
        assert db.query('SELECT count(*) FROM account', consistency='local').scalar() == 3
    record('minority_no_ack_and_explicit_stale_read')
    c.start(2)
    c.start(3)
    with c.connect(pending=saved, timeout=20) as db:
        db.resolve_pending()
        assert db.query('SELECT amount FROM account WHERE id=1').scalar() == 95
    record('recover_uncertain_write_after_quorum_restored')
    for node in (1, 2, 3):
        c.stop(node)
    for node in (1, 2, 3):
        c.start(node)
    for node in (1, 2, 3):
        with c.connect((node,), timeout=20) as db:
            assert db.query('SELECT SUM(amount) FROM account').scalar() == 312
    record('all_process_sigkill_reopen_fenced_convergence')
    if not hasattr(c, 'remote_root'):
        lifecycle_checks(c, record)


def lifecycle_checks(c, record):
    c.processes[1].terminate()
    assert c.processes[1].wait(timeout=10) == 0
    files = list((c.root / 'data1').glob('node.db*'))
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    result = subprocess.run([str(c.binary), 'serve', str(c.root / 'node1.json'), '--create'],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1, result.stdout + result.stderr
    assert {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files} == before
    c.start(1)
    with c.connect((1,), timeout=20) as db:
        assert db.query('SELECT SUM(amount) FROM account').scalar() == 312
    record('graceful_shutdown_and_exclusive_creation')


def cli_checks(c, record):
    m = c.members[0]
    cfg = dict(cluster='network-qualification', address=m['address'], identity=m['identity'],
               certificate=str(c.root / 'client.pem'), key=str(c.root / 'client.key'), ca=str(c.root / 'ca.pem'))
    cfgpath, reqpath = c.root / 'client.json', c.root / 'request.json'
    cfgpath.write_text(json.dumps(cfg))
    for request in (dict(op='status'), dict(op='execute', session='2' * 32, sequence=1,
                                          sql='CREATE TABLE cli_test(id INTEGER PRIMARY KEY)'),
                    dict(op='query', sql='SELECT count(*) AS n FROM cli_test')):
        reqpath.write_text(json.dumps(request))
        result = subprocess.run([str(c.binary), 'request', str(cfgpath), str(reqpath)],
                                capture_output=True, text=True, timeout=65)
        assert result.returncode == 0, result.stderr + result.stdout
        response = json.loads(result.stdout)
        assert response['status'] == 'ok'
        if request['op'] == 'query':
            assert response['rows'][0][0]['integer'] == 0
    record('native_cli_status_write_and_query')


def security_checks(c, record):
    from sqlodin.transport import Transport
    member = c.members[0]
    endpoint = sqlodin.Endpoint(member['address'], member['identity'])
    for cert, key, target in [('rogue', 'rogue', endpoint), ('server', 'server', endpoint),
                              ('node2', 'node2', endpoint)]:
        transport = Transport(sqlodin.TLS(c.root / 'ca.pem', c.root / (cert + '.pem'),
                                         c.root / (key + '.key')))
        try:
            try:
                transport.exchange(target, dict(protocol=1, cluster='network-qualification', op='status'),
                                   time.monotonic() + 2)
            except sqlodin.ConnectionError:
                pass
            else:
                raise AssertionError('Unauthorized identity/role accepted: ' + cert)
        finally:
            transport.close()
    record('untrusted_unlisted_and_peer_as_client_rejected')
    context = sqlodin.TLS(c.root / 'ca.pem', c.root / 'client.pem', c.root / 'client.key').context()
    nested = b'{"op":"status","junk":'+b'['*4096+b'0'+b']'*4096+b'}'
    for frame in (struct.pack('<I', 0), struct.pack('<I', 65537), struct.pack('<I', 1) + b'{',
                  struct.pack('<I', len(nested)) + nested):
        raw = socket.create_connection(endpoint.socket_address(), timeout=2)
        with context.wrap_socket(raw, server_hostname=endpoint.server_name) as peer:
            peer.sendall(frame)
            try:
                assert peer.recv(1) == b''
            except (ssl.SSLError, ConnectionResetError):
                pass
    with c.connect() as db:
        assert db.query('SELECT count(*) FROM account').scalar() == 3
    record('malformed_frames_close_only_offending_connection')


def concurrent_checks(c, record):
    with c.connect() as db:
        db.execute('CREATE TABLE counters(id INTEGER PRIMARY KEY, n INTEGER);')
        for i in range(6):
            db.execute('INSERT INTO counters VALUES(?, 0)', (i,))
    def writer(i):
        with c.connect((i % 3 + 1,), timeout=30) as db:
            for _ in range(20):
                db.execute('UPDATE counters SET n=n+1 WHERE id=?', (i,))
                assert db.query('SELECT n FROM counters WHERE id=?', (i,)).scalar() >= 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(writer, range(6)))
    with c.connect() as db:
        assert [r['n'] for r in db.query('SELECT n FROM counters ORDER BY id')] == [20] * 6
    record('six_concurrent_sessions_mixed_writes_and_fenced_reads')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'bin/sqlodin')
    parser.add_argument('--openssl', default=str(Path(__file__).resolve().parents[1] / 'build/native/openssl'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--storage-format', type=int, choices=(4, 5), default=4)
    args = parser.parse_args()
    report = dict(complete=False, passed=False, scope='three native mTLS SQL service processes on one host; disk WAL FULL',
                  platform=platform.platform(), started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), checks=[])
    report['storage_format'] = args.storage_format
    report['binary_sha256'] = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for directory in ('src', 'service', 'transport', 'cli', 'languages/python/src')
                               for p in sorted((ROOT / directory).rglob('*')) if p.suffix in ('.odin', '.py')}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)
    try:
        scratch = ROOT / 'build/network-work'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='sqlodin-network-', dir=scratch) as work:
            root = Path(work)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, args.binary.resolve(), args.openssl, args.storage_format)
            try:
                checks(c, record)
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-6000:] for p in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
