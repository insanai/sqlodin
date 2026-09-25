#!/usr/bin/env python3
"""Disk-backed Linux comparison using the native SQL service and pinned workload."""
import argparse
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import sqlite3
import time
import traceback

import compare_realworld as previous
from check_network_service import generate
import sqlodin

ROOT = previous.ROOT
reference, workload = previous.reference, previous.workload


class Client:
    def __init__(self, cluster, index=0):
        self.db = cluster.connect(index)
        self.attempts = 0
        exchange = self.db._transport.exchange
        def counted(*args, **kwargs):
            self.attempts += 1
            return exchange(*args, **kwargs)
        self.db._transport.exchange = counted

    def execute(self, statement):
        before = self.attempts
        self.db.execute(statement)
        return self.attempts - before

    def query(self, statement):
        before = self.attempts
        self.db.query(statement)
        return self.attempts - before

    def close(self): self.db.close()


class NativeCluster:
    system = 'sqlodin'

    def __init__(self, folder, binary, port):
        self.run_dir, self.binary = folder, binary
        self.children = reference.ProcessSet(folder, 'sqlodin')
        generate(folder, 'openssl')
        self.members = [dict(id=i+1, address=f'127.0.0.1:{port+i}', identity=f'node{i+1}.sqlodin.test')
                        for i in range(3)]
        self.endpoints = [('127.0.0.1', port+i) for i in range(3)]
        self.tls = sqlodin.TLS(folder/'ca.pem', folder/'client.pem', folder/'client.key')
        for i, member in enumerate(self.members):
            data = folder / f'data-{i}'; data.mkdir()
            config = dict(cluster='network-qualification', node=i+1, listen=member['address'],
                          members=self.members, clients=['node-2.test.sqlodin'], data=str(data),
                          certificate=str(folder/f'node{i+1}.pem'), key=str(folder/f'node{i+1}.key'),
                          ca=str(folder/'ca.pem'))
            (folder/f'node{i+1}.json').write_text(json.dumps(config))

    def connect(self, index=0, single=False):
        members = [self.members[index]] if single else self.members[index:]+self.members[:index]
        return sqlodin.connect([sqlodin.Endpoint(m['address'], m['identity']) for m in members],
                               cluster='network-qualification', tls=self.tls, timeout=30)

    def start(self, index, initial=False):
        self.children.spawn(index, [str(self.binary), 'serve', str(self.run_dir/f'node{index+1}.json'),
                                    *(['--create'] if initial else [])])

    def start_initial(self):
        for i in range(3): self.start(i, True)
        for endpoint in self.endpoints: reference.wait_port(endpoint)

    def restart(self, index):
        self.start(index)
        reference.wait_port(self.endpoints[index])

    def wait_leader(self):
        # Compatibility with the reference schedule; SQLodin has no standing leader.
        return self.children.running_indices()[0]

    def client_factory(self, worker_id): return Client(self, worker_id % 3)

    def setup(self):
        with self.connect() as db:
            for statement in (*workload.SCHEMA, *previous.sqlodin_seed_data()):
                db.execute(' '.join(statement.split()))

    def local_values(self, index):
        with self.connect(index, single=True) as db:
            return list(db.query(workload.INVARIANT_SQL, consistency='local').one().as_tuple())

    def linearizable_values(self):
        with self.connect() as db: return list(db.query(workload.INVARIANT_SQL).one().as_tuple())

    def wait_local_state(self, expected, indices=None, timeout=30):
        indices = self.children.running_indices() if indices is None else indices
        deadline = time.monotonic() + timeout
        while True:
            values = {str(i+1): self.local_values(i) for i in indices}
            if all(v == workload.expected_values(expected) for v in values.values()): return values
            if time.monotonic() >= deadline: raise TimeoutError(f'Catch-up mismatch: {values}')
            time.sleep(.05)

    def integrity(self):
        result = {}
        for i in range(3):
            with sqlite3.connect(f'file:{self.run_dir}/data-{i}/node.db?mode=ro', uri=True) as db:
                check = db.execute('PRAGMA integrity_check').fetchall()
                foreign = db.execute('PRAGMA foreign_key_check').fetchall()
                assert check == [('ok',)] and foreign == [], (check, foreign)
                result[str(i+1)] = 'ok'
        return result

    def cli_evidence(self): return None


