#!/usr/bin/env python3
"""Deploy a bounded native soak to .19/.20/.21; retain every run in a fresh directory."""
import datetime,hashlib,json,os,shlex,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools'))
from check_network_service import generate
hosts=['insan@10.175.52.19','insan@10.175.52.20','insan@10.175.52.21']
seconds=int(sys.argv[1]);label=sys.argv[2]
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+label
local=root/'build/native-soak-deploy'/stamp;local.mkdir(parents=True,mode=0o700)
remote='/home/insan/projects/sqlodin/native-soak/'+stamp
ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10']
def run(argv,**kw):return subprocess.run(list(map(str,argv)),check=True,**kw)
generate(local,str(root/'build/native/openssl'))
key=local/'controller-key'
run(['ssh-keygen','-q','-t','ed25519','-N','','-C','sqlodin-'+stamp,'-f',key])
public=key.with_suffix('.pub').read_text().strip()
deadline=time.time()+seconds+1800
members=[dict(id=i+1,address=host.split('@')[1]+':27701',identity=f'node{i+1}.sqlodin.test') for i,host in enumerate(hosts)]
binary=root/'build/linux-orm-sqlodin'
config=dict(hosts=hosts,root=remote,members=members,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),ssh_key=remote+'/controller-key',known_hosts=remote+'/known_hosts',source_sha256={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'tools/run_native_soak.py',root/'tools/native_soak_worker.py']})
(local/'run.json').write_text(json.dumps(config,indent=2)+'\n')
(local/'supervisor.json').write_text(json.dumps(dict(deadline=deadline,authorized_key=public)))
known=[]
for i,host in enumerate(hosts):
 remote_config=dict(cluster='native-soak',node=i+1,listen=members[i]['address'],members=members,clients=['node-2.test.sqlodin'],data=remote+'/data',certificate=remote+f'/node{i+1}.pem',key=remote+f'/node{i+1}.key',ca=remote+'/ca.pem')
 (local/'node.json').write_text(json.dumps(remote_config))
 run([*ssh,host,'mkdir -p '+shlex.quote(str(Path(remote).parent))+' && mkdir -m 700 '+shlex.quote(remote)+' && mkdir -m 700 '+shlex.quote(remote+'/data')])
 run(['rsync','-az',local/'node.json',local/'supervisor.json',local/'ca.pem',local/f'node{i+1}.pem',local/f'node{i+1}.key',root/'tools/native_soak_worker.py',host+':'+remote+'/'])
 run(['rsync','-az',binary,host+':'+remote+'/sqlodin'])
 # Obtain the host key over the already authenticated SSH connection.
 hostkey=subprocess.check_output([*ssh,host,'cat /etc/ssh/ssh_host_ed25519_key.pub'],text=True).split()
 known.append(host.split('@')[1]+' '+hostkey[0]+' '+hostkey[1])
 if i:
  expiry=datetime.datetime.fromtimestamp(deadline,datetime.timezone.utc).strftime('%Y%m%d%H%M%SZ')
  forced='python3 '+remote+'/native_soak_worker.py'
  line=f'from="10.175.52.19",expiry-time="{expiry}",restrict,command="{forced}" {public}'
  script='from pathlib import Path\np=Path.home()/".ssh/authorized_keys"\np.parent.mkdir(mode=0o700,exist_ok=True)\nwith p.open("a") as f: f.write("\\n"+'+repr(line)+'+"\\n")\np.chmod(0o600)\n'
  run([*ssh,host,'python3 -c '+shlex.quote(script)])
(local/'known_hosts').write_text('\n'.join(known)+'\n')
run(['rsync','-az',local/'run.json',local/'known_hosts',key,local/'client.pem',local/'client.key',root/'tools/run_native_soak.py',hosts[0]+':'+remote+'/'])
run(['rsync','-az',str(root/'languages/python/src/sqlodin'),hosts[0]+':'+remote+'/python/'])
command=['python3',remote+'/run_native_soak.py',remote+'/run.json','--seconds',str(seconds),'--fault-interval',str(20 if seconds<100 else 3600)]
script='import subprocess,pathlib\nr=pathlib.Path('+repr(remote)+')\nf=(r/"controller.log").open("ab")\np=subprocess.Popen('+repr(command)+',stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)\n(r/"controller.pid").write_text(str(p.pid))\nprint(p.pid)'
run([*ssh,hosts[0],'python3 -c '+shlex.quote(script)])
(local/'deployment.json').write_text(json.dumps(dict(remote_root=remote,seconds=seconds,deadline=deadline,hosts=hosts),indent=2)+'\n')
print(remote)
