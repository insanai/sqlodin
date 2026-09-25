#!/usr/bin/env python3
"""Compare native binaries on three SSH-provisioned Linux voters.

The coordinator provisions and supervises voters exactly like check_network_hosts.py.
A separate client host runs the workload over mTLS, so coordinator RTT is excluded.
Binaries alternate within each repetition; every sample and its binary hash is kept.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

from check_network_hosts import RemoteCluster, SSH
from check_majority import ready

ROOT = Path(__file__).resolve().parents[1]

WORKER = r'''
import json, statistics, sys, threading, time
from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, sys.argv[2]); clients = int(sys.argv[3])
import sqlodin
cfg = json.loads((root / "members.json").read_text())
tls = sqlodin.TLS(root / "ca.pem", root / "client.pem", root / "client.key")
def connect(node):
    m = cfg[node - 1]
    return sqlodin.connect([sqlodin.Endpoint(m["address"], m["identity"])],
                           cluster="network-qualification", tls=tls, timeout=60)
out = {}
with connect(1) as db:
    db.execute("CREATE TABLE account(id INTEGER PRIMARY KEY, balance INTEGER, payload BLOB)")
    for first in range(0, 1024, 128):
        rows = ",".join(f"({i},0,zeroblob(256))" for i in range(first, first + 128))
        db.execute("INSERT INTO account VALUES " + rows)
    for kind in ("write", "read"):
        ms = []
        for k in range(40):
            started = time.monotonic()
            if kind == "write":
                db.execute(f"UPDATE account SET balance=balance+1 WHERE id={k}")
            else:
                db.query(f"SELECT balance FROM account WHERE id={k}")
            ms.append(1000 * (time.monotonic() - started))
        out[kind + "_ms_median"] = statistics.median(ms)
expected = 40
def burst(clients, per, read_percent):
    global expected
    conns = [connect(i % 3 + 1) for i in range(clients)]
    for db in conns:
        db.session_epoch(); db.query("SELECT 1")
    gate = threading.Barrier(clients)
    writes = [0] * clients
    def work(i):
        db = conns[i]; gate.wait()
        for k in range(per):
            if (i * 7 + k * 13) % 100 < read_percent:
                db.query(f"SELECT balance FROM account WHERE id={(i * per + k) % 1024}")
            else:
                db.execute(f"UPDATE account SET balance=balance+1 WHERE id={(i * per + k) % 1024}")
                writes[i] += 1
    threads = [threading.Thread(target=work, args=(i,)) for i in range(clients)]
    started = time.monotonic()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.monotonic() - started
    for db in conns: db.close()
    expected += sum(writes)
    return clients * per / elapsed
out["clients"] = clients
out[f"writes_{clients}_per_s"] = burst(clients, 25, 0)
out[f"mixed70_{clients}_per_s"] = burst(clients, 30, 70)
for node in (1, 2, 3):
    with connect(node) as db:
        assert db.query("SELECT sum(balance) FROM account").scalar() == expected
out["verified"] = True
print("RESULT " + json.dumps(out))
'''


def sample(args, binary, stamp):
    with tempfile.TemporaryDirectory(prefix='sqlodin-three-host-') as work:
        c = RemoteCluster(Path(work), binary.resolve(), args.openssl, args.hosts,
                          Path('/home/insan/projects/sqlodin/network-service') / stamp)
        try:
            for node in (1, 2, 3):
                c.start(node, create=True)
            for node in (1, 2, 3):
                ready(c, node)
            remote = f'{args.client_root}/{stamp}'
            (Path(work) / 'members.json').write_text(json.dumps(c.members))
            (Path(work) / 'worker.py').write_text(WORKER)
            subprocess.run([*SSH, args.client, 'mkdir -m 700 -p ' + shlex.quote(remote)], check=True, timeout=20)
            files = [Path(work) / name for name in ('members.json', 'worker.py', 'ca.pem', 'client.pem', 'client.key')]
            subprocess.run(['rsync', '-az', *map(str, files), f'{args.client}:{remote}/'], check=True, timeout=30)
            result = subprocess.run([*SSH, args.client, f'python3 {remote}/worker.py {remote} {args.client_python_src} {args.clients}'],
                                    capture_output=True, text=True, timeout=240)
            lines = [line for line in result.stdout.splitlines() if line.startswith('RESULT ')]
            assert result.returncode == 0 and len(lines) == 1, result.stderr[-3000:]
            return json.loads(lines[0][7:])
        finally:
            c.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--hosts', nargs=3, required=True)
    p.add_argument('--client', required=True, help='SSH target that runs the workload')
    p.add_argument('--client-root', default='/home/insan/projects/sqlodin-perf/build/three-host')
    p.add_argument('--client-python-src', default='/home/insan/projects/sqlodin-perf/languages/python/src')
    p.add_argument('--binary', nargs=2, action='append', metavar=('LABEL', 'PATH'), required=True)
    p.add_argument('--repeats', type=int, default=2)
    p.add_argument('--clients', type=int, default=24, help='closed-loop clients, spread over the voters')
    p.add_argument('--openssl', default=str(ROOT / 'build/native/openssl'))
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        p.error('Retain earlier evidence; choose a new output file')
    if not 3 <= args.clients <= 3 * 24:
        p.error('Use 3..72 clients; each voter admits at most 24')
    report = dict(complete=False, hosts=args.hosts, client=args.client, samples=[],
                  scope='three voters on separate hosts; one client host; closed-loop; not a capacity test',
                  clients=args.clients,
                  binaries={label: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                            for label, path in args.binary},
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    try:
        for repeat in range(args.repeats):
            for label, path in args.binary:
                stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
                result = sample(args, Path(path), stamp)
                report['samples'].append(dict(label=label, repeat=repeat, stamp=stamp, **result))
                print(label, repeat, json.dumps(result), flush=True)
        report['complete'] = True
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
