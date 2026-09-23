#!/usr/bin/env python3
"""Exercise the actual local shell and cluster CLI, including lost-response recovery."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import socket
import sqlite3
import ssl
import struct
import subprocess
import tempfile
import threading
import time

from check_network_service import Cluster

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/sqlodin-shell')
    parser.add_argument('--server', type=Path, default=ROOT / 'bin/sqlodin')
    parser.add_argument('--openssl', type=Path, default=ROOT / 'build/native/openssl')
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmarks/results/local-cli.json')
    args = parser.parse_args()
    binary = args.binary.resolve()
    cases = []
    def record(name):
        cases.append(name)
        print('PASS', name, flush=True)
    with tempfile.TemporaryDirectory(prefix='sqlodin-cli-') as temporary:
        root = Path(temporary)
        def run(argv, text=None, code=0, env=None):
            if argv and argv[0] == 'local': argv = ['local', '-init', os.devnull, *argv[1:]]
            p = subprocess.run([str(binary), *map(str, argv)], input=text, text=True,
                               capture_output=True, timeout=90, env=env, cwd=root)
            assert p.returncode == code, (argv, p.returncode, p.stdout, p.stderr)
            return p
        local = root / 'local.db'
        r = run(['local', local], "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);\n"
                "INSERT INTO t VALUES(1,'Ada');\n.mode json\nSELECT * FROM t;\n"
                "CREATE VIRTUAL TABLE search USING fts5(body);\nINSERT INTO search VALUES('hello');\n"
                "SELECT count(*) AS hits FROM search WHERE search MATCH 'hello';\nSELECT vec_version();\n")
        assert 'Ada' in r.stdout and '0.1.9' in r.stdout and 'hits' in r.stdout
        record('local_sql_rows_fts_vector')
        run(['local', local], f'.backup {root / "backup.db"}\n.dump t\n')
        with sqlite3.connect(root / 'backup.db') as db:
            assert db.execute('SELECT name FROM t').fetchone() == ('Ada',)
        (root / 'data.csv').write_text('2,Grace\n3,Linus\n')
        run(['local', local], f'.mode csv\n.import {root / "data.csv"} t\n')
        r = run(['local', local, 'SELECT count(*) FROM t'])
        assert r.stdout.strip() == '3', r
        record('local_backup_dump_csv_import')
        r = run(['local', local, 'SELECT * FROM absent'], code=1)
        assert 'Hint:' in r.stderr and 'no such table' in r.stderr
        record('local_sql_failure_hint_exit')
        r = run(['connect', 'missing.json'], code=2)
        assert 'Hint:' in r.stderr and '\x1b' not in r.stderr
        record('redirected_diagnostics_plain')
        color_test(binary, root)
        record('terminal_color_and_no_color')
        cluster = Cluster(root, args.server.resolve(), str(args.openssl.resolve()))
        try:
            for node in (1, 2, 3): cluster.start(node, create=True)
            time.sleep(2)
            cfg = dict(cluster='network-qualification', address=cluster.members[0]['address'],
                       identity=cluster.members[0]['identity'], certificate=str(root / 'client.pem'),
                       key=str(root / 'client.key'), ca=str(root / 'ca.pem'))
            config = root / 'client.json'
            config.write_text(json.dumps(cfg))
            def cli(text, code=0, options=()):
                return run(['connect', config, *options], text, code)
            r = cli('CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT, amount INTEGER CHECK(amount>=0));\n'
                    "INSERT INTO item VALUES(1,'Ada',100);\n.mode json\nSELECT * FROM item;\n")
            assert json.loads(r.stdout) == [dict(id=1, name='Ada', amount=100)], r
            record('cluster_create_write_read_json')
            r = cli('.tables\n.schema item\n.indexes item\n.status\n.health\n.connection\n.nodes\n')
            assert 'item' in r.stdout and 'CREATE TABLE' in r.stdout and 'quorum read passed' in r.stdout
            record('cluster_catalog_status_quorum_health')
            second = root / 'second.json'
            second.write_text(json.dumps(dict(cfg, address=cluster.members[1]['address'],
                                              identity=cluster.members[1]['identity'])))
            r = cli(f'.reconnect {second}\n.status\n')
            assert 'node=2' in r.stdout, r
            record('reconnect_another_master_same_identity')
            r = cli('-- transaction comment\nBEGIN /* serializable */ TRANSACTION;\nUPDATE item SET amount=amount-10 WHERE id=1;\n'
                    'SAVEPOINT change;\nUPDATE item SET amount=amount-20 WHERE id=1;\n'
                    'ROLLBACK TO change;\nRELEASE change;\n.mode json\nSELECT amount FROM item;\nCOMMIT;\n'
                    'SELECT amount FROM item;\n')
            assert [json.loads(x) for x in r.stdout.splitlines()] == [[dict(amount=90)], [dict(amount=90)]], r
            record('transaction_preview_savepoint_commit')
            r = cli('BEGIN;\nUPDATE item SET amount=1;\nROLLBACK;\nSELECT amount FROM item;\n')
            assert r.stdout.strip() == '90', r
            record('transaction_rollback')
            r = cli('BEGIN;\nUPDATE item SET amount=2;\n')
            assert 'discarded' in r.stderr
            assert cli('SELECT amount FROM item;\n').stdout.strip() == '90'
            record('exit_discards_uncommitted_preview')
            r = cli('BEGIN;\nUPDATE item SET amount=-1;\nCOMMIT;\nROLLBACK;\nSELECT amount FROM item;\n', code=1)
            assert r.stdout.strip() == '90' and 'Hint:' in r.stderr and 'CONSTRAINT' in r.stderr, r
            record('failed_transaction_requires_rollback')
            r = cli('.parameter set ?1 "O\'Brien; -- quoted"\n'
                    'UPDATE item SET name=?1 WHERE id=1;\n.mode json\nSELECT name, ?1 AS bound FROM item;\n')
            assert json.loads(r.stdout)[0] == dict(name="O'Brien; -- quoted", bound="O'Brien; -- quoted")
            record('typed_parameter_literal_escaping')
            r = cli('.parameter set ?1 1.0\nSELECT typeof(?1);\n')
            assert r.stdout.strip() == 'real', r
            record('real_parameter_type_preserved')
            r = cli('-- leading comment\n.mode list\nCREATE TABLE audit(id INTEGER);\n'
                    'CREATE TRIGGER log AFTER INSERT ON item BEGIN\n'
                    'INSERT INTO audit VALUES(new.id);\nEND;\n'
                    "INSERT INTO item VALUES(2,'Grace; Hopper',50); SELECT count(*) FROM audit;\n")
            assert r.stdout.strip() == '1', r
            record('multiline_trigger_and_semicolon_in_string')
            r = cli('.mode csv\n.headers on\nSELECT id,name FROM item WHERE id=2;\n')
            assert r.stdout == '"id","name"\n"2","Grace; Hopper"\n', r
            record('csv_headers_and_rows')
            r = cli('.mode json\nSELECT 9223372036854775807 AS big, NULL AS empty, X\'00FF\' AS blob;\n')
            try: typed = json.loads(r.stdout)
            except ValueError as exc: raise AssertionError(repr(r.stdout)) from exc
            assert typed == [dict(big=2**63-1, empty=None, blob=dict(base64='AP8='))], r
            record('json_int64_null_blob_types')
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            try:
                p = subprocess.run([str(binary), 'connect', str(config), '-c', 'SELECT 42;'],
                                   stdout=write_fd, stderr=subprocess.PIPE, timeout=30)
                assert p.returncode == 1 and b'query output' in p.stderr, p
            finally: os.close(write_fd)
            record('closed_output_pipe_nonzero_exit')
            script = root / 'script with spaces.sql'
            script.write_text('SELECT count(*) FROM item;\n')
            out = root / 'output.csv'
            r = cli(f'.once "{out}"\n.read "{script}"\nSELECT 42;\n')
            assert out.read_text().strip() == '2' and r.stdout.strip() == '42', r
            record('read_script_once_output')
            r = cli('SELECT absent FROM item;\nSELECT 42;\n', code=1, options=['--bail'])
            assert '42' not in r.stdout and 'Hint:' in r.stderr
            record('batch_bail_nonzero_exit')
            r = cli('.notacommand\n', code=1)
            assert '.help' in r.stderr and 'Hint:' in r.stderr
            record('unknown_dot_command_correction')
            r = cli('SELECT ' + 'a' * 5000 + '; SELECT 42;\n', code=1)
            assert not r.stdout
            record('oversized_input_tail_never_executed')
            lock_test(binary, config)
            record('exclusive_client_state_lock')
            editor_test(binary, config)
            record('interactive_edit_history_completion_cancel')
            conflict_test(binary, config, cluster)
            record('transaction_conflict_never_publishes')
            lost_reply_test(binary, cfg, config, root, cluster)
            record('lost_write_reply_cross_master_retry_once')
            record('replaced_certificate_cannot_replay_pending_identity')
            with cluster.connect() as db:
                assert db.query('SELECT count(*) FROM item').scalar() == 2
            for node in (1, 2, 3): cluster.stop(node)
            for node in (1, 2, 3): cluster.start(node)
            assert cli('SELECT count(*) FROM item;\n').stdout.strip() == '2'
            record('shell_writes_survive_all_voter_restart')
        finally:
            cluster.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(complete=True, checks=cases, count=len(cases),
        generated_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        server_sha256=hashlib.sha256(args.server.read_bytes()).hexdigest()), indent=2) + '\n')


def color_test(binary, root):
    for disabled in (False, True):
        master, slave = pty.openpty()
        env = dict(os.environ, TERM='xterm-256color')
        env.pop('NO_COLOR', None)
        if disabled: env['NO_COLOR'] = ''
        p = subprocess.Popen([str(binary), 'unknown'], stdout=subprocess.PIPE, stderr=slave, env=env, cwd=root)
        os.close(slave)
        output = b''
        while True:
            try:
                part = os.read(master, 4096)
                if not part: break
                output += part
            except OSError: break
        os.close(master)
        assert p.wait(timeout=5) == 2
        assert (b'\x1b[' in output) is not disabled, output
        assert b'Hint:' in output


def lock_test(binary, config):
    holder = subprocess.Popen([str(binary), 'connect', str(config)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.3)
        other = subprocess.run([str(binary), 'connect', str(config), '-c', '.status'], capture_output=True, timeout=10)
        assert other.returncode == 2 and b'locked' in other.stderr, other
    finally:
        holder.communicate(b'.quit\n', timeout=10)


def conflict_test(binary, config, cluster):
    p = subprocess.Popen([str(binary), 'connect', str(config)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        p.stdin.write('BEGIN;\nUPDATE item SET amount=77 WHERE id=1;\n.print ready\n'); p.stdin.flush()
        # os.File writes directly: .print is not libc buffered.
        assert p.stdout.readline().strip() == 'ready'
        with cluster.connect() as db: db.execute('UPDATE item SET amount=88 WHERE id=1')
        out, err = p.communicate('COMMIT;\n', timeout=30)
        assert p.returncode == 1 and 'CONFLICT' in err, (out, err)
        with cluster.connect() as db: assert db.query('SELECT amount FROM item WHERE id=1').scalar() == 88
    finally:
        if p.poll() is None: p.kill(); p.wait()


def exact(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count-len(data))
        if not part: raise EOFError
        data += part
    return data


def frame(sock):
    header = exact(sock, 4)
    return header + exact(sock, struct.unpack('<I', header)[0])


def lost_reply_test(binary, cfg, config, root, cluster):
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(30)
    remote = dict(cfg, address=f'127.0.0.1:{listener.getsockname()[1]}')
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(root / 'node1.pem', root / 'node1.key')
    server.load_verify_locations(root / 'ca.pem'); server.verify_mode = ssl.CERT_REQUIRED
    client = ssl.create_default_context(cafile=cfg['ca'])
    client.load_cert_chain(cfg['certificate'], cfg['key'])
    errors = []
    def proxy():
        try:
            while True:
                raw, _ = listener.accept()
                with server.wrap_socket(raw, server_side=True) as incoming:
                    message = frame(incoming)
                    req = json.loads(message[4:])
                    host, port = cfg['address'].rsplit(':', 1)
                    with client.wrap_socket(socket.create_connection((host, int(port))), server_hostname=cfg['identity']) as outgoing:
                        outgoing.sendall(message)
                        response = frame(outgoing)
                    if req['op'] == 'execute': return  # Commit acknowledged upstream, response lost downstream.
                    incoming.sendall(response)
        except BaseException as exc: errors.append(repr(exc))
    thread = threading.Thread(target=proxy, daemon=True); thread.start()
    config.write_text(json.dumps(remote))
    p = subprocess.run([str(binary), 'connect', str(config), '-c', 'UPDATE item SET amount=amount+1 WHERE id=1;'],
                       capture_output=True, text=True, timeout=90)
    thread.join(5); listener.close()
    assert not thread.is_alive() and not errors, errors
    assert p.returncode == 2 and 'outcome unknown' in p.stderr, p
    state = Path(str(config) + '.shell.db')
    with sqlite3.connect(state) as db:
        pending = json.loads(db.execute('SELECT body FROM state').fetchone()[0])['pending']
        assert pending['op'] == 'execute'
    config.write_text(json.dumps(cfg))
    old_cert, old_key = Path(cfg['certificate']).read_bytes(), Path(cfg['key']).read_bytes()
    try:
        Path(cfg['certificate']).write_bytes((root / 'node1.pem').read_bytes())
        Path(cfg['key']).write_bytes((root / 'node1.key').read_bytes())
        rejected = subprocess.run([str(binary), 'connect', str(config), '-c', '.retry'],
                                  capture_output=True, text=True, timeout=10)
        assert rejected.returncode == 2 and 'certificate' in rejected.stderr, rejected
        with sqlite3.connect(state) as db:
            assert json.loads(db.execute('SELECT body FROM state').fetchone()[0])['pending']['op'] == 'execute'
    finally:
        Path(cfg['certificate']).write_bytes(old_cert)
        Path(cfg['key']).write_bytes(old_key)
    config.write_text(json.dumps(dict(cfg, address=cluster.members[2]['address'],
                                     identity=cluster.members[2]['identity'])))
    p = subprocess.run([str(binary), 'connect', str(config), '-c', '.retry'], capture_output=True, text=True, timeout=90)
    assert p.returncode == 0, p
    with cluster.connect() as db: assert db.query('SELECT amount FROM item WHERE id=1').scalar() == 89
    with sqlite3.connect(state) as db:
        assert json.loads(db.execute('SELECT body FROM state').fetchone()[0])['pending']['op'] == ''
    assert state.stat().st_mode & 0o077 == 0


def editor_test(binary, config):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    process = subprocess.Popen([str(binary), 'connect', str(config)], stdin=slave,
                               stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    def expect(text):
        deadline = time.monotonic() + 15
        while text not in output:
            assert time.monotonic() < deadline, (text, bytes(output)[-1500:])
            if not select.select([master], [], [], 0.2)[0]: continue
            output.extend(os.read(master, 65536))
    try:
        expect(b'sqlodin>')
        os.write(master, b'.print editor-okX\x7f\r')
        expect(b'\r\neditor-ok\r\n')
        output.clear()
        os.write(master, b'\x1b[A\r')
        expect(b'\r\neditor-ok\r\n')
        output.clear()
        os.write(master, b'.heal\t\r')
        expect(b'quorum read passed')
        output.clear()
        os.write(master, b'.print cancelled-value\x03.quit\r')
        process.wait(timeout=10)
        while select.select([master], [], [], 0.1)[0]:
            try:
                part = os.read(master, 65536)
                if not part: break
                output.extend(part)
            except OSError: break
        assert b'\r\ncancelled-value\r\n' not in output
        assert process.returncode == 0
    finally:
        if process.poll() is None: process.kill(); process.wait()
        os.close(master)


if __name__ == '__main__': main()