def native_run(folder, args, seed):
    folder.mkdir()
    cluster = NativeCluster(folder, args.sqlodin_bin, previous.unused_base_port())
    with previous.Monitor(lambda: cluster.children.processes) as monitor:
        result = reference.run_system(cluster, args.operations, args.warmup, args.concurrency, seed)
    # Do not describe rotating ownership as leader election.
    result['phases'][1]['name'] = 'one_voter_crashed'
    result['phases'][2]['name'] = 'entry_voter_crashed'
    result.update(resources=monitor.result, disk=previous.disk_usage(folder),
                  boundary='three native mTLS processes; fresh quorum-barrier reads; writes admitted at all voters',
                  storage='on-disk SQLite application and Paxos journal; WAL synchronous=FULL')
    return result


def native_kv(folder, args):
    folder.mkdir()
    cluster = NativeCluster(folder, args.sqlodin_bin, previous.unused_base_port())
    latencies = []
    with previous.Monitor(lambda: cluster.children.processes) as monitor:
        try:
            cluster.start_initial()
            with cluster.connect() as db:
                db.execute('CREATE TABLE bench(id INTEGER PRIMARY KEY,v TEXT)')
                for i in range(args.warmup): db.execute('INSERT INTO bench VALUES(?,?)', (-i-1, 'x'*256))
                begin = time.perf_counter()
                for i in range(args.operations):
                    start = time.perf_counter()
                    db.execute('INSERT INTO bench VALUES(?,?)', (i, 'x'*256))
                    latencies.append(time.perf_counter()-start)
                elapsed = time.perf_counter()-begin
            cluster.children.crash_all()
            for i in range(3): cluster.restart(i)
            for i in range(3):
                with cluster.connect(i, single=True) as db:
                    assert db.query("SELECT count(*) FROM bench WHERE v=?", ('x'*256,)).scalar() == args.operations+args.warmup
            result = dict(system='sqlodin', operations=args.operations, operations_per_second=args.operations/elapsed,
                          latency_ms=workload.latency_summary(latencies), restart_verified=True,
                          boundary='native mTLS, sequential durable 256-byte inserts', nodes=3)
        finally: cluster.children.crash_all()
    result.update(resources=monitor.result, disk=previous.disk_usage(folder))
    return result


def network_kv(system, folder, args):
    """Use the reference retry-capable client and idempotent row keys."""
    folder.mkdir(); port=previous.unused_base_port()
    cluster=(reference.ZaxonCluster(folder,args.zaxon_bin,port) if system=='zaxonlite'
             else reference.RqliteCluster(folder,args.rqlited_bin,args.rqlite_cli,port))
    if system=='zaxonlite':
        spawn=cluster.children.spawn
        cluster.children.spawn=lambda index,argv:spawn(index,[*argv,'--sync','full'])
    def verify():
        client=cluster.client_factory(0)
        try:
            query="SELECT count(*),count(*) FILTER (WHERE v='"+'x'*256+"') FROM bench WHERE k>0"
            if system=='zaxonlite':
                response,_=client.call(dict(op='query',level='linearizable',sql=query))
                values=workload.values_from_zaxon(response)
            else:
                response,_=client.call('/db/query?level=linearizable&linearizable_timeout=2s',query)
                values=workload.values_from_rqlite(response)
            assert values==[args.operations,args.operations],values
        finally: client.close()
    latencies=[]; retries=0
    with previous.Monitor(lambda:cluster.children.processes) as monitor:
        try:
            cluster.start_initial(); client=cluster.client_factory(0)
            try:
                client.execute('CREATE TABLE IF NOT EXISTS bench(k INTEGER PRIMARY KEY,v TEXT)')
                for i in range(args.warmup):
                    client.execute(f"INSERT OR IGNORE INTO bench VALUES({-i-1},'{'x'*256}')")
                start=time.perf_counter()
                for i in range(args.operations):
                    before=time.perf_counter()
                    retries+=client.execute(f"INSERT OR IGNORE INTO bench VALUES({i+1},'{'x'*256}')")-1
                    latencies.append(time.perf_counter()-before)
                elapsed=time.perf_counter()-start
            finally: client.close()
            verify(); cluster.children.crash_all()
            for i in range(3): cluster.restart(i)
            cluster.wait_leader(); verify()
        finally: cluster.children.crash_all()
    result=previous.driver.summary(system,latencies,elapsed,args.operations,256)
    result.update(restart_verified=True,retry_attempts=retries,resources=monitor.result,disk=previous.disk_usage(folder),
                  boundary='reference retry-capable client; idempotent INSERT OR IGNORE; retry-inclusive latency')
    return result


