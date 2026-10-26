"""A CLI handoff must not start a different resolved native configuration."""
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import unittest
import test_native_configuration as native
from startup_bus_fixture import write_busctl


class NativeHandoffConfiguration(unittest.TestCase):
    def fixture(self):
        case=native.NativeConfiguration();case.setUp();self.addCleanup(case.doCleanups)
        shutil.copy2(native.ROOT/'pzm',case.repo/'pzm')
        case.other=case.repo/'Zomboid';shutil.copytree(case.world,case.other)
        for world,name in ((case.world,'cli-sentinel'),(case.other,'unit-sentinel')):
            with closing(sqlite3.connect(world/'db'/(case.name+'.db'))) as db:
                db.execute('UPDATE whitelist SET username=?',(name,));db.commit()
        state=case.base/'unit-state.json'
        state.write_text(json.dumps(dict(ActiveState='inactive',SubState='dead',MainPID=0,ControlPID=0)))
        case.env.update(HANDOFF_STATE=str(state),HANDOFF_REPO=str(case.repo))
        write_busctl(case.bin,case.repo/'data/scripts/internal/startServer.sh','zomboid.service')
        case.executable(case.bin/'systemctl','''#!/usr/bin/env python3
import os,sys,json,subprocess
from pathlib import Path
args=sys.argv[1:];state=Path(os.environ['HANDOFF_STATE'])
if 'start' in args:
 state.write_text(json.dumps(dict(ActiveState='activating',SubState='start-pre',MainPID=0,ControlPID=os.getpid())))
 # A real systemd service does not inherit its client's PZ_* environment.
 env={k:v for k,v in os.environ.items() if not k.startswith('PZ_')}
 repo=Path(env['HANDOFF_REPO'])
 for argv in ([str(repo/'data/scripts/internal/startServer.sh'),'--check'],[str(repo/'data/scripts/internal/prepareWorldStart.sh')],[str(repo/'data/scripts/internal/startServer.sh')]):
  result=subprocess.run(argv,env=env)
  if result.returncode:sys.exit(result.returncode)
 state.write_text(json.dumps(dict(ActiveState='active',SubState='running',MainPID=1234,ControlPID=0)));sys.exit(0)
if 'show' in args:
 for k,v in json.loads(state.read_text()).items():print(k+'='+str(v))
 sys.exit(0)
sys.exit(89)
''')
        return case

    def snapshot(self,case):
        return {(str(world),str(path.relative_to(world))):path.read_bytes()
                for world in (case.world,case.other) for path in world.rglob('*') if path.is_file()}

    def start(self,case):
        return subprocess.run(['bash',str(case.repo/'pzm'),'server','start'],env=case.env,
                              capture_output=True,text=True,timeout=20)

    def test_inherited_cli_source_refuses_before_either_world_changes(self):
        case=self.fixture();case.values.pop('PZ_SOURCE_DIR');case.write_env()
        case.env['PZ_SOURCE_DIR']=str(case.world)
        # The inherited channel remains valid for offline tools on the intended A.
        result=subprocess.run(['bash',str(case.repo/'data/scripts/admin/purgeInactivePlayers.sh')],
                              env=case.env,capture_output=True,text=True,timeout=12)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        with closing(sqlite3.connect(case.db)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM whitelist').fetchone()[0],0)
        before=self.snapshot(case)
        result=self.start(case)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('configuration',result.stderr)
        self.assertEqual(self.snapshot(case),before)
        self.assertFalse(case.capture.exists(),'native game ran despite a different cachedir')

    def test_explicit_shared_configuration_starts_only_the_configured_world(self):
        case=self.fixture();before=self.snapshot(case)
        result=self.start(case)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Open=false',case.ini.read_text())
        with closing(sqlite3.connect(case.db)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM whitelist').fetchone()[0],0)
        for path in case.other.rglob('*'):
            if path.is_file():self.assertEqual(path.read_bytes(),before[(str(case.other),str(path.relative_to(case.other)))])
        self.assertEqual(json.loads(case.capture.read_text())['argv'],
                         ['-cachedir='+str(case.world),'-servername',case.name])


    def test_same_invalid_cli_and_service_identity_is_refused(self):
        for variant in ('name','source-space','source-token'):
            with self.subTest(variant=variant):
                case=self.fixture()
                field='PZ_SERVER_NAME' if variant=='name' else 'PZ_SOURCE_DIR'
                value=case.name+' ' if variant=='name' else str(case.world)+' ' if variant=='source-space' else str(case.base/'-cachedir=world')
                targets=case.identity_targets(field,value)|{case.other};before=case.identity_image(targets)
                case.env[field]=value
                result=self.start(case)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(field,result.stderr);self.assertIn('native',result.stderr)
                self.assertEqual(case.identity_image(targets),before);self.assertFalse(case.capture.exists())
                self.assertEqual(json.loads(Path(case.env['HANDOFF_STATE']).read_text())['ActiveState'],'inactive')


if __name__=='__main__':unittest.main()
