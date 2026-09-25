#!/usr/bin/env python3
"""Catch up an offline native voter from certified images after two compaction cycles."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

from snapshot_proxy import SnapshotProxy

from check_network_service import Cluster, ROOT
from check_majority import ready
from check_snapshot_service import wait_sealed


def wait_caught_up(cluster, target, frontier, deadline):
    # Observe recovery without injecting a new Paxos read barrier every two
    # seconds into the very suffix being measured. Verify a fresh quorum read
    # once the independently observed application frontier has arrived.
    while time.monotonic() < deadline:
        try:
            with cluster.connect((3,), timeout=2) as db:
                state = db.status()
                if state['generation_prefix'] >= target and state['applied'] >= frontier:
                    with cluster.connect((3,), timeout=min(10, deadline-time.monotonic())) as reader:
                        assert reader.query('SELECT 1').scalar() == 1
                    return
        except Exception:
            if time.monotonic() >= deadline:
                raise
        time.sleep(.1)
    raise TimeoutError(f'Voter 3 did not recover certified prefix {target} and frontier {frontier}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rows', type=int, default=8192)
    p.add_argument('--operations', type=int, default=90)
    p.add_argument('--slow-kib', type=int, default=0, help='throttle voter 3 inbound peer links')
    p.add_argument('--drop-once', action='store_true', help='interrupt one throttled transfer after 2 MiB')
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = p.parse_args()
    if args.output.exists() or not 3 <= args.rows <= 10000 or args.operations < 3 or args.slow_kib < 0:
        p.error('Use a new evidence path, 3–10000 rows and at least three operations')
    report = dict(complete=False, passed=False, checks=[], rows=args.rows, operations_per_cycle=args.operations,
                  slow_kib=args.slow_kib, drop_once=args.drop_once,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  scope='authenticated snapshot catch-up after two retained-prefix changes; explicit compaction')
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    try:
        scratch = ROOT / 'build/snapshot-catchup-work'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(
                    ['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, args.binary.resolve(), args.openssl, storage_format=5)
            proxy = None
            writer = None
            concurrent = dict(writes=0, errors=[])
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT, visits INTEGER)')
                with c.connect((3,)) as db:
                    assert db.query('SELECT count(*) FROM items').scalar() == 0
                    report['offline_prefix'] = db.status()['applied']
                c.stop(3)
                with c.connect((1, 2), timeout=30) as db:
                    db.execute('WITH d(x) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)), '
                               'n(x) AS (SELECT 1+a.x+10*b.x+100*c.x+1000*e.x '
                               'FROM d a CROSS JOIN d b CROSS JOIN d c CROSS JOIN d e) '
                               f'INSERT INTO items SELECT x,printf(\'%0256d\',x),0 FROM n WHERE x<={args.rows} ORDER BY x')
                for cycle in range(2):
                    with c.connect((1, 2)) as db:
                        for i in range(args.operations):
                            db.execute('UPDATE items SET visits=visits+1 WHERE id=?', (i % args.rows + 1,))
                        target = db.request_snapshot()
                    wait_sealed(c, target, nodes=(1, 2))
                    for node in (1, 2):
                        c.stop(node)
                        result = subprocess.run([str(args.binary.resolve()), 'compact',
                                                 str(root / f'node{node}.json')],
                                                capture_output=True, text=True, timeout=120)
                        assert result.returncode == 0, result.stderr
                        c.start(node)
                        ready(c, node)
                        with c.connect((node,)) as db:
                            assert db.status()['generation_prefix'] >= target
                    record(f'cycle_{cycle}_survivors_publish_while_third_voter_remains_offline')
                images = list((root / 'data1/snapshots').glob('image-*.db'))
                report['largest_image_bytes'] = max(path.stat().st_size for path in images)
                if args.rows >= 8192:
                    assert report['largest_image_bytes'] > 1024 * 1024
                if args.slow_kib:
                    proxy = SnapshotProxy(c.members[2]['address'], args.slow_kib,
                                          2 * 1024 * 1024 if args.drop_once else 0)
                    for node in (1, 2):
                        cfg_path = root / f'node{node}.json'
                        cfg = json.loads(cfg_path.read_text())
                        cfg['members'][2]['address'] = proxy.address
                        cfg_path.write_text(json.dumps(cfg))
                        c.stop(node)
                        c.start(node)
                        ready(c, node)

                    def write_during_transfer():
                        try:
                            with c.connect((1, 2), timeout=5) as db:
                                for _ in range(30):
                                    db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                                    concurrent['writes'] += 1
                                    time.sleep(.02)
                        except Exception as exc:
                            concurrent['errors'].append(repr(exc))

                    writer = threading.Thread(target=write_during_transfer, daemon=True)
                    writer.start()
                c.start(3)
                catchup_started = time.monotonic()
                if writer:
                    writer.join(timeout=60)
                    assert not writer.is_alive() and not concurrent['errors'], concurrent
                    assert concurrent['writes'] == 30, concurrent
                    report['concurrent'] = concurrent
                    record('healthy_quorum_writes_continue_during_throttled_snapshot_transfer')
                with c.connect((1, 2)) as db:
                    frontier = db.status()['applied']
                report['catchup_frontier'] = frontier
                wait_caught_up(c, target, frontier, catchup_started+90)
                report['catchup_seconds'] = time.monotonic()-catchup_started
                if proxy:
                    report['proxy'] = dict(downstream_bytes=proxy.downstream_bytes, drops=proxy.drops)
                    if args.drop_once:
                        assert proxy.drops == 1, report['proxy']
                with c.connect((3,)) as db:
                    state = db.status()
                    assert not state['snapshot_error'], state
                    assert state['generation_prefix'] >= target, state
                    assert db.query('SELECT count(*) FROM items').scalar() == args.rows
                    assert db.query('SELECT sum(visits) FROM items').scalar() == 2 * args.operations + concurrent['writes']
                    db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                record('offline_voter_installs_certified_image_and_continues_writes')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT sum(visits) FROM items').scalar() == 2 * args.operations + concurrent['writes'] + 1
                record('installed_generation_and_all_acknowledged_effects_survive_full_restart')
                report.update(complete=True, passed=True)
            finally:
                if writer:
                    writer.join(timeout=5)
                report['concurrent'] = concurrent
                if proxy:
                    report['proxy'] = dict(downstream_bytes=proxy.downstream_bytes, drops=proxy.drops)
                report['final_status'] = {}
                for node in (1, 2, 3):
                    try:
                        with c.connect((node,), timeout=2) as db:
                            report['final_status'][str(node)] = db.status()
                    except Exception as exc:
                        report['final_status'][str(node)] = dict(error=repr(exc))
                c.close()
                if proxy:
                    proxy.close()
                report['logs'] = {path.name: path.read_text()[-14000:] for path in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
