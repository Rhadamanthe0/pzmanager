#!/usr/bin/env python3
"""Real maintenance entrypoint/state/trap; package, game and reboot boundaries stubbed."""
import json
import os
from pathlib import Path
import shlex
import sqlite3
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(os.environ['PZ_TEST_ROOT'])

class MaintenanceRecovery(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='maintenance-recovery-',dir=ROOT.parent)
        self.base=Path(self.tmp.name);self.repo=self.base/'repository'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        self.runtime=self.base/'runtime';self.runtime.mkdir(mode=0o700)
        self.bin=self.base/'bin';self.bin.mkdir()
        self.game=self.base/'game';self.game.mkdir()
        self.java=self.base/'java';self.java.mkdir()
        self.world=self.base/'world';self.world.mkdir()
        self.state=self.base/'maintenance.state';self.events=self.base/'events.jsonl'
        self.notes=self.base/'notifications'
        self.events.touch()
        self.executable(self.bin/'sudo', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
state=Path(os.environ['PZ_MAINT_STATE_FILE'])
with open(os.environ['MAINT_TEST_EVENTS'],'a') as out:
 out.write(json.dumps(dict(kind='sudo',args=sys.argv[1:],state=state.read_text().strip() if state.exists() else None,armed=Path(str(state)+'.recovery_armed').exists()))+'\\n')
sys.exit(int(os.environ.get('MAINT_TEST_REBOOT_RC','0')) if sys.argv[1:] and sys.argv[1]=='/sbin/reboot' else 0)
''')
        self.executable(self.repo/'data/scripts/core/pz.sh', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
state=Path(os.environ['PZ_MAINT_STATE_FILE']);events=Path(os.environ['MAINT_TEST_EVENTS'])
starts=sum(e['kind']=='pz' and e['args'][0]=='start' for e in map(json.loads,events.read_text().splitlines())) if events.exists() else 0
with events.open('a') as out:out.write(json.dumps(dict(kind='pz',args=sys.argv[1:],state=state.read_text().strip() if state.exists() else None,armed=Path(str(state)+'.recovery_armed').exists()))+'\\n')
sys.exit(int(os.environ.get('MAINT_TEST_FIRST_START_RC','0')) if sys.argv[1]=='start' and starts==0 else 0)
''')
        for relative in ('internal/linkJvm.sh','internal/configureJvm.sh','backup/fullBackup.sh'):
            self.executable(self.repo/'data/scripts'/relative,'#!/bin/bash\nexit 0\n')
        self.executable(self.bin/'steamcmd','#!/bin/bash\nexit 0\n')
        self.executable(self.bin/'pgrep','#!/bin/bash\nexit "${MAINT_TEST_JVM_RC:-0}"\n')
        self.executable(self.bin/'systemctl', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if os.environ.get('MAINT_TEST_BUS_REFUSED')=='1':sys.exit(1)
path=Path(os.environ['MAINT_TEST_SERVER_STATE']) if os.environ.get('MAINT_TEST_SERVER_STATE') else None
state=json.loads(path.read_text()) if path else dict(LoadState='loaded',ActiveState='active' if os.environ.get('MAINT_TEST_ACTIVE','1')=='1' else 'inactive',SubState='running',MainPID='1234',ControlPID='0',InvocationID='fixture')
args=sys.argv[1:]
if 'is-active' in args:sys.exit(0 if state['ActiveState']=='active' else 3)
for action in ('stop','start'):
 if action in args:
  with open(os.environ['MAINT_TEST_EVENTS'],'a') as out:out.write(json.dumps(dict(kind='service',action=action))+'\\n')
  if action=='start' and os.environ.get('MAINT_TEST_REAL_START_RC'):sys.exit(int(os.environ['MAINT_TEST_REAL_START_RC']))
  state.update(ActiveState='inactive' if action=='stop' else 'active',MainPID='0' if action=='stop' else '1234',ControlPID=os.environ.get('MAINT_TEST_STOP_CONTROL_PID','0') if action=='stop' else '0',SubState='dead' if action=='stop' else 'running')
  path.write_text(json.dumps(state));sys.exit(0)
keys=('ActiveState','SubState','MainPID','ControlPID') if any(a.startswith('--property=') for a in args) else tuple(state)
for key in keys:print(key+'='+str(state[key]))
''')
        # Game readiness/notifications are external service boundaries. The
        # production main, EXIT trap, filesystem state and all locks stay real.
        common=self.repo/'data/scripts/lib/common.sh'
        with common.open('a') as out:
            out.write('\nnotify() { printf "%s\\n" "$*" >> "$MAINT_TEST_NOTES"; }\nwait_for_server_ready() { if [[ "$0" == */core/pz.sh ]]; then return "${MAINT_TEST_STOP_READY_RC:-0}"; fi; return "${MAINT_TEST_READY_RC:-0}"; }\n')
        vals=dict(PZ_HOME=str(self.base),PZ_SOURCE_DIR=str(self.world),PZ_INSTALL_DIR=str(self.game),JAVA_PATH=str(self.java),STEAMCMD_PATH=str(self.bin/'steamcmd'),PZ_MAINT_SELF_UPDATE='0')
        (self.repo/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in vals.items())+'\n')
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(self.runtime),PZ_MAINT_STATE_FILE=str(self.state),MAINT_TEST_EVENTS=str(self.events),MAINT_TEST_NOTES=str(self.notes))
    def tearDown(self):self.tmp.cleanup()
    def executable(self,path,text):path.write_text(text);path.chmod(0o700)
    def invoke(self,*args):
        return subprocess.run(['bash',str(self.repo/'data/scripts/admin/performFullMaintenance.sh'),'now',*args],env=self.env,capture_output=True,text=True,timeout=20)
    def recorded(self):return [json.loads(line) for line in self.events.read_text().splitlines()]
    def assert_failure_recovered(self,p,code,expected_starts):
        self.assertEqual(p.returncode,code,p.stdout+p.stderr)
        self.assertEqual(self.state.read_text().strip(),'FAILED',p.stdout+p.stderr)
        self.assertTrue(Path(str(self.state)+'.recovery_armed').exists())
        starts=[event for event in self.recorded() if event['kind']=='pz' and event['args'][0]=='start']
        self.assertEqual(len(starts),expected_starts,p.stdout+p.stderr)
        self.assertIn('Reprise après échec de la maintenance',starts[-1]['args'])
        self.assertTrue(starts[-1]['armed'])
        self.assertEqual(starts[-1]['state'],'FAILED')
        logs=list((self.repo/'logs/maintenance').glob('*.log'))
        self.assertEqual(len(logs),1,p.stdout+p.stderr)
        self.assertIn('ÉCHEC de la maintenance',logs[0].read_text())
    def messages(self):
        return self.notes.read_text() if self.notes.exists() else ''
    def real_stop_backup_chain(self):
        shutil.copy2(ROOT/'data/scripts/core/pz.sh',self.repo/'data/scripts/core/pz.sh')
        state=self.base/'service.json'
        state.write_text(json.dumps(dict(LoadState='loaded',ActiveState='active',SubState='running',MainPID='1234',ControlPID='0',InvocationID='fixture')))
        self.env.update(MAINT_TEST_SERVER_STATE=str(state),PZ_BACKUP_CPU_SCOPED='1')
        self.executable(self.bin/'sleep','#!/bin/bash\nexit 0\n')
        self.executable(self.repo/'data/scripts/internal/sendCommand.sh','#!/bin/bash\necho "Players connected (0)"\n')
        self.executable(self.bin/'rsync','''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['MAINT_TEST_EVENTS'],'a') as out:out.write(json.dumps(dict(kind='rsync',code=23))+'\\n')
