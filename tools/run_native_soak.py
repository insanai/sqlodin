#!/usr/bin/env python3
"""Bounded eight-hour native mTLS mixed-SQL soak; coordinator runs on a Linux host."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys
import time
import traceback

sys.path.insert(0,str(Path(__file__).resolve().parent/'python'))
import sqlodin


def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path,value):
    temp=path.with_suffix('.tmp'); temp.write_text(json.dumps(value,indent=2)+'\n'); temp.replace(path)


def control(cfg,index,*words):
    if index==0: command=[sys.executable,str(Path(__file__).with_name('native_soak_worker.py')),*words]
    else: command=['ssh','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
                  '-o','ConnectTimeout=10','-o','UserKnownHostsFile='+cfg['known_hosts'],
                  '-i',cfg['ssh_key'],cfg['hosts'][index],*words]
    result=subprocess.run(command,check=True,capture_output=True,text=True,timeout=90)
    return json.loads(result.stdout)


def connect(cfg,index=0,pending=None,single=False):
    members=cfg['members']; members=[members[index]] if single else members[index:]+members[:index]
    root=Path(cfg['root'])
    return sqlodin.connect([sqlodin.Endpoint(m['address'],m['identity']) for m in members],
                           cluster='native-soak',tls=sqlodin.TLS(root/'ca.pem',root/'client.pem',root/'client.key'),
                           timeout=45,pending=pending)


SETUP=('CREATE TABLE accounts(id INTEGER PRIMARY KEY,balance INTEGER CHECK(balance>=0));'
       'INSERT INTO accounts VALUES(1,1000000),(2,1000000),(3,1000000);'
       'CREATE TABLE transfers(id INTEGER PRIMARY KEY,src REFERENCES accounts(id),dst REFERENCES accounts(id),'
       'amount INTEGER CHECK(amount>0),payload TEXT);'
       'CREATE TABLE ledger(tx REFERENCES transfers(id),account REFERENCES accounts(id),delta INTEGER);'
       'CREATE INDEX ledger_tx ON ledger(tx);'
       'CREATE TRIGGER audit AFTER INSERT ON transfers BEGIN '
       'INSERT INTO ledger VALUES(new.id,new.src,-new.amount);'
       'INSERT INTO ledger VALUES(new.id,new.dst,new.amount); END;')


def verify(cfg,first,last,balances):
    for node in range(3):
        with connect(cfg,node,single=True) as db:
            assert [r['balance'] for r in db.query('SELECT balance FROM accounts ORDER BY id')]==balances
            for start in range(first,last+1,128):
                end=min(start+127,last)
                query=(f'SELECT t.id FROM transfers t JOIN ledger l ON l.tx=t.id '
                       f'WHERE t.id BETWEEN {start} AND {end} AND l.tx BETWEEN {start} AND {end} '
                       'AND t.src=t.id%3+1 AND t.dst=t.src%3+1 AND t.amount=t.id%17+1 '
                       f"AND t.payload='{'x'*256}' "
                       'AND ((l.account=t.src AND l.delta=-t.amount) OR (l.account=t.dst AND l.delta=t.amount)) '
                       'GROUP BY t.id HAVING count(*)=2 AND count(DISTINCT l.account)=2')
                assert len(db.query(query))==end-start+1, (node,start,end)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('config',type=Path); parser.add_argument('--seconds',type=int,default=28800)
    parser.add_argument('--fault-interval',type=int,default=3600); args=parser.parse_args()
    if not 30<=args.seconds<=28800 or args.fault_interval<15: parser.error('Invalid bounds')
    cfg=json.loads(args.config.read_text()); root=Path(cfg['root']); output=root/'soak.json'
    if output.exists(): raise RuntimeError('Refusing to overwrite a prior run')
    report=dict(complete=False,status='starting',started_utc=utc(),hosts=cfg['hosts'],requested_workload_seconds=args.seconds,
                scope='three Linux instances; native mTLS replication and SQL; closed-loop 70/30 reads/transfers',
                binary_sha256=cfg['binary_sha256'],limits=dict(rss_bytes=512*1024**2,data_bytes=8*1024**3,min_free_bytes=10*1024**3),
                faults=[],source_sha256=cfg['source_sha256'])
    clients=[]; writes=reads=verified=duplicates=0; balances=[1000000]*3
    samples={'read':[],'write':[]}; rng=random.Random(20260923)
    def progress(start):
        resources=[control(cfg,n,'status') for n in range(3)]
        assert all(r['pid'] and not r['resources'].get('error') for r in resources), resources
        report.update(progress=dict(elapsed_seconds=time.monotonic()-start,reads=reads,writes=writes,
                                    verified_transfers=verified,acknowledged_retries=duplicates,resources=resources,
                                    latency_ms={k:{f'p{p}':sorted(v)[min(len(v)-1,int(len(v)*p/100))]*1000
                                                    for p in (50,95,99)} for k,v in samples.items() if v}),updated_utc=utc())
        save(output,report)
        with (root/'soak.jsonl').open('a') as f: f.write(json.dumps(report['progress'])+'\n')
        for v in samples.values(): v.clear()
    try:
        for node in range(3):
            control(cfg,node,'start','create')
            assert control(cfg,node,'status')['binary_sha256']==cfg['binary_sha256']
        clients=[connect(cfg,n%3) for n in range(12)]
        clients[0].execute(SETUP)
        start=time.monotonic(); deadline=start+args.seconds; next_check=start+60; next_fault=start+args.fault_interval
        report.update(status='running',workload_started_utc=utc(),planned_end_utc=datetime.datetime.fromtimestamp(time.time()+args.seconds,datetime.timezone.utc).isoformat())
        progress(start)
        while time.monotonic()<deadline:
            db=clients[(reads+writes)%len(clients)]; before=time.monotonic()
            if rng.random()<.3:
                number=writes+1; src=number%3+1; dst=src%3+1; amount=number%17+1
                body=(f"INSERT INTO transfers VALUES({number},{src},{dst},{amount},'{'x'*256}');"
                      f'UPDATE accounts SET balance=balance-{amount} WHERE id={src};'
                      f'UPDATE accounts SET balance=balance+{amount} WHERE id={dst}')
                saved=sqlodin.PendingWrite(db._session,db._sequence,body)
                try: db.execute(body)
                except sqlodin.UnknownOutcome as exc:
                    (root/'pending.json').write_text(exc.pending.to_json()); raise
                writes+=1; balances[src-1]-=amount; balances[dst-1]+=amount
                samples['write'].append(time.monotonic()-before)
                if writes%257==0:
                    with connect(cfg,(writes//257)%3,pending=saved) as retry: retry.resolve_pending()
                    duplicates+=1
            else:
                node=rng.randrange(3)
                assert db.query('SELECT balance FROM accounts WHERE id=?',(node+1,)).scalar()==balances[node]
                reads+=1; samples['read'].append(time.monotonic()-before)
            if time.monotonic()>=next_fault and time.monotonic()<deadline:
                victim=len(report['faults'])%3; control(cfg,victim,'stop')
                try:
                    # Surviving quorum continues while one voter is actually absent.
                    with connect(cfg,(victim+1)%3,single=True) as surviving:
                        assert surviving.query('SELECT sum(balance) FROM accounts').scalar()==3000000
                        surviving.execute('UPDATE accounts SET balance=balance WHERE id=1')
                finally: control(cfg,victim,'start')
                report['faults'].append(dict(node=victim+1,epoch=time.time(),kind='SIGKILL, surviving-quorum read/write, reopen'))
                next_fault+=args.fault_interval
            if time.monotonic()>=next_check:
                verify(cfg,verified+1,writes,balances); verified=writes; progress(start); next_check=time.monotonic()+60
        verify(cfg,verified+1,writes,balances); verified=writes; progress(start)
        report['status']='final-recovery'; save(output,report)
        for db in clients: db.close()
        clients=[]
        for node in range(3): control(cfg,node,'stop')
        for node in range(3): control(cfg,node,'start')
        verify(cfg,max(1,writes-127),writes,balances)
        for node in range(3): control(cfg,node,'stop')
        audits=[control(cfg,node,'audit') for node in range(3)]
        assert audits[0]==audits[1]==audits[2],audits
        assert audits[0]['tables']['transfers']['rows']==writes
        assert audits[0]['tables']['ledger']['rows']==2*writes
        report.update(complete=True,status='passed',audits=audits,finished_utc=utc())
    except BaseException as exc:
        report.update(status='failed',error=repr(exc),traceback=traceback.format_exc(),finished_utc=utc())
        raise
    finally:
        for db in clients: db.close()
        cleanup=[]
        for node in range(3):
            try: control(cfg,node,'stop')
            except Exception as exc: cleanup.append(repr(exc))
        for node in (1,2):
            try: control(cfg,node,'retire')
            except Exception as exc: cleanup.append(repr(exc))
        if cleanup: report['cleanup_errors']=cleanup
        save(output,report)


if __name__=='__main__': main()
