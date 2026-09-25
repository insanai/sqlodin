#!/usr/bin/env python3
"""Bounded R6 calibration: native quorum SQL versus the exact pinned SQLite archive."""
import argparse
import concurrent.futures
import ctypes as C
import hashlib
import json
import math
import os
import random
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from check_network_service import Cluster, ROOT
from check_majority import ready
from check_resource_load import sample
from sqlite_group_reference import GroupReference, GroupConnection


class SQLite:
    def __init__(self, library, path):
        self.lib = library
        self.db = C.c_void_p()
        assert library.sqlite3_open(str(path).encode(), C.byref(self.db)) == 0
        assert library.sqlite3_busy_timeout(self.db, 30000) == 0
        self.run('PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON')

    def run(self, text, write=False):
        if write:
            self.run('BEGIN IMMEDIATE')
        try:
            rc = self.lib.sqlite3_exec(self.db, text.encode(), None, None, None)
            if rc:
                raise RuntimeError(f'SQLite {rc}: {self.lib.sqlite3_errmsg(self.db).decode()}')
            if write:
                self.run('COMMIT')
        except BaseException:
            if write:
                self.run('ROLLBACK')
            raise

    def scalar(self, text):
        stmt = C.c_void_p()
        assert self.lib.sqlite3_prepare_v2(self.db, text.encode(), -1, C.byref(stmt), None) == 0
        try:
            assert self.lib.sqlite3_step(stmt) == 100
            return self.lib.sqlite3_column_int64(stmt, 0)
        finally:
            self.lib.sqlite3_finalize(stmt)

    def close(self):
        assert self.lib.sqlite3_close(self.db) == 0


def library(path):
    lib = C.CDLL(str(path))
    signatures = {
        'sqlite3_open': ([C.c_char_p, C.POINTER(C.c_void_p)], C.c_int),
        'sqlite3_close': ([C.c_void_p], C.c_int),
        'sqlite3_busy_timeout': ([C.c_void_p, C.c_int], C.c_int),
        'sqlite3_exec': ([C.c_void_p, C.c_char_p, C.c_void_p, C.c_void_p, C.c_void_p], C.c_int),
        'sqlite3_errmsg': ([C.c_void_p], C.c_char_p),
        'sqlite3_prepare_v2': ([C.c_void_p, C.c_char_p, C.c_int, C.POINTER(C.c_void_p), C.c_void_p], C.c_int),
        'sqlite3_step': ([C.c_void_p], C.c_int),
        'sqlite3_column_int64': ([C.c_void_p, C.c_int], C.c_int64),
        'sqlite3_finalize': ([C.c_void_p], C.c_int),
        'sqlite3_sourceid': ([], C.c_char_p),
    }
    for name, (args, result) in signatures.items():
        getattr(lib, name).argtypes, getattr(lib, name).restype = args, result
    return lib


def workload(seed, count, reads, payload, statements=1, rows=1, skew=False):
    rng = random.Random(seed)
    result = []
    for _ in range(count):
        key = rng.randrange(32 if skew and rng.random() < .9 else 1024)
        key -= key % rows
        write = rng.randrange(100) >= reads
        text = (f'UPDATE account SET balance=balance+1,payload=zeroblob({payload}) '
                f'WHERE id>={key} AND id<{key+rows}' if write
                else f'SELECT id,balance,length(payload) FROM account WHERE id={key}')
        if write:
            pieces = []
            for statement in range(statements):
                first = key+statement*rows//statements
                last = key+(statement+1)*rows//statements
                if first == last:
                    last = first+1
                pieces.append(f'UPDATE account SET balance=balance+1,payload=zeroblob({payload}) '
                              f'WHERE id>={first} AND id<{last}')
            text = ';'.join(pieces)
        result.append((write, text))
    return result


