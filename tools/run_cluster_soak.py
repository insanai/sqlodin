#!/usr/bin/env python3
"""Bounded multi-host qualification fixture with authenticated SSH transport.

One fixed-membership durable Odin voter per host. This is not the production
service, dynamic membership, or evidence of independent physical failure domains.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import subprocess
import time
import traceback

from check_process_cluster import Cluster, Worker, exercise, transaction


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def atomic_json(path, value):
    temp = path.with_suffix('.tmp')
    with temp.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)


def command(config, node, *args):
    root = config['remote_root']
    if node == 0:
        return ['python3', root + '/qualification_worker.py', root, *args]
    return ['ssh', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
            '-o', 'UserKnownHostsFile=' + config['known_hosts'],
            '-i', config['ssh_key'], config['hosts'][node], *args]


class RemoteWorker(Worker):
    def __init__(self, config, node, phase, create):
        self.node = node
        self.log = (Path(config['local_results']) / f'{phase}-node-{node + 1}-transport.log').open('ab')
        self.process = subprocess.Popen(command(config, node, 'start', phase,
                                                'create' if create else 'open'),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        for stream in (self.process.stdin, self.process.stdout):
            os.set_blocking(stream.fileno(), False)

    def stop(self, kill=False):
        error = None
        if self.process.poll() is None:
            try:
                response = self.rpc({'_supervisor': 'kill'})
                if response != {'stopped': True, 'returncode': -9}:
                    raise RuntimeError(f'Unconfirmed remote SIGKILL: {response}')
            except Exception as exc:
                error = exc
            finally:
                self.process.stdin.close()
                try:
                    self.process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=10)
        self.process.stdout.close()
        self.log.close()
        if error:
            raise error


class RemoteCluster(Cluster):
    def __init__(self, config, phase):
        self.config, self.phase = config, phase
        self.remote_resources = [None] * 3
        self.actual_peak = [0] * 3
        super().__init__(None, Path(config['local_results']))

    def start(self, node, create=False):
        self.workers[node] = RemoteWorker(self.config, node, self.phase, create)
        self.pids.append(self.workers[node].process.pid)

    def sample_cpu(self, node):
        pass  # Never mislabel the local SSH client's CPU as remote voter CPU.

    def round(self, *args, **kwargs):
        results = super().round(*args, **kwargs)
        for node, response in results.items():
            resource = response['_resources']
            self.remote_resources[node] = resource
            self.cpu_by_pid[(node, resource['pid'])] = resource['cpu_seconds']
            self.actual_peak[node] = max(self.actual_peak[node], resource.get('VmHWM', 0))
        self.peak_rss = self.actual_peak[:]
        return results

    def close(self):
        errors = []
        for node, worker in enumerate(self.workers):
            if worker:
                try:
                    worker.stop(kill=True)
                except Exception as exc:
                    errors.append(str(exc))
                self.workers[node] = None
        self.pool.shutdown(wait=True)
        if errors:
            raise RuntimeError('Remote cleanup errors: ' + '; '.join(errors))

    def forget_completed(self):
        # Keep controller state bounded while sessions advance on the same database.
        for state in (self.completed, self.first_completion, self.completion_counts, self.awaited_counts):
            state.clear()
        self.read_latency_samples.clear()


SETUP = ('CREATE TABLE accounts(id INTEGER PRIMARY KEY,balance INTEGER CHECK(balance>=0));'
         'INSERT INTO accounts VALUES(1,1000000),(2,1000000),(3,1000000);'
         'CREATE TABLE transfers(id INTEGER PRIMARY KEY,src REFERENCES accounts(id),'
         'dst REFERENCES accounts(id),amount INTEGER CHECK(amount>0),payload TEXT);'
         'CREATE TABLE ledger(tx REFERENCES transfers(id),account REFERENCES accounts(id),delta INTEGER);'
         'CREATE INDEX ledger_tx ON ledger(tx);'
         'CREATE TRIGGER audit AFTER INSERT ON transfers BEGIN '
         'INSERT INTO ledger VALUES(new.id,new.src,-new.amount);'
         'INSERT INTO ledger VALUES(new.id,new.dst,new.amount); END;')


def require_applied(cluster, requests):
    for request in requests:
        key = request['client'], request['sequence']
        if cluster.completed.get(key, {}).get('kind') != 'Applied':
            raise RuntimeError(f'Request did not apply: {key}: {cluster.completed.get(key)}')


def verify_range(cluster, first, last, balances):
    """Indexed exact checks, bounded independently of total retained history."""
    cluster.settle()
    query = 'SELECT id FROM accounts WHERE ' + ' OR '.join(
        f'(id={i+1} AND balance={value})' for i, value in enumerate(balances))
    if cluster.fenced_reads({n: query for n in range(3)}) != {0: 3, 1: 3, 2: 3}:
        raise RuntimeError('Fenced account balances differ')
    for start in range(first, last + 1, 32):
        end = min(start + 31, last)
        query = (f'SELECT t.id FROM transfers t JOIN ledger l ON l.tx=t.id '
                 f'WHERE t.id BETWEEN {start} AND {end} AND l.tx BETWEEN {start} AND {end} '
                 'AND t.src=t.id%3+1 '
                 'AND t.dst=t.src%3+1 AND t.amount=t.id%17+1 '
                 f"AND t.payload='{'x'*256}' "
                 'AND ((l.account=t.src AND l.delta=-t.amount) '
                 'OR (l.account=t.dst AND l.delta=t.amount)) '
                 'GROUP BY t.id HAVING count(*)=2 AND count(DISTINCT l.account)=2')
        if any(r['rows'] != end - start + 1 for r in cluster.round(reads={n: query for n in range(3)}).values()):
            raise RuntimeError(f'Exact transfer/audit mismatch in {start}..{end}')


def percentiles(values):
    values = sorted(values)
    return {f'p{p}': values[min(len(values)-1, int(len(values)*p/100))]
            for p in (50, 95, 99)} if values else {}


def run_soak(cluster, seconds, seed, report, output):
    request = {'client': 1, 'sequence': 1, 'sql': SETUP}
    cluster.submit([request])
    cluster.settle([request])
    require_applied(cluster, [request])
    rng = random.Random(seed)
    sequences, balances = [0] * 12, [1000000] * 3
    writes, reads, checked, rounds, retries = 0, 0, 0, 0, 0
    latencies, read_latencies = [], []
    started = time.monotonic()
    deadline, next_status, next_fault = started + seconds, started + 60, started + 3600
    report.update(status='running', workload_started_utc=utc(), requested_workload_seconds=seconds,
                  planned_workload_end_utc=datetime.datetime.fromtimestamp(
                      time.time()+seconds, datetime.timezone.utc).isoformat())
    atomic_json(output, report)
    interval_operations, interval_started = 0, started
    last_requests = []
    with output.with_suffix('.jsonl').open('x', buffering=1) as events:
        def event(value):
            value['utc'] = utc()
            events.write(json.dumps(value, separators=(',', ':')) + '\n')
            events.flush()
            os.fsync(events.fileno())

        while time.monotonic() < deadline:
            cluster.forget_completed()
            requests, read_count = [], 0
            for _ in range(12):
                if rng.random() < .7:
                    read_count += 1
                else:
                    identifier = writes + len(requests) + 1
                    req, amount = transaction(identifier)
                    client = (identifier - 1) % 12
                    sequences[client] += 1
                    req.update(client=100 + client, sequence=sequences[client])
                    requests.append(req)
                    source = identifier % 3
                    balances[source] -= amount
                    balances[(source + 1) % 3] += amount
            before = time.monotonic()
            if requests:
                cluster.submit(requests, offset=rounds % 3)
                cluster.settle(requests)
                require_applied(cluster, requests)
                latencies.extend(1000 * (cluster.first_completion[(r['client'], r['sequence'])] - before)
                                 for r in requests)
                writes += len(requests)
                last_requests = requests
            for offset in range(0, read_count, 3):
                queries = {n: f'SELECT id FROM accounts WHERE id=1 AND balance={balances[0]}'
                           for n in range(min(3, read_count - offset))}
                if any(count != 1 for count in cluster.fenced_reads(queries).values()):
                    raise RuntimeError('Ordered read missed an acknowledged write')
            read_latencies.extend(cluster.read_latency_samples)
            reads += read_count
            interval_operations += 12
            rounds += 1
            if len(latencies) + len(read_latencies) > 100000:
                raise RuntimeError('Interval latency sample budget exceeded')
            if time.monotonic() >= next_status or time.monotonic() >= deadline:
                verify_range(cluster, checked + 1, writes, balances)
                checked = writes
                # Retry latest requests before their sessions advance again.
                if last_requests:
                    cluster.submit(last_requests, offset=(rounds + 1) % 3)
                    cluster.settle(last_requests)
                    require_applied(cluster, last_requests)
                    retries += len(last_requests)
                now = time.monotonic()
                sample = {'type': 'interval', 'elapsed_seconds': now-started,
                          'operations': reads+writes, 'reads': reads, 'writes': writes,
                          'verified_transfers': checked, 'acknowledged_retries': retries,
                          'interval_operations_per_second': interval_operations/(now-interval_started),
                          'write_latency_ms': percentiles(latencies),
                          'read_latency_ms': percentiles(read_latencies),
                          'voter_resources': [dict(r) for r in cluster.remote_resources],
                          'voter_cpu_seconds': sum(cluster.cpu_by_pid.values()),
                          'peak_rss_bytes_per_voter': cluster.peak_rss}
                event(sample)
                report['progress'] = sample
                atomic_json(output, report)
                print(json.dumps(sample), flush=True)
                latencies.clear()
                read_latencies.clear()
                interval_operations, interval_started, next_status = 0, now, now+60
            if time.monotonic() >= next_fault and time.monotonic() < deadline-120:
                node = (int((time.monotonic()-started)//3600)-1) % 3
                cluster.stop(node)
                cluster.start(node)
                # Fresh read on the recovered voter checks its recovered durable prefix.
                query = f'SELECT id FROM accounts WHERE id=1 AND balance={balances[0]}'
                if cluster.fenced_reads({node: query}) != {node: 1}:
                    raise RuntimeError('Restarted voter served stale state')
                event({'type': 'hourly_voter_sigkill_recovery', 'node': node+1, 'writes': writes})
                next_fault += 3600
        report['workload_seconds'] = time.monotonic()-started
        report['workload_finished_utc'] = utc()
        report['status'] = 'final_recovery'
        atomic_json(output, report)
        # Kill and reopen all three real remote voters, then check the recovered view.
        for node in range(3):
            cluster.stop(node)
        for node in range(3):
            cluster.start(node)
        for _ in range(12):
            cluster.round(tick=True)
        verify_range(cluster, checked+1, writes, balances)
        cluster.settle()
        applied = [r['applied'] for r in cluster.round().values()]
        if len(set(applied)) != 1:
            raise RuntimeError(f'Final applied prefixes differ: {applied}')
        event({'type': 'final_whole_cluster_sigkill_recovery', 'applied': applied, 'writes': writes})
        report.update(reads=reads, writes=writes, operations=reads+writes,
                      acknowledged_retries=retries, final_applied=applied,
                      session_count=13, expected_balances=balances)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--phase', choices=('smoke', 'pilot', 'soak'), required=True)
    parser.add_argument('--seconds', type=int, default=28800)
    parser.add_argument('--seed', type=int, default=20260923)
    args = parser.parse_args()
    if not 30 <= args.seconds <= 28800:
        parser.error('Workload duration must be 30 seconds through eight hours')
    config = json.loads(args.config.read_text())
    output = Path(config['local_results']) / f'{args.phase}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        parser.error('Report already exists; do not overwrite evidence')
    report = {'complete': False, 'status': 'preflight', 'started_utc': utc(), 'hosts': config['hosts'],
              'scope': 'three Linux instances, one fixed-membership durable voter each; '
                       'authenticated SSH framed-pipe transport through a coordinator; '
                       'not a native network service or proof of physical-host independence',
              'workload': '70/30 generated mixed point reads/transfers; ' +
                          ('distinct sessions for smoke fault cases' if args.phase == 'smoke' else
                           'twelve long-lived transfer sessions plus one schema session'),
              'limits': config['limits'], 'seed': args.seed, 'phase': args.phase,
              'manifest': json.loads((Path(config['remote_root']) / 'manifest.json').read_text())}
    atomic_json(output, report)
    cluster = None
    def timed_out(signum, frame):
        raise TimeoutError('Qualification run exceeded duration plus finalization budget')
    signal.signal(signal.SIGALRM, timed_out)
    signal.signal(signal.SIGTERM, timed_out)
    signal.alarm(args.seconds + 900)
    try:
        inspections = []
        for node in range(3):
            inspections.append(json.loads(subprocess.check_output(command(config, node, 'inspect'), timeout=30)))
        if len({i['binary_sha256'] for i in inspections}) != 1:
            raise RuntimeError('Voter binary fingerprints differ')
        if len({i['identity']['/etc/machine-id'] for i in inspections}) != 3:
            raise RuntimeError('Three distinct Linux instance identities required')
        if any(i['filesystem']['filesystems'][0]['fstype'] in ('tmpfs', 'ramfs') for i in inspections):
            raise RuntimeError('Persistent filesystems required')
        report['host_inspection'] = inspections
        cluster = RemoteCluster(config, args.phase)
        if args.phase == 'smoke':
            report['sample'] = exercise(cluster, 240, args.seed, 'fenced')
        else:
            run_soak(cluster, args.seconds, args.seed, report, output)
        cluster.close()
        cluster = None
        audits = [json.loads(subprocess.check_output(command(config, node, 'audit', args.phase), timeout=300))
                  for node in range(3)]
        if any(a['logical_sha256'] != audits[0]['logical_sha256'] for a in audits):
            raise RuntimeError('Offline logical state hashes differ across voters')
        expected_writes = report.get('writes', report.get('sample', {}).get('verified_transfers_including_fault_phases'))
        if any(a['counts']['transfers'] != expected_writes for a in audits):
            raise RuntimeError('Offline transfer count differs from acknowledged workload')
        report.update(complete=True, status='passed', offline_audits=audits)
    except BaseException as exc:
        report.update(status='failed', error=str(exc), traceback=traceback.format_exc())
        raise
    finally:
        if cluster:
            try:
                cluster.close()
            except Exception as exc:
                report['cleanup_error'] = str(exc)
        report['finished_utc'] = utc()
        atomic_json(output, report)
        signal.alarm(0)


if __name__ == '__main__':
    main()
