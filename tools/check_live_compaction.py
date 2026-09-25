#!/usr/bin/env python3
"""Bounded native online compaction: writes, publication, absent voter and restart."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile
import time

from check_network_service import Cluster, ROOT
from check_majority import ready
from check_snapshot_catchup import wait_caught_up


def retained_generation_files(root):
    """Read a stable catalog view and verify both protected generations and images."""
    with sqlite3.connect(f'file:{root / "consensus.db"}?mode=ro', uri=True) as catalog:
        catalog.execute('BEGIN')
        current, = catalog.execute('SELECT name FROM _sqlodin_current_generation').fetchone()
        with sqlite3.connect(f'file:{root / current / "consensus.db"}?mode=ro', uri=True) as active:
            previous, image = active.execute('SELECT previous,name FROM _sqlodin_generation_base').fetchone()
        assert previous and (root / previous / 'node.db').is_file(), (current, previous)
        with sqlite3.connect(f'file:{root / previous / "consensus.db"}?mode=ro', uri=True) as predecessor:
            prior_image, = predecessor.execute('SELECT name FROM _sqlodin_generation_base').fetchone()
        images = catalog.execute('SELECT name,directory FROM _sqlodin_image_inventory').fetchall()
        owned = {name: Path(directory) / name for name, directory in images}
        assert owned[image].is_file() and owned[prior_image].is_file(), (image, prior_image)
        return len(list(root.glob('generation-*'))), len(images), not (root / "node.db").exists()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--operations', type=int, default=30)
    p.add_argument('--cycles', type=int, default=2)
    p.add_argument('--scheduled', action='store_true', help='use a build with a short test-only dirty interval')
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    args = p.parse_args()
    if args.output.exists() or args.operations < 3 or not 2 <= args.cycles <= 8:
        p.error('Use a new output path and at least three operations')
    report = dict(complete=False, passed=False, checks=[], scheduled=args.scheduled,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(), operations=args.operations, cycles=args.cycles)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)

    scratch = ROOT / 'build/live-compaction-work'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(root, args.binary.resolve(), args.openssl, storage_format=5, maintenance='auto')
            try:
                for node in (1, 2, 3): c.start(node, create=True)
                for node in (1, 2, 3): ready(c, node)
                with c.connect() as db:
                    db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY, visits INTEGER)')
                    db.execute('INSERT INTO items VALUES(1,0)')
                with c.connect((3,)) as db:
                    assert db.query('SELECT visits FROM items').scalar() == 0
                c.stop(3)
                writes = 0
                for cycle in range(args.cycles):
                    with c.connect((1, 2)) as db:
                        old = db.status()['generation_prefix']
                        for _ in range(args.operations):
                            db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                            writes += 1
                        target = old+1 if args.scheduled else db.request_snapshot()
                    deadline = time.monotonic()+60
                    published = set()
                    while time.monotonic() < deadline:
                        for node in (1, 2):
                            with c.connect((node,), timeout=5) as db:
                                state = db.status()
                                assert not state['snapshot_error'], state
                                if state['generation_prefix'] >= target:
                                    published.add(node)
                                db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                                writes += 1
                        if len(published) == 2:
                            break
                        time.sleep(.1)
                    assert len(published) == 2, published
                    record(f'cycle_{cycle}_both_live_voters_publish_while_accepting_writes')
                if args.cycles >= 3:
                    deadline = time.monotonic()+30
                    while time.monotonic() < deadline:
                        counts = {node: retained_generation_files(root / f'data{node}') for node in (1, 2)}
                        if all(dirs == 2 and images <= 3 and root_retired for dirs, images, root_retired in counts.values()):
                            break
                        time.sleep(.1)
                    assert all(dirs == 2 and images <= 3 and root_retired for dirs, images, root_retired in counts.values()), counts
                    record('superseded_generations_and_images_retire_with_active_and_exact_predecessor_preserved')
                with c.connect((1,)) as db:
                    target, frontier = db.status()['generation_prefix'], db.status()['applied']
                c.start(3)
                wait_caught_up(c, target, frontier, time.monotonic()+90)
                with c.connect((3,)) as db:
                    assert db.query('SELECT visits FROM items').scalar() == writes
                    db.execute('UPDATE items SET visits=visits+1 WHERE id=1')
                    writes += 1
                record('offline_voter_installs_online_generation_and_accepts_write')
                for node in (1, 2, 3): c.stop(node)
                for node in (1, 2, 3): c.start(node)
                for node in (1, 2, 3):
                    ready(c, node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT visits FROM items').scalar() == writes
                record('all_acknowledged_writes_survive_full_restart')
                report.update(complete=True, passed=True, writes=writes)
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-12000:] for p in root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
