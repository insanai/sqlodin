#!/usr/bin/env python3
"""Three independent durable voters; bounded same-machine framed-pipe fault/workload test.

Controller scheduling and JSON/base64 transport are part of the measurement.
Fresh ordered read barriers are the default; local snapshots are an explicit option.
This is a contract/workload check, not production network service capacity.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import select
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MAX_FRAME = 8 * 1024 * 1024


class Worker:
    def __init__(self, binary, directory, node, create):
        directory.mkdir(parents=True, exist_ok=True)
        self.log = (directory / 'stderr.log').open('ab')
        self.process = subprocess.Popen([str(binary), str(directory), str(node + 1),
                                         'create' if create else 'open'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.node = node
        for stream in (self.process.stdin, self.process.stdout):
            os.set_blocking(stream.fileno(), False)

    def rpc(self, command):
        payload = json.dumps(command, separators=(',', ':')).encode()
        if len(payload) > MAX_FRAME:
            raise RuntimeError('Controller frame exceeds its budget')
        deadline = time.monotonic() + 45
        data = struct.pack('<I', len(payload)) + payload
        fd = self.process.stdin.fileno()
        while data:
            ready = select.select([], [fd], [], max(0, deadline - time.monotonic()))[1]
            if not ready:
                raise TimeoutError(f'Worker {self.node} write timeout')
            data = data[os.write(fd, data):]
        header = self.read_exact(4, deadline)
        length, = struct.unpack('<I', header)
        if not 0 < length <= MAX_FRAME:
            raise RuntimeError('Invalid worker frame length')
        return json.loads(self.read_exact(length, deadline))

    def read_exact(self, count, deadline):
        chunks = []
        while count:
            fd = self.process.stdout.fileno()
            ready = select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]
            if not ready:
                raise TimeoutError(f'Worker {self.node} response timeout')
            chunk = os.read(fd, count)
            if not chunk:
                raise RuntimeError(f'Worker {self.node} exited; see its stderr.log')
            chunks.append(chunk)
            count -= len(chunk)
        return b''.join(chunks)

    def stop(self, kill=False):
        if self.process.poll() is None:
            if kill:
                self.process.kill()
            else:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()
        if not kill and self.process.returncode != 0:
            raise RuntimeError(f'Worker {self.node} did not close cleanly')


class Cluster:
    def __init__(self, binary, directory):
        self.binary, self.directory = binary, directory
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.workers = [None] * 3
        self.queues = [[], [], []]
        self.partition = set()
        self.completed = {}
        self.first_completion = {}
        self.completion_counts = {}
        self.awaited_counts = {}
        self.peak_rss = [None, None, None]
        self.pids = []
        self.cpu_by_pid = {}
        self.read_latency_samples = []
        try:
            for node in range(3):
                self.start(node, True)
        except BaseException:
            self.close()
            raise

    def start(self, node, create=False):
        self.workers[node] = Worker(self.binary, self.directory / f'node-{node + 1}', node, create)
        self.pids.append(self.workers[node].process.pid)

    def stop(self, node):
        self.workers[node].stop(kill=True)
        self.workers[node] = None
        self.queues[node].clear()

    def close(self):
        for worker in self.workers:
            if worker:
                worker.stop(kill=True)
        self.pool.shutdown(wait=True)

    def sample_cpu(self, node):
        pid = self.workers[node].process.pid
        stat = Path(f'/proc/{pid}/stat')
        if stat.exists():
            fields = stat.read_text().rsplit(')', 1)[1].split()
            self.cpu_by_pid[pid] = (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')

    def round(self, writes=None, tick=False, reads=None, controls=None):
        writes, reads = writes or {}, reads or {}
        jobs = {}
        for node, worker in enumerate(self.workers):
            if worker is None:
                self.queues[node].clear()
                continue
            incoming, self.queues[node] = self.queues[node][:128], self.queues[node][128:]
            command = {'action': 'read' if node in reads else ('tick' if tick else 'drive'),
                       'packets': incoming, 'writes': writes.get(node, []), 'sql': reads.get(node, '')}
            command.update((controls or {}).get(node, {}))
            jobs[node] = self.pool.submit(worker.rpc, command)
        results = {}
        for node, job in jobs.items():
            response = job.result()
            if response.get('sql_error', 'None') != 'None':
                raise RuntimeError(f'Worker {node} read failed: {response["sql_error"]}; '
                                   f'query={reads.get(node, "")!r}')
            results[node] = response
            for packet in response['packets'] or []:
                source, target = packet['from'] - 1, packet['to'] - 1
                if (source, target) not in self.partition and self.workers[target]:
                    if len(self.queues[target]) >= 4096:
                        raise RuntimeError('Controller peer queue exceeded its budget')
                    self.queues[target].append(packet)
            for completion in response['completed'] or []:
                key = (completion['client'], completion['sequence'])
                previous = self.completed.get(key)
                if previous and previous != completion:
                    raise RuntimeError(f'Unstable retry outcome: {previous} / {completion}')
                self.completed[key] = completion
                self.completion_counts[key] = self.completion_counts.get(key, 0) + 1
                self.first_completion.setdefault(key, time.monotonic())
            self.sample_cpu(node)
            status = Path(f'/proc/{self.workers[node].process.pid}/status')
            if status.exists():
                for line in status.read_text().splitlines():
                    if line.startswith('VmHWM:'):
                        self.peak_rss[node] = max(self.peak_rss[node] or 0, int(line.split()[1]) * 1024)
        return results

    def settle(self, requests=(), rounds=300):
        keys = {(r['client'], r['sequence']) for r in requests}
        for attempt in range(rounds):
            if all(self.completion_counts.get(k, 0) >= self.awaited_counts.get(k, 1) for k in keys) and not any(self.queues):
                return
            self.round(tick=attempt % 8 == 7)
        raise RuntimeError(f'Cluster did not settle; missing {keys - self.completed.keys()}')

    def submit(self, requests, offset=0, alive=(0, 1, 2)):
        groups = {}
        for r in requests:
            key = (r["client"], r["sequence"])
            self.awaited_counts[key] = self.completion_counts.get(key, 0) + 1
        for index, request in enumerate(requests):
            node = alive[(index + offset) % len(alive)]
            groups.setdefault(node, []).append(request)
        result = self.round(writes=groups)
        for node, group in groups.items():
            if result[node]['accepted'] != len(group) or result[node]['backpressure']:
                raise RuntimeError('Unexpected bounded-workload backpressure')

    def fenced_reads(self, queries):
        started = time.monotonic()
        replies = self.round(controls={n: {'action': 'begin_read'} for n in queries})
        tickets = {n: replies[n]['ticket'] for n in queries}
        results = {}
        for attempt in range(300):
            if attempt % 4 == 3:
                self.round(tick=True)
            replies = self.round(controls={
                n: {'action': 'poll_read', 'ticket': ticket, 'sql': queries[n]}
                for n, ticket in tickets.items()})
            for n in list(tickets):
                read = replies[n]['read_result']
                if read['status'] == 'Ready':
                    if read['sql_error'] != 'None':
                        raise RuntimeError(f'Fenced read failed: {read}')
                    results[n] = read['rows']
                    self.read_latency_samples.append(1000 * (time.monotonic() - started))
                    del tickets[n]
                elif read['status'] == 'Displaced':
                    restart = self.round(controls={n: {'action': 'begin_read'}})
                    tickets[n] = restart[n]['ticket']
            if not tickets:
                return results
        raise RuntimeError('Read barrier did not complete')

    def verify(self, transfers):
        count, amount = len(transfers), sum(transfers.values())
        query = ("SELECT 1 WHERE (SELECT count(*) FROM transfers)=" + str(count) +
                 " AND (SELECT coalesce(sum(amount),0) FROM transfers)=" + str(amount) +
                 " AND (SELECT count(*) FROM ledger)=" + str(count * 2) +
                 " AND (SELECT coalesce(sum(delta),0) FROM ledger)=0" +
                 " AND (SELECT sum(balance) FROM accounts)=3000000" +
                 " AND NOT EXISTS(SELECT 1 FROM accounts WHERE balance<0)" +
                 " AND NOT EXISTS(SELECT tx FROM ledger GROUP BY tx HAVING count(*)!=2)")
        self.settle()
        result = self.round(reads={node: query for node in range(3) if self.workers[node]})
        for node, response in result.items():
            if response['rows'] != 1:
                raise RuntimeError(f'Account/transfer/ledger invariant failed on node {node}')
        balances = [1000000] * 3
        for identifier, value in transfers.items():
            source = identifier % 3
            balances[source] -= value
            balances[(source + 1) % 3] += value
        query = 'SELECT id FROM accounts WHERE ' + ' OR '.join(
            f'(id={i + 1} AND balance={balance})' for i, balance in enumerate(balances))
        for response in self.round(reads={n: query for n in result}).values():
            if response['rows'] != 3:
                raise RuntimeError('Exact per-account balance mismatch')
        # Bound each verification query. A correlated subquery over all transfers
        # can exceed the reader's VM budget; preserve that budget as histories grow.
        # Check exact acknowledged IDs, amounts, endpoints, payloads and audit pairs.
        for start in range(0, count, 32):
            ids = list(transfers)[start:start + 32]
            values = ','.join(f'({i},{i % 3 + 1},{(i % 3 + 1) % 3 + 1},{transfers[i]})'
                              for i in ids)
            query = ('WITH expected(id,src,dst,amount) AS (VALUES ' + values + ') '
                     'SELECT t.id FROM expected e JOIN transfers t ON t.id=e.id '
                     'JOIN ledger l ON l.tx=e.id '
                     'WHERE t.src=e.src AND t.dst=e.dst AND t.amount=e.amount '
                     f"AND t.payload='{'x' * 256}' "
                     'AND ((l.account=e.src AND l.delta=-e.amount) '
                     'OR (l.account=e.dst AND l.delta=e.amount)) '
                     'GROUP BY t.id HAVING count(*)=2 AND count(DISTINCT l.account)=2')
            for response in self.round(reads={n: query for n in result}).values():
                if response['rows'] != len(ids):
                    raise RuntimeError('Exact transfer or audit-pair verification failed')


def transaction(identifier):
    source = identifier % 3 + 1
    target = source % 3 + 1
    amount = identifier % 17 + 1
    text = (f"INSERT INTO transfers VALUES({identifier},{source},{target},{amount},'{'x' * 256}');"
            f'UPDATE accounts SET balance=balance-{amount} WHERE id={source};'
            f'UPDATE accounts SET balance=balance+{amount} WHERE id={target};')
    return {'client': identifier + 100, 'sequence': 1, 'sql': text}, amount


def exercise(cluster, operations, seed, read_mode):
    setup = {'client': 1, 'sequence': 1, 'sql':
             'CREATE TABLE accounts(id INTEGER PRIMARY KEY,balance INTEGER CHECK(balance>=0));'
             'INSERT INTO accounts VALUES(1,1000000),(2,1000000),(3,1000000);'
             'CREATE TABLE transfers(id INTEGER PRIMARY KEY,src REFERENCES accounts(id),'
             'dst REFERENCES accounts(id),amount INTEGER CHECK(amount>0),payload TEXT);'
             'CREATE TABLE ledger(tx REFERENCES transfers(id),account REFERENCES accounts(id),delta INTEGER);'
             'CREATE INDEX ledger_tx ON ledger(tx);'
             'CREATE TRIGGER audit AFTER INSERT ON transfers BEGIN '
             'INSERT INTO ledger VALUES(new.id,new.src,-new.amount);'
             'INSERT INTO ledger VALUES(new.id,new.dst,new.amount); END;'}
    cluster.submit([setup])
    cluster.settle([setup])
    expected = {}
    all_requests = []
    latencies = []
    rng = random.Random(seed)
    reads, writes = 0, 0
    cpu_before = sum(cluster.cpu_by_pid.values())
    read_sample_start = len(cluster.read_latency_samples)
    started = time.monotonic()
    for start in range(0, operations, 12):
        requests = []
        read_count = 0
        for _ in range(min(12, operations - start)):
            if rng.random() < .7:
                read_count += 1
                continue
            identifier = len(expected) + 1
            request, amount = transaction(identifier)
            requests.append(request)
            expected[identifier] = amount
        before = time.monotonic()
        if requests:
            cluster.submit(requests)
            cluster.settle(requests)
            for r in requests:
                latencies.append(1000 * (cluster.first_completion[(r['client'], 1)] - before))
                if cluster.completed[(r['client'], 1)]['kind'] != 'Applied':
                    raise RuntimeError(f'Healthy transaction rejected: {cluster.completed[(r["client"], 1)]}')
        for offset in range(0, read_count, 3):
            balance = 1000000 + sum(value * (1 if (key % 3 + 1) % 3 == 0 else -1)
                                    for key, value in expected.items() if key % 3 in (0, 2))
            queries = {n: f'SELECT balance FROM accounts WHERE id=1 AND balance={balance}'
                       for n in range(min(3, read_count - offset))}
            if read_mode == 'fenced':
                if any(rows != 1 for rows in cluster.fenced_reads(queries).values()):
                    raise RuntimeError('Fenced read returned an unexpected account set')
            else:
                cluster.round(reads=queries)
        reads += read_count
        writes += len(requests)
        all_requests.extend(requests)
    seconds = time.monotonic() - started
    cpu_seconds = sum(cluster.cpu_by_pid.values()) - cpu_before
    read_latencies = sorted(cluster.read_latency_samples[read_sample_start:])
    cluster.verify(expected)
    cases = ['mixed_transactions_indexes_triggers_foreign_keys_all_voters']
    assert cluster.fenced_reads({n: 'SELECT id FROM accounts' for n in range(3)}) == {0: 3, 1: 3, 2: 3}
    cases.append('fresh_ordered_read_barrier_on_every_voter')
    # Kill every voter after submission but before delivering its emitted packets.
    uncertain = []
    for _ in range(9):
        identifier = len(expected) + 1
        request, amount = transaction(identifier)
        expected[identifier] = amount
        uncertain.append(request)
    cluster.submit(uncertain)
    for node in range(3):
        cluster.stop(node)
    for node in range(3):
        cluster.start(node)
    cluster.queues = [[], [], []]
    cluster.submit(uncertain, offset=1)
    cluster.settle(uncertain)
    cluster.verify(expected)
    cases.append('all_processes_sigkill_uncertain_retry_other_master')
    # Retried acknowledgements must produce original outcomes, without extra effects.
    retries = all_requests[:6]
    cluster.submit(retries, offset=2)
    cluster.settle(retries)
    cluster.verify(expected)
    cases.append('acknowledged_retry_other_master_after_restart')
    # A minority may accept ingress but must not acknowledge a write by itself.
    identifier = len(expected) + 1
    minority, amount = transaction(identifier)
    cluster.partition = {(0, 1), (0, 2), (1, 0), (2, 0)}
    barrier = cluster.round(controls={0: {'action': 'begin_read'}})[0]['ticket']
    cluster.submit([minority], alive=(0,))
    for _ in range(16):
        cluster.round(tick=True)
    if (minority['client'], 1) in cluster.completed:
        raise RuntimeError('Minority acknowledged a write')
    result = cluster.round(controls={0: {'action': 'poll_read', 'ticket': barrier,
                                        'sql': 'SELECT id FROM accounts'}})
    if result[0]['read_result']['status'] != 'Pending':
        raise RuntimeError('Minority completed a fenced read without quorum')
    cases.append('minority_cannot_complete_fenced_read')
    cluster.partition.clear()
    # Repropose the same identity: the original slot may have been displaced by a skip.
    cluster.submit([minority], alive=(1,))
    cluster.settle([minority])
    expected[identifier] = amount
    cluster.verify(expected)
    for attempt in range(300):
        if attempt % 4 == 3:
            cluster.round(tick=True)
        response = cluster.round(controls={0: {
            'action': 'poll_read', 'ticket': barrier, 'sql': 'SELECT id FROM accounts'}})
        if response[0]['read_result']['status'] != 'Pending':
            break
    else:
        raise RuntimeError(f'Old read barrier did not resolve after partition healing: {barrier}, {response[0]}')
    assert cluster.fenced_reads({0: 'SELECT id FROM accounts'}) == {0: 3}
    cases.append('minority_no_ack_heal_retry')
    # One stopped voter does not prevent the remaining quorum from writing.
    cluster.stop(0)
    more = []
    for _ in range(12):
        identifier = len(expected) + 1
        request, amount = transaction(identifier)
        expected[identifier] = amount
        more.append(request)
    cluster.submit(more, alive=(1, 2))
    cluster.settle(more)
    cluster.start(0)
    # Invoke immediately on the stale restarted replica, before explicit catch-up.
    query = f'SELECT 1 WHERE (SELECT count(*) FROM transfers)={len(expected)}'
    if cluster.fenced_reads({0: query}) != {0: 1}:
        raise RuntimeError('Restarted replica served a stale fenced read')
    cases.append('restarted_stale_voter_fenced_read_observes_acknowledged_writes')
    for _ in range(40):
        cluster.round(tick=True)
    cluster.settle()
    cluster.verify(expected)
    cases.append('surviving_quorum_writes_offline_voter_catchup')
    for node in range(3):
        cluster.stop(node)
    for node in range(3):
        cluster.start(node)
    for _ in range(12):
        cluster.round(tick=True)
    cluster.verify(expected)
    cases.append('all_acknowledged_transactions_survive_final_sigkill')
    latencies.sort()
    return {'operations': operations, 'reads': reads, 'writes': writes, 'seconds': seconds,
            'operations_per_second': operations / seconds,
            'voter_cpu_seconds_timed': cpu_seconds if cluster.cpu_by_pid else None,
            'controller_boundary': 'closed-loop waves, at most 12 writes or 3 fenced reads outstanding',
            'read_latency_ms': {f'p{p}': read_latencies[min(len(read_latencies) - 1, int(len(read_latencies) * p / 100))]
                                for p in (50, 95, 99)} if read_latencies else {},
            'write_latency_ms': {f'p{p}': latencies[min(len(latencies) - 1, int(len(latencies) * p / 100))]
                                 for p in (50, 95, 99)} if latencies else {},
            'verified_transfers_including_fault_phases': len(expected),
            'peak_rss_bytes_per_voter': cluster.peak_rss, 'checks': cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--operations', type=int, default=240)
    parser.add_argument('--seed', type=int, default=20260922)
    parser.add_argument('--read-mode', choices=('fenced', 'local'), default='fenced')
    parser.add_argument('--individual-journal', action='store_true',
                        help='reference build: commit each incoming transition separately')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path)
    args = parser.parse_args()
    if not 12 <= args.operations <= 10000:
        parser.error('operations must be between 12 and 10000')
    if args.output.exists():
        parser.error('output exists; retain previous evidence and use a new path')
    if args.work_dir and args.work_dir.exists():
        parser.error('work directory exists; use a new isolated test directory')
    scratch = tempfile.TemporaryDirectory(prefix='sqlodin-process-build-')
    binary = Path(scratch.name) / 'worker'
    group_flag = f'-define:SQLODIN_JOURNAL_GROUP_COMMIT={str(not args.individual_journal).lower()}'
    subprocess.run([os.environ.get('ODIN', 'odin'), 'build', str(ROOT / 'internal/process_probe'),
                    '-o:speed' if sys.platform == 'linux' else '-debug', '-vet', '-strict-style',
                    group_flag, f'-out:{binary}'], check=True, cwd=ROOT)
    data_root = ROOT / 'build/process-checks'
    data_root.mkdir(parents=True, exist_ok=True)
    if args.work_dir:
        work = args.work_dir
        work.mkdir(parents=True)
    else:
        work = Path(tempfile.mkdtemp(prefix='run-', dir=data_root))
    filesystem = None
    if sys.platform == 'linux':
        filesystem = json.loads(subprocess.check_output(
            ['findmnt', '--json', '-T', str(work), '-o', 'TARGET,FSTYPE,SOURCE,OPTIONS'], text=True))
        if filesystem['filesystems'][0]['fstype'] in ('tmpfs', 'ramfs'):
            raise RuntimeError('Durable disk workload refuses tmpfs/ramfs; select persistent --work-dir')
    cluster = Cluster(binary, work)
    try:
        sample = exercise(cluster, args.operations, args.seed, args.read_mode)
        sources = [*ROOT.glob('src/**/*.odin'), *ROOT.glob('internal/process_probe/*.odin'), Path(__file__)]
        report = {'complete': True, 'run_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'scope': 'one machine, three separate voter processes/directories; FULL durability; '
                           'framed JSON/base64 pipe transport via parallel controller; '
                           'bounded workload/fault test, not service capacity or power-loss qualification',
                  'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in sorted(sources)},
                  'read_mode': args.read_mode, 'seed': args.seed, 'sample': sample, 'worker_pids': cluster.pids,
                  'journal_group_commit': not args.individual_journal,
                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'filesystem': filesystem, 'run_directory': str(work),
                  'native_dependencies': json.loads((ROOT / 'build/native/build.json').read_text())
                      if sys.platform == 'linux' else {'sqlite': 'macOS platform library'}}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(sample, indent=2), flush=True)
    finally:
        cluster.close()
        scratch.cleanup()


if __name__ == '__main__':
    main()
