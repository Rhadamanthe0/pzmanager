import json, os
from pathlib import Path
import shlex, shutil, sqlite3, subprocess, tempfile, unittest
ROOT=Path(os.environ['PZ_TEST_ROOT'])

class WatchdogRecovery(unittest.TestCase):
 def run_recovery(self,mode="failed"):
  with tempfile.TemporaryDirectory(dir=ROOT.parent) as d:
   base=Path(d);repo=base/'repository';shutil.copytree(ROOT/'data/scripts',repo/'data/scripts');shutil.copy2(ROOT/'pzm',repo/'pzm')
   runtime=base/'runtime';runtime.mkdir(mode=0o700);state=runtime/'pzmanager';state.mkdir(mode=0o700)
   logs=repo/'logs/zomboid';logs.mkdir(parents=True);world=repo/'Zomboid';world.mkdir()
   bin=base/'bin';bin.mkdir();calls=base/'calls';calls.touch();status=base/'state';status.write_text('active')
   inv='a'*32
   (state/'stallwatch.state').write_text(f'123 42 1999 0 {inv} 123 1000000\n')
   (repo/'.env').write_text('PZ_PROMETHEUS_PORT=1\nDISCORD_WEBHOOK=\nDISCORD_ADMIN_WEBHOOK=\n')
   def command(name,text):
    p=bin/name;p.write_text(text);p.chmod(0o700)
   command('systemctl', '''#!/usr/bin/python3
import os,sys
from pathlib import Path
p=Path(os.environ['REPRO_STATE']);state=p.read_text();args=sys.argv[1:]
with open(os.environ['REPRO_CALLS'],'a') as f:f.write(repr(args)+'\\n')
if 'is-active' in args:sys.exit(0 if state=='active' else 3)
if 'kill' in args:
 if os.environ['REPRO_MODE']=='kill-fails':sys.exit(1)
 p.write_text('inactive' if os.environ['REPRO_MODE']=='inactive' else 'failed');sys.exit(0)
if 'start' in args:p.write_text('active');sys.exit(0)
if state!='active' and os.environ['REPRO_MODE']=='bus-fails':sys.exit(1)
fields=dict(LoadState='loaded',ActiveState=state,SubState='running' if state=='active' else 'failed',Result='success' if state=='active' else 'signal',MainPID='123' if state=='active' else '0',ControlPID='0',InvocationID='a'*32,ControlGroup='/user.slice/user-1005.slice/user@1005.service/pz.slice/zomboid.service',ActiveEnterTimestampMonotonic='1000000',ActiveEnterTimestamp='2026-10-25 06:00:00 UTC')
mode=os.environ['REPRO_MODE']
if mode.startswith('fallback'):fields['InvocationID']=''
if state!='active':
 if mode=='alive':fields['MainPID']='123'
 if mode=='control':fields['ControlPID']='55'
 if mode=='unloaded':fields['LoadState']='not-found'
 if mode=='fallback-changed':fields['ActiveEnterTimestampMonotonic']='2000000'
 if mode=='fallback-unknown':fields['ActiveEnterTimestampMonotonic']='0'
 if mode=='delayed':
  wait=Path(os.environ['REPRO_COUNT']+'-wait');n=int(wait.read_text())+1 if wait.exists() else 1;wait.write_text(str(n))
  if n<3:fields['MainPID']='123'
 if mode=='new-invocation':fields.update(InvocationID='b'*32,MainPID='456',ActiveState='active')
if '--value' in args:
 print(fields.get(args[args.index('-p')+1],''));sys.exit(0)
for k,v in fields.items():print(k+'='+v)
''')
   command('python3','''#!/bin/bash
if [[ "$1" == */service_process.py ]]; then echo 123; else exec /usr/bin/python3 "$@"; fi
''')
   command('journalctl','''#!/bin/bash
printf '%s\n' '{"__REALTIME_TIMESTAMP":"2000000000","MESSAGE":"LOG : General f:42 st:1> fixture"}'
''')
   command('curl','''#!/bin/bash
echo 'game{parameter="players"} 1'
''')
   command('top','#!/bin/bash\nexit 0\n')
   command('sleep','#!/bin/bash\nexit 0\n')
   command('jcmd','''#!/usr/bin/python3
import os
from pathlib import Path
p=Path(os.environ['REPRO_COUNT']);n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
print('"main" #1 prio=5 cpu=%d.00ms elapsed=%d.00s tid=0x2 nid=0x2 runnable [0x0]'%(100000+n*10000,100+n*10))
''')
   env=dict(os.environ,PATH=str(bin)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(runtime),REPRO_STATE=str(status),REPRO_CALLS=str(calls),REPRO_COUNT=str(base/'count'),REPRO_MODE=mode)
   p=subprocess.run(['bash',str(repo/'data/scripts/internal/watchServerStall.sh')],env=env,text=True,capture_output=True,timeout=20)
   return p,status.read_text(),calls.read_text()
 def test_killed_failed_and_inactive_services_start_through_real_dispatcher(self):
  for mode in ('failed','inactive','delayed','fallback'):
   with self.subTest(mode=mode):
    result,state,calls=self.run_recovery(mode)
    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    self.assertEqual(state,'active')
    self.assertTrue(any("'start'" in line for line in calls.splitlines()),calls)
    self.assertFalse(any("'stop'" in line or "'restart'" in line for line in calls.splitlines()),calls)
 def test_unproven_kill_or_stop_or_replaced_identity_never_starts(self):
  for mode in ('kill-fails','alive','control','bus-fails','new-invocation','unloaded','fallback-changed','fallback-unknown'):
   with self.subTest(mode=mode):
    result,state,calls=self.run_recovery(mode)
    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
    self.assertFalse(any("'start'" in line for line in calls.splitlines()),calls)

if __name__=='__main__':os.umask(0o077);unittest.main()
