"""Observe live backup staging and exercise real fsync publication boundaries."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]


class BackupPublication(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.manager=self.root/'manager'
        scripts=self.manager/'data/scripts';(scripts/'backup').mkdir(parents=True)
        shutil.copytree(ROOT/'data/scripts/lib',scripts/'lib')
        (scripts/'internal').mkdir()
        shutil.copy2(ROOT/'data/scripts/internal/configureWritingTextOnly.py',scripts/'internal/configureWritingTextOnly.py')
        for name in ('fullBackup.sh','dataBackup.sh','listBackups.sh'):shutil.copy2(ROOT/'data/scripts/backup'/name,scripts/'backup'/name)
        common=scripts/'lib/common.sh'
        common.write_text(common.read_text()+'\nsource_env() { apply_env_defaults; }\n')
        self.bin=self.root/'bin';self.bin.mkdir()
        self.sync=self.root/'sync';self.sync.mkdir()
        self.backups=self.root/'backups';self.backups.mkdir()
        previous=self.backups/'previous';(previous/'Saves').mkdir(parents=True)
        (previous/'Saves/world').write_text('previous')
        self.latest=self.backups/'latest';self.latest.symlink_to(previous,target_is_directory=True)
        self.world=self.root/'world';(self.world/'Saves').mkdir(parents=True)
        (self.world/'Saves/world').write_text('new-world')
        self.runtime=self.root/'runtime';self.runtime.mkdir(mode=0o700)
        self.home=self.root/'home';self.home.mkdir()
        (self.manager/'.env').write_text('fixture-secret-to-backup\n')
        self.events=self.root/'events';self.gate=self.root/'gate';self.release=self.root/'release'
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(self.runtime),
                      PZ_HOME=str(self.home),PZ_MANAGER_DIR=str(self.manager),PZ_SOURCE_DIR=str(self.world),
                      PZ_DATA_DIR=str(self.manager/'data'),PZ_SCRIPTS_DIR=str(scripts),PZ_CONTROL_PIPE=str(self.root/'absent-fifo'),
                      BACKUP_DIR=str(self.backups),BACKUP_LATEST_LINK=str(self.latest),SYNC_BACKUPS_DIR=str(self.sync),
                      PZ_BACKUP_CPU_SCOPED='1',AGE_RECIPIENT='fixture-recipient',AGE_RECIPIENTS='',
                      FIXTURE_ROOT=str(self.root),FIXTURE_EVENTS=str(self.events))
        self.command('systemctl', '''print('LoadState=loaded\\nActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0\\nInvocationID=fixture')''')
        self.command('sudo','raise SystemExit(1)')
        self.command('rsync', '''import pathlib,shutil,sys
args=sys.argv[1:];dest=pathlib.Path(args[-1]);dest.mkdir(parents=True,exist_ok=True)
if '--relative' in args:
 for name in ('Saves','db','Server','Lua'):
  source=pathlib.Path(name)
  if source.is_dir():shutil.copytree(source,dest/name,dirs_exist_ok=True)
else:
 source=pathlib.Path(args[-2]);target=dest/str(source).lstrip('/')
 target.parent.mkdir(parents=True,exist_ok=True)
 if source.is_dir():shutil.copytree(source,target,dirs_exist_ok=True)
 else:shutil.copy2(source,target)
''')
        self.command('zip', '''import json,os,pathlib,sys,time,zipfile
args=[arg for arg in sys.argv[1:] if not arg.startswith('-')];archive=pathlib.Path(args[0])
with zipfile.ZipFile(archive,'w') as output:
 for member in args[1:]:
  for base,dirs,files in os.walk(member):
   for name in files:output.write(pathlib.Path(base)/name)
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
(root/'archive-path').write_text(str(archive))
(root/'work-path').write_text(str(pathlib.Path.cwd()))
if os.environ.get('FIXTURE_BLOCK')=='zip':
 (root/'gate').touch()
 while not (root/'release').exists():time.sleep(.02)
''')
        self.command('unzip', '''import sys,zipfile
with zipfile.ZipFile(sys.argv[-1]) as archive:
 if archive.testzip():raise SystemExit(1)
''')
        self.command('age', '''import os,pathlib,sys,time
args=sys.argv[1:];output=pathlib.Path(args[args.index('-o')+1]);source=pathlib.Path(args[-1])
root=pathlib.Path(os.environ['FIXTURE_ROOT']);(root/'age-source').write_text(str(source))
output.write_bytes(b'age-encryption.org/v1\\nfixture-ciphertext')
(root/'age-output').write_text(str(output))
if os.environ.get('FIXTURE_BLOCK')=='age':
 (root/'gate').touch()
 while not (root/'release').exists():time.sleep(.02)
if os.environ.get('FIXTURE_AGE_FAIL'):raise SystemExit(7)
''')
        self.command('python3', '''import json,os,pathlib,runpy,sys
args=sys.argv[1:]
if args and args[0].endswith('/world_transaction.py') and 'sync' in args:
 root=pathlib.Path(os.environ['FIXTURE_ROOT']);events=root/'events'
 call={'action':'sync-directory' if '--directory-only' in args else 'sync-tree','path':args[args.index('--world')+1]}
 before=[json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
 number=1+sum(entry['action'].startswith('sync-') for entry in before)
 with events.open('a') as stream:stream.write(json.dumps(call)+'\\n')
 fail=os.environ.get('FIXTURE_SYNC_FAIL')==str(number)
 original=os.fsync
 def fsync(fd):
  with events.open('a') as stream:stream.write(json.dumps({'action':'fsync','path':os.readlink('/proc/self/fd/'+str(fd))})+'\\n')
  if fail:raise OSError('injected fsync storage error')
  original(fd)
 os.fsync=fsync;sys.argv=args;sys.path.insert(0,str(pathlib.Path(args[0]).parent));runpy.run_path(args[0],run_name='__main__')
else:os.execv('/usr/bin/python3',['/usr/bin/python3',*args])
''')
        self.command('mv', '''import json,os,pathlib,sys
args=sys.argv[1:]
with pathlib.Path(os.environ['FIXTURE_EVENTS']).open('a') as stream:stream.write(json.dumps({'action':'rename','source':args[-2],'destination':args[-1]})+'\\n')
os.execv('/bin/mv',['/bin/mv',*args])
''')
        self.scripts=scripts

    def command(self,name,source):
        path=self.bin/name;path.write_text('#!/usr/bin/python3\n'+source+'\n');path.chmod(0o700)

    def run_data(self,fail=''):
        return subprocess.run(['bash',str(self.scripts/'backup/dataBackup.sh'),'--snapshot-only','--required'],
                              env=dict(self.env,FIXTURE_SYNC_FAIL=fail),capture_output=True,text=True,timeout=10)

    def test_incremental_staging_is_hidden_until_real_rsync_publication(self):
        self.command('rsync', """import os,pathlib,subprocess,sys,time
