#!/usr/bin/env python3
"""Event-count qualification: each voter stays down while both survivors serve durable mixed SQL."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import platform
import subprocess
import tempfile
import time

from check_network_service import Cluster, sqlodin


def ready(cluster, node, seconds=60):
    start = time.monotonic()
    last = None
    while time.monotonic() - start < seconds:
        try:
            with cluster.connect((node,), timeout=min(2, seconds-(time.monotonic()-start))) as db:
                assert db.query('SELECT 1').scalar() == 1
                return time.monotonic() - start
        except sqlodin.ConnectionError as exc:
            last = str(exc)
            time.sleep(.02)
    raise TimeoutError(f'Node {node} not quorum-ready: {last}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--operations', type=int, default=240)
    p.add_argument('--openssl', default=str(Path(__file__).resolve().parents[1]/'build/native/openssl'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--storage-format', type=int, choices=(4, 5), default=5)
    args = p.parse_args()
    if args.operations < 90 or args.output.exists(): p.error('Use at least 90 operations and a new output path')
    root = Path(__file__).resolve().parents[1]
    work_root = root / 'build/majority-work'
    work_root.mkdir(parents=True, exist_ok=True)
    report = dict(complete=False, passed=False, cases=[], operations_per_failure=args.operations,
                  storage_format=args.storage_format, platform=platform.platform(),
                  source_sha256={str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
                                 for folder in ('src', 'service') for f in (root / folder).rglob('*.odin')},
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-majority-', dir=work_root) as name:
            if platform.system() == 'Linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', name], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(Path(name), args.binary.resolve(), args.openssl, storage_format=args.storage_format)
            try:
                for node in (1,2,3): c.start(node, create=True)
                for node in (1,2,3): ready(c,node)
                with c.connect() as db:
                    db.execute('CREATE TABLE durable_majority(id INTEGER PRIMARY KEY, payload TEXT)')
                writes = 0
                for victim in (1,2,3):
                    survivors = [n for n in (1,2,3) if n != victim]
                    with c.connect((victim,)) as db: before = db.status()['applied']
                    c.stop(victim)
                    row = dict(absent=victim, operations=0, writes=0, passed=False)
                    report['cases'].append(row)
                    start = time.monotonic()
                    clients = [c.connect((n,),timeout=5) for n in survivors]
                    try:
                        rng = random.Random(24000+victim)
                        for i in range(args.operations):
                            db = clients[i%2]
                            if i == 0 or rng.random() < .3:
                                writes += 1
                                db.execute('INSERT INTO durable_majority VALUES(?,?)',(writes,'x'*256))
                                row['writes'] += 1
                            else:
                                assert db.query('SELECT count(*) FROM durable_majority').scalar() == writes
                            row['operations'] += 1
                            if i == 0: row['quorum_first_write_seconds'] = time.monotonic()-start
                        assert row['quorum_first_write_seconds'] <= 5, row
                        prefix = max(db.status()['applied'] for db in clients)
                        assert prefix-before > 64, (before,prefix)
                        row['lag_slots'] = prefix-before
                    finally:
                        for db in clients: db.close()
                    c.start(victim)
                    row['recovery_seconds'] = ready(c,victim)
                    with c.connect((victim,)) as db:
                        assert db.query('SELECT count(*) FROM durable_majority').scalar() == writes
                        assert db.status()['applied'] >= prefix
                    row['passed'] = True
                    print(f'PASS voter {victim} absent: both survivors served {args.operations} operations',flush=True)
                for node in (1,2,3): c.stop(node)
                for node in (1,2,3): c.start(node)
                for node in (1,2,3):
                    ready(c,node)
                    with c.connect((node,)) as db:
                        assert db.query('SELECT count(*) FROM durable_majority').scalar() == writes
                report.update(complete=True, passed=True, verified_writes=writes, all_voter_restart=True)
            finally:
                c.close()
                report['logs']={f.name:f.read_text() for f in Path(name).glob('node*.log')}
    except BaseException as exc:
        report['error']=repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__': main()
