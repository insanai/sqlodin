#!/usr/bin/env python3
"""Bounded native mTLS checks across three explicit SSH-authorized Linux hosts.

The coordinator speaks SQL directly over TLS. SSH only provisions and supervises
processes; it does not relay consensus packets. Every server has a five-minute
watchdog. Test directories are unique; existing data is never reused implicitly.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time

from check_network_service import Cluster, checks, generate

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']


class RemoteCluster(Cluster):
    def __init__(self, root, binary, openssl, hosts, remote_root):
        self.root, self.binary = root, binary
        self.hosts, self.remote_root = hosts, remote_root
        self.processes, self.logs = {}, []
        generate(root, openssl)
        self.members = [dict(id=i + 1, address=host.split('@')[-1] + ':27601',
                             identity=f'node{i + 1}.sqlodin.test') for i, host in enumerate(hosts)]
        for m, host in zip(self.members, hosts):
            node = m['id']
            data = remote_root / 'data'
            cfg = dict(storage_format=5, maintenance='auto', cluster='network-qualification', node=node, listen=m['address'], data=str(data),
                       certificate=str(remote_root / f'node{node}.pem'), key=str(remote_root / f'node{node}.key'),
                       ca=str(remote_root / 'ca.pem'), members=self.members, clients=['node-2.test.sqlodin'])
            path = root / f'node{node}.json'
            path.write_text(json.dumps(cfg))
            subprocess.run([*SSH, host, 'mkdir -m 700 -p ' + shlex.quote(str(remote_root.parent)) +
                            ' && mkdir -m 700 ' + shlex.quote(str(remote_root)) +
                            ' && mkdir -m 700 ' + shlex.quote(str(data))], check=True, timeout=20)
            files = [binary, path, root / 'ca.pem', root / f'node{node}.pem', root / f'node{node}.key']
            subprocess.run(['rsync', '-az', *map(str, files), host + ':' + str(remote_root) + '/'],
                           check=True, timeout=30)

    def start(self, node, create=False):
        host = self.hosts[node - 1]
        argv = [str(self.remote_root / self.binary.name), 'serve', str(self.remote_root / f'node{node}.json')]
        if create:
            argv.append('--create')
        # The supervisor owns only this child, writes its PID, and always reaps it.
        script = ('import pathlib,subprocess\n'
                  f'p=subprocess.Popen({argv!r})\n'
                  f'pathlib.Path({str(self.remote_root / "server.pid")!r}).write_text(str(p.pid))\n'
                  'try:\n p.wait(timeout=300)\n'
                  'finally:\n'
                  ' if p.poll() is None: p.kill()\n'
                  ' p.wait()\n')
        log = open(self.root / f'node{node}.log', 'ab')
        self.logs.append(log)
        self.processes[node] = subprocess.Popen([*SSH, host, 'python3 -c ' + shlex.quote(script)],
                                               stdout=log, stderr=log)
        # SSH supervision starting does not mean storage recovery has opened the
        # listener. Wait for local readiness before timing quorum operations.
        deadline = time.monotonic()+60
        address, port = self.members[node-1]['address'].rsplit(':', 1)
        while time.monotonic() < deadline:
            assert self.processes[node].poll() is None, (self.root / f'node{node}.log').read_text()
            try:
                with socket.create_connection((address, int(port)), timeout=1):
                    return
            except OSError:
                time.sleep(.05)
        raise TimeoutError(f'Node {node} did not open its listener within 60 seconds')

    def stop(self, node):
        if self.processes[node].poll() is not None:
            return
        pidfile = str(self.remote_root / 'server.pid')
        executable = str(self.remote_root / self.binary.name)
        script = ('import pathlib,os,signal\n'
                  f'pid=int(pathlib.Path({pidfile!r}).read_text())\n'
                  'p=pathlib.Path(f"/proc/{pid}/cmdline")\n'
                  f'if p.exists() and p.read_bytes().split(b"\\x00")[0]=={executable.encode()!r}:\n'
                  ' os.kill(pid,signal.SIGKILL)\n')
        subprocess.run([*SSH, self.hosts[node - 1], 'python3 -c ' + shlex.quote(script)], check=True, timeout=15)
        self.processes[node].wait(timeout=15)



def majority_checks(c, record, report):
    """Every missing voter, both survivors, more than one window, then certified generation."""
    from check_majority import ready
    with c.connect() as db:
        db.execute('CREATE TABLE host_progress(id INTEGER PRIMARY KEY,value INTEGER)')
        db.execute('INSERT INTO host_progress VALUES(1,0)')
    writes = 0
    report['majority_cases'] = []
    for victim in (1, 2, 3):
        survivors = [node for node in (1, 2, 3) if node != victim]
        clients = [c.connect((node,), timeout=5) for node in survivors]
        case = dict(absent=victim, operations=0, samples=[])
        report['majority_cases'].append(case)
        try:
            for db in clients:
                db.session_epoch()
                db.query('SELECT 1')
            started = time.monotonic()
            c.stop(victim)
            for operation in range(90):
                db = clients[operation%2]
                op_started = time.monotonic()
                if operation == 0 or operation%3 == 0:
                    db.execute('UPDATE host_progress SET value=value+1 WHERE id=1')
                    writes += 1
                    if operation == 0:
                        case['first_write_seconds'] = time.monotonic()-started
                else:
                    assert db.query('SELECT value FROM host_progress WHERE id=1').scalar() == writes
                case['operations'] += 1
                case['samples'].append(dict(operation=operation, node=survivors[operation%2],
                                            seconds=time.monotonic()-op_started))
            case['recovery_goal_met'] = case['first_write_seconds'] <= 5
        except BaseException:
            # Preserve the first failure; diagnostics must not turn a timeout into a pass.
            case['failure_operation'] = case['operations']
            case['process_returncodes'] = {str(n): p.poll() for n, p in c.processes.items()}
            case['failure_states'] = []
            for node in survivors:
                try:
                    with c.connect((node,), timeout=2) as probe:
                        case['failure_states'].append(probe.status())
                except Exception as exc:
                    case['failure_states'].append(dict(node=node, error=repr(exc)))
            case['pending_requests'] = [repr(db.pending) for db in clients]
            raise
        finally:
            for db in clients:
                db.close()
        c.start(victim)
        ready(c, victim)
        with c.connect((victim,)) as db:
            assert db.query('SELECT value FROM host_progress WHERE id=1').scalar() == writes
        record(f'absent_{victim}_both_survivors_continue_and_rejoin')
    with c.connect() as db:
        target = db.request_snapshot()
    deadline = time.monotonic()+120
    while time.monotonic() < deadline:
        states = []
        for node in (1, 2, 3):
            with c.connect((node,)) as db:
                states.append(db.status())
        assert all(not state['snapshot_error'] for state in states), states
        if all(state['generation_prefix'] >= target for state in states):
            break
        time.sleep(.1)
    else:
        raise TimeoutError('Three-host snapshot publication timed out')
    record('three_host_certified_generation_published')
    for node in (1, 2, 3):
        c.stop(node)
    for node in (1, 2, 3):
        c.start(node)
    for node in (1, 2, 3):
        ready(c, node)
        with c.connect((node,)) as db:
            assert db.query('SELECT value FROM host_progress WHERE id=1').scalar() == writes
            assert db.status()['generation_prefix'] >= target
    record('three_host_generation_and_acknowledged_data_survive_restart')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hosts', nargs=3, required=True)
    parser.add_argument('--binary', type=Path, required=True, help='Local copy of the Linux binary')
    parser.add_argument('--openssl', default=str(Path(__file__).resolve().parents[1] / 'build/native/openssl'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--majority', action='store_true', help='Each absent voter, generation and restart')
    parser.add_argument('--orm', action='store_true', help='Also exercise ORM transactions and commit recovery')
    parser.add_argument('--python-features', action='store_true', help='Also exercise vector/FTS and SQLAlchemy')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Retain earlier evidence; choose a new output file')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    remote_root = Path('/home/insan/projects/sqlodin/network-service') / stamp
    report = dict(complete=False, passed=False, hosts=args.hosts, remote_root=str(remote_root),
                  scope='three Linux instances; direct native mTLS consensus and SQL; fixed membership',
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(), checks=[],
                  python_features=args.python_features, orm=args.orm, majority=args.majority,
                  source_sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [Path(__file__), Path(__file__).with_name('check_network_service.py'),
                                           Path(__file__).with_name('check_python_features.py'),
                                           Path(__file__).with_name('check_orm_transactions.py')]})
    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-native-hosts-') as work:
            c = RemoteCluster(Path(work), args.binary.resolve(), args.openssl, args.hosts, remote_root)
            try:
                checks(c, record)
                if args.python_features:
                    from check_python_features import features
                    features(c, record)
                if args.orm:
                    from check_orm_transactions import orm_checks
                    orm_checks(c, record)
                if args.majority:
                    majority_checks(c, record, report)
                report.update(complete=True, passed=True)
                report['filesystem'] = []
                for host in args.hosts:
                    result = subprocess.run([*SSH, host, 'findmnt -J -T ' + shlex.quote(str(remote_root))],
                                            check=True, capture_output=True, text=True, timeout=15)
                    fs = json.loads(result.stdout)
                    assert fs['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
                    report['filesystem'].append(fs)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-6000:] for p in c.root.glob('*.log')}
    except BaseException as exc:
        report.update(error=repr(exc), complete=False, passed=False)
        raise
    finally:
        report['ended_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
