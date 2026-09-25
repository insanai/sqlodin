#!/usr/bin/env python3
"""Replay a stopped native-soak dataset in isolated directories on its three authorized hosts.

Copies database/WAL files only after checking the source voter is stopped. Uses new TLS keys,
new ports, a new executable path, and the existing bounded RemoteCluster process supervisor.
Never alters the original databases. Does not benchmark or start an endurance run.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

from check_network_hosts import RemoteCluster, SSH
from check_network_service import sqlodin


class SavedCluster(RemoteCluster):
    def connect(self, nodes=(1, 2, 3), **options):
        endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in self.members if m['id'] in nodes]
        return sqlodin.connect(endpoints, cluster='native-soak',
                               tls=sqlodin.TLS(self.root/'ca.pem', self.root/'client.pem', self.root/'client.key'),
                               **options)

    def copy_data(self, source):
        for i, host in enumerate(self.hosts, 1):
            script = f'''import json, pathlib, shutil
src=pathlib.Path({str(source)!r})
dst=pathlib.Path({str(self.remote_root)!r})
pidfile=src/'server.pid'
if pidfile.exists():
    proc=pathlib.Path('/proc')/pidfile.read_text().strip()/'cmdline'
    if proc.exists() and proc.read_bytes().split(b'\\0')[0]==str(src/'sqlodin').encode():
        raise RuntimeError('Source voter is running; refusing to copy live state')
for suffix in ('','-wal','-shm'):
    old=src/'data'/('node.db'+suffix)
    if old.exists(): shutil.copy2(old,dst/'data'/old.name)
cfgpath=dst/'node{i}.json'
cfg=json.loads(cfgpath.read_text()); cfg['cluster']='native-soak'
cfgpath.write_text(json.dumps(cfg))
'''
            subprocess.run([*SSH, host, 'python3 -c '+shlex.quote(script)], check=True, timeout=60)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--hosts', nargs=3, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--openssl', default=str(Path(__file__).resolve().parents[1]/'build/native/openssl'))
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.exists(): p.error('Use a new output path; retain previous evidence')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    remote = Path('/home/insan/projects/sqlodin/recovery-replay')/stamp
    report = dict(complete=False, passed=False, source_root=str(args.source_root), remote_root=str(remote),
                  hosts=args.hosts, binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(), nodes={})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-recovery-') as name:
            c = SavedCluster(Path(name), args.binary.resolve(), args.openssl, args.hosts, remote)
            try:
                c.copy_data(args.source_root)
                started = time.monotonic()
                for node in (1, 2, 3): c.start(node)
                deadline = started + 90
                pending = {1, 2, 3}
                while pending and time.monotonic() < deadline:
                    for node in sorted(pending):
                        try:
                            with c.connect((node,), timeout=2) as db:
                                status = db.status()
                                rows = db.query('SELECT count(*) FROM transfers').scalar()
                                accounts = [r.as_tuple() for r in db.query('SELECT * FROM accounts ORDER BY id')]
                                report['nodes'][node] = dict(status=status, transfers=rows, accounts=accounts,
                                                             ready_seconds=time.monotonic()-started)
                                pending.remove(node)
                        except sqlodin.ConnectionError as exc:
                            report.setdefault('last_error', {})[node] = str(exc)
                    if pending: time.sleep(.05)
                if pending: raise TimeoutError(f'Voters did not recover: {sorted(pending)}')
                values = list(report['nodes'].values())
                assert len({v['transfers'] for v in values}) == 1, values
                assert all(v['accounts'] == values[0]['accounts'] for v in values), values
                report.update(complete=True, passed=True)
            finally:
                c.close()
                report['logs'] = {f.name: f.read_text() for f in Path(name).glob('node*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__': main()
