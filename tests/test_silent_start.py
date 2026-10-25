"""Silent starts through real pz, broker handoff and a separate ready notifier."""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import unittest
from startup_bus_fixture import write_busctl

ROOT=Path(os.environ['PZ_TEST_ROOT'])
A='a'*32
B='b'*32
C='c'*32

class SilentStart(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=ROOT.parent);self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.repo=self.base/'repo'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        self.bin=self.base/'bin';self.bin.mkdir()
        write_busctl(self.bin,self.repo/'data/scripts/internal/startServer.sh','zomboid.service')
        self.runtime=self.base/'runtime';self.runtime.mkdir(mode=0o700)
        self.world=self.base/'world';self.world.mkdir()
        self.state=self.base/'state';self.sent=self.base/'sent';self.events=self.base/'events'
        self.write_state('inactive',A)
        envfile=dict(PZ_HOME=str(self.base),PZ_SOURCE_DIR=str(self.world),PZ_CONTROL_PIPE=str(self.base/'absent-fifo'),DISCORD_WEBHOOK='https://discord.invalid/fixture')
        (self.repo/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in envfile.items())+'\n')
        self.executable(self.repo/'data/scripts/internal/sendDiscord.sh','#!/bin/bash\nprintf "%s\\n" "$*" >> "$SILENT_TEST_SENT"\n')
        self.executable(self.repo/'data/scripts/internal/sendCommand.sh','#!/bin/bash\necho "Players connected (0)"\n')
        self.executable(self.repo/'data/scripts/backup/dataBackup.sh','#!/bin/bash\nexit 0\n')
        self.executable(self.bin/'sleep','#!/bin/bash\nexit 0\n')
        self.executable(self.bin/'journalctl','#!/bin/bash\necho "LOG : General f:42 t:123 st:456> ready"\n')
        self.executable(self.bin/'systemctl', '''#!/usr/bin/env python3
import json,os,subprocess,sys,signal
from pathlib import Path
path=Path(os.environ['SILENT_TEST_STATE']);state=json.loads(path.read_text());args=sys.argv[1:]
if 'is-active' in args:sys.exit(0 if state['ActiveState']=='active' else 3)
if 'stop' in args:
 state.update(ActiveState='inactive',MainPID='0',ControlPID='0',SubState='dead');path.write_text(json.dumps(state));sys.exit(0)
if 'start' in args:
 if state['ActiveState']=='active':sys.exit(0)
 mode=os.environ.get('SILENT_TEST_MODE','normal')
 if mode=='fail-before':sys.exit(7)
 if mode=='kill-before':os.kill(os.getppid(),signal.SIGKILL);sys.exit(7)
 iid=os.environ.get('SILENT_TEST_NEXT','b'*32)
 state.update(ActiveState='activating',MainPID='0',ControlPID=str(os.getpid()),SubState='start-pre',InvocationID=iid);path.write_text(json.dumps(state))
 root=Path(os.environ['SILENT_TEST_REPO']);helper=root/'data/scripts/internal/writing_start_admission.py'
 env=dict(os.environ,INVOCATION_ID=os.environ.get('SILENT_TEST_INVOCATION',iid))
 command=[sys.executable,str(helper),'run','--lock-path',str(Path(env['XDG_RUNTIME_DIR'])/'pzmanager/world.lock'),'--unit','zomboid.service','--',sys.executable,'-c','import sys;sys.path.insert(0,sys.argv[1]);from writing_start_admission import validate_worker_admission;validate_worker_admission()',str(helper.parent)]
 result=subprocess.run(command,env=env)
 if result.returncode:sys.exit(result.returncode)
 if mode=='fail-after':
  state.update(ActiveState='failed',MainPID='0',ControlPID='0',SubState='failed');path.write_text(json.dumps(state));sys.exit(7)
 if mode=='kill-after':os.kill(os.getppid(),signal.SIGKILL)
 state.update(ActiveState='active',MainPID='1234',ControlPID='0',SubState='running');path.write_text(json.dumps(state))
 if mode!='kill-after':subprocess.run(['bash',str(root/'data/scripts/internal/notifyServerReady.sh')],env=env)
 sys.exit(0)
if '--value' in args:
 if 'ActiveEnterTimestamp' in args or 'ExecMainStartTimestamp' in args:print('2026-10-25 00:00:00 UTC')
 else:print(state['InvocationID'])
elif any(arg.startswith('--property=') for arg in args):
 for key in ('ActiveState','SubState','MainPID','ControlPID'):print(key+'='+state[key])
else:
 for key,value in state.items():print(key+'='+value)
''')
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(self.runtime),SILENT_TEST_REPO=str(self.repo),SILENT_TEST_STATE=str(self.state),SILENT_TEST_SENT=str(self.sent),PZ_NOTIFY_READY_TIMEOUT='2',PZ_NOTIFY_READY_POLL_INTERVAL='1')
    def executable(self,path,text):path.write_text(text);path.chmod(0o700)
    def write_state(self,active,iid):
        self.state.write_text(json.dumps(dict(LoadState='loaded',ActiveState=active,SubState='running' if active=='active' else 'dead',MainPID='1234' if active=='active' else '0',ControlPID='0',InvocationID=iid)))
    def cli(self,*args):return subprocess.run(['bash',str(self.repo/'data/scripts/core/pz.sh'),*args],env=self.env,capture_output=True,text=True,timeout=12)
    def notify(self,iid):return subprocess.run(['bash',str(self.repo/'data/scripts/internal/notifyServerReady.sh')],env=dict(self.env,INVOCATION_ID=iid),capture_output=True,text=True,timeout=6)
    def ready_messages(self):return [line for line in self.sent.read_text().splitlines() if 'en ligne' in line] if self.sent.exists() else []
    def test_silent_start_and_duplicate_notifier_suppress_only_current_boot(self):
        result=self.cli('start','--silent')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.ready_messages(),[])
        self.assertEqual(self.notify(B).returncode,0)
        self.assertEqual(self.ready_messages(),[])
        self.write_state('active',C)
        result=self.notify(C);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len(self.ready_messages()),1)
    def test_silent_restart_is_bound_to_new_invocation(self):
        self.write_state('active',A)
        result=self.cli('restart','now','--silent')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.ready_messages(),[])
    def test_cli_silence_also_consumes_maintenance_marker_for_same_boot(self):
        flags=self.repo/'logs';flags.mkdir(parents=True,exist_ok=True)
        marker=flags/'.silent_next_start';marker.touch()
        result=self.cli('start','--silent')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(marker.exists());self.assertEqual(self.ready_messages(),[])
        self.write_state('active',C)
        result=self.notify(C);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len(self.ready_messages()),1)
    def test_silent_noop_active_does_not_suppress_that_or_next_boot(self):
        self.write_state('active',A)
        result=self.cli('start','--silent');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.notify(A).returncode,0)
        self.assertEqual(len(self.ready_messages()),1)
        self.write_state('active',B);self.assertEqual(self.notify(B).returncode,0)
        self.assertEqual(len(self.ready_messages()),2)
    def test_silent_failed_start_before_and_after_admission_does_not_leak(self):
        for mode in ('fail-before','fail-after'):
            with self.subTest(mode=mode):
                self.write_state('inactive',A);self.env['SILENT_TEST_MODE']=mode
                result=self.cli('start','--silent');self.assertEqual(result.returncode,7,result.stdout+result.stderr)
                self.assertFalse(list(self.runtime.glob('pzmanager/writing-start.json')))
                self.write_state('active',C if mode=='fail-before' else A)
                iid=json.loads(self.state.read_text())['InvocationID']
                before=len(self.ready_messages());self.assertEqual(self.notify(iid).returncode,0)
                self.assertEqual(len(self.ready_messages()),before+1)
    def test_caller_sigkill_before_and_after_admission_does_not_silence_next_boot(self):
        for mode,iid in [('kill-before',B),('kill-after',C)]:
            with self.subTest(mode=mode):
                self.write_state('inactive',A);self.env['SILENT_TEST_MODE']=mode
                self.env['SILENT_TEST_NEXT']=iid
                before=len(self.ready_messages())
                result=self.cli('start','--silent');self.assertEqual(result.returncode,-signal.SIGKILL,result.stdout+result.stderr)
                if mode=='kill-after':
                    self.assertEqual(self.notify(iid).returncode,0)
                    self.assertEqual(len(self.ready_messages()),before)
                next_iid=A if iid==C else C
                self.write_state('active',next_iid)
                before=len(self.ready_messages());self.assertEqual(self.notify(next_iid).returncode,0)
                self.assertEqual(len(self.ready_messages()),before+1)
    def test_silent_admission_requires_matching_valid_invocation(self):
        for invocation in ('', 'not-an-id', A):
            with self.subTest(invocation=invocation):
                self.write_state('inactive', A)
                self.env['SILENT_TEST_INVOCATION']=invocation
                result=self.cli('start','--silent')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Silent readiness requires',result.stderr)
                self.assertFalse(list(self.runtime.glob('pzmanager/*.silent')))
    def test_ready_refuses_symlink_or_public_silent_marker(self):
        self.write_state('active',B)
        private=self.runtime/'pzmanager';private.mkdir(mode=0o700)
        marker=private/('notify-ready-'+B+'.silent')
        outside=self.base/'outside';outside.write_text('preserved')
        marker.symlink_to(outside)
        result=self.notify(B);self.assertNotEqual(result.returncode,0)
        self.assertEqual(outside.read_text(),'preserved');self.assertEqual(self.ready_messages(),[])
        marker.unlink();marker.write_text('');marker.chmod(0o644)
        result=self.notify(B);self.assertNotEqual(result.returncode,0)
        self.assertTrue(marker.exists());self.assertEqual(self.ready_messages(),[])

if __name__=='__main__':
    os.umask(0o077);unittest.main()
