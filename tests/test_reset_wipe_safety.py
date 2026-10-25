#!/usr/bin/env python3
"""Destructive admin chain: real locks, backups, SQLite and transaction records.
Only systemd/the game and final server start are fixture boundaries.
"""
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(os.environ['PZ_TEST_ROOT'])

# Provider wrapper retained verbatim; only its Java/game executables are fixtures.
VENDOR_WRAPPER = '#!/bin/bash\n#\n###############################################################################\n#\n# Edit memory option -Xmx in ProjectZomboid64.json for 64bit servers (common)\n#\n############\n\nINSTDIR="`dirname $0`" ; cd "${INSTDIR}" ; INSTDIR="`pwd`"\n\nif "${INSTDIR}/jre64/bin/java" -version > /dev/null 2>&1; then\n\texport PATH="${INSTDIR}/jre64/bin:$PATH"\n\texport LD_LIBRARY_PATH="${INSTDIR}/linux64:${INSTDIR}:${INSTDIR}/jre64/lib/amd64:${LD_LIBRARY_PATH}"\n\tJSIG="libjsig.so"\n\tLD_PRELOAD="${LD_PRELOAD}:${JSIG}" ./ProjectZomboid64 "$@"\nelse\n\techo "Only 64bit is supported"\nfi\nexit 0\n\n#\n# EOF\n#\n###############################################################################\n\n'

SCHEMA = '''CREATE TABLE whitelist(world TEXT,username TEXT UNIQUE,password TEXT,steamid TEXT,role TEXT,displayName TEXT,lastConnection TEXT);
CREATE TABLE allowedsteamid(steamid TEXT UNIQUE);'''