def save(path, report):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(report, indent=2)+'\n'); temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--operations', type=int, default=400)
    parser.add_argument('--warmup', type=int, default=100)
    parser.add_argument('--concurrency', type=int, default=4)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--systems', nargs='+', default=['sqlodin','zaxonlite','rqlite','cowsql'],
                        choices=['sqlodin','zaxonlite','rqlite','cowsql'])
    parser.add_argument('--sqlodin-bin', type=Path, default=ROOT/'bin/sqlodin')
    parser.add_argument('--sqlodin-build', type=Path, help='Build manifest for the selected SQLodin binary')
    parser.add_argument('--zaxon-bin', default=str(ROOT/'build/comparison-tools/zaxon-release/zaxon'))
    parser.add_argument('--rqlited-bin', default=str(ROOT/'build/comparison-tools/rqlite-v10.2.7-linux-amd64/rqlited'))
    parser.add_argument('--rqlite-cli', default=str(ROOT/'build/comparison-tools/rqlite-v10.2.7-linux-amd64/rqlite'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--resume-from', type=Path,
                        help='Retain fully verified completed samples from an interrupted run on this host')
    parser.add_argument('--resume-source', type=Path)
    parser.add_argument('--recorded-failures', type=Path,
                        help='Preserved failed samples: retain and do not retry these attempts')
    args = parser.parse_args()
    if platform.system() != 'Linux': parser.error('Benchmark runs require Linux')
    if args.output.exists(): parser.error('Choose a fresh report path')
    if min(args.operations,args.concurrency,args.repeats) < 1 or args.warmup < 0: parser.error('Invalid counts')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    work = ROOT/'build/native-comparison-runs'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    work.mkdir(parents=True)
    filesystem = json.loads(previous.command('findmnt','-J','-T',work))
    assert filesystem['filesystems'][0]['fstype'] not in ('tmpfs','ramfs')
    report = dict(schema_version=1, complete=False, started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  host=platform.node(), host_address='10.175.52.18', platform=platform.platform(),
                  cpu=previous.command('lscpu'), filesystem=filesystem, run_directory=str(work),
                  workload=dict(operations=args.operations,warmup=args.warmup,concurrency=args.concurrency,repeats=args.repeats,
                                read_percent=70,write_percent=30), realworld=[],sequential_writes=[],failures=[],
                  sqlodin_build=(json.loads((args.sqlodin_build or Path(str(args.sqlodin_bin)+'.build.json')).read_text())
                                 if 'sqlodin' in args.systems else None),
                  comparison_build=(json.loads((ROOT/'build/comparison-tools/build.json').read_text())
                                    if any(s in args.systems for s in ('rqlite','cowsql')) else None),
                  zaxon_release=(json.loads((ROOT/'build/comparison-tools/zaxon-release/release.json').read_text())
                                 if 'zaxonlite' in args.systems else None),
                  source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [Path(__file__), ROOT/'tools/compare_realworld.py', *previous.VENDOR.glob('*.py')]})
    report['binaries_sha256'] = {name:hashlib.sha256(Path(path).read_bytes()).hexdigest() for name,path in
        [('sqlodin',args.sqlodin_bin),('zaxonlite',args.zaxon_bin),('rqlite',args.rqlited_bin),
         ('cowsql',ROOT/'build/comparison-tools/cowsql-demo')] if name in args.systems}
    if 'sqlodin' in args.systems:
        assert report['binaries_sha256']['sqlodin'] == report['sqlodin_build']['binary_sha256']
    if args.resume_from:
        earlier=json.loads(args.resume_from.read_text())
        source=args.resume_source or args.resume_from.with_name('linux18-native-initial-runner.py')
        assert hashlib.sha256(source.read_bytes()).hexdigest()==earlier['source_sha256']['tools/compare_native_workloads.py']
        def definitions(path):
            return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(path.read_text()).body
                    if isinstance(n,(ast.FunctionDef,ast.ClassDef))}
        before,after=definitions(source),definitions(Path(__file__))
        for name in ('Client','NativeCluster','native_run'):
            assert before[name]==after[name],f'Mixed adapter changed: {name}'
        if earlier['sequential_writes']:
            for name in ('native_kv','network_kv'):
                assert before[name]==after[name],f'Sequential adapter changed: {name}'
        for key in ('host','host_address','workload','binaries_sha256'):
            assert earlier[key]==report[key],f'Resume metadata mismatch: {key}'
        for key,digest in earlier['source_sha256'].items():
            if key!='tools/compare_native_workloads.py': assert report['source_sha256'][key]==digest,key
        report['resumed_from']=dict(path=str(args.resume_from),sha256=hashlib.sha256(args.resume_from.read_bytes()).hexdigest(),
                                    source_sha256=earlier['source_sha256'],run_directory=earlier['run_directory'],
                                    reason='Retain fully verified samples and separately record failed attempts',
                                    prior_provenance=earlier.get('resumed_from'))
        # Only complete mixed samples, each with all fault phases and final integrity, qualify.
        for row in earlier['realworld']:
            assert len(row['phases'])==3 and row['correctness']['integrity'] and row['total_cluster_restart']
            report['realworld'].append(dict(row,sample_run_directory=row.get('sample_run_directory',earlier['run_directory'])))
        for row in earlier['sequential_writes']:
            assert row.get('restart_verified') or row.get('verified_before_restart')
            report['sequential_writes'].append(dict(row,sample_run_directory=row.get('sample_run_directory',earlier['run_directory'])))
        report['failures'].extend(earlier.get('failures',[]))
    if args.recorded_failures:
        failures=json.loads(args.recorded_failures.read_text())
        assert failures['source_report_sha256']==hashlib.sha256(args.resume_from.read_bytes()).hexdigest()
        report['failures'].extend(failures['failures'])
    def done(group,system,repeat):
        return any(r['system']==system and r['repeat']==repeat for r in report[group]) or any(
            r['group']==group and r['system']==system and r['repeat']==repeat for r in report['failures'])
    def sample(group,system,repeat,folder,run):
        try:
            result=run();result['repeat']=repeat;report[group].append(result)
        except Exception as exc:
            report['failures'].append(dict(group=group,system=system,repeat=repeat,
                                          error=repr(exc),traceback=traceback.format_exc(),directory=str(folder)))
            print('FAILED',group,repeat,system,repr(exc),flush=True)
        save(args.output,report)
    try:
        for repeat in range(args.repeats):
            seed = 20260923 + repeat*100
            systems = [s for s in args.systems if s != 'cowsql']; random.Random(seed).shuffle(systems)
            for system in systems:
                if done('realworld',system,repeat): continue
                print('RUN mixed',repeat,system,flush=True)
                folder = work/f'{repeat}-{system}-mixed'
                sample('realworld',system,repeat,folder,lambda:native_run(folder,args,seed) if system=='sqlodin'
                       else previous.network_run(system,folder,args,seed,previous.unused_base_port()))
            systems = list(args.systems); random.Random(seed+1).shuffle(systems)
            for system in systems:
                if done('sequential_writes',system,repeat): continue
                print('RUN sequential',repeat,system,flush=True)
                folder = work/f'{repeat}-{system}-kv'
                sample('sequential_writes',system,repeat,folder,lambda:native_kv(folder,args) if system=='sqlodin'
                       else previous.cowsql_run(folder,args,previous.unused_base_port()) if system=='cowsql'
                       else network_kv(system,folder,args))
        report['complete']=True
        report['all_samples_passed']=not report['failures'] and all(r.get('restart_verified',True) for r in report['sequential_writes'])
    except BaseException as exc:
        report['error']=repr(exc); raise
    finally:
        report['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat(); save(args.output,report)


if __name__ == '__main__': main()