def measure(factory, case, count):
    epoch = [0.0]
    barrier = threading.Barrier(case['clients'], action=lambda: epoch.__setitem__(0, time.monotonic()+.02))
    raw = []
    lock = threading.Lock()
    def worker(index):
        db = factory(index)
        ops = workload(case['seed']+index, count, case['read_percent'], case['payload'],
                       case['statements'], case['rows'], case['skew'])
        try:
            # Connect and discover epochs before timing steady-state work.
            if not isinstance(db, (SQLite, GroupConnection)):
                db.session_epoch()
                db.query('SELECT 1')
            barrier.wait(timeout=60)
            for number, (write, text) in enumerate(ops):
                due = epoch[0]+(number*case['clients']+index)/case['rate'] if case['rate'] else None
                if due is not None:
                    time.sleep(max(0, due-time.monotonic()))
                started = time.monotonic()
                result = dict(start=started, due=due if due is not None else started, write=write,
                              client=index, operation=number, status='ok')
                try:
                    if isinstance(db, (SQLite, GroupConnection)):
                        db.run(text, write)
                    elif write:
                        reply = db.execute(text)
                        result.update(applied=reply.applied, node=reply.node)
                    else:
                        reply = db.query(text)
                        assert len(reply) == 1
                        result.update(applied=reply.applied, node=reply.node)
                except BaseException as exc:
                    result.update(status='error', error=repr(exc))
                    if not isinstance(db, (SQLite, GroupConnection)) and db.pending is not None:
                        result['pending'] = db.pending.to_json()
                        try:
                            db.resolve_pending()
                            result['status'] = 'resolved_unknown'
                        except BaseException as resolution:
                            result['resolution_error'] = repr(resolution)
                result['end'] = time.monotonic()
                with lock:
                    raw.append(result)
                if result['status'] == 'error':
                    return  # Preserve this failure and never abandon an unresolved request identity.
        finally:
            db.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=case['clients']) as pool:
        futures = [pool.submit(worker, i) for i in range(case['clients'])]
        for future in concurrent.futures.as_completed(futures):
            future.result()
    assert raw, 'No workload operations recorded'
    elapsed = max(x['end'] for x in raw)-min(x['start'] for x in raw)
    latency = {}
    for write in (False, True):
        values = sorted(1000*(x['end']-x['due']) for x in raw if x['write'] == write)
        if values:
            latency['write' if write else 'read'] = dict(count=len(values),
                p50=values[math.ceil(.5*len(values))-1], p99=values[math.ceil(.99*len(values))-1])
    return dict(elapsed=elapsed, scheduled_rate=case['rate'] or None,
                latency_basis='scheduled arrival' if case['rate'] else 'closed-loop invocation',
                offered=count*case['clients'], invoked=len(raw),
                completed=sum(x['status'] != 'error' for x in raw),
                errors=sum(x['status'] == 'error' for x in raw),
                resolved_unknown=sum(x['status'] == 'resolved_unknown' for x in raw),
                per_second=sum(x['status'] != 'error' for x in raw)/elapsed, latency_ms=latency, raw=raw)




def reference_measure(shared, folder, setup, case, args):
    job = dict(library=str(shared.resolve()), database=str((folder/'reference.db').resolve()),
               setup=setup, case=case, count=args.operations, group=args.sqlite_group,
               output=str((folder/'reference-result.json').resolve()))
    job_path = folder/'reference-job.json'
    job_path.write_text(json.dumps(job))
    environment = os.environ.copy()
    if args.io_profile_library:
        environment['LD_PRELOAD'] = str(args.io_profile_library.resolve())
    child = subprocess.run([sys.executable, str(ROOT/'tools/sqlite_reference_worker.py'), str(job_path)],
                           capture_output=True, text=True, env=environment, timeout=300)
    if Path(job['output']).exists():
        result = json.loads(Path(job['output']).read_text())
        case['sqlite'] = result.get('measurement', {})
        case['sqlite_groups'] = result.get('groups', [])
        case['sqlite_resources'] = {key:result.get(key) for key in ('before','after')}
        case['sqlite_verified'] = result.get('complete', False)
    case['sqlite_group_limit'] = args.sqlite_group
    case['sqlite_worker_exit'] = child.returncode
    case['sqlite_worker_stderr'] = child.stderr
    assert child.returncode == 0 and case.get('sqlite_verified'), child.stderr
    if args.io_profile_library:
        profiles = [json.loads(line.split(' ',1)[1]) for line in child.stderr.splitlines()
                    if line.startswith('SQLODIN_IO_PROFILE ')]
        assert len(profiles) == 1 and profiles[0]['errors'] == 0, profiles
        case['sqlite_io_profile'] = profiles[0]


def observe(cluster):
    observation = dict(resources=sample(cluster), nodes={})
    for node in (1, 2, 3):
        with cluster.connect((node,), timeout=30) as db:
            observation['nodes'][node] = db.status()
        observation['nodes'][node]['history_bytes'] = sum(
            p.stat().st_size for p in (cluster.root/f'data{node}').rglob('consensus.db*') if p.is_file())
    frontiers = [s['applied'] for s in observation['nodes'].values()]
    observation['observed_prefix_spread'] = max(frontiers)-min(frontiers)
    return observation


