#!/usr/bin/env python3
"""Bounded disk-backed capacity, live snapshots and recovery on three native voters."""
import argparse
import hashlib
import json
import random
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from check_network_service import Cluster, ROOT, sqlodin
from check_majority import ready
from check_resource_load import sample

GIB = 1024**3


def inventory(root):
    files = []
    for p in root.rglob('*'):
        if p.is_file() and p.suffix not in ('.pem', '.key', '.csr'):
            st = p.stat()
            files.append(dict(path=str(p.relative_to(root)), bytes=st.st_size, allocated=st.st_blocks*512))
    return files


def states(cluster):
    result = {}
    for node in (1, 2, 3):
        with cluster.connect((node,), timeout=5) as db:
            result[node] = db.status()
    return result


def execute(db, sql, params=()):
    try:
        return db.execute(sql, params)
    except sqlodin.UnknownOutcome:
        # Preserve the exact request identity; bounded resolution never submits a new write.
        for attempt in range(3):
            try:
                return db.resolve_pending()
            except sqlodin.UnknownOutcome:
                if attempt == 2:
                    raise


def checkpoint(cluster, report, output):
    before = time.monotonic()
    with cluster.connect(timeout=60) as db:
        target = db.request_snapshot()
    report['snapshot_target'] = target
    # Existing worker budgets remain unchanged. This watchdog bounds the campaign.
    watchdog = max(1800, 90*report['target_payload_bytes']/GIB)
    report['snapshot_watchdog_seconds'] = watchdog
    while time.monotonic()-before < watchdog:
        current = states(cluster)
        report['last_snapshot_states'] = current
        assert all(not s['snapshot_error'] for s in current.values()), current
        if all(s['generation_prefix'] >= target for s in current.values()):
            report['snapshot_seconds'] = time.monotonic()-before
            return
        output()
        time.sleep(1)
    raise TimeoutError('Capacity snapshot did not publish within the campaign watchdog')


def verify(cluster, rows, payloads, seed):
    rng = random.Random(seed)
    for node in (1, 2, 3):
        with cluster.connect((node,), timeout=60) as db:
            assert db.query('SELECT count(*) FROM capacity').scalar() == rows
            for _ in range(8):
                key = rng.randrange(rows)
                actual = db.query('SELECT length(payload),hex(substr(payload,1,32)) FROM capacity WHERE id=?',
                                  (key,)).one().as_tuple()
                assert actual == (4096, payloads[key % len(payloads)][:32].encode().hex().upper()), actual


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--gib', type=int, nargs='+', default=[10])
    p.add_argument('--fixture-mib', type=int, help='Small harness validation only; not capacity qualification')
    args = p.parse_args()
    assert not args.output.exists() and args.gib == sorted(set(args.gib))
    assert all(1 <= n <= 100 for n in args.gib)
    sizes = [n*GIB for n in args.gib]
    if args.fixture_mib is not None:
        assert 2 <= args.fixture_mib <= 64
        sizes = [args.fixture_mib*1024**2]
    base = ROOT/'build/capacity-work'
    base.mkdir(parents=True, exist_ok=True)
    report = dict(complete=False, stages=[], seed=20260925,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  scope='4 KiB printable random payloads cast to BLOB; public SQL; allocated bytes recorded separately',
                  fixture_only=args.fixture_mib is not None,
                  samples=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        args.output.write_text(json.dumps(report, indent=2)+'\n')
    stop = threading.Event()
    monitor = None
    try:
        with tempfile.TemporaryDirectory(dir=base) as work:
            root = Path(work)
            report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            report['initial_free_bytes'] = shutil.disk_usage(root).free
            assert report['initial_free_bytes'] > max(sizes)*12+20*GIB, 'Insufficient staging reserve'
            cluster = Cluster(root, args.binary.resolve(), str(ROOT/'build/native/openssl'),
                              storage_format=5, maintenance='auto')
            try:
                for node in (1, 2, 3):
                    cluster.start(node, create=True)
                for node in (1, 2, 3):
                    ready(cluster, node)
                def watch():
                    while not stop.wait(1):
                        try:
                            report['samples'].append(sample(cluster))
                        except (FileNotFoundError, ProcessLookupError):
                            pass  # The campaign deliberately restarts processes.
                monitor = threading.Thread(target=watch)
                monitor.start()
                rng = random.Random(report['seed'])
                payloads = [''.join(chr(rng.randrange(33,127)) for _ in range(4096)) for _ in range(256)]
                with cluster.connect(timeout=60) as db:
                    execute(db, 'CREATE TABLE capacity(id INTEGER PRIMARY KEY,balance INTEGER NOT NULL,payload BLOB)')
                    for key, payload in enumerate(payloads):
                        execute(db, f'INSERT INTO capacity VALUES({key},0,CAST('+('||'.join(['?']*16))+ ' AS BLOB))',
                                tuple(payload[i:i+256] for i in range(0,4096,256)))
                    rows = len(payloads)
                    for size in sizes:
                        stage = dict(target_payload_bytes=size, started=time.monotonic())
                        report['stages'].append(stage)
                        target = size//4096
                        while rows < target:
                            chunk = min(rows, 4096, target-rows)
                            execute(db, f'INSERT INTO capacity SELECT id+{rows},0,payload FROM capacity WHERE id<{chunk}')
                            rows += chunk
                            if rows % (64*4096) == 0:
                                stage.update(rows=rows, free_bytes=shutil.disk_usage(root).free)
                                assert stage['free_bytes'] > 20*GIB
                                save()
                        stage.update(rows=rows, load_seconds=time.monotonic()-stage['started'])
                        verify(cluster, rows, payloads, report['seed'])
                        stage['before_snapshot_files'] = inventory(root)
                        checkpoint(cluster, stage, save)
                        stage['after_snapshot_files'] = inventory(root)
                        # Short transactions touch indexed rows throughout the actual large table.
                        for operation in range(90):
                            with cluster.connect((operation%3+1,), timeout=60) as client:
                                key = rng.randrange(rows)
                                execute(client, 'UPDATE capacity SET balance=balance+1 WHERE id=?', (key,))
                                assert client.query('SELECT balance FROM capacity WHERE id=?', (key,)).scalar() >= 1
                        for node in (1, 2, 3):
                            cluster.stop(node)
                        started = time.monotonic()
                        for node in (1, 2, 3):
                            cluster.start(node)
                        for node in (1, 2, 3):
                            ready(cluster, node, seconds=60)
                        stage['restart_seconds'] = time.monotonic()-started
                        verify(cluster, rows, payloads, report['seed']+1)
                        stage['restart_goal_met'] = stage['restart_seconds'] <= 60
                        stage['complete'] = True
                        print('PASS capacity stage', size/GIB, 'GiB payload; restart', stage['restart_seconds'], flush=True)
                        save()
                        # Reconnect after full process restart; the old handle carries no pending write.
                        db.close()
                        db = cluster.connect(timeout=60)
                    db.close()
                report['complete'] = True
            finally:
                stop.set()
                if monitor:
                    monitor.join(timeout=5)
                report['peak_rss'] = {node:max((s['nodes'].get(node,{}).get('rss_bytes',0)
                                               for s in report['samples']), default=0) for node in (1,2,3)}
                cluster.close()
                report['logs'] = {f.name:f.read_text()[-12000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
