#!/usr/bin/env python3
"""Linux-only, disk-backed workload measurements with explicit product boundaries."""
import argparse
import dataclasses
import datetime
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import statistics
import socket
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'benchmarks/vendor/zaxonlite'
sys.path.insert(0, str(VENDOR))
import realworld_workload as workload
import driver
spec = importlib.util.spec_from_file_location('reference', VENDOR / 'compare-rqlite-realworld-3node.py')
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


def command(*args):
    return subprocess.check_output([str(a) for a in args], text=True, timeout=180)


_used_ports = set()


def unused_base_port():
    # Stay below Linux's ephemeral range so outgoing connections cannot steal listeners.
    for base in range(12000, 30000, 200):
        if base in _used_ports:
            continue
        sockets = []
        try:
            for port in [base, base+1, base+2, base+100, base+101, base+102]:
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(('127.0.0.1', port))
            _used_ports.add(base)
            return base
        except OSError:
            pass
        finally:
            for sock in sockets:
                sock.close()
    raise RuntimeError('No free benchmark port block')


def disk_usage(path):
    roots = [p for p in path.iterdir() if p.is_dir() and
             (p.name.startswith(('zaxon-', 'rqlite-', 'data-')))]
    files = [p for root in roots for p in root.rglob('*') if p.is_file()]
    files += [p for p in path.glob('node-*.db*') if p.is_file()]
    return {'logical_bytes': sum(p.stat().st_size for p in files),
            'allocated_bytes': sum(p.stat().st_blocks * 512 for p in files),
            'scope': 'persistent node databases, logs, snapshots and metadata after shutdown'}