def native_measure(cluster, case, count):
    stop = threading.Event()
    case['samples'] = []
    def watch():
        while not stop.wait(.25):
            try:
                case['samples'].append(sample(cluster))
            except BaseException as exc:
                case['monitor_error'] = repr(exc)
                return
    monitor = threading.Thread(target=watch)
    monitor.start()
    try:
        return measure(lambda i: cluster.connect((i%3+1,), timeout=30), case, count)
    finally:
        stop.set()
        monitor.join(timeout=5)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--operations', type=int, default=40, help='per client per case')
    p.add_argument('--clients', type=int, nargs='+', default=[1, 8, 32, 64])
    p.add_argument('--reads', type=int, nargs='+', default=[70, 0])
    p.add_argument('--payload', type=int, choices=(256, 4096), default=256)
    p.add_argument('--statements', type=int, choices=range(1, 9), default=1)
    p.add_argument('--rows', type=int, choices=range(1, 5), default=1)
    p.add_argument('--skew', action='store_true')
    p.add_argument('--seed', type=int, default=20260925)
    p.add_argument('--sqlite-group', type=int, choices=(0, 16), default=0)
    p.add_argument('--rate', type=int, default=0, help='Scheduled aggregate arrivals/sec; 0 is closed-loop')
    p.add_argument('--io-profile-library', type=Path)
    args = p.parse_args()
    assert not args.output.exists() and 10 <= args.operations <= 1000 and 0 <= args.rate <= 10000
    assert all(1 <= n <= 64 for n in args.clients) and all(0 <= n <= 100 for n in args.reads)
    root = ROOT/'build/mixed-calibration'
    root.mkdir(parents=True, exist_ok=True)
    shared = root/'pinned-sqlite.so'
    archive = ROOT/'build/native/libsqlite3.a'
    subprocess.run(['cc', '-shared', '-o', str(shared), '-Wl,--whole-archive', str(archive),
                    '-Wl,--no-whole-archive', '-lm', '-lpthread', '-ldl'], check=True)
    lib = library(shared)
    report = dict(complete=False, scope='selected bounded transaction shape; scheduled-arrival latency when rate is nonzero',
        sqlite_sourceid=lib.sqlite3_sourceid().decode(), sqlite_archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        group_reference_sha256=hashlib.sha256((ROOT/'tools/sqlite_group_reference.py').read_bytes()).hexdigest(), cases=[])
    if args.io_profile_library:
        report['io_library_sha256'] = hashlib.sha256(args.io_profile_library.read_bytes()).hexdigest()
    report['reference_worker_sha256'] = hashlib.sha256((ROOT/'tools/sqlite_reference_worker.py').read_bytes()).hexdigest()
    try:
        for clients in args.clients:
            for reads in args.reads:
                case = dict(clients=clients, read_percent=reads, payload=args.payload,
                            statements=args.statements, rows=args.rows, skew=args.skew, seed=args.seed, rate=args.rate)
                report['cases'].append(case)
                with tempfile.TemporaryDirectory(dir=root) as work:
                    folder = Path(work)
                    case['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
                    assert case['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
                    setup = ['CREATE TABLE seed(id INTEGER PRIMARY KEY)',
                        'INSERT INTO seed VALUES '+','.join(f'({i})' for i in range(32)),
                        'CREATE TABLE account(id INTEGER PRIMARY KEY,balance INTEGER,payload BLOB)',
                        f'INSERT INTO account SELECT a.id*32+b.id,0,zeroblob({args.payload}) FROM seed a,seed b']
                    reference_measure(shared, folder, setup, case, args)
                    cluster_dir = folder/'cluster'
                    cluster_dir.mkdir()
                    cluster = Cluster(cluster_dir, args.binary.resolve(), str(ROOT/'build/native/openssl'),
                                      storage_format=5, maintenance='auto')
                    if args.io_profile_library:
                        cluster.environment = {**os.environ, 'LD_PRELOAD': str(args.io_profile_library.resolve())}
                        case['io_scope'] = 'whole native process including setup, validation and shutdown'
                    try:
                        for node in (1, 2, 3):
                            cluster.start(node, create=True)
                        for node in (1, 2, 3):
                            ready(cluster, node)
                        with cluster.connect() as db:
                            for text in setup:
                                db.execute(text)
                        case['frontiers_before'] = observe(cluster)
                        case['before'] = sample(cluster)
                        case['sqlodin'] = native_measure(cluster, case, args.operations)
                        case['after'] = sample(cluster)
                        case['frontiers_after'] = observe(cluster)
                        assert case['sqlodin']['completed'] == args.operations*clients and not case['sqlodin']['errors']
                        for node in (1, 2, 3):
                            with cluster.connect((node,)) as db:
                                assert db.query('SELECT sum(balance) FROM account').scalar() == max(args.rows,args.statements)*sum(x['write'] for x in case['sqlodin']['raw'])
                        case['verified'] = True
                        print(clients, reads, case['sqlite']['per_second'], case['sqlodin']['per_second'], flush=True)
                        for process in cluster.processes.values():
                            process.terminate()
                        for process in cluster.processes.values():
                            assert process.wait(timeout=10) == 0
                    finally:
                        cluster.close()
                        case['logs'] = {f.name:f.read_text()[-4000:] for f in cluster_dir.glob('*.log')}
                        if args.io_profile_library:
                            case['io_profiles'] = {}
                            for name, log in case['logs'].items():
                                profiles = [json.loads(line.split(' ', 1)[1]) for line in log.splitlines()
                                            if line.startswith('SQLODIN_IO_PROFILE ')]
                                if case.get('verified'):
                                    assert len(profiles) == 1 and profiles[0]['errors'] == 0, profiles
                                case['io_profiles'][name] = profiles[0] if len(profiles) == 1 else None
                args.output.write_text(json.dumps(report, indent=2)+'\n')
        report['complete'] = True
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