sys.exit(23)
''')
        (self.world/'db').mkdir()
        with sqlite3.connect(self.world/'db/servertest.db') as db:db.execute('CREATE TABLE fixture(value TEXT)')
        return state
    def test_backup_failure_after_real_stop_recovers(self):
        state=self.real_stop_backup_chain()
        p=self.invoke('--no-reboot')
        events=self.recorded()
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertTrue(any(e['kind']=='rsync' and e['code']==23 for e in events),p.stdout+p.stderr)
        self.assertEqual([e['action'] for e in events if e['kind']=='service'],['stop','start'],p.stdout+p.stderr)
        self.assertEqual(json.loads(state.read_text())['ActiveState'],'active')
        self.assertEqual(self.state.read_text().strip(),'FAILED')
        self.assertTrue(Path(str(self.state)+'.recovery_armed').exists())
        self.assertIn('prêt',self.messages())
    def test_boot_stop_refusal_does_not_start_recovery(self):
        state=self.real_stop_backup_chain();self.env['MAINT_TEST_STOP_READY_RC']='1'
        p=self.invoke('--no-reboot')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Arrêt annulé',p.stdout)
        self.assertFalse([e for e in self.recorded() if e['kind'] in {'service','rsync'}])
        self.assertEqual(json.loads(state.read_text())['ActiveState'],'active')
        self.assertNotIn('serveur a été redémarré',self.messages())
    def test_bus_refusal_does_not_start_recovery(self):
        self.real_stop_backup_chain();self.env['MAINT_TEST_BUS_REFUSED']='1'
        p=self.invoke('--no-reboot')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertFalse([e for e in self.recorded() if e['kind']=='service'])
        self.assertNotIn('serveur a été redémarré',self.messages())
    def test_ambiguous_post_stop_pid_blocks_recovery(self):
        state=self.real_stop_backup_chain();self.env['MAINT_TEST_STOP_CONTROL_PID']='999'
        p=self.invoke('--no-reboot')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        events=self.recorded()
        self.assertTrue(any(e['kind']=='rsync' and e['code']==23 for e in events),p.stdout+p.stderr)
        self.assertEqual([e['action'] for e in events if e['kind']=='service'],['stop'])
        self.assertEqual(json.loads(state.read_text())['ControlPID'],'999')
        self.assertIn('reprise refusée',self.messages())
    def test_interrupted_validated_recovery_resumes_then_disarms(self):
        self.state.write_text('SELF\n');Path(str(self.state)+'.recovery_armed').touch()
        p=self.invoke('--no-reboot')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        calls=[e['args'][0] for e in self.recorded() if e['kind']=='pz']
        self.assertEqual(calls,['start','stop','start'])
        self.assertIn('Maintenance précédente interrompue (SELF) — serveur prêt',self.messages())
        self.assertEqual(self.state.read_text().strip(),'DONE')
        self.assertFalse(Path(str(self.state)+'.recovery_armed').exists())
    def test_failed_rescue_start_never_claims_restarted(self):
        self.env.update(MAINT_TEST_REBOOT_RC='7',MAINT_TEST_FIRST_START_RC='7')
        p=self.invoke()
        self.assert_failure_recovered(p,7,1)
        self.assertIn('échec',self.messages())
        self.assertNotIn('a été redémarré',self.messages())
        self.assertNotIn('serveur prêt',self.messages())
    def test_failed_rescue_readiness_never_claims_ready(self):
        self.env.update(MAINT_TEST_REBOOT_RC='7',MAINT_TEST_READY_RC='1')
        p=self.invoke()
        self.assert_failure_recovered(p,7,1)
        self.assertIn('non vérifiée',self.messages())
        self.assertNotIn('a été redémarré',self.messages())
        self.assertNotIn('serveur prêt',self.messages())
    def test_interrupted_start_failure_stops_maintenance_honestly(self):
        self.state.write_text('SELF\n');Path(str(self.state)+'.recovery_armed').touch()
        self.env['MAINT_TEST_FIRST_START_RC']='7'
        p=self.invoke()
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.state.read_text().strip(),'FAILED')
        calls=[e for e in self.recorded() if e['kind']=='pz']
        self.assertEqual(len(calls),1,p.stdout+p.stderr)
        self.assertEqual(calls[0]['args'][0],'start')
        self.assertNotIn('serveur redémarré',self.messages())
        self.assertIn('échec',self.messages())
    def test_interrupted_ready_failure_stops_maintenance_honestly(self):
        self.state.write_text('SELF\n');Path(str(self.state)+'.recovery_armed').touch()
        self.env['MAINT_TEST_READY_RC']='1'
        p=self.invoke()
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.state.read_text().strip(),'FAILED')
        self.assertIn('non vérifiée',self.messages())
        self.assertNotIn('serveur redémarré',self.messages())
    def test_pending_world_blocks_rescue_before_start(self):
        staging=self.base/'staging';staging.mkdir()
        record=subprocess.run(['python3',str(self.repo/'data/scripts/lib/world_transaction.py'),'begin','--world',str(self.world),'--kind','fixture','--recovery',str(self.base/'recovery'),'--after-tree',str(staging)],env=self.env,capture_output=True,text=True)
        self.assertEqual(record.returncode,0,record.stderr)
        self.env['MAINT_TEST_REBOOT_RC']='7'
        p=self.invoke()
        self.assertEqual(p.returncode,7,p.stdout+p.stderr)
        self.assertFalse([e for e in self.recorded() if e['kind']=='pz' and e['args'][0]=='start'],p.stdout+p.stderr)
        self.assertIn('unfinished',p.stdout+p.stderr)
        self.assertTrue(Path(str(self.state)+'.recovery_armed').exists())
    def test_reboot_refusal_recovers_and_preserves_failure_state(self):
        self.env['MAINT_TEST_REBOOT_RC']='7'
        p=self.invoke()
        self.assert_failure_recovered(p,7,1)
        reboot=[e for e in self.recorded() if e['kind']=='sudo' and e['args']==['/sbin/reboot']]
        self.assertEqual(len(reboot),1)
        self.assertEqual(reboot[0]['state'],'SELF');self.assertTrue(reboot[0]['armed'])
    def test_accepted_reboot_disarms_after_command_without_rescue(self):
        p=self.invoke()
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        reboot=[e for e in self.recorded() if e['kind']=='sudo' and e['args']==['/sbin/reboot']]
        self.assertEqual(len(reboot),1)
        self.assertEqual(reboot[0]['state'],'SELF');self.assertTrue(reboot[0]['armed'])
        self.assertEqual(self.state.read_text().strip(),'DONE')
        self.assertFalse(Path(str(self.state)+'.recovery_armed').exists())
        self.assertFalse([e for e in self.recorded() if e['kind']=='pz' and e['args'][0]=='start'])
    def test_service_start_failure_recovers(self):
        self.env['MAINT_TEST_FIRST_START_RC']='9'
        p=self.invoke('--no-reboot')
        self.assert_failure_recovered(p,9,2)
    def test_service_validation_failure_recovers(self):
        self.env['MAINT_TEST_READY_RC']='1'
        p=self.invoke('--no-reboot')
        self.assert_failure_recovered(p,1,2)
    def test_service_validated_start_disarms_without_rescue(self):
        p=self.invoke('--no-reboot')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.state.read_text().strip(),'DONE')
        self.assertFalse(Path(str(self.state)+'.recovery_armed').exists())
        starts=[e for e in self.recorded() if e['kind']=='pz' and e['args'][0]=='start']
        self.assertEqual(len(starts),1)
        self.assertTrue(starts[0]['armed']);self.assertEqual(starts[0]['state'],'SELF')

if __name__=='__main__':
    os.umask(0o077);unittest.main()