class Monitor:
    """Sample only database child PIDs, retaining counters across their restarts."""
    def __init__(self, processes):
        self.processes = processes
        self.cpu = {}
        self.peak = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def __enter__(self):
        self.started = time.monotonic()
        self.thread.start()
        return self

    def sample(self):
        ticks = os.sysconf('SC_CLK_TCK')
        pages = os.sysconf('SC_PAGE_SIZE')
        while not self.stop.is_set():
            rss = 0
            for process in list(self.processes()):
                if process is None:
                    continue
                try:
                    fields = Path(f'/proc/{process.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    self.cpu[process.pid] = (int(fields[11]) + int(fields[12])) / ticks
                    rss += int(fields[21]) * pages
                except (FileNotFoundError, ProcessLookupError):
                    pass
            self.peak = max(self.peak, rss)
            self.stop.wait(.01)

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()
        elapsed = time.monotonic() - self.started
        self.result = {'sampled_database_cpu_seconds': sum(self.cpu.values()),
                       'sampled_peak_aggregate_rss_bytes': self.peak,
                       'whole_lifecycle_seconds': elapsed, 'interval_ms': 10,
                       'scope': 'database children; setup, verification and recovery included; client excluded'}


def sqlodin_seed_data():
    """Same reference seed rows, loaded outside timing without recursive SQL."""
    customers = [f"({i},'customer-{i:04d}@example.test','{('apac', 'amer', 'emea', 'latam')[i % 4]}',"
                 f"{1 + i % 3},{1700000000 + i})" for i in range(1, workload.CUSTOMERS + 1)]
    products = [f"({i},'SKU-{i:05d}','Catalog product {i:05d}',{500 + i * 17},{workload.INITIAL_STOCK})"
                for i in range(1, workload.PRODUCTS + 1)]
    result = []
    for table, rows in [('customers', customers), ('products', products)]:
        for start in range(0, len(rows), 32):
            result.append(f'INSERT OR IGNORE INTO {table} VALUES ' + ','.join(rows[start:start + 32]))
    return result


def sqlodin_manifest(path, operations, warmup, seed):
    expected = workload.ExpectedState()
    warm, next_id = workload.generate_operations(warmup, seed, 1, expected)
    ops, _ = workload.generate_operations(operations, seed + 1, next_id, expected)
    setup = [' '.join(s.split()) for s in workload.SCHEMA] + sqlodin_seed_data()
    assert max(map(len, setup)) <= 4096
    path.write_text(json.dumps({'setup': setup,
                               'warmup': [dataclasses.asdict(o) for o in warm],
                               'operations': [dataclasses.asdict(o) for o in ops],
                               'invariant_sql': workload.INVARIANT_SQL,
                               'expected': list(expected.as_dict().values())}))
    return expected.as_dict()


def sqlodin_run(folder, binary, args, seed, kv=False):
    folder.mkdir()
    manifest = folder / 'workload.json'
    if not kv:
        expected = sqlodin_manifest(manifest, args.operations, args.warmup, seed)
    else:
        payload = 'x' * 256
        ops = [{'kind': 'write', 'sql': f"INSERT INTO bench VALUES({i + 1},'{payload}')"}
               for i in range(args.operations + args.warmup)]
        expected = {'rows': args.operations + args.warmup}
        manifest.write_text(json.dumps({'setup': ['CREATE TABLE bench(id INTEGER PRIMARY KEY,v TEXT)'],
                                       'warmup': ops[:args.warmup], 'operations': ops[args.warmup:],
                                       'invariant_sql': f"SELECT count(*) FROM bench WHERE v='{payload}'",
                                       'expected': list(expected.values())}))
    with (folder / 'result.json').open('w') as output, (folder / 'stderr.log').open('w') as errors:
        process = subprocess.Popen([str(binary), str(manifest), str(folder)], stdout=output, stderr=errors)
        with Monitor(lambda: [process]) as monitor:
            if process.wait(timeout=180):
                raise RuntimeError((folder / 'stderr.log').read_text())
    monitor.result['scope'] = 'one embedded process including all three database hosts and workload driver; entire lifecycle'
    result = json.loads((folder / 'result.json').read_text())
    values = sorted(result.pop('latencies_ms'))
    result['latency_ms'] = {'p50': statistics.median(values),
                            'p95': driver.percentile(values, .95), 'p99': driver.percentile(values, .99)}
    result.update(system='sqlodin', nodes=3, resources=monitor.result, disk=disk_usage(folder),
                  expected=expected, client_concurrency=1,
                  storage='on-disk SQLite application and Paxos journal; WAL synchronous=FULL',
                  boundary='embedded host, three disk databases, in-process transport, local snapshot reads')
    return result


def network_run(system, folder, args, seed, port, kv=False):
    folder.mkdir()
    if system == 'zaxonlite':
        cluster = reference.ZaxonCluster(folder, args.zaxon_bin, port)
    else:
        cluster = reference.RqliteCluster(folder, args.rqlited_bin, args.rqlite_cli, port)
    if system == 'zaxonlite':
        spawn = cluster.children.spawn
        def spawn_durable(index, argv):
            return spawn(index, [*argv, '--sync', 'full'])
        cluster.children.spawn = spawn_durable
    with Monitor(lambda: cluster.children.processes) as monitor:
        if not kv:
            result = reference.run_system(cluster, args.operations, args.warmup, args.concurrency, seed)
        else:
            try:
                cluster.start_initial()
                if system == 'zaxonlite':
                    addresses = ','.join(f'{h}:{p}' for h, p in cluster.endpoints)
                    tls = SimpleNamespace(tls_cert=str(cluster.client_cert), tls_key=str(cluster.client_key),
                                          tls_ca=str(cluster.ca_path))
                    result = driver.benchmark_zaxon(addresses, args.operations, args.warmup, 256, tls)
                else:
                    h, p = cluster.endpoints[cluster.wait_leader()]
                    result = driver.benchmark_rqlite(f'{h}:{p}', args.operations, args.warmup, 256, None)
            finally:
                cluster.children.crash_all()
    result.update(resources=monitor.result, disk=disk_usage(folder),
                  storage=('on-disk SQLite WAL NORMAL with separate full-sync Paxos log' if system == 'zaxonlite'
                           else 'on-disk SQLite materialization with persistent Raft log and snapshots'))
    return result


def cowsql_request(connection, method, key, value=None):
    # The stock cowsql demo uses HTTP 200 even for SQL errors and appends one newline.
    connection.request(method, '/' + key, body=value)
    response = connection.getresponse()
    body = response.read()
    if response.status != 200 or (method == 'PUT' and body != b'done\n'):
        raise RuntimeError(f'cowsql {method} failed: {response.status} {body!r}')
    return body


def cowsql_workload(port, args):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    value = b'x' * 256
    try:
        for index in range(args.warmup):
            cowsql_request(connection, 'PUT', f'warmup-{index}', value)
        latencies = []
        started = time.perf_counter()
        for index in range(args.operations):
            before = time.perf_counter()
            cowsql_request(connection, 'PUT', f'measured-{index}', value)
            latencies.append(time.perf_counter() - before)
        elapsed = time.perf_counter() - started
        for index in range(args.operations):
            if cowsql_request(connection, 'GET', f'measured-{index}') != value + b'\n':
                raise RuntimeError(f'cowsql payload mismatch at measured-{index}')
        return driver.summary('cowsql', latencies, elapsed, args.operations, 256)
    finally:
        connection.close()


def cowsql_run(folder, args, port):
    folder.mkdir()
    processes = reference.ProcessSet(folder, 'cowsql')
    binary = ROOT / 'build/comparison-tools/cowsql-demo'
    commands = []
    with Monitor(lambda: processes.processes) as monitor:
        try:
            for i in range(3):
                cmd = [str(binary), '--api', f'127.0.0.1:{port+i}', '--db', f'127.0.0.1:{port+100+i}',
                       '--dir', str(folder / f'data-{i}')]
                if i:
                    cmd += ['--join', f'127.0.0.1:{port+100}']
                commands.append(cmd)
                processes.spawn(i, cmd)
                reference.wait_port(('127.0.0.1', port+i))
            # Membership assignment is asynchronous in the stock demo. Persisted cluster
            # files below must show three voters before timing. The stock role adjustment
            # interval is 30 seconds; allow multiple refreshes without changing its settings.
            deadline = time.monotonic() + 95
            while time.monotonic() < deadline:
                stores = list(folder.glob('data-*/**/cluster.yaml'))
                if len(stores) == 3 and all(p.read_text().count('Role: 0') == 3 for p in stores):
                    break
                time.sleep(.1)
            else:
                raise RuntimeError('Stock cowsql did not expose three persisted voter assignments')
            result = cowsql_workload(port, args)
            membership = {str(p.relative_to(folder)): p.read_text() for p in stores}
            result.update(system='cowsql', restart_verified=False, verified_before_restart=True, membership=membership,
                          storage='in-memory SQLite materialization; durable Raft logs and snapshots',
                          boundary='stock go-cowsql demo PUT/GET; no arbitrary SQL workload')
            (folder / 'timed-result.json').write_text(json.dumps(result, indent=2) + '\n')
            try:
                processes.crash_all()
                for i, cmd in enumerate(commands):
                    processes.spawn(i, cmd)
                for i in range(3):
                    reference.wait_port(('127.0.0.1', port+i))
                for i in range(3):
                    connection = http.client.HTTPConnection('127.0.0.1', port+i, timeout=30)
                    try:
                        for key in range(args.operations):
                            if cowsql_request(connection, 'GET', f'measured-{key}') != b'x' * 256 + b'\n':
                                raise RuntimeError('Restarted cowsql payload mismatch')
                    finally:
                        connection.close()
                result['restart_verified'] = True
            except (TimeoutError, OSError, RuntimeError, http.client.HTTPException) as error:
                # The stock demo is not a production recovery controller. Preserve a failed
                # optional restart check explicitly; never label it verified or patch cowsql.
                result['restart_error'] = str(error)
                result['restart_logs'] = {p.name: p.read_text()[-3000:] for p in folder.glob('*-g2.log')}
        finally:
            processes.crash_all()
    result.update(resources=monitor.result, disk=disk_usage(folder))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reuse-sql-results', type=Path,
                        help='Reuse a complete SQL-system run, verifying its source and workload; measure only cowsql')
    parser.add_argument('--operations', type=int, default=1200)
    parser.add_argument('--warmup', type=int, default=240)
    parser.add_argument('--concurrency', type=int, default=4)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--zaxon-bin', default=str(ROOT / 'build/comparison-tools/zaxon-release/zaxon'))
    base = ROOT / 'build/comparison-tools/rqlite-v10.2.7-linux-amd64'
    parser.add_argument('--rqlited-bin', default=str(base / 'rqlited'))
    parser.add_argument('--rqlite-cli', default=str(base / 'rqlite'))
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmarks/results/linux-realworld-current.json')
    parser.add_argument('--durability-report', type=Path,
                        default=ROOT / 'benchmarks/results/linux-candidate-v3-durability.json')
    args = parser.parse_args()
    if platform.system() != 'Linux':
        raise SystemExit('Linux required')
    if min(args.operations, args.repeats, args.concurrency) < 1 or args.warmup < 0:
        raise SystemExit('Invalid counts')
    if args.output.exists():
        raise SystemExit(f'Refusing to overwrite recorded evidence: {args.output}; use a new --output path')
    durability = json.loads(args.durability_report.read_text())
    if not durability['checks'] or not all(c['passed'] for c in durability['checks']):
        raise SystemExit('Durability checks did not all pass')
    for source in ROOT.glob('src/**/*.odin'):
        key = str(source.relative_to(ROOT))
        if durability['source_sha256'].get(key) != hashlib.sha256(source.read_bytes()).hexdigest():
            raise SystemExit(f'Durability evidence differs from current source: {key}; rerun checks')
    report = {'schema_version': 1, 'complete': False, 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'host': platform.platform(), 'cpu': command('lscpu'), 'odin': command('odin', 'version').strip(),
              'paxos_pin': command('git', '-C', ROOT / 'deps/paxos-odin', 'rev-parse', 'HEAD').strip(),
              'rqlite_version': reference.command_version([args.rqlited_bin, '-version']),
              'workload': {'operations': args.operations, 'warmup': args.warmup, 'repeats': args.repeats,
                           'network_concurrency': args.concurrency, 'embedded_concurrency': 1},
              'comparability': 'No aggregate ranking: embedded and network/read consistency boundaries differ.',
              'native_dependencies': json.loads((ROOT / 'build/native/build.json').read_text()),
              'comparison_dependencies': json.loads((ROOT / 'build/comparison-tools/build.json').read_text()),
              'durability': durability,
              'zaxon_release': json.loads((ROOT / 'build/comparison-tools/zaxon-release/release.json').read_text()),
              'realworld': [], 'sequential_writes': []}
    work = ROOT / 'build/comparison-runs' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    work.mkdir(parents=True)
    report['run_directory'] = str(work)
    source_files = [*ROOT.glob('src/**/*.odin'), *ROOT.glob('bench/realworld/*.odin'),
                    ROOT / 'tools/compare_realworld.py', *VENDOR.glob('*.py')]
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sorted(source_files)}
    report['filesystem'] = command('findmnt', '-T', work, '-o', 'SOURCE,FSTYPE,OPTIONS')
    reused = None
    binary = work / 'sqlodin-realworld'
    if args.reuse_sql_results:
        reused = json.loads(args.reuse_sql_results.read_text())
        if not reused.get('complete') or reused['workload'] != report['workload']:
            raise RuntimeError('Only a complete run with identical workload settings can be reused')
        for path, digest in report['source_sha256'].items():
            if path != 'tools/compare_realworld.py' and reused['source_sha256'].get(path) != digest:
                raise RuntimeError(f'Reused measurement source differs: {path}')
        if reused['paxos_pin'] != report['paxos_pin']:
            raise RuntimeError('Reused Paxos pin differs')
        binary = Path(reused['run_directory']) / 'sqlodin-realworld'
        report['reused_sql_run'] = {key: reused[key] for key in
            ('started_utc', 'finished_utc', 'run_directory', 'source_sha256', 'binaries_sha256',
             'native_dependencies', 'comparison_dependencies', 'zaxon_release')}
        report['reused_sql_run']['source_report_sha256'] = hashlib.sha256(args.reuse_sql_results.read_bytes()).hexdigest()
        for group in ('realworld', 'sequential_writes'):
            report[group] = [{**row, 'sample_run_directory': reused['run_directory']} for row in reused[group]
                             if row['system'] in ('sqlodin', 'zaxonlite', 'rqlite')]
            if len(report[group]) != 3 * args.repeats:
                raise RuntimeError('Reused run has incomplete SQL samples')
    else:
        command('odin', 'build', ROOT / 'bench/realworld', '-o:speed', '-vet', '-strict-style', f'-out:{binary}')
    report['binaries_sha256'] = {name: hashlib.sha256(Path(path).read_bytes()).hexdigest() for name, path in
                                 [('sqlodin', binary), ('zaxonlite', args.zaxon_bin),
                                  ('rqlite', args.rqlited_bin),
                                  ('cowsql', ROOT / 'build/comparison-tools/cowsql-demo')]}
    if reused:
        for system in ('sqlodin', 'zaxonlite', 'rqlite'):
            if report['binaries_sha256'][system] != reused['binaries_sha256'][system]:
                raise RuntimeError(f'Reused binary differs: {system}')
    for repeat in range(args.repeats):
        systems = [] if reused else ['sqlodin', 'zaxonlite', 'rqlite']
        random.Random(20260922 + repeat).shuffle(systems)
        for system in systems:
            print(f'realworld repeat={repeat+1} system={system}', file=sys.stderr, flush=True)
            folder = work / f'realworld-{repeat}-{system}'
            seed = 20260922 + repeat * 100
            result = (sqlodin_run(folder, binary, args, seed) if system == 'sqlodin' else
                      network_run(system, folder, args, seed, unused_base_port()))
            report['realworld'].append({'repeat': repeat + 1, **result})
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
        systems.append('cowsql')
        random.Random(20260923 + repeat).shuffle(systems)
        for system in systems:
            print(f'sequential repeat={repeat+1} system={system}', file=sys.stderr, flush=True)
            folder = work / f'sequential-{repeat}-{system}'
            if system == 'sqlodin':
                result = sqlodin_run(folder, binary, args, seed, kv=True)
            elif system == 'cowsql':
                result = cowsql_run(folder, args, unused_base_port())
            else:
                result = network_run(system, folder, args, seed, unused_base_port(), kv=True)
            report['sequential_writes'].append({'repeat': repeat + 1, **result})
            args.output.write_text(json.dumps(report, indent=2) + '\n')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    report['complete'] = True
    report['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['run_directory'] = str(work)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()
