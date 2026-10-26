"""One config for native launch, startup workers and readonly heap preflight."""
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from test_reset_wipe_safety import VENDOR_WRAPPER
from startup_bus_fixture import write_busctl

ROOT = Path(os.environ['PZ_TEST_ROOT'])
GROUP = '/user.slice/user-1005.slice/user@1005.service/pz.slice'


class NativeConfiguration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT.parent)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base/'home'
        self.repo = self.home/'pzmanager'
        shutil.copytree(ROOT/'data/scripts', self.repo/'data/scripts')
        shutil.copytree(ROOT/'data/setupTemplates', self.repo/'data/setupTemplates')
        self.world = self.base/"world'世界"
        self.game = self.base/'configured game'
        self.default_game = self.repo/'data/pzserver'
        self.name = 'configured-world'
        self.ini = self.world/'Server'/(self.name+'.ini')
        self.db = self.world/'db'/(self.name+'.db')
        self.ini.parent.mkdir(parents=True)
        self.ini.write_text('Open=true\nMods=\n')
        self.db.parent.mkdir()
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript("CREATE TABLE whitelist(id INTEGER PRIMARY KEY,username TEXT,steamid TEXT,lastConnection TEXT); CREATE TABLE allowedsteamid(steamid TEXT); INSERT INTO whitelist VALUES(1,'old',NULL,'2000-01-01');")
        self.capture = self.base/'capture.json'
        for game in (self.game,self.default_game):
            game.mkdir(parents=True)
            (game/'ProjectZomboid64.json').write_text(json.dumps({'vmArgs':['-Xmx8g']}))
            self.executable(game/'ProjectZomboid64', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
data={'argv':sys.argv[1:],'file':__file__,'cwd':os.getcwd()}
if os.environ.get('CAPTURE_FD'):
 fd=os.environ['CAPTURE_FD'];data['fdinfo']=Path('/proc/self/fdinfo/'+fd).read_text()
Path(os.environ['CAPTURE_FILE']).write_text(json.dumps(data))
''')
            java=game/'jre64/bin/java';java.parent.mkdir(parents=True)
            self.executable(java,'#!/bin/sh\nexit 0\n')
            self.executable(game/'start-server.sh',VENDOR_WRAPPER)
            os.mkfifo(game/'zomboid.control',0o600)
        self.pipe = self.game/'zomboid.control'
        self.runtime = self.base/'runtime'
        self.runtime.mkdir(mode=0o700)
        self.bin = self.base/'bin'
        self.bin.mkdir()
        self.bus = self.base/'bus-called'
        self.executable(self.bin/'systemctl', '''#!/usr/bin/env python3
import os
from pathlib import Path
Path(os.environ['CAPTURE_BUS']).touch()
print('ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0')
''')
        self.values = dict(PZ_HOME=str(self.home),PZ_MANAGER_DIR=str(self.repo),
                           PZ_SOURCE_DIR=str(self.world),PZ_INSTALL_DIR=str(self.game),
                           PZ_CONTROL_PIPE=str(self.pipe),PZ_SERVER_NAME=self.name)
        self.write_env()
        self.env = dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],
                        XDG_RUNTIME_DIR=str(self.runtime),CAPTURE_FILE=str(self.capture),
                        CAPTURE_BUS=str(self.bus))
        # Substitute only physical cgroup files in the disposable helper copies.
        self.proc = self.base/'proc-cgroup'
        self.proc.write_text('0::'+GROUP+'/fixture.scope\n')
        self.cg = self.base/'cgroups'
        group = self.cg/GROUP.lstrip('/')/'fixture.scope'
        group.mkdir(parents=True)
        for parent in [group,*list(group.parents)[:len(group.relative_to(self.cg).parts)-1]]:
            (parent/'memory.max').write_text(str(20*1024**3))
        (group.parent/'memory.swap.max').write_text('0')
        (group.parent/'memory.current').write_text('0')
        for name in ('shared_memory_budget.py','jvm_memory_budget.py'):
            file=self.repo/'data/scripts/lib'/name
            text=file.read_text()
            # The runner may already have substituted the shared helper.
            original=(ROOT/'data/scripts/lib'/name).read_text()
            if name=='shared_memory_budget.py':
                import re
                text=re.sub(r'proc_cgroup=Path\([^\n]*?\), cgroup_root=Path\([^\n]*?\)',
                    'proc_cgroup=Path('+repr(str(self.proc))+'), cgroup_root=Path('+repr(str(self.cg))+')',original)
                text=re.sub(r'proc_cgroup=Path\([^\n]*?\)', 'proc_cgroup=Path('+repr(str(self.proc))+')',text)
                text=re.sub(r'cgroup_root=Path\([^\n]*?\)', 'cgroup_root=Path('+repr(str(self.cg))+')',text)
            else:
                text=text.replace('Path("/proc/self/cgroup")','Path('+repr(str(self.proc))+')').replace('Path("/sys/fs/cgroup")','Path('+repr(str(self.cg))+')')
            file.write_text(text)

    def executable(self,path,text):
        path.write_text(text);path.chmod(0o700)

    def write_env(self,extra=None):
        values={**self.values,**(extra or {})}
        (self.repo/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in values.items())+'\n')
        (self.repo/'.env').chmod(0o600)

    def command(self,key):
        lines=(ROOT/'data/setupTemplates/zomboid.service').read_text().splitlines()
        if key=='check':
            line=next(line for line in lines if line.startswith('ExecStartPre=') and
                      ('jvm_memory_budget.py check' in line or 'startServer.sh --check' in line))
        else:line=next(line for line in lines if line.startswith('ExecStart='))
        return shlex.split(line.split('=',1)[1].replace('%h',str(self.home)))

    def invoke(self,key,**kwargs):
        kwargs.setdefault('cwd',self.default_game)
        return subprocess.run(self.command(key),env=self.env,capture_output=True,text=True,timeout=12,**kwargs)

    def prepare(self):
        return subprocess.run(['bash',str(self.repo/'data/scripts/internal/prepareWorldStart.sh')],
                              env=self.env,capture_output=True,text=True,timeout=12)

    def test_native_launch_and_workers_use_the_same_custom_world_and_name(self):
        checked=self.invoke('check');self.assertEqual(checked.returncode,0,checked.stderr)
        prepared=self.prepare();self.assertEqual(prepared.returncode,0,prepared.stdout+prepared.stderr)
        self.assertIn('Open=false',self.ini.read_text())
        with closing(sqlite3.connect(self.db)) as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM whitelist').fetchone(),(0,))
        lock=self.base/'inherited.lock'
        with lock.open('w') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX)
            self.env['CAPTURE_FD']=str(stream.fileno())
            result=self.invoke('start',pass_fds=(stream.fileno(),))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        actual=json.loads(self.capture.read_text())
        self.assertEqual(Path(actual['file']),self.game/'ProjectZomboid64')
        self.assertEqual(Path(actual['cwd']),self.game)
        self.assertEqual(actual['argv'],['-cachedir='+str(self.world),'-servername',self.name])
        self.assertRegex(actual['fdinfo'],r'FLOCK\s+ADVISORY\s+WRITE')

    def test_conflicting_old_settings_refuse_before_world_or_database_mutation(self):
        outside=self.base/'external.ini';outside.write_text('Open=true\n')
        external_db=self.base/'external.db';shutil.copy2(self.db,external_db)
        for field,path in [('PZ_INI_PATH',outside),('PZ_DB_PATH',external_db)]:
            with self.subTest(field=field):
                self.write_env({field:str(path)})
                before=(self.ini.read_bytes(),self.db.read_bytes(),outside.read_bytes(),external_db.read_bytes())
                result=self.prepare()
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(field,result.stderr)
                self.assertEqual((self.ini.read_bytes(),self.db.read_bytes(),outside.read_bytes(),external_db.read_bytes()),before)
                self.assertFalse(self.capture.exists())

    def test_matching_old_derived_values_remain_compatible(self):
        self.write_env(dict(PZ_INI_PATH=str(self.ini),PZ_DB_PATH=str(self.db)))
        result=self.prepare();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Open=false',self.ini.read_text())

    def test_heap_check_uses_the_json_actually_launched(self):
        (self.game/'ProjectZomboid64.json').write_text(json.dumps({'vmArgs':['-Xmx20g']}))
        result=self.invoke('check')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(self.capture.exists())
        self.assertEqual(self.ini.read_text(),'Open=true\nMods=\n')

    def test_check_does_not_create_or_chmod_configuration_or_open_fifo_or_secret(self):
        config=self.repo/'.env';config.chmod(0o644)
        secret=self.repo/'.admin_password';secret.write_text('private-secret\n');secret.chmod(0o600)
        # Replacing the FIFO by a missing path makes accidental opening visible.
        self.pipe.unlink()
        before=(config.read_bytes(),config.stat().st_mode,config.stat().st_mtime_ns,secret.read_bytes(),secret.stat().st_mtime_ns)
        result=self.invoke('check');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((config.read_bytes(),config.stat().st_mode,config.stat().st_mtime_ns,secret.read_bytes(),secret.stat().st_mtime_ns),before)
        self.assertFalse(self.pipe.exists());self.assertFalse(self.capture.exists());self.assertFalse(self.bus.exists())
        config.unlink()
        result=self.invoke('check');self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(config.exists());self.assertFalse(self.capture.exists())

    def test_relative_launch_paths_are_refused_before_work(self):
        for field in ('PZ_SOURCE_DIR','PZ_INSTALL_DIR','PZ_CONTROL_PIPE'):
            with self.subTest(field=field):
                self.write_env({field:'relative-path'})
                result=self.invoke('check')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(field,result.stderr)
                self.assertFalse(self.capture.exists())

    def test_resource_migration_checks_effective_launcher_and_preflight_without_starting(self):
        if os.geteuid()==0:self.skipTest('resource migration is a manager-only command; normal run covers it')
        unit_dir=self.home/'.config/systemd/user';unit_dir.mkdir(parents=True)
        unit=unit_dir/'zomboid.service'
        template=(ROOT/'data/setupTemplates/zomboid.service').read_text()
        unit.write_text(template)
        write_busctl(self.bin,self.repo/'data/scripts/internal/startServer.sh','zomboid.service')
        events=self.base/'migration-events'
        self.env.update(HOME=str(self.home),STARTUP_TEST_UNIT_FILE=str(unit),MIGRATION_EVENTS=str(events))
        self.executable(self.bin/'systemctl','''#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MIGRATION_EVENTS'],'a') as out:out.write(' '.join(args)+'\\n')
if 'daemon-reload' in args:sys.exit(0)
if '-p' not in args:sys.exit(88)
prop=args[args.index('-p')+1]
if prop=='ActiveState':print('inactive')
elif prop=='Slice':print('pz.slice')
elif prop=='ExecStartPre':
 unit=Path(os.environ['STARTUP_TEST_UNIT_FILE'])
 print(' '.join(line.split('=',1)[1] for file in [unit,*sorted(Path(str(unit)+'.d').glob('*.conf'))] for line in file.read_text().splitlines() if line.startswith('ExecStartPre=')))
else:sys.exit(89)
''')
        command=['bash',str(self.repo/'data/scripts/install/setupSharedBudget.sh')]
        before=(self.ini.read_bytes(),self.db.read_bytes())
        result=subprocess.run(command,env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue((unit_dir/'zomboid.service.d/90-pz-shared-budget.conf').is_file())
        # A coincidental human token is not an actual readonly heap preflight.
        unit.write_text(template.replace('ExecStartPre=%h/pzmanager/data/scripts/internal/startServer.sh --check',
                                        'ExecStartPre=/bin/echo startServer.sh --check'))
        failed=subprocess.run(command,env=self.env,capture_output=True,text=True,timeout=15)
        self.assertNotEqual(failed.returncode,0,failed.stdout+failed.stderr)
        self.assertIn('Lanceur effectif',failed.stderr)
        self.assertEqual((self.ini.read_bytes(),self.db.read_bytes()),before)
        self.assertFalse(any(word in line.split() for line in events.read_text().splitlines() for word in ('start','stop','restart','kill')))
        self.assertTrue(list((self.home/'.local/state/pzmanager').glob('shared-budget-*/manifest.json')))


    def identity_targets(self,field,value):
        self.values[field]=value;self.write_env()
        trim=''.join(map(chr,range(33)))
        source=self.values['PZ_SOURCE_DIR'];name=self.values['PZ_SERVER_NAME']
        targets={(Path(source),name),(Path(source.replace('-cachedir=','').strip(trim)),name.strip(trim))}
        for world,server in targets:
            ini=world/'Server'/(server+'.ini');ini.parent.mkdir(parents=True,exist_ok=True)
            ini.write_text('Open=true\nMods=\n')
            database=world/'db'/(server+'.db');database.parent.mkdir(exist_ok=True)
            if database!=self.db:shutil.copy2(self.db,database)
            Path(str(database)+'-journal').write_bytes(b'')
            (world/'Server'/(server+'_SandboxVars.lua')).write_text('SandboxVars = {}\n')
            save=world/'Saves/Multiplayer'/server;save.mkdir(parents=True,exist_ok=True)
            (save/'sentinel').write_bytes(b'saved character')
            recovery=world/'recovery';recovery.mkdir(exist_ok=True);(recovery/'sentinel').write_bytes(b'recovery retained')
        return {world for world,_ in targets}

    def identity_image(self,targets):
        result={}
        for world in targets:
            for path in [world,*world.rglob('*')]:
                info=path.lstat()
                result[str(path)]=(info.st_mode,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_nlink,
                    path.read_bytes() if path.is_file() else None)
        return result

    def test_native_identity_refuses_three_transformed_targets_before_work(self):
        for variant in ('name-trim','source-trim','source-token'):
            for action in ('check','start','prepare'):
                with self.subTest(variant=variant,action=action):
                    case=NativeConfiguration();case.setUp()
                    try:
                        field='PZ_SERVER_NAME' if variant=='name-trim' else 'PZ_SOURCE_DIR'
                        value=case.name+' ' if variant=='name-trim' else str(case.world)+' ' if variant=='source-trim' else str(case.base/'-cachedir=world')
                        targets=case.identity_targets(field,value);before=case.identity_image(targets)
                        secret=case.repo/'.admin_password';secret.write_bytes(b'private-password\n');secret.chmod(0o600)
                        secret_before=(secret.read_bytes(),secret.stat().st_mtime_ns,secret.stat().st_ctime_ns)
                        fifo=os.open(case.pipe,os.O_RDWR|os.O_NONBLOCK)
                        try:
                            os.write(fifo,b'prior-command\n')
                            result=case.prepare() if action=='prepare' else case.invoke(action)
                            after=case.identity_image(targets)
                            self.assertFalse([path for path in set(before)|set(after) if before.get(path)!=after.get(path)],'world changed before native identity refusal')
                            self.assertEqual((secret.read_bytes(),secret.stat().st_mtime_ns,secret.stat().st_ctime_ns),secret_before)
                            self.assertEqual(os.read(fifo,4096),b'prior-command\n')
                            self.assertFalse(case.capture.exists(),'vendor fixture called')
                            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                            self.assertIn(field,result.stderr);self.assertIn('native',result.stderr)
                            self.assertFalse(case.bus.exists(),'identity rejection depended on a bus call')
                        finally:os.close(fifo)
                    finally:case.doCleanups()

    def test_java_trim_matrix_strict_and_stop_preserve_raw_values(self):
        cases=[('/tmp/control-world','selected ',False),('/tmp/control-world ','selected',False),
               ('/tmp/-cachedir=control-world','selected',False),('/tmp/control-world','selected',True),
               ("/tmp/équipe d'été","monde d'été 世界",True),('/tmp/world\u00a0','\u00a0selected\u00a0',True),
               ('/tmp/world\u2003','\u2003selected\u2003',True),('/tmp/world','selected-cachedir=ok',True)]
        for edge in ('\x01','\t','\n','\r','\x1f',' '):
            cases.extend([('/tmp/world',edge+'selected',False),('/tmp/world','selected'+edge,False),('/tmp/world'+edge,'selected',False)])
        self.assertEqual(len(cases),26)
        # Also preserve Unicode NEL and DEL, which Java trim does not remove,
        # and reject every other non-NUL <= U+0020 edge or repeated cache token.
        extras=[('/tmp/world'+edge,edge+'selected'+edge,True) for edge in ('\u0085','\x7f')]
        extras += [('/tmp/-cachedir=one/-cachedir=two-cachedir=','selected',False)]
        extras += [('/tmp/world'+chr(n),'selected'+chr(n),False) for n in range(1,33)]
        for source,name,valid in cases+extras:
            for stopping in (False,True):
                with self.subTest(source=source,name=name,stopping=stopping):
                    env=dict(self.env,PZ_SOURCE_DIR=source,PZ_SERVER_NAME=name)
                    command='set -euo pipefail; source "$1"; apply_env_defaults "$2"; printf "%s\\0" "$PZ_SOURCE_DIR" "$PZ_SERVER_NAME" "$PZ_INI_PATH" "$PZ_DB_PATH"'
                    result=subprocess.run(['bash','-c',command,'fixture',str(self.repo/'data/scripts/lib/common.sh'),str(stopping).lower()],env=env,capture_output=True,timeout=5)
                    self.assertEqual(result.returncode==0,valid or stopping,result.stderr)
                    if valid or stopping:
                        self.assertEqual(result.stdout.decode().split('\0')[:-1],[source,name,source+'/Server/'+name+'.ini',source+'/db/'+name+'.db'])
                    else:self.assertIn(b'native',result.stderr)

    def test_inherited_identity_is_checked_and_file_setting_keeps_precedence(self):
        for field,value in [('PZ_SERVER_NAME','selected '),('PZ_SOURCE_DIR',str(self.world)+' '),('PZ_SOURCE_DIR',str(self.base/'-cachedir=world'))]:
            with self.subTest(field=field,value=value):
                case=NativeConfiguration();case.setUp()
                try:
                    targets=case.identity_targets(field,value);before=case.identity_image(targets)
                    case.values.pop(field);case.write_env();case.env[field]=value
                    result=case.invoke('check')
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn(field,result.stderr);self.assertIn('native',result.stderr)
                    self.assertEqual(case.identity_image(targets),before);self.assertFalse(case.capture.exists())
                    # Explicit valid .env configuration still overrides inheritance.
                    case.values[field]=self.values[field];case.write_env()
                    result=case.invoke('check');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                finally:case.doCleanups()



if __name__=='__main__':
    os.umask(0o077)
    unittest.main()
