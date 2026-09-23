#!/usr/bin/env python3
"""Run-directory-scoped, expiring native-service soak supervisor and audit endpoint."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent


def save(name, value):
    path = ROOT/name
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2)+'\n'); temp.replace(path)


def alive():
    path = ROOT/'server.pid'
    if not path.exists(): return None
    pid = int(path.read_text())
    command = Path(f'/proc/{pid}/cmdline')
    if command.exists() and command.read_bytes().split(b'\0')[0] == str(ROOT/'sqlodin').encode(): return pid
    return None


def usage(pid=None):
    result = dict(free_bytes=shutil.disk_usage(ROOT).free,
                  data_bytes=sum(p.stat().st_size for p in (ROOT/'data').glob('node.db*')))
    if pid:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        result['cpu_seconds'] = (int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK')
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith(('VmRSS:', 'VmHWM:')):
                key, value, _ = line.split(); result[key[:-1]]=int(value)*1024
    return result


def watch(create):
    cfg = json.loads((ROOT/'supervisor.json').read_text())
    if time.time() >= cfg['deadline']: raise RuntimeError('Expired run')
    def limits():
        if ctypes.CDLL(None).prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
            os._exit(125)
        resource.setrlimit(resource.RLIMIT_AS, (2*1024**3,2*1024**3))
    with (ROOT/'server.log').open('ab') as log:
        child = subprocess.Popen([str(ROOT/'sqlodin'),'serve',str(ROOT/'node.json'),
                                  *(['--create'] if create else [])], stdout=log,stderr=log,preexec_fn=limits)
        (ROOT/'server.pid').write_text(str(child.pid))
        report = dict(pid=child.pid, started=time.time(), samples=[], error=None)
        try:
            while child.poll() is None and time.time() < cfg['deadline']:
                row = usage(child.pid); row['epoch']=time.time()
                report['latest']=row
                if row['data_bytes'] > 8*1024**3 or row['free_bytes'] < 10*1024**3 or row['VmRSS'] > 512*1024**2:
                    raise RuntimeError('Resource guard exceeded')
                save('resource.json',report)
                time.sleep(2)
        except BaseException as exc:
            report['error']=repr(exc)
        finally:
            if child.poll() is None: child.kill()
            child.wait(); report.update(returncode=child.returncode,finished=time.time())
            save(f'resource-{child.pid}.json',report); save('resource.json',report)


def audit():
    if alive(): raise RuntimeError('Stop voter before offline audit')
    with sqlite3.connect(f'file:{ROOT}/data/node.db?mode=ro',uri=True) as db:
        integrity=db.execute('PRAGMA integrity_check').fetchall()
        foreign=db.execute('PRAGMA foreign_key_check').fetchall()
        assert integrity == [('ok',)] and not foreign, (integrity,foreign)
        result=dict(integrity='ok',foreign_keys='ok',tables={})
        for table,order in [('accounts','id'),('transfers','id'),('ledger','tx,account')]:
            digest=hashlib.sha256(); count=0
            for row in db.execute(f'SELECT * FROM {table} ORDER BY {order}'):
                digest.update(json.dumps(row,separators=(',',':')).encode()+b'\n'); count+=1
            result['tables'][table]=dict(rows=count,sha256=digest.hexdigest())
        result['balances']=db.execute('SELECT id,balance FROM accounts ORDER BY id').fetchall()
    save('audit.json',result)
    return result


def action(words):
    cfg=json.loads((ROOT/'supervisor.json').read_text())
    if time.time() > cfg['deadline']: raise RuntimeError('Expired run')
    if words in (['start'],['start','create']):
        if alive(): raise RuntimeError('Voter already running')
        with (ROOT/'supervisor.log').open('ab') as log:
            p=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'watch',*words[1:]],
                               stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
        for _ in range(100):
            if alive(): return dict(pid=alive())
            if p.poll() is not None: break
            time.sleep(.05)
        raise RuntimeError('Start failed')
    if words == ['stop']:
        pid=alive()
        if pid: os.kill(pid,signal.SIGKILL)
        for _ in range(100):
            if not alive(): return dict(stopped=True)
            time.sleep(.05)
        raise RuntimeError('Stop failed')
    if words == ['status']:
        resources=json.loads((ROOT/'resource.json').read_text()) if (ROOT/'resource.json').exists() else {}
        return dict(pid=alive(),resources=resources,usage=usage(),
                    binary_sha256=hashlib.sha256((ROOT/'sqlodin').read_bytes()).hexdigest())
    if words == ['audit']: return audit()
    if words == ['retire']:
        if alive(): raise RuntimeError('Stop voter before retiring controller access')
        public = cfg.get('authorized_key')
        if public:
            path = Path.home()/'.ssh/authorized_keys'
            lines = path.read_text().splitlines()
            path.write_text('\n'.join(line for line in lines if not line.endswith(public))+'\n')
            path.chmod(0o600)
        return dict(retired=True)
    raise ValueError('Unsupported supervisor action')


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='watch': watch('create' in sys.argv[2:])
    else:
        words=shlex.split(os.environ.get('SSH_ORIGINAL_COMMAND','')) if len(sys.argv)==1 else sys.argv[1:]
        print(json.dumps(action(words)),flush=True)
