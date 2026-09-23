#!/usr/bin/env python3
"""Restricted, expiring SSH test supervisor; not a SQLodin network service."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import shlex
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import time

MAX_FRAME = 8 * 1024 * 1024


def read_frame(stream, deadline):
    def exact(count):
        parts = []
        while count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
                raise TimeoutError('Supervisor frame timeout')
            chunk = os.read(stream.fileno(), count)
            if not chunk:
                raise EOFError('Frame stream closed')
            parts.append(chunk)
            count -= len(chunk)
        return b''.join(parts)
    length, = struct.unpack('<I', exact(4))
    if not 0 < length <= MAX_FRAME:
        raise ValueError('Frame length outside budget')
    return exact(length)


def send_frame(stream, payload):
    if not 0 < len(payload) <= MAX_FRAME:
        raise ValueError('Frame length outside budget')
    stream.write(struct.pack('<I', len(payload)) + payload)
    stream.flush()


def usage(root, child=None):
    result = {'free_bytes': shutil.disk_usage(root).free,
              'data_bytes': sum(p.stat().st_size for p in root.glob('*/node.db*'))}
    if child is not None:
        fields = Path(f'/proc/{child.pid}/stat').read_text().rsplit(')', 1)[1].split()
        result.update(pid=child.pid, cpu_seconds=(int(fields[11]) + int(fields[12])) /
                      os.sysconf('SC_CLK_TCK'))
        for line in Path(f'/proc/{child.pid}/status').read_text().splitlines():
            if line.startswith(('VmRSS:', 'VmHWM:')):
                key, value, _ = line.split()
                result[key.rstrip(':')] = int(value) * 1024
    return result


def inspect(root):
    files = {}
    for name in ['/etc/os-release', '/etc/machine-id', '/proc/sys/kernel/random/boot_id',
                 '/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/cpu.max']:
        path = Path(name)
        files[name] = path.read_text().strip() if path.exists() else None
    return {'hostname': os.uname().nodename, 'kernel': os.uname().release, 'identity': files,
            'cpu_affinity': sorted(os.sched_getaffinity(0)), 'resources': usage(root),
            'binary_sha256': hashlib.sha256((root / 'worker').read_bytes()).hexdigest(),
            'filesystem': json.loads(subprocess.check_output(
                ['findmnt', '--json', '-T', str(root), '-o', 'TARGET,FSTYPE,SOURCE,OPTIONS'])),
            'virtualization': subprocess.run(['systemd-detect-virt'], capture_output=True,
                                             text=True).stdout.strip(),
            'clock_epoch': time.time()}


def audit(root, phase):
    """Offline read-only audit, streamed in key order; never repairs a database."""
    path = root / phase / 'node.db'
    connection = sqlite3.connect(f'{path.as_uri()}?mode=ro', uri=True)
    try:
        integrity = [r[0] for r in connection.execute('PRAGMA integrity_check')]
        hashes, counts = {}, {}
        queries = {'accounts': 'SELECT * FROM accounts ORDER BY id',
                   'transfers': 'SELECT * FROM transfers ORDER BY id',
                   'ledger': 'SELECT * FROM ledger ORDER BY tx,account',
                   'sessions': 'SELECT hex(session),seq,hex(hash),kind,code,changes,slot '
                               'FROM _sqlodin_sessions ORDER BY session',
                   'state': 'SELECT * FROM _sqlodin_state ORDER BY id'}
        for name, query in queries.items():
            digest, count = hashlib.sha256(), 0
            for row in connection.execute(query):
                digest.update(json.dumps(row, separators=(',', ':')).encode() + b'\n')
                count += 1
            hashes[name], counts[name] = digest.hexdigest(), count
        # Every generated transfer is uniquely prescribed by its sequential ID.
        balances, expected_id = [1000000] * 3, 1
        for identifier, source, target, amount, payload in connection.execute(
                'SELECT id,src,dst,amount,payload FROM transfers ORDER BY id'):
            if (identifier != expected_id or source != identifier % 3 + 1 or
                    target != source % 3 + 1 or amount != identifier % 17 + 1 or
                    payload != 'x' * 256):
                raise RuntimeError(f'Unexpected transfer {identifier}')
            balances[source - 1] -= amount
            balances[target - 1] += amount
            expected_id += 1
        actual = list(connection.execute('SELECT id,balance FROM accounts ORDER BY id'))
        if actual != list(enumerate(balances, 1)):
            raise RuntimeError('Final exact balances differ')
        invalid = connection.execute('SELECT count(*) FROM ledger l JOIN transfers t ON t.id=l.tx '
            'WHERE NOT ((l.account=t.src AND l.delta=-t.amount) '
            'OR (l.account=t.dst AND l.delta=t.amount))').fetchone()[0]
        bad_pairs = connection.execute('SELECT count(*) FROM (SELECT tx FROM ledger GROUP BY tx '
                                       'HAVING count(*)!=2 OR count(DISTINCT account)!=2)').fetchone()[0]
        foreign_keys = list(connection.execute('PRAGMA foreign_key_check'))
        if integrity != ['ok'] or foreign_keys or invalid or bad_pairs or counts['ledger'] != 2 * counts['transfers']:
            raise RuntimeError('Offline integrity/audit-pair check failed')
        return {'integrity': integrity, 'logical_sha256': hashes, 'counts': counts,
                'exact_transfers_and_balances': True, 'audit_pairs': True,
                'resources': usage(root), 'verification_sqlite': sqlite3.sqlite_version}
    finally:
        connection.close()


def child_limits():
    # A killed supervisor must not leave a writer running behind its SSH channel.
    parent = os.getppid()
    if ctypes.CDLL(None).prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
        os._exit(126)
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)
    resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))


def supervise(root, config, phase, mode):
    directory = root / phase
    if mode == 'create':
        directory.mkdir()  # Exclusive: never silently reuse a previous run.
    elif not (directory / 'node.db').is_file():
        raise RuntimeError('Refusing to replace a missing voter')
    with (directory / 'stderr.log').open('ab', buffering=0) as log:
        child = subprocess.Popen([str(root / 'worker'), str(directory), str(config['node']), mode],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                 preexec_fn=child_limits)
        (directory / 'worker.pid').write_text(str(child.pid) + '\n')
        try:
            while True:
                command = json.loads(read_frame(sys.stdin.buffer, time.monotonic() + 90))
                if command.pop('_supervisor', None) == 'kill':
                    child.kill()
                    child.wait(timeout=15)
                    send_frame(sys.stdout.buffer, json.dumps({'stopped': True, 'returncode': child.returncode}).encode())
                    return
                send_frame(child.stdin, json.dumps(command, separators=(',', ':')).encode())
                response = json.loads(read_frame(child.stdout, time.monotonic() + 300))
                response['_resources'] = usage(root, child)
                if response['_resources']['free_bytes'] < config['min_free_bytes']:
                    raise RuntimeError('Free-space safety floor reached')
                if response['_resources']['data_bytes'] > config['max_data_bytes']:
                    raise RuntimeError('Configured per-host data budget reached')
                if response['_resources'].get('VmRSS', 0) > config['max_rss_bytes']:
                    raise RuntimeError('Configured voter RSS budget reached')
                send_frame(sys.stdout.buffer, json.dumps(response, separators=(',', ':')).encode())
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=15)


def main():
    root = Path(sys.argv[1]).resolve()
    config = json.loads((root / 'host.json').read_text())
    remaining = int(config['expires_epoch'] - time.time())
    if remaining <= 0:
        raise SystemExit('This qualification supervisor has expired')
    def expired(signum, frame):
        raise TimeoutError('Qualification host deadline reached')
    signal.signal(signal.SIGALRM, expired)
    signal.signal(signal.SIGTERM, expired)
    signal.alarm(remaining)
    args = shlex.split(os.environ.get('SSH_ORIGINAL_COMMAND', '')) if len(sys.argv) == 2 else sys.argv[2:]
    if args == ['inspect']:
        print(json.dumps(inspect(root)))
    elif len(args) == 2 and args[0] == 'audit' and args[1] in ('smoke', 'pilot', 'soak'):
        print(json.dumps(audit(root, args[1])))
    elif len(args) == 3 and args[0] == 'start' and args[1] in ('smoke', 'pilot', 'soak') and args[2] in ('create', 'open'):
        supervise(root, config, args[1], args[2])
    else:
        raise SystemExit('Only inspect, audit PHASE, or start PHASE create|open is allowed')


if __name__ == '__main__':
    main()