def database(path, old=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as db:
        db.executescript(SCHEMA)
        db.execute('INSERT INTO whitelist VALUES(?,?,?,?,?,?,?)', ('world','admin','old-secret' if old else 'new-secret','123','admin','Admin','2026-10-01'))
        if old:
            db.execute('INSERT INTO whitelist VALUES(?,?,?,?,?,?,?)', ('world','player','secret','456','user','Player','2026-10-02'))
            db.execute('INSERT INTO allowedsteamid VALUES(?)', ('456',))
        db.commit()

class Safety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='admin-safety-', dir=ROOT.parent)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'repository'
        shutil.copytree(ROOT / 'data/scripts', self.repo / 'data/scripts')
        self.home = self.base / "home'quoted"
        self.home.mkdir()
        self.live = self.home / 'Zomboid'
        self.backups = self.base / 'backups'
        self.runtime = self.base / 'runtime'; self.runtime.mkdir()
        self.bin = self.base / 'bin'; self.bin.mkdir()
        self.install = self.base / 'game'; self.install.mkdir()
        self.executable(self.bin / 'systemctl', '#!/bin/bash\nprintf "%s\\n" LoadState=loaded ActiveState=inactive SubState=dead MainPID=0 ControlPID=0 InvocationID=fixture\n')
        self.executable(self.repo / 'data/scripts/core/pz.sh', '#!/bin/bash\necho "$*" >> "$FIXTURE_START_LOG"\n')
        self.executable(self.install / 'start-server.sh', '''#!/usr/bin/env python3
import os,sys,time
from pathlib import Path
import sqlite3
cachedir=Path(next(a.split('=',1)[1] for a in sys.argv if a.startswith('-cachedir=')))
if os.environ.get('FIXTURE_GENERATOR')=='fail':sys.exit(1)
if os.environ.get('FIXTURE_GENERATOR')=='hang':time.sleep(90);sys.exit()
(cachedir/'db').mkdir(exist_ok=True)
(cachedir/'Server').mkdir(exist_ok=True)
config=cachedir/'Server/servertest.ini'
if not config.exists():config.write_text('new-config')
db=sqlite3.connect(cachedir/'db/servertest.db')
db.executescript("CREATE TABLE whitelist(world TEXT,username TEXT UNIQUE,password TEXT,steamid TEXT,role TEXT,displayName TEXT,lastConnection TEXT); CREATE TABLE allowedsteamid(steamid TEXT UNIQUE); INSERT INTO whitelist VALUES('world','admin','new-secret','123','admin','Admin','now');")
db.commit();db.close()
time.sleep(90)
''')
        values = dict(PZ_USER=os.environ.get('USER','pzuser42'),PZ_HOME=str(self.home),PZ_SOURCE_DIR=str(self.live),PZ_INSTALL_DIR=str(self.install),BACKUP_DIR=str(self.backups),PZ_GAME_USER=os.environ.get('USER','pzuser42'),PZ_MANAGER_USER=os.environ.get('USER','pzuser42'))
        (self.repo / '.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in values.items())+'\n')
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], XDG_RUNTIME_DIR=str(self.runtime), PZ_BACKUP_CPU_SCOPED='1', PZ_RESET_MAX_WAIT='4', PZ_RESET_ADMIN_WAIT='2', PZ_RESET_EARLY_GRACE='0', PZ_RESET_POLL_INTERVAL='1', FIXTURE_START_LOG=str(self.base/'starts'))
        database(self.live / 'db/servertest.db', True)
        (self.live / 'Server').mkdir()
        for suffix in ('.ini','_SandboxVars.lua','_spawnpoints.lua','_spawnregions.lua'):
            (self.live/'Server'/('servertest'+suffix)).write_text('old'+suffix)
        self.tile=self.live/'Saves/Multiplayer/world/map/0/0.bin'
        self.tile.parent.mkdir(parents=True);self.tile.write_bytes(b'old-map')
        self.before=self.image(self.live)
    def tearDown(self):
        ready=self.base/'generator-child.json'
        if ready.exists():
            identity=json.loads(ready.read_text())
            if self.child_alive(identity):
                os.kill(identity['pid'],signal.SIGKILL)
        self.tmp.cleanup()
    def child_alive(self,identity):
        try:
            fields=Path('/proc/'+str(identity['pid'])+'/stat').read_text().rsplit(')',1)[1].split()
            return int(fields[19])==identity['birth'] and fields[0]!='Z'
        except FileNotFoundError:return False
    def vendor_generator(self,ignore_term=False,wrapper_exits=False):
        child=self.install/'ProjectZomboid64'
        child.write_text((self.install/'start-server.sh').read_text())
        child.chmod(0o700)
        child.write_text(child.read_text().replace('import os,sys,time','''import os,sys,time,signal,json
if os.environ.get('FIXTURE_IGNORE_TERM')=='1':signal.signal(signal.SIGTERM,signal.SIG_IGN)
from pathlib import Path
fields=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()
ready=Path(os.environ['FIXTURE_CHILD_READY'])
ready.with_suffix('.tmp').write_text(json.dumps(dict(pid=os.getpid(),birth=int(fields[19]),locks={key:os.environ.get(key) for key in ('PZ_WORLD_LOCK_FD','SERVERCTL_LOCK_FD')})))
ready.with_suffix('.tmp').replace(ready)'''))
        java=self.install/'jre64/bin/java';java.parent.mkdir(parents=True)
        self.executable(java,'#!/bin/bash\nexit 0\n')
        wrapper=VENDOR_WRAPPER
        if wrapper_exits:
            wrapper=wrapper.replace('./ProjectZomboid64 "$@"','./ProjectZomboid64 "$@" &')
        self.executable(self.install/'start-server.sh',wrapper)
        self.env.update(FIXTURE_CHILD_READY=str(self.base/'generator-child.json'),FIXTURE_IGNORE_TERM='1' if ignore_term else '0')
    def wait_for_child(self,process):
        ready=self.base/'generator-child.json';deadline=time.monotonic()+6
        while not ready.exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(.02)
        self.assertTrue(ready.exists(),'provider wrapper never launched its child')
        identity=json.loads(ready.read_text());self.assertTrue(self.child_alive(identity),'generator child not alive at precondition')
        return identity
    def assert_child_stopped(self):
        ready=self.base/'generator-child.json'
        self.assertTrue(ready.exists(),'provider child launch not proven')
        self.assertFalse(self.child_alive(json.loads(ready.read_text())),'provider child still writing after reset returned')
    def test_vendor_child_inherits_world_and_serverctl_locked_fds(self):
        self.vendor_generator(ignore_term=True);self.env['FIXTURE_GENERATOR']='hang'
        common=self.repo/'data/scripts/lib/common.sh'
        script='source "$1"; source_env; acquire_world_lock --required; acquire_serverctl_lock_or_die; exec bash "$2"'
        p=subprocess.Popen(['bash','-euo','pipefail','-c',script,'bash',str(common),str(self.repo/'data/scripts/admin/resetServer.sh')],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            child=self.wait_for_child(p)
            metadata=next(self.home.glob('Zomboid.new.*/.pzm-generator.json'))
            supervisor=json.loads(metadata.read_text())
            for variable,name in [('PZ_WORLD_LOCK_FD','world.lock'),('SERVERCTL_LOCK_FD','serverctl.lock')]:
                with self.subTest(lock=name):
                    fd=child['locks'][variable]
                    self.assertIsNotNone(fd,'wrapper did not receive the lock environment')
                    lock=self.runtime/'pzmanager'/name
                    expected=lock.stat()
                    for pid in (supervisor['pid'],child['pid']):
                        held=Path('/proc')/str(pid)/'fd'/fd
                        self.assertTrue(held.exists(),f'{variable} FD closed before process {pid}')
                        actual=held.stat()
                        self.assertEqual((actual.st_dev,actual.st_ino),(expected.st_dev,expected.st_ino))
                        info=(Path('/proc')/str(pid)/'fdinfo'/fd).read_text()
                        self.assertRegex(info,r'FLOCK\s+ADVISORY\s+WRITE')
                    with lock.open('rb') as concurrent:
                        with self.assertRaises(BlockingIOError):fcntl.flock(concurrent,fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally:
            if p.poll() is None:p.terminate()
            out=p.communicate(timeout=15)[0]
            self.assertNotEqual(p.returncode,0,out)
            self.assert_child_stopped()
    def test_vendor_wrapper_success_stops_term_ignoring_child(self):
        self.vendor_generator(ignore_term=True)
        p=self.run_admin('resetServer.sh')
        self.assertEqual(p.returncode,0,p.stdout)
        self.assert_child_stopped()
    def test_vendor_wrapper_timeout_stops_child(self):
        self.vendor_generator(ignore_term=True);self.env['FIXTURE_GENERATOR']='hang'
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout);self.assertIn('Timeout',p.stdout)
        self.assert_child_stopped();self.assertEqual(self.image(self.live),self.before)
    def test_vendor_wrapper_term_stops_child(self):
        self.vendor_generator(ignore_term=True);self.env['FIXTURE_GENERATOR']='hang'
        p=subprocess.Popen(self.command('resetServer.sh'),env=self.env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            self.wait_for_child(p)
            p.terminate();out=p.communicate(timeout=15)[0]
            self.assertNotEqual(p.returncode,0,out)
            self.assert_child_stopped();self.assertEqual(self.image(self.live),self.before)
        finally:
            if p.poll() is None:p.kill();p.communicate()
    def test_unprovable_generator_identity_preserves_staging(self):
        self.assert_unprovable_generator_identity('birth')
    def test_wrong_generator_cachedir_preserves_staging_and_child(self):
        self.assert_unprovable_generator_identity('cachedir')
    def assert_unprovable_generator_identity(self,field):
        self.vendor_generator(ignore_term=True);self.env['FIXTURE_GENERATOR']='hang'
        p=subprocess.Popen(self.command('resetServer.sh'),env=self.env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        original=None;metadata=None
        try:
            self.wait_for_child(p)
            metadata=next(self.home.glob('Zomboid.new.*/.pzm-generator.json'))
            original=json.loads(metadata.read_text())
            corrupt=dict(original)
            corrupt[field]=original[field]+1 if field=='birth' else original[field]+'.suffix'
            metadata.write_text(json.dumps(corrupt))
            p.terminate();out=p.communicate(timeout=15)[0]
            self.assertNotEqual(p.returncode,0,out)
            self.assertIn('staging et journal conservés',out)
            self.assertTrue(metadata.exists(),'staging evidence deleted despite unknown identity')
            self.assertTrue(self.child_alive(json.loads((self.base/'generator-child.json').read_text())))
            self.assertEqual(self.image(self.live),self.before)
        finally:
            if p.poll() is None:p.kill();p.communicate()
            if metadata is not None and original is not None:
                metadata.write_text(json.dumps(original))
                stopped=subprocess.run(['python3',str(self.repo/'data/scripts/lib/reset_generator.py'),'stop','--metadata',str(metadata),'-cachedir='+original['cachedir'],'--pid',str(original['pid'])],env=self.env,capture_output=True,text=True,timeout=10)
                self.assertEqual(stopped.returncode,0,stopped.stdout+stopped.stderr)
    def test_exited_wrapper_still_stops_remaining_child(self):
        self.vendor_generator(ignore_term=True,wrapper_exits=True);self.env['FIXTURE_GENERATOR']='hang'
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout)
        self.assert_child_stopped();self.assertEqual(self.image(self.live),self.before)

    def executable(self,path,content):path.write_text(content);path.chmod(0o700)
    def image(self,path): return {str(p.relative_to(path)):p.read_bytes() for p in path.rglob('*') if p.is_file()}
    def command(self,script,*args):return ['bash',str(self.repo/'data/scripts/admin'/script),*args]
    def run_admin(self,script,*args):return subprocess.run(self.command(script,*args),env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    def records(self):return [json.loads(p.read_text()) for p in (self.home/'.Zomboid.pzm-transactions').glob('*.json')]
    def test_wipe_locked_backup_preserves_all_files(self):
        state=self.runtime/'pzmanager';state.mkdir(mode=0o700)
        with (state/'backup.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            p=self.run_admin('wipeMapTile.sh','0','0')
        self.assertNotEqual(p.returncode,0,p.stdout)
        self.assertIn('BACKUP_REQUIRED_LOCKED',p.stdout)
        self.assertEqual(self.image(self.live),self.before)

    def test_partial_wipe_blocks_start_until_verified_recovery(self):
        metadata=self.live/'Saves/Multiplayer/world/metagrid/metacell_0_0.bin'
        metadata.parent.mkdir(parents=True);metadata.write_bytes(b'cell-metadata')
        self.executable(self.bin/'date', '''#!/bin/bash
if [[ "$1" == '+%Y-%m-%d_%Hh%Mm%Ss' ]]; then echo 2001-01-01_00h00m00s
else exec /usr/bin/date "$@"; fi
''')
        self.executable(self.bin/'rm', '''#!/usr/bin/python3
import os,sys
targets=[p for p in sys.argv[1:] if p.endswith('/map/0/0.bin')]
if targets:
 os.unlink(targets[0]);sys.exit(74)
os.execv('/usr/bin/rm',['/usr/bin/rm',*sys.argv[1:]])
''')
        result=self.run_admin('wipeMapTile.sh','0','0')
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertFalse(self.tile.exists(),result.stdout);self.assertEqual(metadata.read_bytes(),b'cell-metadata')
        records=self.records();self.assertEqual(len(records),1)
        record=records[0];self.assertEqual(record['state'],'prepared')
        snapshot=self.backups.joinpath('latest').resolve()
        self.assertEqual(Path(record['recovery']),snapshot)
        self.assertEqual((snapshot/self.tile.relative_to(self.live)).read_bytes(),b'old-map')
        helper=self.repo/'data/scripts/lib/world_transaction.py'
        def transaction(*args):
            return subprocess.run(['python3',str(helper),*args,'--world',str(self.live)],env=self.env,capture_output=True,text=True)
        check=transaction('check');self.assertNotEqual(check.returncode,0);self.assertIn('unfinished',check.stderr)
        premature=transaction('finish','--token',record['id'],'--state','complete')
        self.assertNotEqual(premature.returncode,0)
        (self.bin/'date').unlink()
        backup=self.repo/'data/scripts/backup/dataBackup.sh'
        forensic=subprocess.run(['bash',str(backup)],env=self.env,capture_output=True,text=True,timeout=20)
        self.assertEqual(forensic.returncode,0,forensic.stdout+forensic.stderr)
        self.assertTrue(snapshot.is_dir(),'retention deleted the pending recovery')
        self.assertNotEqual((self.backups/'latest').resolve(),snapshot)
        self.tile.write_bytes((snapshot/self.tile.relative_to(self.live)).read_bytes())
        reverted=transaction('finish','--token',record['id'],'--state','reverted')
        self.assertEqual(reverted.returncode,0,reverted.stderr)
        self.assertEqual(transaction('check').returncode,0)
        self.executable(self.bin/'date', '''#!/bin/bash
if [[ "$1" == '+%Y-%m-%d_%Hh%Mm%Ss' ]]; then echo 2030-01-01_00h00m00s
else exec /usr/bin/date "$@"; fi
''')
        clean=subprocess.run(['bash',str(backup)],env=self.env,capture_output=True,text=True,timeout=20)
        self.assertEqual(clean.returncode,0,clean.stdout+clean.stderr)
        self.assertFalse(snapshot.exists(),'clean journal should retain ordinary GFS pruning')
    def wipe_decimal(self,text):
        wanted=self.live/'Saves/Multiplayer/world/map/12/0.bin'
        wrong=self.live/'Saves/Multiplayer/world/map/8/0.bin'
        wanted.parent.mkdir(parents=True);wrong.parent.mkdir(parents=True)
        wanted.write_bytes(b'decimal100');wrong.write_bytes(b'decimal64')
        p=self.run_admin('wipeMapTile.sh',text,'0')
        self.assertEqual(p.returncode,0,p.stdout)
        self.assertFalse(wanted.exists());self.assertEqual(wrong.read_bytes(),b'decimal64')
    def test_wipe_decimal_100(self):self.wipe_decimal('100')
    def test_wipe_decimal_0100(self):self.wipe_decimal('0100')
    def test_wipe_java_int_boundary_and_overflow(self):
        for value in ('2147483648','18446744073709551624'):
            p=self.run_admin('wipeMapTile.sh',value,'0')
            self.assertNotEqual(p.returncode,0,p.stdout)
            self.assertEqual(self.image(self.live),self.before)
        maximum=self.live/'Saves/Multiplayer/world/map/268435455/0.bin'
        maximum.parent.mkdir(parents=True);maximum.write_bytes(b'max-int')
        p=self.run_admin('wipeMapTile.sh','2147483647','0')
        self.assertEqual(p.returncode,0,p.stdout);self.assertFalse(maximum.exists())
        self.assertEqual(self.tile.read_bytes(),b'old-map')
    def test_reset_success_backup_and_options(self):
        p=self.run_admin('resetServer.sh','--keep-config','--keep-whitelist')
        self.assertEqual(p.returncode,0,p.stdout)
        self.assertTrue((self.backups/'latest').is_dir(),p.stdout)
        snapshot=self.image(self.backups/'latest');snapshot.pop('.pzm-snapshot.json')
        self.assertEqual(snapshot,self.before)
        self.assertEqual((self.live/'Server/servertest.ini').read_text(),'old.ini')
        with closing(sqlite3.connect(self.live/'db/servertest.db')) as db:
            self.assertEqual(db.execute('SELECT username,password,lastConnection FROM whitelist ORDER BY username').fetchall(), [('admin','old-secret','2026-10-01'),('player','secret','2026-10-02')])
            self.assertEqual(db.execute('SELECT * FROM allowedsteamid').fetchall(),[('456',)])
        self.assertEqual([r['state'] for r in self.records()],['complete'])
        self.assertFalse(list(self.home.glob('.reset-previous-*')))
    def test_generation_failure_keeps_live(self):
        self.env['FIXTURE_GENERATOR']='fail'
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout)
        self.assertEqual(self.image(self.live),self.before)
        self.assertFalse(any(r['state']=='prepared' for r in self.records()))
    def test_initially_absent_world(self):
        shutil.rmtree(self.live)
        p=self.run_admin('resetServer.sh')
        self.assertEqual(p.returncode,0,p.stdout)
        self.assertEqual(self.records()[0]['tree']['before'],None)
        self.assertEqual(self.records()[0]['state'],'complete')
    def test_timeout_keeps_live(self):
        self.env['FIXTURE_GENERATOR']='hang'
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout)
        self.assertIn('Timeout',p.stdout)
        self.assertEqual(self.image(self.live),self.before)
    def test_swap_failure_restores_verified_live(self):
        self.executable(self.bin/'mv', "#!/bin/bash\nif [[ \"$*\" == *Zomboid.new.* ]]; then exit 1; fi\nexec /usr/bin/mv \"$@\"\n")
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout)
        self.assertEqual(self.image(self.live),self.before)
        self.assertEqual(self.records()[0]['state'],'reverted')
    def test_term_during_generation_keeps_live(self):
        self.env['FIXTURE_GENERATOR']='hang'
        p=subprocess.Popen(self.command('resetServer.sh'),env=self.env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            for _ in range(150):
                if list(self.home.glob('Zomboid.new.*/.pzm-generator.json')):break
                if p.poll() is not None:break
                time.sleep(.05)
            p.terminate();out=p.communicate(timeout=15)[0]
            self.assertEqual(self.image(self.live),self.before,out)
        finally:
            if p.poll() is None:p.kill();p.wait()
    def test_sigkill_after_live_move_blocks_start_with_recovery(self):
        self.executable(self.bin/'mv', '''#!/bin/bash
/usr/bin/mv "$@" || exit
if [[ "$*" == *".reset-previous-"* && "$*" == *"Zomboid"* ]]; then
    kill -KILL "$PPID"
fi
''')
        p=self.run_admin('resetServer.sh')
        self.assertNotEqual(p.returncode,0,p.stdout)
        records=self.records();self.assertEqual(len(records),1,p.stdout)
        self.assertEqual(records[0]['state'],'prepared')
        self.assertFalse(self.live.exists())
        self.assertEqual(self.image(Path(records[0]['recovery'])),self.before)
        check=subprocess.run(['python3',str(self.repo/'data/scripts/lib/world_transaction.py'),'check','--world',str(self.live)],capture_output=True,text=True)
        self.assertNotEqual(check.returncode,0)
        self.assertIn('unfinished',check.stderr)
    def test_interruption_between_intent_and_moves(self):
        for action in ('TERM','KILL'):
            with self.subTest(action=action):
                known={r['id'] for r in self.records()}
                self.executable(self.bin/'mv', '''#!/bin/bash
if [[ "$*" == *".reset-previous-"* && "$*" == *"Zomboid"* ]]; then
    kill -%s "$PPID"
    sleep .2
    exit 1
fi
exec /usr/bin/mv "$@"
''' % action)
                p=self.run_admin('resetServer.sh')
                self.assertNotEqual(p.returncode,0,p.stdout)
                self.assertEqual(self.image(self.live),self.before,p.stdout)
                records=[r for r in self.records() if r['id'] not in known];self.assertEqual(len(records),1,p.stdout)
                self.assertIn(records[0]['state'],['reverted','prepared'])
                if records[0]['state']=='prepared':
                    check=subprocess.run(['python3',str(self.repo/'data/scripts/lib/world_transaction.py'),'check','--world',str(self.live)],capture_output=True,text=True)
                    self.assertNotEqual(check.returncode,0)
                    break

if __name__=='__main__':
    os.umask(0o077)
    unittest.main()
