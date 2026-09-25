#!/usr/bin/env python3
"""Bounded real-time predicate/transaction histories checked against a serial model."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess
import tempfile
import time

from check_network_service import ROOT, Cluster
import sqlodin
from sqlodin import dbapi


def serial_history(initial, history):
    """Exhaust all legal orders, preserving response-before-invocation precedence.

    Successful transactions contribute their complete read/write observations.
    Serialization failures have no committed effects and remain in the raw report.
    Every batch ends with a nonconcurrent predicate read fixing the resulting state.
    """
    ops = [op for op in history if op['status'] == 'ok']
    before = [sum(1 << j for j, other in enumerate(ops)
                  if other['end'] < op['start']) for op in ops]
    full = (1 << len(ops)) - 1
    visited = set()

    def search(mask, state, order):
        if mask == full:
            return dict(state=state, order=order)
        key = (mask, tuple(state))
        if key in visited:
            return None
        visited.add(key)
        for i, op in enumerate(ops):
            if mask & (1 << i) or before[i] & ~mask or op['observed'] != state:
                continue
            after = state
            if op['kind'] == 'transaction':
                after = sorted(set(state) ^ {op['key']})
                if op['after'] != after:
                    continue
            if op['kind'] == 'readonly_transaction' and op['after'] != state:
                continue
            result = search(mask | (1 << i), after, order + [op['id']])
            if result is not None:
                return result
        return None

    return search(0, sorted(initial), [])


def negative_controls():
    write = dict(id=0, start=1, end=2, status='ok', kind='transaction',
                 observed=[], after=[1], key=1)
    stale = dict(id=1, start=3, end=4, status='ok', kind='read', observed=[])
    assert serial_history([], [write, stale]) is None
    skew = dict(id=1, start=1, end=3, status='ok', kind='transaction',
                observed=[], after=[2], key=2)
    assert serial_history([], [write, skew]) is None
    valid = dict(stale, observed=[1])
    assert serial_history([], [write, valid])['state'] == [1]
    return ['completed_write_then_stale_predicate_rejected', 'committed_write_skew_rejected',
            'ordered_write_and_fresh_predicate_accepted']


def operation(cluster, engine, node, identifier, key):
    from sqlalchemy import text
    from sqlalchemy.exc import OperationalError
    op = dict(id=identifier, node=node, start=time.monotonic_ns(),
              kind=('read' if key is None else 'readonly_transaction' if key == 0 else 'transaction'),
              key=key, status='pending')
    query = 'SELECT id FROM history_rows WHERE active=1 ORDER BY id'
    try:
        if key is None:
            with cluster.connect((node,), timeout=15) as db:
                op['observed'] = [row[0] for row in db.query(query)]
        else:
            with engine.begin() as conn:
                op['observed'] = list(conn.execute(text(query)).scalars())
                if key != 0:
                    active = int(key not in op['observed'])
                    conn.execute(text('UPDATE history_rows SET active=:active WHERE id=:key'),
                                 dict(active=active, key=key))
                op['after'] = list(conn.execute(text(query)).scalars())
        op['status'] = 'ok'
    except OperationalError as exc:
        if not isinstance(exc.orig, dbapi.SerializationError):
            raise
        op['status'] = 'serialization_abort'
        op['error'] = str(exc.orig)
    finally:
        op['end'] = time.monotonic_ns()
    return op


def campaign(cluster, report, rounds, seed):
    from sqlodin.sqlalchemy import create_engine
    tls = sqlodin.TLS(cluster.root / 'ca.pem', cluster.root / 'client.pem', cluster.root / 'client.key')
    engines = {m['id']: create_engine([sqlodin.Endpoint(m['address'], m['identity'])],
               cluster='network-qualification', tls=tls, timeout=15) for m in cluster.members}
    rng = random.Random(seed)
    state, identifier = [], 0
    try:
        for node in (1, 2, 3):
            cluster.start(node, create=True)
        with cluster.connect(timeout=20) as db:
            db.execute('CREATE TABLE history_rows(id INTEGER PRIMARY KEY, active INTEGER NOT NULL)')
            db.execute('INSERT INTO history_rows VALUES(1,0),(2,0),(3,0),(4,0)')
        for absent in (None, 1, 2, 3):
            live = [node for node in (1, 2, 3) if node != absent]
            if absent is not None:
                cluster.stop(absent)
            try:
                for batch in range(rounds):
                    entry = dict(absent=absent, batch=batch, initial=state[:], history=[])
                    report['batches'].append(entry)
                    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                        jobs = []
                        for i in range(8):
                            node = live[i % len(live)]
                            key = rng.randint(1, 4) if i % 2 == 0 else (0 if i % 4 == 3 else None)
                            jobs.append(pool.submit(operation, cluster, engines[node], node, identifier, key))
                            identifier += 1
                        for job in concurrent.futures.as_completed(jobs):
                            entry['history'].append(job.result())
                    # Real-time anchor after every completed transaction/read.
                    anchor = operation(cluster, None, live[batch % len(live)], identifier, None)
                    identifier += 1
                    entry['history'].append(anchor)
                    witness = serial_history(state, entry['history'])
                    assert witness is not None, f'No serial explanation: {entry}'
                    entry['witness'] = witness
                    state = witness['state']
                    assert any(op['kind'] == 'transaction' and op['status'] == 'ok'
                               for op in entry['history']), 'No transaction made progress'
            finally:
                if absent is not None:
                    cluster.start(absent)
            for node in (1, 2, 3):
                anchor = operation(cluster, None, node, identifier, None)
                identifier += 1
                report['rejoin_reads'].append(anchor)
                assert anchor['observed'] == state
            print('PASS serial_predicate_histories_absent_' + str(absent), flush=True)
        for node in (1, 2, 3):
            cluster.stop(node)
        for node in (1, 2, 3):
            cluster.start(node)
        for node in (1, 2, 3):
            anchor = operation(cluster, None, node, identifier, None)
            identifier += 1
            report['restart_reads'].append(anchor)
            assert anchor['observed'] == state
        print('PASS final_predicate_state_after_full_restart', flush=True)
    finally:
        for engine in engines.values():
            engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=4)
    parser.add_argument('--seed', type=int, default=481516)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 32 or args.output.exists():
        parser.error('Use 1..32 rounds and a new output path')
    report = dict(complete=False, format=5, policy=None, seed=args.seed, rounds=args.rounds,
                  batches=[], rejoin_reads=[], restart_reads=[], platform=platform.platform(),
                  negative_controls=negative_controls(),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for directory in ('src', 'service', 'languages/python/src')
                           for p in (ROOT / directory).rglob('*') if p.suffix in ('.odin', '.py')})
    root = ROOT / 'build/history-work'
    root.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=root) as work:
            if platform.system() == 'Linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            cluster = Cluster(Path(work), args.binary.resolve(), str(ROOT / 'build/native/openssl'), storage_format=5)
            try:
                campaign(cluster, report, args.rounds, args.seed)
                with cluster.connect() as db:
                    report['policy'] = db.status().get('policy')
                report['complete'] = True
            finally:
                cluster.close()
                report['logs'] = {p.name: p.read_text()[-6000:] for p in cluster.root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
