#!/usr/bin/env python3
"""Linux bounded saturation: slow readers, rejected SQL, writes and snapshots."""
import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

from check_network_service import Cluster, ROOT, sqlodin
from check_majority import ready
from sqlodin.transport import Transport


def summarize(report):
    """Describe this closed-loop resource campaign without claiming open-loop capacity."""
    elapsed = report['load_finished']-report['load_started']
    operations = [op for op in report['operations'] if op['kind'] != 'snapshot']
    kinds = {}
    for kind in sorted({op['kind'] for op in operations}):
        durations = sorted(op['end']-op['start'] for op in operations if op['kind'] == kind)
        kinds[kind] = dict(completed=len(durations),
                           p99_ms=1000*durations[math.ceil(.99*len(durations))-1])
    nodes = {}
    samples = report['samples']
    for node in (1, 2, 3):
        first, last = samples[0], samples[-1]
        quarters = [samples[len(samples)*i//4:len(samples)*(i+1)//4] for i in range(4)]
        nodes[node] = dict(
            average_cpu_cores=(last['nodes'][node]['cpu_seconds']-first['nodes'][node]['cpu_seconds']) /
                              (last['time']-first['time']),
            rss_quarter_peaks=[max(s['nodes'][node]['rss_bytes'] for s in part) for part in quarters],
            kernel_io_delta={key: last['nodes'][node]['io'][key]-first['nodes'][node]['io'][key]
                             for key in first['nodes'][node]['io']})
    return dict(scope='closed-loop admitted saturation; excess connections separately rejected',
                elapsed_seconds=elapsed, completed_per_second=len(operations)/elapsed,
                operations=kinds, nodes=nodes)


def sample(cluster):
    result = dict(time=time.monotonic(), nodes={})
    for node, process in cluster.processes.items():
        fields = Path(f'/proc/{process.pid}/stat').read_text().rsplit(')', 1)[1].split()
        io = dict(line.split(': ') for line in Path(f'/proc/{process.pid}/io').read_text().splitlines())
        result['nodes'][node] = dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                                    rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE'),
                                    io={key: int(value) for key, value in io.items()})
    return result


def frame(request):
    body = json.dumps(dict(cluster='network-qualification', protocol=1, **request)).encode()
    return struct.pack('<I', len(body))+body


def worker(db, node, identity, operations, request_snapshot):
    results = []
    for i in range(operations):
        before = time.monotonic()
        if request_snapshot and i == 1:
            target = db.request_snapshot()
            results.append(dict(kind='snapshot', target=target, start=before, end=time.monotonic()))
        if i % 4 == 0:
            db.execute('UPDATE resource_rows SET value=value+1 WHERE id=?', (identity,))
            kind = 'write'
        elif i % 4 == 3:
            try:
                db.query('SELECT count(*) FROM seed a,seed b,seed c,seed d')
            except sqlodin.QueryError as exc:
                assert 'Query_Limit' in str(exc), repr(exc)
            else:
                raise AssertionError('Expensive read did not hit its instruction budget')
            kind = 'limited_read'
        else:
            assert db.query('SELECT count(*) FROM resource_rows').scalar() == 60
            kind = 'read'
        results.append(dict(kind=kind, start=before, end=time.monotonic(), node=node, identity=identity))
    return results


def campaign(cluster, report, operations):
    clients, slow, stalled = [], [], []
    stop = threading.Event()
    sampler = None
    tls = sqlodin.TLS(cluster.root/'ca.pem', cluster.root/'client.pem', cluster.root/'client.key')
    try:
        for node in (1, 2, 3):
            cluster.start(node, create=True)
        for node in (1, 2, 3):
            ready(cluster, node)
        with cluster.connect() as db:
            db.execute('CREATE TABLE seed(id INTEGER PRIMARY KEY)')
            db.execute('INSERT INTO seed VALUES '+','.join(f'({i})' for i in range(1, 65)))
            db.execute('CREATE TABLE resource_rows(id INTEGER PRIMARY KEY,value INTEGER NOT NULL)')
            db.execute('INSERT INTO resource_rows SELECT id,0 FROM seed WHERE id<=60')
            db.execute('CREATE TABLE payload(id INTEGER PRIMARY KEY, value BLOB)')
            db.execute('INSERT INTO payload SELECT a.id*64+b.id,zeroblob(1024) FROM seed a,seed b')
            db.execute('CREATE TABLE work_result(value INTEGER)')
        report['idle_start'] = sample(cluster)
        time.sleep(1)
        report['idle_end'] = sample(cluster)
        for node in (1, 2, 3):
            endpoint = sqlodin.Endpoint(cluster.members[node-1]['address'], cluster.members[node-1]['identity'])
            for _ in range(4):
                transport = Transport(tls)
                response = transport.exchange(endpoint, dict(op='status', cluster='network-qualification', protocol=1),
                                              time.monotonic()+5)
                assert response['status'] == 'ok'
                response = transport.exchange(endpoint, dict(op='query', consistency='local',
                    sql='SELECT hex(zeroblob(60000))', timeout_ms=5000,
                    cluster='network-qualification', protocol=1), time.monotonic()+5)
                assert response['status'] == 'ok' and len(response['rows'][0][0]['text']) == 120000, response
                transport.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                slow.append(transport)
            for _ in range(20):
                db = cluster.connect((node,), timeout=20)
                assert db.status()['node'] == node
                clients.append((node, db))
            # Attempt further authenticated clients above capacity; each gets Busy.
            for _ in range(4):
                excess = Transport(tls)
                try:
                    response = excess.exchange(endpoint, dict(op='status', cluster='network-qualification', protocol=1),
                                               time.monotonic()+5)
                    assert response.get('error') == 'Busy', response
                finally:
                    excess.close()
        report['capacity'] = dict(active_clients=60, slow_readers=12, rejected_excess=12)
        report['samples'] = []

        def monitor():
            while not stop.is_set():
                try:
                    report['samples'].append(sample(cluster))
                except BaseException as exc:
                    report['monitor_error'] = repr(exc)
                    return
                stop.wait(.1)

        sampler = threading.Thread(target=monitor)
        sampler.start()
        # Pipeline bounded requests without consuming their responses. Native
        # output queues must backpressure/close these connections, not grow forever.
        large_read = frame(dict(op='query', consistency='local', timeout_ms=5000,
                                sql='SELECT hex(zeroblob(60000))'))
        for transport in slow:
            transport.socket.sendall(large_read*64)
        for member in cluster.members:
            address, port = member['address'].rsplit(':', 1)
            for _ in range(4):
                stalled.append(socket.create_connection((address, int(port)), timeout=2))
        report['load_started'] = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=60) as pool:
            jobs = [pool.submit(worker, db, node, identity, operations, identity == 1)
                    for identity, (node, db) in enumerate(clients, 1)]
            report['operations'] = []
            for job in concurrent.futures.as_completed(jobs):
                report['operations'].extend(job.result())
        report['load_finished'] = time.monotonic()
        for sock in stalled:
            sock.close()
        stalled.clear()
        for transport in slow:
            transport.close()
        slow.clear()
        # Permitted write performs substantial expression work, then the quorum
        # must continue serving and the durable result must agree everywhere.
        before = time.monotonic()
        clients[0][1].execute('INSERT INTO work_result SELECT count(*) FROM seed a,seed b,seed c')
        report['expensive_write_seconds'] = time.monotonic()-before
        expected = (operations+3)//4
        for node in (1, 2, 3):
            db = clients[(node-1)*20][1]
            assert db.query('SELECT count(*) FROM resource_rows WHERE value=?', (expected,)).scalar() == 60
            assert db.query('SELECT value FROM work_result').scalar() == 64**3
            report.setdefault('status_after', {})[node] = db.status()
        target = next(op['target'] for op in report['operations'] if op['kind'] == 'snapshot')
        deadline = time.monotonic()+60
        while time.monotonic() < deadline:
            states = [clients[i*20][1].status() for i in range(3)]
            assert all(not state['snapshot_error'] for state in states), states
            if all(state['generation_prefix'] >= target for state in states):
                break
            time.sleep(.1)
        assert all(state['generation_prefix'] >= target for state in states), states
        report['snapshot_states'] = states
        stop.set()
        sampler.join(timeout=5)
        assert not sampler.is_alive() and 'monitor_error' not in report
        report['rss_peak_bytes'] = {node: max(s['nodes'][node]['rss_bytes'] for s in report['samples'])
                                    for node in (1, 2, 3)}
        assert max(report['rss_peak_bytes'].values()) <= 512*1024*1024, report['rss_peak_bytes']
        report['summary'] = summarize(report)
        assert all(process.poll() is None for process in cluster.processes.values())
        print('PASS bounded saturation, slow readers, expensive SQL, snapshot and consistent writes', flush=True)
    finally:
        stop.set()
        if sampler is not None:
            sampler.join(timeout=5)
        for _, db in clients:
            db.close()
        for transport in slow:
            transport.close()
        for sock in stalled:
            sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--operations', type=int, default=12)
    parser.add_argument('--profile', action='store_true', help='Require qualification-only allocator counters')
    parser.add_argument('--io-profile-library', type=Path, help='Linux forwarding-only syscall interposer')
    args = parser.parse_args()
    if not Path('/proc/self/stat').exists() or args.output.exists() or not 4 <= args.operations <= 64:
        parser.error('Linux, a new output path, and 4..64 operations/client are required')
    report = dict(complete=False, operations_per_client=args.operations, instrumented=args.profile,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    root = ROOT/'build/resource-work'
    root.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=root) as work:
            report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            cluster = Cluster(Path(work), args.binary.resolve(), str(ROOT/'build/native/openssl'),
                              storage_format=5, maintenance='auto')
            if args.io_profile_library:
                library = args.io_profile_library.resolve()
                report['io_library_sha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
                report['io_source_sha256'] = hashlib.sha256((ROOT/'internal/io_profile/profile.c').read_bytes()).hexdigest()
                report['io_scope'] = 'whole-process sync/pwrite calls, including setup/maintenance/shutdown; forwarded unchanged'
                cluster.environment = {**os.environ, 'LD_PRELOAD': str(library)}
            try:
                campaign(cluster, report, args.operations)
                for process in cluster.processes.values():
                    process.terminate()
                for process in cluster.processes.values():
                    assert process.wait(timeout=10) == 0
                if args.profile:
                    report['allocation_profiles'] = {}
                    for node in (1, 2, 3):
                        lines = (cluster.root/f'node{node}.log').read_text().splitlines()
                        profiles = [json.loads(line.split(' ', 1)[1]) for line in lines
                                    if line.startswith('SQLODIN_RESOURCE_PROFILE ')]
                        assert len(profiles) == 1 and profiles[0]['heap_calls'] > 1000, profiles
                        assert profiles[0]['frame_copy_bytes'] > 0, profiles
                        report['allocation_profiles'][node] = profiles[0]
                if args.io_profile_library:
                    report['io_profiles'] = {}
                    for node in (1, 2, 3):
                        lines = (cluster.root/f'node{node}.log').read_text().splitlines()
                        profiles = [json.loads(line.split(' ', 1)[1]) for line in lines
                                    if line.startswith('SQLODIN_IO_PROFILE ')]
                        assert len(profiles) == 1 and profiles[0]['sync_calls'] > 0, profiles
                        assert profiles[0]['write_bytes'] > 0 and profiles[0]['errors'] == 0, profiles
                        report['io_profiles'][node] = profiles[0]
                report['complete'] = True
            finally:
                cluster.close()
                report['logs'] = {p.name: p.read_text()[-10000:] for p in cluster.root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for directory in ('src', 'service', 'transport')
                             for p in (ROOT/directory).rglob('*.odin')}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
