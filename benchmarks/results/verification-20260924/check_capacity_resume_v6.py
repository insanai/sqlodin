#!/usr/bin/env python3
"""Bounded disk-backed capacity, live snapshots and recovery on three native voters."""
import argparse
from contextlib import contextmanager
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


@contextmanager
def retained_workspace(base, report, resume=None):
    root = resume if resume else Path(tempfile.mkdtemp(dir=base))
    report['work_directory'] = str(root)
    try:
        yield root
    except BaseException:
        report['failed_data_retained'] = True
        raise
    else:
        shutil.rmtree(root)


def retained_cluster(root, binary):
    """Reopen only the explicit failed campaign; never recreate its identities."""
    cluster = Cluster.__new__(Cluster)
    cluster.root, cluster.binary = root, binary
    cluster.processes, cluster.logs = {}, []
    cluster.members = json.loads((root/'node1.json').read_text())['members']
    assert [m['id'] for m in cluster.members] == [1, 2, 3]
    assert all(m['address'].startswith('127.0.0.1:') for m in cluster.members)
    for node in (1, 2, 3):
        config = json.loads((root/f'node{node}.json').read_text())
        assert config['node'] == node and config['members'] == cluster.members
        assert config['cluster'] == 'network-qualification' and config['storage_format'] == 5
        assert config['maintenance'] == 'auto'
        assert Path(config['data']).resolve() == root/f'data{node}'
        assert Path(config['certificate']).resolve() == root/f'node{node}.pem'
        assert Path(config['key']).resolve() == root/f'node{node}.key'
        assert Path(config['ca']).resolve() == root/'ca.pem'
    return cluster


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
    required = max(s['applied'] for s in states(cluster).values())
    target = None
    watchdog = max(1800, 90*report['target_payload_bytes']/GIB)
    report['snapshot_watchdog_seconds'] = watchdog
    report['required_snapshot_prefix'] = required
    while time.monotonic()-before < watchdog:
        current = states(cluster)
        report['last_snapshot_states'] = current
        assert all(not s['snapshot_error'] for s in current.values()), current
        if all(s['generation_prefix'] >= (target or required) for s in current.values()):
            report['snapshot_target'] = target or min(s['generation_prefix'] for s in current.values())
            report['snapshot_seconds'] = time.monotonic()-before
            return
        # The default fifteen-minute policy can already be capturing a growing
        # dataset. Wait for that bounded job instead of treating admission Busy
        # as a storage failure or starting concurrent maintenance.
        working = any(max(s['snapshot_prefix'], s['snapshot_sealed']) > s['generation_prefix']
                      for s in current.values())
        if target is None and not working:
            try:
                with cluster.connect(timeout=5) as db:
                    target = db.request_snapshot()
                report['snapshot_target'] = target
            except sqlodin.ConnectionError as exc:
                if str(exc) != 'Operation deadline exceeded: Busy':
                    raise
                report['snapshot_busy_retries'] = report.get('snapshot_busy_retries',0)+1
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
    p.add_argument('--resume-report', type=Path, help='Explicit retained failed campaign; recover before continuing')
    p.add_argument('--interrupt-after-load', action='store_true', help='Fixture-only recovery negative control')
    args = p.parse_args()
    assert not args.output.exists() and args.gib == sorted(set(args.gib))
    assert all(1 <= n <= 100 for n in args.gib)
    sizes = [n*GIB for n in args.gib]
    if args.fixture_mib is not None:
        assert 2 <= args.fixture_mib <= 64
        sizes = [args.fixture_mib*1024**2]
    assert not args.interrupt_after_load or args.fixture_mib is not None
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
    resume = None
    if args.resume_report:
        previous = json.loads(args.resume_report.read_text())
        assert not previous['complete'] and previous['failed_data_retained']
        assert previous['seed'] == report['seed'] and previous['fixture_only'] == report['fixture_only']
        resume = Path(previous['work_directory'])
        assert resume.is_absolute() and resume.resolve() == resume and resume.is_dir()
        report['resume'] = dict(report=str(args.resume_report.resolve()),
            report_sha256=hashlib.sha256(args.resume_report.read_bytes()).hexdigest(),
            previous_binary_sha256=previous['binary_sha256'],
            note='Explicit recovery continuation; previous failure remains, retained files are reopened in place')
    try:
        with retained_workspace(base, report, resume) as work:
            root = Path(work)
            report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            report['initial_free_bytes'] = shutil.disk_usage(root).free
            existing = sum(f['allocated'] for f in inventory(root)) if resume else 0
            report['initial_allocated_bytes'] = existing
            assert report['initial_free_bytes']+existing > max(sizes)*12+20*GIB, 'Insufficient staging reserve'
            cluster = (retained_cluster(root, args.binary.resolve()) if resume else
                       Cluster(root, args.binary.resolve(), str(ROOT/'build/native/openssl'),
                               storage_format=5, maintenance='auto'))
            try:
                startup = time.monotonic()
                for node in (1, 2, 3):
                    cluster.start(node, create=not resume)
                # Observe failed-generation recovery long enough to diagnose it.
                # Record the original 60-second goal separately; final qualified
                # snapshot restart below retains its existing 60-second watchdog.
                watchdog = 600 if resume else 60
                report['initial_readiness_watchdog_seconds'] = watchdog
                for node in (1, 2, 3):
                    ready(cluster, node, seconds=max(1, watchdog-(time.monotonic()-startup)))
                report['initial_readiness_seconds'] = time.monotonic()-startup
                report['initial_sixty_second_goal_met'] = report['initial_readiness_seconds'] <= 60
                save()
                def watch():
                    while not stop.wait(1):
                        try:
                            report['samples'].append(sample(cluster))
                        except (FileNotFoundError, ProcessLookupError):
                            pass  # The campaign deliberately restarts processes.
                        except PermissionError as exc:
                            # Linux can revoke /proc access while a child exits.
                            # Preserve the sampling gap instead of losing the monitor.
                            report.setdefault('sampling_errors', []).append(repr(exc))
                monitor = threading.Thread(target=watch)
                monitor.start()
                rng = random.Random(report['seed'])
                payloads = [''.join(chr(rng.randrange(33,127)) for _ in range(4096)) for _ in range(256)]
                with cluster.connect(timeout=60) as db:
                    if resume:
                        rows = db.query('SELECT count(*) FROM capacity').scalar()
                        assert db.query('SELECT min(id) FROM capacity').scalar() == 0
                        assert db.query('SELECT max(id) FROM capacity').scalar() == rows-1
                        assert len(payloads) <= rows <= max(sizes)//4096
                        verify(cluster, rows, payloads, report['seed'])
                        report['resume']['verified_rows_before_continuation'] = rows
                    else:
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
                            # A resumed campaign can have one old uncertain insert.
                            # The deterministic primary keys/payloads make overlap
                            # idempotent without resubmitting a different old identity.
                            verb = 'INSERT OR IGNORE' if resume else 'INSERT'
                            execute(db, f'{verb} INTO capacity SELECT id+{rows},0,payload FROM capacity WHERE id<{chunk}')
                            rows += chunk
                            if rows % (64*4096) == 0:
                                stage.update(rows=rows, free_bytes=shutil.disk_usage(root).free)
                                assert stage['free_bytes'] > 20*GIB
                                save()
                        stage.update(rows=rows, load_seconds=time.monotonic()-stage['started'])
                        verify(cluster, rows, payloads, report['seed'])
                        if args.interrupt_after_load:
                            report['expected_fixture_interruption'] = True
                            raise RuntimeError('Requested fixture interruption after verified load')
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
                report['process_returncodes_before_cleanup'] = {
                    node:process.poll() for node,process in cluster.processes.items()}
                cluster.close()
                report['logs'] = {f.name:f.read_text()[-12000:] for f in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
