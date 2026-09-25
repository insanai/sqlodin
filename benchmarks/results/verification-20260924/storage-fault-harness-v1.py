#!/usr/bin/env python3
"""Linux exact-WAL ENOSPC, partial-write/EIO and sync-error recovery checks (R5.3)."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from check_network_service import Cluster, ROOT, sqlodin
from check_majority import ready


class FaultCluster(Cluster):
    injection = None

    def start(self, node, create=False):
        if node != 1 or self.injection is None:
            return super().start(node, create)
        log = open(self.root/'node1.log', 'ab')
        self.logs.append(log)
        self.processes[node] = subprocess.Popen([str(self.binary), 'serve', str(self.root/'node1.json')],
            stdout=log, stderr=log, env=dict(os.environ, **self.injection))
        time.sleep(.15)
        assert self.processes[node].poll() is None, (self.root/'node1.log').read_text()


def case(binary, library, openssl, root, database, mode):
    root.mkdir()
    result = dict(database=database, mode=mode, passed=False)
    c = FaultCluster(root, binary, openssl, storage_format=5)
    try:
        for node in (1, 2, 3): c.start(node, create=True)
        for node in (1, 2, 3): ready(c, node)
        with c.connect((1,)) as db:
            db.execute('CREATE TABLE faults(id INTEGER PRIMARY KEY, value INTEGER)')
            db.execute('INSERT INTO faults VALUES(1,100)')
        for node in (1, 2, 3):
            with c.connect((node,)) as db:
                assert db.query('SELECT value FROM faults WHERE id=1').scalar() == 100
        c.stop(1)
        c.injection = dict(LD_PRELOAD=str(library), SQLODIN_FAULT_TARGET=str(root/'data1'/database),
                           SQLODIN_FAULT_ARMED=str(root/'armed'), SQLODIN_FAULT_MARKER=str(root/'triggered'),
                           SQLODIN_FAULT_MODE=mode)
        c.start(1)
        ready(c, 1)
        (root/'armed').write_text('armed after quorum readiness\n')
        pending = sqlodin.PendingWrite('ef'*16, 1, 'UPDATE faults SET value=value+1 WHERE id=1')
        with c.connect((1,), pending=pending, timeout=2) as db:
            try: db.resolve_pending()
            except sqlodin.UnknownOutcome: result['client_outcome'] = 'unknown'
            else: raise AssertionError('Faulting voter acknowledged its failed persistence')
        assert (root/'triggered').read_text() == mode, 'Injection never reached selected syscall'
        result['faulting_exit'] = c.processes[1].wait(timeout=10)
        assert result['faulting_exit'] != 0, 'Storage error did not halt the voter'
        # The same unknown identity must succeed once through a surviving master.
        with c.connect((2,), pending=pending) as db:
            db.resolve_pending()
            assert db.query('SELECT value FROM faults WHERE id=1').scalar() == 101
        (root/'armed').unlink()
        c.injection = None
        c.start(1)
        ready(c, 1)
        with c.connect((1,), pending=pending) as db:
            db.resolve_pending()
            assert db.query('SELECT value FROM faults WHERE id=1').scalar() == 101
        for node in (1, 2, 3): c.stop(node)
        for node in (1, 2, 3): c.start(node)
        for node in (1, 2, 3):
            ready(c, node)
            with c.connect((node,)) as db:
                assert db.query('SELECT value FROM faults WHERE id=1').scalar() == 101
        result['passed'] = True
    except BaseException as exc:
        result['error'] = repr(exc)
    finally:
        c.close()
        result['logs'] = {f.name: f.read_text()[-12000:] for f in root.glob('*.log')}
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--openssl', default=str(ROOT/'build/native/openssl'))
    args = p.parse_args()
    if sys.platform != 'linux' or args.output.exists(): p.error('Linux and a new evidence path required')
    source = ROOT/'internal/storage_fault/interpose.c'
    scratch = ROOT/'build/storage-fault-work'
    scratch.mkdir(parents=True, exist_ok=True)
    library = scratch/'libsqlodin-storage-fault.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(library)], check=True)
    report = dict(complete=False, passed=False, cases=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  injector_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  scope='Injected Linux WAL syscall failures, not physical power-loss certification')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', str(root)], text=True))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            for database in ('consensus.db-wal', 'node.db-wal'):
                for mode in ('write-enospc', 'short-write', 'sync-eio'):
                    result = case(args.binary.resolve(), library, args.openssl,
                                  root/f'{database}-{mode}', database, mode)
                    report['cases'].append(result)
                    args.output.write_text(json.dumps(report, indent=2)+'\n')
                    print('PASS' if result['passed'] else 'FAIL', database, mode, flush=True)
                    if not result['passed']: raise AssertionError(result.get('error'))
            report.update(complete=True, passed=True)
    finally:
        report['sources'] = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                             for d in ('src', 'service', 'cli', 'transport') for f in (ROOT/d).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
