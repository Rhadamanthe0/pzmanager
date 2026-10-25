#!/usr/bin/env python3
"""Account mutations: real SQLite/flock/admission, disposable service fixture."""
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

ROOT=Path(os.environ['PZ_TEST_ROOT'])

class Accounts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='accounts-',dir=ROOT.parent)
        self.base=Path(self.tmp.name); self.repo=self.base/'repository'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        self.world=self.base/"world'世界";self.world.mkdir()
        self.db=self.base/"accounts'外.db";self.players=self.world/'Saves/Multiplayer/save/players.db';self.players.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript("CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT UNIQUE,password TEXT,steamid TEXT,lastConnection TEXT,role TEXT,displayName TEXT); CREATE TABLE allowedsteamid(steamid TEXT UNIQUE); INSERT INTO whitelist VALUES(1,'admin','a','76561198000000001','2000-01-01','admin','Admin'); INSERT INTO whitelist VALUES(2,'old','secret','76561198000000002','2000-01-01','user','Old'); INSERT INTO whitelist VALUES(3,'kept','x','76561198000000003',date('now'),'user','Kept'); INSERT INTO allowedsteamid VALUES('76561198000000002');")
            db.commit()
        with closing(sqlite3.connect(self.players)) as db:
            db.executescript("CREATE TABLE networkPlayers(id INTEGER PRIMARY KEY,username TEXT); INSERT INTO networkPlayers VALUES(1,'old');");db.commit()
        self.runtime=self.base/'runtime';self.runtime.mkdir(mode=0o700)
        self.bin=self.base/'bin';self.bin.mkdir();self.state=self.base/'state.json'
        self.set_state('inactive','dead',0,0)
        self.executable(self.bin/'systemctl', '''#!/usr/bin/env python3
import json,os,sys
s=json.load(open(os.environ['ACCOUNT_TEST_STATE']))
if 'is-active' in sys.argv:
 print(s['ActiveState']);sys.exit(0 if s['ActiveState']=='active' else 3)
keys=['ActiveState','SubState','MainPID','ControlPID'] if any(a.startswith('--property=') for a in sys.argv) else ['LoadState','ActiveState','SubState','MainPID','ControlPID','InvocationID']
for k in keys:print(k+'='+str(s.get(k,{'LoadState':'loaded','InvocationID':'fixture'}.get(k,''))))
''')
        self.executable(self.bin/'backup', '#!/bin/bash\nexit 0\n')
        vals=dict(PZ_DB_PATH=str(self.db),PZ_SOURCE_DIR=str(self.world),PZ_HOME=str(self.base),WHITELIST_LEDGER=str(self.base/'ledger.csv'),BACKUP_DIR=str(self.base/'backups'))
        (self.repo/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in vals.items())+'\n')
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],ACCOUNT_TEST_STATE=str(self.state),XDG_RUNTIME_DIR=str(self.runtime),PZ_DATABACKUP_BIN=str(self.bin/'backup'))
    def tearDown(self):self.tmp.cleanup()
    def executable(self,p,s):p.write_text(s);p.chmod(0o700)
    def set_state(self,a,s,m,c):self.state.write_text(json.dumps(dict(ActiveState=a,SubState=s,MainPID=m,ControlPID=c)))
    def rows(self,path,table):
        with closing(sqlite3.connect(path)) as db:return db.execute('SELECT * FROM '+table+' ORDER BY 1').fetchall()
    def invoke(self,script,*args,**kw):return subprocess.run(['bash',str(self.repo/'data/scripts/admin'/script),*args],env=self.env,text=True,capture_output=True,timeout=20,**kw)
    def check_pending_mutation(self,script,*args):
        staging=self.base/'staged';shutil.copytree(self.world,staging)
        helper=self.repo/'data/scripts/lib/world_transaction.py'
        def transaction(*arguments):
            return subprocess.run(['python3',str(helper),*arguments,'--world',str(self.world)],env=self.env,capture_output=True,text=True)
        prepared=transaction('begin','--kind','fixture','--recovery',str(self.base/'recovery'),'--after-tree',str(staging))
        self.assertEqual(prepared.returncode,0,prepared.stderr)
        before=self.rows(self.db,'whitelist');allowed=self.rows(self.db,'allowedsteamid')
        tree={str(p.relative_to(self.world)):p.read_bytes() for p in self.world.rglob('*') if p.is_file()}
        if script in {'dataBackup.sh','restoreCharacter.sh'}:
            result=subprocess.run(['bash',str(self.repo/'data/scripts/backup'/script),*args],env=dict(self.env,PZ_BACKUP_CPU_SCOPED='1'),capture_output=True,text=True,timeout=20)
        else:result=self.invoke(script,*args,input='oui\n')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('unfinished',result.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertEqual(self.rows(self.db,'allowedsteamid'),allowed)
        self.assertEqual({str(p.relative_to(self.world)):p.read_bytes() for p in self.world.rglob('*') if p.is_file()},tree)
        reverted=transaction('finish','--token',prepared.stdout.strip(),'--state','reverted')
        self.assertEqual(reverted.returncode,0,reverted.stderr)
    def test_pending_rename_refused(self):self.check_pending_mutation('manageWhitelist.sh','rename-account','old','new')
    def test_pending_remove_refused(self):self.check_pending_mutation('manageWhitelist.sh','remove-account','old')
    def test_pending_resetpassword_refused(self):self.check_pending_mutation('manageWhitelist.sh','resetpassword','old')
    def test_pending_interactive_purge_refused(self):self.check_pending_mutation('manageWhitelist.sh','purge','30j','--delete')
    def test_pending_wipe_refused(self):self.check_pending_mutation('wipeMapTile.sh','0','0')
    def test_pending_consistent_backup_refused(self):self.check_pending_mutation('dataBackup.sh','--consistent','--snapshot-only')
    def test_pending_character_restore_refused(self):
        source=self.base/'source-players.db';shutil.copy2(self.players,source)
        self.check_pending_mutation('restoreCharacter.sh','old',str(source))

    def test_remove_invalid_id_refused(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript("ALTER TABLE whitelist RENAME TO original; CREATE TABLE whitelist AS SELECT * FROM original;")
            db.execute('UPDATE whitelist SET id=? WHERE username=?',('not-an-id','old'));db.commit()
        before=self.rows(self.db,'whitelist')
        p=self.invoke('manageWhitelist.sh','remove-account','old')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
    def test_rename_interruption_before_commit_preserves_both(self):
        helper=self.repo/'data/scripts/lib/account_safety.py'
        code='''import sys,sqlite3,os,signal
sys.path.insert(0,sys.argv[1]);import account_safety
original=account_safety.connect
def traced(path):
 db=original(path)
 def stop(sql):
  if sql=='COMMIT':os.kill(os.getpid(),signal.SIGKILL)
 db.set_trace_callback(stop)
 return db
account_safety.connect=traced
account_safety.rename(sys.argv[2],sys.argv[3],'old','new')
'''
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        p=subprocess.run(['python3','-c',code,str(helper.parent),str(self.db),str(self.players)],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,-signal.SIGKILL,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before);self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_purge_read_error_before_backup(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('ALTER TABLE whitelist RENAME TO unreadable_whitelist');db.commit()
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Lecture SQLite impossible',p.stderr)
        self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
    def test_purge_read_and_write_lock_fail_closed(self):
        for transaction in ('BEGIN EXCLUSIVE','BEGIN IMMEDIATE'):
            with closing(sqlite3.connect(self.db)) as lock:
                lock.execute(transaction)
                before=lock.execute('SELECT * FROM whitelist ORDER BY 1').fetchall()
                p=self.invoke('purgeInactivePlayers.sh')
                self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
                if transaction=='BEGIN EXCLUSIVE':
                    self.assertIn('Lecture SQLite impossible',p.stderr)
                    self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
                else:
                    self.assertIn('Écriture SQLite impossible',p.stderr)
                    files=list(self.base.glob(self.db.name+'.pre-purge-*'))
                    self.assertEqual(len(files),1,p.stdout+p.stderr)
                    self.assertEqual(self.rows(files[0],'whitelist'),before)
                self.assertEqual(lock.execute('SELECT * FROM whitelist ORDER BY 1').fetchall(),before)
                lock.rollback()
    def test_purge_trigger_error_rolls_back_all(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("INSERT INTO whitelist VALUES(4,'second','secret','76561198000000004','2000-01-01','user','Second')")
            db.execute("CREATE TRIGGER reject BEFORE DELETE ON whitelist WHEN old.id=4 BEGIN SELECT RAISE(ABORT,'fixture reject'); END");db.commit()
        before=self.rows(self.db,'whitelist')
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('ROLLBACK',p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
    def test_purge_shared_sid_unknown_age_and_empty_plan(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("INSERT INTO whitelist VALUES(4,'shared','secret','76561198000000002',date('now'),'user','Shared')")
            db.execute("INSERT INTO whitelist VALUES(5,'unknown','secret','76561198000000005',NULL,'user','Unknown')");db.commit()
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept','shared','unknown'])
        self.assertEqual(self.rows(self.db,'allowedsteamid'),[('76561198000000002',)])
        backups=list(self.base.glob(self.db.name+'.pre-purge-*'))
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(list(self.base.glob(self.db.name+'.pre-purge-*')),backups)
    def test_purge_backup_error_prevents_delete(self):
        helper=self.repo/'data/scripts/lib/account_safety.py'
        helper.write_text(helper.read_text().replace('def backup(db_path):','def backup(db_path):\n    raise OSError("fixture disk unavailable")'))
        before=self.rows(self.db,'whitelist')
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Sauvegarde SQLite impossible',p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
    def wait_for_purge_backup(self,process,sentinel,timeout=5):
        deadline=time.monotonic()+timeout
        while not sentinel.exists() and process.poll() is None and time.monotonic()<deadline:
            time.sleep(.03)
        self.assertTrue(sentinel.exists(),'purge did not reach the durable-backup sentinel')
        self.assertIsNone(process.poll(),'purge exited before the pre-DELETE interruption')
    def test_term_precondition_rejects_unreached_backup(self):
        # A live process alone proves nothing: this guard must fail when backup
        # never publishes its explicit sentinel (the previous test passed here).
        class Alive:
            def poll(self):return None
        with self.assertRaisesRegex(AssertionError,'did not reach'):
            self.wait_for_purge_backup(Alive(),self.base/'never-published',timeout=0)
    def test_purge_term_before_delete_preserves_rows(self):
        self.env['PZ_PURGE_TEST_SLEEP']='10'
        temporary=self.base/'tmp';temporary.mkdir();self.env['TMPDIR']=str(temporary)
        sentinel=self.base/'backup-published';self.env['ACCOUNT_BACKUP_SENTINEL']=str(sentinel)
        helper=self.repo/'data/scripts/lib/account_safety.py'
        text=helper.read_text()
        publication='os.rename(temporary,final,src_dir_fd=parent,dst_dir_fd=parent);os.fsync(parent)'
        self.assertIn(publication,text)
        helper.write_text(text.replace(publication,publication+"\n        Path(os.environ['ACCOUNT_BACKUP_SENTINEL']).write_text(str(path.parent/final))"))
        before=self.rows(self.db,'whitelist');allowed=self.rows(self.db,'allowedsteamid')
        p=subprocess.Popen(['bash',str(self.repo/'data/scripts/admin/purgeInactivePlayers.sh')],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            self.wait_for_purge_backup(p,sentinel)
            backup=Path(sentinel.read_text())
            self.assertEqual(self.rows(backup,'whitelist'),before)
            # Wait for the real pre-DELETE sleep to exec before signalling its group.
            deadline=time.monotonic()+5
            observed=None
            while time.monotonic()<deadline and p.poll() is None:
                for candidate in Path('/proc').iterdir():
                    if not candidate.name.isdigit():continue
                    try:
                        fields=(candidate/'stat').read_text().rsplit(')',1)[1].split()
                        argv=(candidate/'cmdline').read_bytes().split(b'\0')
                        executable=os.readlink(candidate/'exe')
                        if int(fields[2])==p.pid and executable=='/usr/bin/sleep' and argv[:2]==[b'sleep',b'10']:
                            observed=(int(candidate.name),int(fields[2]),executable);break
                    except (OSError,ValueError):continue
                if observed:break
                time.sleep(.005)
            self.assertIsNotNone(observed,'native sleep 10 was not exec in purge process group')
            os.killpg(p.pid,signal.SIGTERM);out,err=p.communicate(timeout=10)
            self.assertNotEqual(p.returncode,0,out+err)
            self.assertEqual(self.rows(self.db,'whitelist'),before)
            self.assertEqual(self.rows(self.db,'allowedsteamid'),allowed)
            self.assertEqual(list(temporary.glob('pz-purge-*.sql')),[])
            lock=self.runtime/'pzmanager/world.lock'
            with lock.open('rb') as probe:
                fcntl.flock(probe,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.env.pop('PZ_PURGE_TEST_SLEEP')
            again=self.invoke('purgeInactivePlayers.sh')
            self.assertEqual(again.returncode,0,again.stdout+again.stderr)
            self.assertIn('Purge terminée : 1 compte(s) retiré(s), 1 SteamID',again.stdout)
            self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept'])
        finally:
            if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.communicate()
    def test_term_guard_rejects_worker_before_backup(self):
        helper=self.repo/'data/scripts/lib/account_safety.py'
        helper.write_text(helper.read_text().replace('def backup(db_path):','def backup(db_path):\n    time.sleep(30)'))
        with self.assertRaisesRegex(AssertionError,'did not reach the durable-backup sentinel'):
            self.test_purge_term_before_delete_preserves_rows()
    def test_purge_nominal_without_sid_third_authorization_and_counts(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("INSERT INTO whitelist VALUES(4,'shared-stale','secret','76561198000000003','2000-01-01','user','Shared')")
            db.execute("INSERT INTO whitelist VALUES(5,'without-sid','secret',NULL,'2000-01-01','user','No sid')")
            db.execute("INSERT INTO whitelist VALUES(6,'unknown','secret','76561198000000006',NULL,'user','Unknown')")
            db.execute("INSERT INTO allowedsteamid VALUES('76561198000000003')")
            db.execute("INSERT INTO allowedsteamid VALUES('76561198000000099')");db.commit()
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Purge terminée : 3 compte(s) retiré(s), 1 SteamID désautorisé(s).',p.stdout)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept','unknown'])
        self.assertEqual(self.rows(self.db,'allowedsteamid'),[('76561198000000003',),('76561198000000099',)])
        self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
        files=list(self.base.glob(self.db.name+'.pre-purge-*'))
        self.assertEqual(len(files),1,p.stdout+p.stderr)
        self.assertEqual(self.rows(files[0],'whitelist'),before)
    def freeze_purge_date(self):
        # Only the clock boundary is substituted in this disposable fixture.
        # Reads/deletes still execute the production SQL using real sqlite3.
        self.env['TZ']='UTC'
        self.executable(self.bin/'date', '''#!/usr/bin/env python3
import subprocess,sys
args=sys.argv[1:]
if '-d' in args:
 i=args.index('-d');relative=args[i+1];args=args[:i]+args[i+2:]
 when='2030-06-30 12:00:00 UTC '+relative
else:when='2030-06-30 12:00:00'
sys.exit(subprocess.call(['/usr/bin/date','--date',when,*args]))
''')
        self.executable(self.bin/'sqlite3', '''#!/usr/bin/env python3
import os,sys
args=[a.replace("date('now'", "date('2030-06-30'") for a in sys.argv[1:]]
os.execv('/usr/bin/sqlite3',['/usr/bin/sqlite3',*args])
''')
    def test_purge_days_boundary_and_existing_ledger(self):
        self.freeze_purge_date()
        fixtures=[(1,'admin','2000-01-01'),(2,'connection-old','2030-05-30'),(3,'connection-boundary','2030-05-31'),(4,'connection-recent','2030-06-01'),(5,'ledger-old',None),(6,'ledger-boundary',None),(7,'ledger-recent',None),(8,'unknown-age',None)]
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('DELETE FROM whitelist');db.execute('DELETE FROM allowedsteamid')
            for identity,name,last in fixtures:
                db.execute('INSERT INTO whitelist VALUES(?,?,?,?,?,?,?)',(identity,name,'secret',None,last,'admin' if name=='admin' else 'user',name))
            db.commit()
        ledger=self.base/'ledger.csv'
        existing='# username;steamid;created_at\nledger-old;;2030-05-31 11:59:59\nledger-boundary;;2030-05-31 12:00:00\nledger-recent;;2030-05-31 12:00:01\n'
        ledger.write_text(existing)
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        default=self.invoke('purgeInactivePlayers.sh','--dry-run')
        self.assertEqual(default.returncode,0,default.stdout+default.stderr)
        self.assertIn('Aucun compte inactif',default.stdout)
        self.assertEqual(ledger.read_text(),existing)
        preview=self.invoke('purgeInactivePlayers.sh','--dry-run','--days','30')
        self.assertEqual(preview.returncode,0,preview.stdout+preview.stderr)
        self.assertIn('2 compte(s) inactif(s)',preview.stdout)
        self.assertIn('connection-old : compte supprimé',preview.stdout)
        self.assertIn('ledger-old : compte supprimé',preview.stdout)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertEqual(ledger.read_text(),existing)
        p=self.invoke('purgeInactivePlayers.sh','--days=30')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Purge terminée : 2 compte(s) retiré(s), 0 SteamID désautorisé(s).',p.stdout)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','connection-boundary','connection-recent','ledger-boundary','ledger-recent','unknown-age'])
        self.assertTrue(ledger.read_text().startswith(existing),'pre-existing ledger entries changed')
        self.assertIn('unknown-age;;2030-06-30 12:00:00',ledger.read_text())
        self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_purge_keeps_invalid_dates_and_accepts_native_calendar_dates(self):
        self.check_purge_calendar_dates()
    def test_interactive_purge_keeps_invalid_calendar_dates(self):
        self.check_purge_calendar_dates(manual=True)
    def check_purge_calendar_dates(self,manual=False):
        self.freeze_purge_date()
        invalid=['0','1900-99-99','1900-02-29','2000-02-30','2001-04-31',
                 '2000-00-01','2000-01-00','2000-13-01','2000-01-32',
                 '2000-01-01 24:00:00','2000-01-01 12:60:00',
                 '2000-01-01 12:00:60','2000-1-01','2000-01-01 trailing',
                 '2000-01-01T12:00:00','2000-01-01 1:00:00']
        old=['1900-01-01','2000-02-29','2028-02-29 23:59:59','2000-01-01 00:00:00']
        kept=['2032-02-29','2032-02-29 23:59:59','2030-05-31','2030-05-31 12:00:00',None,'']
        fixtures=[('admin','1900-01-01')]
        ledger=['# username;steamid;created_at']
        for i,value in enumerate(invalid+old+kept):
            fixtures.append((f'connection-{i}',value))
            fixtures.append((f'ledger-{i}',None))
            ledger_value='2030-05-31 12:00:00' if value=='2030-05-31' else value
            ledger.append(f'ledger-{i};;{ledger_value or ""}')
        expected=[name for name,last in fixtures if name=='admin' or int(name.split('-')[1]) not in range(len(invalid),len(invalid)+len(old))]
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('DELETE FROM whitelist');db.execute('DELETE FROM allowedsteamid')
            for identity,(name,last) in enumerate(fixtures,1):
                db.execute('INSERT INTO whitelist VALUES(?,?,?,?,?,?,?)',(identity,name,'secret',None,last,'user',name))
            db.commit()
        ledger_path=self.base/'ledger.csv';existing='\n'.join(ledger)+'\n';ledger_path.write_text(existing)
        before=self.rows(self.db,'whitelist')
        preview=self.invoke('purgeInactivePlayers.sh','--dry-run','--days','30')
        self.assertEqual(preview.returncode,0,preview.stdout+preview.stderr)
        self.assertIn(f'{2*len(old)} compte(s) inactif(s)',preview.stdout)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertEqual(ledger_path.read_text(),existing)
        result=(self.invoke('manageWhitelist.sh','purge','30j','--delete',input='oui\n')
                if manual else self.invoke('purgeInactivePlayers.sh','--days','30'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],expected)
        self.assertTrue(ledger_path.read_text().startswith(existing))

    def test_purge_invalid_days_and_benign_bad_record_refused(self):
        before=self.rows(self.db,'whitelist')
        invalid=self.invoke('purgeInactivePlayers.sh','--days','not-a-number')
        self.assertNotEqual(invalid.returncode,0,invalid.stdout+invalid.stderr)
        self.assertIn('--days attend un nombre de jours',invalid.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('UPDATE whitelist SET username=? WHERE id=2',('benign\nmultiline',));db.commit()
        before=self.rows(self.db,'whitelist')
        malformed=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(malformed.returncode,0,malformed.stdout+malformed.stderr)
        self.assertRegex(malformed.stderr,'Registre incohérent|Ligne inattendue')
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
    def test_purge_wal_backup_includes_committed_pages(self):
        with closing(sqlite3.connect(self.db)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute("INSERT INTO whitelist VALUES(4,'wal-old','secret','76561198000000004','2000-01-01','user','Wal')");writer.commit()
            before=self.rows(self.db,'whitelist')
            p=self.invoke('purgeInactivePlayers.sh')
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            files=list(self.base.glob(self.db.name+'.pre-purge-*'))
            self.assertEqual(len(files),1,p.stdout+p.stderr)
            self.assertEqual(self.rows(files[0],'whitelist'),before)
    def test_purge_pending_transaction_refused(self):
        staging=self.base/'staging';shutil.copytree(self.world,staging)
        helper=self.repo/'data/scripts/lib/world_transaction.py'
        p=subprocess.run(['python3',str(helper),'begin','--world',str(self.world),'--kind','fixture','--recovery',str(self.base/'recovery'),'--after-tree',str(staging)],env=self.env,capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        before=self.rows(self.db,'whitelist')
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('unfinished',p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
    def test_start_pre_broker_preserves_parent_lock(self):
        self.run_start_pre_purge()
    def test_start_pre_backup_error_keeps_parent_lock_and_data(self):
        self.run_start_pre_purge(backup_fails=True)
    def run_start_pre_purge(self,backup_fails=False):
        before=self.rows(self.db,'whitelist')
        if backup_fails:
            helper=self.repo/'data/scripts/lib/account_safety.py'
            helper.write_text(helper.read_text().replace('def backup(db_path):','def backup(db_path):\n    raise OSError("fixture disk unavailable")'))
        private=self.runtime/'pzmanager';private.mkdir(mode=0o700)
        lock=private/'world.lock';ready=self.base/'ready';release=self.base/'release';token=self.base/'token'
        helper=self.repo/'data/scripts/internal/writing_start_admission.py'
        script='''set -euo pipefail
exec 201>"$1"
chmod 600 "$1"
flock -n 201
python3 "$2" prepare --lock-path "$1" --pid "$$" --fd 201 --unit zomboid.service > "$3"
touch "$4"
while [[ ! -f "$5" ]]; do sleep .02; done
python3 "$2" clear --lock-path "$1" --token "$(cat "$3")"
'''
        owner=subprocess.Popen(['bash','-c',script,'bash',str(lock),str(helper),str(token),str(ready),str(release)],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(150):
                if ready.exists():break
                if owner.poll() is not None:break
                time.sleep(.03)
            self.assertTrue(ready.exists(),'broker fixture failed')
            self.set_state('activating','start-pre',0,os.getpid())
            p=self.invoke('purgeInactivePlayers.sh')
            if backup_fails:
                self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
                self.assertIn('Sauvegarde SQLite impossible',p.stderr)
                self.assertEqual(self.rows(self.db,'whitelist'),before)
                self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
            else:
                self.assertEqual(p.returncode,0,p.stdout+p.stderr)
                self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept'])
                backups=list(self.base.glob(self.db.name+'.pre-purge-*'))
                self.assertEqual(len(backups),1,p.stdout+p.stderr)
                self.assertEqual(self.rows(backups[0],'whitelist'),before)
            with lock.open('rb') as probe:
                with self.assertRaises(BlockingIOError):fcntl.flock(probe,fcntl.LOCK_EX|fcntl.LOCK_NB)
            release.touch();out,err=owner.communicate(timeout=8)
            self.assertEqual(owner.returncode,0,out+err)
        finally:
            if owner.poll() is None:
                release.touch()
                try:owner.communicate(timeout=8)
                except subprocess.TimeoutExpired:owner.kill();owner.communicate()
    def test_remove_read_error_fails_closed(self):
        before=self.rows(self.db,'whitelist')
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('ALTER TABLE whitelist RENAME TO unreadable_whitelist');db.commit()
        p=self.invoke('manageWhitelist.sh','remove-account','old','--dry-run')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'unreadable_whitelist'),before)
    def test_remove_benign_multiline_and_duplicate_targets(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('UPDATE whitelist SET username=? WHERE id=2',('multi\nline',));db.commit()
        chars=self.rows(self.players,'networkPlayers')
        p=self.invoke('manageWhitelist.sh','remove-account','multi\nline','76561198000000002','multi\nline')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept'])
        self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_rename_atomic_second_update_error(self):
        with closing(sqlite3.connect(self.players)) as db:
            db.execute("CREATE TRIGGER reject BEFORE UPDATE ON networkPlayers BEGIN SELECT RAISE(ABORT,'fixture reject'); END");db.commit()
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        p=self.invoke('manageWhitelist.sh','rename-account','old',"new'世界")
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before);self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_rename_selects_configured_world_among_multiple(self):
        # The foreign save is created first, as it was for the legacy find|head.
        configured=self.world/'Saves/Multiplayer/servertest/players.db'
        configured.parent.mkdir()
        with closing(sqlite3.connect(configured)) as db:
            db.executescript("CREATE TABLE networkPlayers(id INTEGER PRIMARY KEY,username TEXT); INSERT INTO networkPlayers VALUES(1,'old'); INSERT INTO networkPlayers VALUES(2,'configured-sentinel');");db.commit()
        foreign_before=self.rows(self.players,'networkPlayers')
        p=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist')[1][1],'new')
        self.assertEqual(self.rows(configured,'networkPlayers'),[(1,'new'),(2,'configured-sentinel')])
        self.assertEqual(self.rows(self.players,'networkPlayers'),foreign_before)
    def test_rename_ambiguous_world_refuses_all_mutations(self):
        another=self.world/'Saves/Multiplayer/another/players.db'
        another.parent.mkdir();shutil.copy2(self.players,another)
        before=self.rows(self.db,'whitelist')
        first=self.rows(self.players,'networkPlayers');second=self.rows(another,'networkPlayers')
        p=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('Multiple character databases',p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertEqual(self.rows(self.players,'networkPlayers'),first)
        self.assertEqual(self.rows(another,'networkPlayers'),second)
    def test_rename_without_character_database_keeps_account_only_case(self):
        self.players.unlink()
        p=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist')[1][1],'new')
        self.assertFalse(self.players.exists())
    def test_rename_nominal(self):
        p=self.invoke('manageWhitelist.sh','rename-account','old',"new'世界")
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist')[1][1],"new'世界")
        self.assertEqual(self.rows(self.players,'networkPlayers')[0][1],"new'世界")
    def test_rename_wal_refused(self):
        with closing(sqlite3.connect(self.players)) as db:db.execute('PRAGMA journal_mode=WAL')
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        p=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before);self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_force_active_dry_run_is_read_only(self):
        self.set_state('active','running',1234,0)
        before=self.rows(self.db,'whitelist')
        p=self.invoke('purgeInactivePlayers.sh','--force','--dry-run')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertFalse((self.base/'ledger.csv').exists())
        self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
    def test_force_active_cannot_mutate(self):
        self.set_state('active','running',1234,0)
        before=self.rows(self.db,'whitelist')
        p=self.invoke('purgeInactivePlayers.sh','--force')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
    def test_manual_purge_has_faithful_backup(self):
        before=self.rows(self.db,'whitelist');chars=self.rows(self.players,'networkPlayers')
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept'])
        files=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
        self.assertEqual(len(files),1,p.stdout+p.stderr)
        self.assertEqual(self.rows(files[0],'whitelist'),before)
        self.assertEqual(self.rows(self.players,'networkPlayers'),chars)
    def test_foreign_states_and_fake_fd_refused(self):
        before=self.rows(self.db,'whitelist')
        private=self.runtime/'pzmanager';private.mkdir(mode=0o700)
        self.held=(private/'world.lock').open('w')
        self.addCleanup(self.held.close)
        fcntl.flock(self.held,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for state in [('activating','start-pre',0,999999),('deactivating','stop',0,0),('inactive','dead',1234,0),('failed','failed',0,0)]:
            self.set_state(*state)
            p=self.invoke('purgeInactivePlayers.sh','--force')
            self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
            self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.set_state('inactive','dead',0,0)
        occupied=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(occupied.returncode,0,occupied.stdout+occupied.stderr)
        self.assertIn('world operation is already running',occupied.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)
        self.assertFalse(list(self.base.glob(self.db.name+'.pre-purge-*')))
        self.env.update(PZ_WORLD_LOCK_FD='9999',PZ_WORLD_LOCK_DEPTH='1',PZ_WORLD_LOCK_FILE=str(private/'world.lock'))
        p=self.invoke('purgeInactivePlayers.sh','--admitted-worker')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)

if __name__=='__main__':
    os.umask(0o077);unittest.main()