subprocess.run(['/usr/bin/rsync',*sys.argv[1:]],check=True)
root=pathlib.Path(os.environ['FIXTURE_ROOT']);(root/'gate').touch()
while not (root/'release').exists():time.sleep(.02)
""")
        legacy=self.backups/'backup_legacy';legacy.mkdir()
        proc=subprocess.Popen(['bash',str(self.scripts/'backup/dataBackup.sh'),'--snapshot-only','--required'],
                              env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        def listing():
            result=subprocess.run(['bash',str(self.scripts/'backup/listBackups.sh')],env=self.env,capture_output=True,text=True,timeout=8)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            return result.stdout
        try:
            deadline=time.monotonic()+8
            while not self.gate.exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(self.gate.exists(),'producer did not reach real rsync publication barrier')
            staged=list(self.backups.glob('backup_*.tmp'));self.assertEqual(len(staged),1)
            final=Path(str(staged[0])[:-4])
            before=listing()
            self.assertNotIn(str(staged[0]),before)
            self.assertNotIn(str(final)+'\n',before)
            self.assertIn(str(legacy),before)
            self.assertIn('12h horaires / 3j@6h / 14j daily',before)
            self.release.touch();out,err=proc.communicate(timeout=8)
            self.assertEqual(proc.returncode,0,out+err)
            self.assertFalse(staged[0].exists())
            self.assertTrue(final.is_dir())
            self.assertIn(str(final),listing())
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate()

    def test_staging_sync_failure_prevents_publication(self):
        result=self.run_data('1')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.latest.resolve(),self.backups/'previous')
        self.assertEqual(list(self.backups.glob('backup_*')),[])
        self.assertEqual((self.backups/'previous/Saves/world').read_text(),'previous')

    def test_parent_sync_failure_is_reported_before_success(self):
        for failure in ('2','3'):
            with self.subTest(failure=failure):
                # Separate timestamps and remove only this fixture's published final.
                for path in self.backups.glob('backup_*'):shutil.rmtree(path)
                self.latest.unlink();self.latest.symlink_to(self.backups/'previous')
                self.events.unlink(missing_ok=True)
                result=self.run_data(failure)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertNotIn('Snapshot ponctuel créé',result.stdout)
                self.assertEqual((self.backups/'previous/Saves/world').read_text(),'previous')
                if failure=='2':self.assertEqual(self.latest.resolve(),self.backups/'previous')

    def test_fsync_files_and_directories_precede_publish_and_latest_success(self):
        result=self.run_data();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        events=[json.loads(line) for line in self.events.read_text().splitlines()]
        actions=[entry['action'] for entry in events]
        self.assertEqual([action for action in actions if action!='fsync'],['sync-tree','rename','sync-directory','rename','sync-directory'])
        first_rename=actions.index('rename')
        synced={entry['path'] for entry in events[:first_rename] if entry['action']=='fsync'}
        staging=Path(events[0]['path'])
        for suffix in ('Saves/world','Saves','.pzm-snapshot.json',''):
            self.assertIn(str(staging/suffix),synced)
        self.assertEqual((self.latest/'Saves/world').read_text(),'new-world')

    def observe_full(self,stage,terminate=False,fail=False):
        env=dict(self.env,FIXTURE_BLOCK=stage,FIXTURE_AGE_FAIL='1' if fail else '')
        proc=subprocess.Popen(['bash',str(self.scripts/'backup/fullBackup.sh')],env=env,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            deadline=time.monotonic()+8
            while not self.gate.exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(self.gate.exists(),'backup did not reach '+stage)
            archive=Path((self.root/'archive-path').read_text())
            self.assertTrue(archive.is_file())
            self.assertFalse(archive.is_relative_to(self.sync),str(archive))
            self.assertEqual(archive.stat().st_mode & 0o777,0o600)
            self.assertEqual(archive.parent.stat().st_mode & 0o777,0o700)
            self.assertFalse(any(zipfile.is_zipfile(path) for path in self.sync.iterdir() if path.is_file()))
            if stage=='age':
                output=Path((self.root/'age-output').read_text())
                self.assertEqual(output.parent,self.sync)
                self.assertTrue(output.name.startswith('.'))
                self.assertEqual(output.stat().st_mode & 0o777,0o600)
            if terminate:os.killpg(proc.pid,signal.SIGTERM)
            else:self.release.touch()
            out,err=proc.communicate(timeout=8)
            self.assertEqual(proc.returncode==0,not (terminate or fail),out+err)
            self.assertFalse(archive.exists())
            self.assertFalse(archive.parent.exists())
            if terminate or fail:self.assertEqual(list(self.sync.iterdir()),[])
            else:
                final=list(self.sync.iterdir());self.assertEqual(len(final),1)
                self.assertTrue(final[0].name.endswith('.zip.age'))
                self.assertEqual(final[0].stat().st_mode & 0o777,0o600)
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate()

    def test_default_clear_zip_is_atomic_in_sync_with_truthful_warning(self):
        env=dict(self.env,AGE_RECIPIENT='',AGE_RECIPIENTS='',FIXTURE_BLOCK='zip')
        proc=subprocess.Popen(['bash',str(self.scripts/'backup/fullBackup.sh')],env=env,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            deadline=time.monotonic()+8
            while not self.gate.exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(self.gate.exists(),'clear backup did not reach zip')
            temporary=Path((self.root/'archive-path').read_text())
            self.assertEqual(temporary.parent,self.sync)
            work=Path((self.root/'work-path').read_text())
            self.assertEqual(work.stat().st_mode & 0o777,0o700)
            self.assertFalse(work.is_relative_to(self.sync))
            self.assertTrue(temporary.name.startswith('.'))
            self.assertEqual(temporary.stat().st_mode & 0o777,0o600)
            self.assertEqual(list(self.sync.glob('*.zip')),[])
            self.release.touch()
            out,err=proc.communicate(timeout=8)
            self.assertEqual(proc.returncode,0,out+err)
            final=list(self.sync.glob('*.zip'));self.assertEqual(len(final),1)
            self.assertEqual(final[0].stat().st_mode & 0o777,0o600)
            self.assertFalse(temporary.exists())
            self.assertFalse(work.exists())
            self.assertFalse((self.root/'age-source').exists())
            with zipfile.ZipFile(final[0]) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read('zomboid/Saves/world'),b'previous')
                self.assertTrue(any(name.endswith('/manager/.env') for name in archive.namelist()))
            events=[json.loads(line) for line in self.events.read_text().splitlines()]
            rename=next(entry for entry in events if entry['action']=='rename')
            self.assertEqual(Path(rename['source']),temporary)
            self.assertEqual(Path(rename['destination']),final[0])
            self.assertIn('ZIP clair',err)
            self.assertIn('répertoire synchronisé',err)
            self.assertNotIn('local seul',out+err)
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate()

    def test_temp_directory_inside_sync_is_refused_before_secret_staging(self):
        result=subprocess.run(['bash',str(self.scripts/'backup/fullBackup.sh')],
                              env=dict(self.env,TMPDIR=str(self.sync)),capture_output=True,text=True,timeout=8)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('zone synchronisée',result.stderr)
        self.assertEqual(list(self.sync.iterdir()),[])
        self.assertFalse((self.root/'archive-path').exists())

    def test_full_archive_durability_precedes_rotation_in_both_modes(self):
        # Real packaging and copying; only the optional encryption boundary is
        # synthetic. The fsync observer above still calls the actual syscall.
        for name in ('zip','unzip','rsync'):
            executable=shutil.which(name,path='/usr/bin:/bin')
            self.assertIsNotNone(executable,name+' required')
            self.command(name,'import os,sys\nos.execv('+repr(executable)+','+repr([executable])+'+sys.argv[1:])')
        self.command('rm', '''import json,os,pathlib,sys
with pathlib.Path(os.environ['FIXTURE_EVENTS']).open('a') as stream:
 stream.write(json.dumps({'action':'remove','paths':sys.argv[1:]})+'\\n')
os.execv('/bin/rm',['/bin/rm',*sys.argv[1:]])
''')
        for encrypted in (False,True):
            for failure in ('1','2',''):
                with self.subTest(encrypted=encrypted,failure=failure):
                    for path in self.sync.iterdir():path.unlink()
                    self.events.unlink(missing_ok=True)
                    previous=self.sync/'2001-01-01_00-00.zip';previous.write_bytes(b'previous-recovery')
                    env=dict(self.env,AGE_RECIPIENT='fixture' if encrypted else '',OFFSITE_BACKUP_COUNT='1',FIXTURE_SYNC_FAIL=failure)
                    result=subprocess.run(['bash',str(self.scripts/'backup/fullBackup.sh')],env=env,capture_output=True,text=True,timeout=10)
                    events=[json.loads(line) for line in self.events.read_text().splitlines()]
                    if failure:
                        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                        self.assertEqual(previous.read_bytes(),b'previous-recovery')
                        self.assertNotIn('Backup off-site terminé',result.stdout)
                        continue
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertFalse(previous.exists())
                    rename=next(i for i,e in enumerate(events) if e['action']=='rename')
                    final=events[rename]['destination'];temporary=events[rename]['source']
                    self.assertIn(temporary,[e['path'] for e in events[:rename] if e['action']=='fsync'])
                    removal=next(i for i,e in enumerate(events) if e['action']=='remove' and str(previous) in e['paths'])
                    self.assertIn(str(self.sync),[e['path'] for e in events[rename:removal] if e['action']=='fsync'])
                    self.assertTrue(Path(final).is_file())

    def test_forensic_backup_keeps_old_recovery_when_journal_is_corrupt(self):
        expired=self.backups/'backup_2001-01-01_00h00m00s';expired.mkdir()
        (expired/'recovery').write_bytes(b'keep-for-recovery')
        state=self.world.parent/('.'+self.world.name+'.pzm-transactions');state.mkdir(mode=0o700)
        record=state/'damaged.json';record.write_text('{broken');record.chmod(0o600)
        result=subprocess.run(['bash',str(self.scripts/'backup/dataBackup.sh')],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((expired/'recovery').read_bytes(),b'keep-for-recovery')
        self.assertEqual((self.latest/'Saves/world').read_text(),'new-world')
        self.assertIn('Rétention GFS différée',result.stdout)

    def test_plaintext_outside_sync_while_zip_is_running(self):self.observe_full('zip')
    def test_plaintext_outside_sync_while_age_is_blocked(self):self.observe_full('age')
    def test_age_failure_leaves_no_plaintext_or_partial_in_sync(self):self.observe_full('age',fail=True)
    def test_termination_cleans_private_plaintext_and_ciphertext_staging(self):self.observe_full('age',terminate=True)


if __name__=='__main__':unittest.main()
