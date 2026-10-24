#!/usr/bin/env python3
"""Real maintenance entrypoint/state/trap; package, game and reboot boundaries stubbed."""
import json
import os
from pathlib import Path
import shlex
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
        self.executable(self.bin/'systemctl','#!/bin/bash\n[[ "${MAINT_TEST_ACTIVE:-1}" == 1 ]]\n')
        # Game readiness/notifications are external service boundaries. The
        # production main, EXIT trap, filesystem state and all locks stay real.
        common=self.repo/'data/scripts/lib/common.sh'
        with common.open('a') as out:
            out.write('\nnotify() { return 0; }\nwait_for_server_ready() { return "${MAINT_TEST_READY_RC:-0}"; }\n')
        vals=dict(PZ_HOME=str(self.base),PZ_SOURCE_DIR=str(self.world),PZ_INSTALL_DIR=str(self.game),JAVA_PATH=str(self.java),STEAMCMD_PATH=str(self.bin/'steamcmd'),PZ_MAINT_SELF_UPDATE='0')
        (self.repo/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in vals.items())+'\n')
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(self.runtime),PZ_MAINT_STATE_FILE=str(self.state),MAINT_TEST_EVENTS=str(self.events))
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
