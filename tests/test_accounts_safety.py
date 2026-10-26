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
from startup_bus_fixture import write_busctl

ROOT=Path(os.environ['PZ_TEST_ROOT'])

class Accounts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='accounts-',dir=ROOT.parent)
        self.base=Path(self.tmp.name); self.repo=self.base/'repository'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        self.world=self.base/"world'世界";self.world.mkdir()
        self.db=self.world/"db/accounts'外.db";self.db.parent.mkdir();self.players=self.world/'Saves/Multiplayer/save/players.db';self.players.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript("CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT UNIQUE,password TEXT,steamid TEXT,lastConnection TEXT,role TEXT,displayName TEXT); CREATE TABLE allowedsteamid(steamid TEXT UNIQUE); INSERT INTO whitelist VALUES(1,'admin','a','76561198000000001','2000-01-01','admin','Admin'); INSERT INTO whitelist VALUES(2,'old','secret','76561198000000002','2000-01-01','user','Old'); INSERT INTO whitelist VALUES(3,'kept','x','76561198000000003',date('now'),'user','Kept'); INSERT INTO allowedsteamid VALUES('76561198000000002');")
            db.commit()
        with closing(sqlite3.connect(self.players)) as db:
            db.executescript("CREATE TABLE networkPlayers(id INTEGER PRIMARY KEY,username TEXT); INSERT INTO networkPlayers VALUES(1,'old');");db.commit()
        self.runtime=self.base/'runtime';self.runtime.mkdir(mode=0o700)
        self.bin=self.base/'bin';self.bin.mkdir();self.state=self.base/'state.json'
        write_busctl(self.bin,self.repo/'data/scripts/internal/startServer.sh','zomboid.service')
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
        vals=dict(PZ_SERVER_NAME="accounts'外",PZ_SOURCE_DIR=str(self.world),PZ_HOME=str(self.base),WHITELIST_LEDGER=str(self.base/'ledger.csv'),BACKUP_DIR=str(self.base/'backups'))
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
    def whitelist_cli(self,*args):
        shutil.copy2(ROOT/'pzm',self.repo/'pzm')
        return subprocess.run(['bash',str(self.repo/'pzm'),'whitelist',*args],env=self.env,
                              text=True,capture_output=True,timeout=20)

    def test_whitelist_reads_locked_database_report_failure(self):
        ledger=self.base/'ledger.csv'
        players=self.players.read_bytes()
        for bans in (False,True):
            if bans:
                with closing(sqlite3.connect(self.db)) as db:
                    db.executescript("CREATE TABLE bannedid(steamid TEXT,reason TEXT); INSERT INTO bannedid VALUES('76561198000000099','fixture');")
                    db.commit()
            before=self.db.read_bytes()
            for history in (None,b'# historical registry\nold;;1998-01-01\n'):
                if history is not None:ledger.write_bytes(history)
                with closing(sqlite3.connect(self.db)) as lock:
                    lock.execute('BEGIN EXCLUSIVE')
                    self.assertEqual(lock.execute('SELECT COUNT(*) FROM whitelist').fetchone()[0],3)
                    self.assertEqual(lock.execute("SELECT COUNT(*) FROM whitelist WHERE username<>'admin' AND lastConnection<date('now','-30 days')").fetchone()[0],1)
                    for args in (('list',),('purge','30j')):
                        with self.subTest(bannedid=bans,history=history is not None,args=args):
                            result=self.whitelist_cli(*args)
                            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                            self.assertIn('Lecture SQLite impossible',result.stderr)
                            self.assertIn('locked',result.stderr)
                            self.assertNotIn('Total: 0',result.stdout)
                            self.assertNotIn('Aucun compte trouvé.',result.stdout)
                            self.assertEqual(ledger.read_bytes() if ledger.exists() else None,history)
                    help_result=self.whitelist_cli('help')
                    self.assertEqual(help_result.returncode,0,help_result.stdout+help_result.stderr)
                    self.assertIn('Usage:',help_result.stdout)
                    lock.rollback()
                self.assertEqual(self.db.read_bytes(),before)
                self.assertEqual(self.players.read_bytes(),players)
                if ledger.exists():ledger.unlink()

    def test_whitelist_reads_nominal_and_empty(self):
        ledger=self.base/'ledger.csv'
        history=b'# historical registry\nold;;1998-01-01\nadmin;;1998-01-01\nkept;;1998-01-01\n'
        ledger.write_bytes(history)
        for bans in (False,True):
            if bans:
                with closing(sqlite3.connect(self.db)) as db:
                    db.executescript("CREATE TABLE bannedid(steamid TEXT,reason TEXT); INSERT INTO bannedid VALUES('76561198000000099','fixture');")
                    db.commit()
            before=self.db.read_bytes();players=self.players.read_bytes()
            listed=self.whitelist_cli('list')
            self.assertEqual(listed.returncode,0,listed.stdout+listed.stderr)
            self.assertIn('Total: 1 SteamID autorisé(s)',listed.stdout)
            self.assertIn('Total: 3 compte(s)',listed.stdout)
            self.assertEqual('SteamID bannis (1)' in listed.stdout,bans)
            preview=self.whitelist_cli('purge','30j')
            self.assertEqual(preview.returncode,0,preview.stdout+preview.stderr)
            self.assertIn('Total: 1 compte(s)',preview.stdout)
            self.assertIn('old',preview.stdout)
            self.assertEqual(self.db.read_bytes(),before)
            self.assertEqual(self.players.read_bytes(),players)
            self.assertEqual(ledger.read_bytes(),history)
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript('DELETE FROM whitelist; DELETE FROM allowedsteamid; DELETE FROM bannedid;')
            db.commit()
        before=self.db.read_bytes()
        listed=self.whitelist_cli('list');preview=self.whitelist_cli('purge','30j')
        self.assertEqual(listed.returncode,0,listed.stdout+listed.stderr)
        self.assertIn('Total: 0 SteamID autorisé(s)',listed.stdout)
        self.assertIn('Total: 0 compte(s)',listed.stdout)
        self.assertEqual(preview.returncode,0,preview.stdout+preview.stderr)
        self.assertIn('Aucun compte trouvé.',preview.stdout)
        self.assertEqual(self.db.read_bytes(),before)
        self.assertEqual(self.players.read_bytes(),players)
        self.assertEqual(ledger.read_bytes(),history)

    def test_ledger_lock_contention_preserves_bytes_and_aliases(self):
        ledger=self.base/'ledger.csv'
        history=b'# history\nlegacy;;1998-01-01\n'
        ledger.write_bytes(history)
        state=self.base/'pzmanager';state.mkdir(mode=0o700)
        import hashlib
        lock=state/('ledger-'+hashlib.sha256(os.fsencode(ledger.resolve())).hexdigest()+'.lock')
        alias=self.base/'alias.csv';alias.symlink_to(ledger)
        runtime=self.base/'other-runtime';runtime.mkdir(mode=0o700)
        before=self.db.read_bytes()
        with lock.open('w') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            inode=lock.stat().st_ino
            for target in (ledger,alias):
                with self.subTest(target=target):
                    with (self.repo/'.env').open('a') as config:
                        config.write('WHITELIST_LEDGER='+shlex.quote(str(target))+'\n')
                    result=subprocess.run(['bash',str(self.repo/'data/scripts/admin/creationDateInit.sh')],
                                          env=dict(self.env,XDG_RUNTIME_DIR=str(runtime)),text=True,capture_output=True,timeout=20)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('Verrou du registre',result.stderr)
                    self.assertEqual(ledger.read_bytes(),history)
                    self.assertEqual(self.db.read_bytes(),before)
        result=self.invoke('creationDateInit.sh')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(ledger.read_bytes().startswith(history))
        self.assertEqual(lock.stat().st_ino,inode)

    def test_ledger_private_lock_rejects_prepositioned_entries(self):
        import hashlib
        ledger=self.base/'ledger.csv';history=b'# immutable history\n'
        ledger.write_bytes(history)
        state=self.base/'pzmanager';state.mkdir(mode=0o700)
        lock=state/('ledger-'+hashlib.sha256(os.fsencode(ledger.resolve())).hexdigest()+'.lock')
        victim=self.base/'victim';victim.write_bytes(b'untouched')
        for kind in ('symlink','fifo','hardlink'):
            with self.subTest(kind=kind):
                if kind=='symlink':lock.symlink_to(victim)
                elif kind=='fifo':os.mkfifo(lock,0o600)
                else:os.link(victim,lock)
                try:
                    result=self.invoke('creationDateInit.sh')
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('Verrou du registre non sûr',result.stderr)
                    self.assertEqual(ledger.read_bytes(),history)
                    self.assertEqual(victim.read_bytes(),b'untouched')
                finally:lock.unlink()

    def test_ledger_hardlink_refused_before_mutation(self):
        ledger=self.base/'ledger.csv';history=b'# immutable history\n'
        ledger.write_bytes(history);os.link(ledger,self.base/'hardlink.csv')
        result=self.invoke('creationDateInit.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('liens multiples',result.stderr)
        self.assertEqual(ledger.read_bytes(),history)

    def test_ledger_paths_preserve_final_newlines_and_exact_parents(self):
        import hashlib
        before=self.db.read_bytes()
        for name,nested,alias in (('ledger.csv\n',False,False),('ledger.csv\n\n',False,False),
                                  ('ledger.csv\n',False,True),('ledger.csv',True,False)):
            with self.subTest(name=name,nested=nested,alias=alias):
                case=Path(tempfile.mkdtemp(dir=self.base))
                parent=case/'parent\n' if nested else case
                parent.mkdir(exist_ok=True)
                target=parent/name;history=b'# exact configured history\n'
                target.write_bytes(history)
                sibling=parent/name.rstrip('\n') if name.endswith('\n') else case/'parent'
                if nested:sibling.mkdir()
                else:sibling.write_bytes(b'# unrelated file\n')
                configured=case/'alias.csv' if alias else target
                if alias:configured.symlink_to(target)
                with (self.repo/'.env').open('a') as config:
                    config.write('WHITELIST_LEDGER='+shlex.quote(str(configured))+'\n')
                result=self.invoke('creationDateInit.sh')
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertTrue(target.read_bytes().startswith(history))
                self.assertIn(b'old;76561198000000002;',target.read_bytes())
                if not nested:self.assertEqual(sibling.read_bytes(),b'# unrelated file\n')
                lock=parent/'pzmanager'/('ledger-'+hashlib.sha256(os.fsencode(target)).hexdigest()+'.lock')
                self.assertTrue(lock.is_file(),str(lock))
                self.assertEqual(self.db.read_bytes(),before)

    def test_ledger_rejects_exact_insecure_newline_ancestor(self):
        actual=self.base/'parent\n';actual.mkdir();actual.chmod(0o777)
        safe=self.base/'parent';safe.mkdir(mode=0o700)
        directory=actual/'inner';directory.mkdir()
        target=directory/'ledger.csv';history=b'# untouched\n';target.write_bytes(history)
        with (self.repo/'.env').open('a') as config:
            config.write('WHITELIST_LEDGER='+shlex.quote(str(target))+'\n')
        result=self.invoke('creationDateInit.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Verrou du registre non sûr',result.stderr)
        self.assertEqual(target.read_bytes(),history)
        self.assertFalse((directory/'pzmanager').exists())

    def test_ledger_canonicalization_failure_rejects_partial_output(self):
        target=self.base/'partial.csv';history=b'# partial output is not a path\n';target.write_bytes(history)
        self.executable(self.bin/'readlink', '#!/bin/bash\nif [[ "${1:-}" == -m ]]; then\n'
                        +'printf "%s\\n" '+shlex.quote(str(target))+'\nexit 23\nfi\nexec /usr/bin/readlink "$@"\n')
        result=self.invoke('creationDateInit.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Chemin du registre',result.stderr)
        self.assertEqual(target.read_bytes(),history)
        self.assertFalse((self.base/'ledger.csv').exists())
        self.assertFalse((self.base/'pzmanager').exists())

    def test_ledger_framing_keeps_distinct_unknown_account(self):
        self.check_ledger_framing()
    def test_ledger_new_file_and_interactive_purge_keep_unknown_account(self):
        self.check_ledger_framing(prior=False,manual=True)
    def check_ledger_framing(self,prior=True,manual=False):
        shutil.copy2(ROOT/'pzm',self.repo/'pzm')
        def rename(old,new):
            result=subprocess.run(['bash',str(self.repo/'pzm'),'whitelist','rename-account',old,new],env=self.env,text=True,capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        victim='new-player'
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('INSERT INTO whitelist VALUES(?,?,?,?,?,?,?)',(4,victim,'fixture','76561198000000004',None,'user','New'))
            db.execute('INSERT INTO allowedsteamid VALUES(?)',('76561198000000004',));db.commit()
        ledger=self.base/'ledger.csv'
        history=b'# historical registry\nhistoric;;1999-01-01 00:00:00\nold;76561198000000002;1998-01-01\n'
        if prior:ledger.write_bytes(history)
        else:history=b''
        players=self.rows(self.players,'networkPlayers')
        alias='prefix\n'+victim
        rename('old',alias)
        generated=self.invoke('creationDateInit.sh')
        self.assertEqual(generated.returncode,0,generated.stdout+generated.stderr)
        self.assertTrue(ledger.read_bytes().startswith(history))
        before_guard=self.rows(self.db,'whitelist')
        guard=self.invoke('purgeInactivePlayers.sh','--dry-run','--days','30')
        self.assertNotEqual(guard.returncode,0,guard.stdout+guard.stderr)
        self.assertIn('Registre incohérent',guard.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before_guard)
        rename(alias,'old')
        purged=(self.invoke('manageWhitelist.sh','purge','30j','--delete',input='oui\n')
                if manual else self.invoke('purgeInactivePlayers.sh','--days','30'))
        self.assertEqual(purged.returncode,0,purged.stdout+purged.stderr)
        self.assertIn(victim,[row[1] for row in self.rows(self.db,'whitelist')])
        self.assertIn(('76561198000000004',),self.rows(self.db,'allowedsteamid'))
        self.assertNotIn('old',[row[1] for row in self.rows(self.db,'whitelist')])
        self.assertEqual(self.rows(self.players,'networkPlayers'),players)
        self.assertTrue(ledger.read_bytes().startswith(history))
        self.assertNotIn(b'new-player;76561198000000002;',ledger.read_bytes())

    def test_ledger_select_failure_preserves_absence_or_history(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('ALTER TABLE whitelist RENAME TO unavailable');db.commit()
        before=self.db.read_bytes()
        ledger=self.base/'ledger.csv'
        for history in (None,b'# historic\nold;;1998-01-01\n'):
            with self.subTest(existing=history is not None):
                if history is not None:ledger.write_bytes(history)
                result=self.invoke('creationDateInit.sh')
                self.assertIn('registre inchangé',result.stdout+result.stderr)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(ledger.read_bytes() if ledger.exists() else None,history)
                self.assertEqual(self.db.read_bytes(),before)

    def test_ledger_representable_names_and_first_appearance(self):
        ledger=self.base/'ledger.csv'
        history=b'# historic\r\nhistoric;;1999-01-01 00:00:00\r\nold;76561198000000002;1998-01-01\n'
        ledger.write_bytes(history)
        for alias in ('MabEira | Hannibal 世界','US-prefix\x1fUS-suffix'):
            with self.subTest(alias=alias):
                rename=self.invoke('manageWhitelist.sh','rename-account','old',alias)
                self.assertEqual(rename.returncode,0,rename.stdout+rename.stderr)
                before=self.db.read_bytes()
                result=self.invoke('creationDateInit.sh')
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                expected=(alias+';76561198000000002;2000-01-01\n').encode()
                self.assertIn(expected,ledger.read_bytes())
                self.assertEqual(self.db.read_bytes(),before)
                with closing(sqlite3.connect(self.db)) as db:
                    db.execute('UPDATE whitelist SET lastConnection=? WHERE username=?',('2001-01-01',alias));db.commit()
                again=self.invoke('creationDateInit.sh')
                self.assertEqual(again.returncode,0,again.stdout+again.stderr)
                self.assertEqual(ledger.read_bytes().count(expected),1)
                self.assertNotIn((alias+';76561198000000002;2001-01-01').encode(),ledger.read_bytes())
                self.assertTrue(ledger.read_bytes().startswith(history))
                restored=self.invoke('manageWhitelist.sh','rename-account',alias,'old')
                self.assertEqual(restored.returncode,0,restored.stdout+restored.stderr)
                with closing(sqlite3.connect(self.db)) as db:
                    db.execute('UPDATE whitelist SET lastConnection=? WHERE username=?',('2000-01-01','old'));db.commit()
        self.assertEqual(ledger.stat().st_mode & 0o777,0o600)

    def test_ledger_rejects_unrepresentable_fields_without_forged_rows(self):
        ledger=self.base/'ledger.csv'
        history=b'# historic\nhistoric;;1999-01-01 00:00:00\n'
        ledger.write_bytes(history)
        for field in ('username','steamid','lastConnection'):
            for delimiter in (';','\n','\r','\0'):
                with self.subTest(field=field,delimiter=repr(delimiter)):
                    with closing(sqlite3.connect(self.db)) as db:
                        db.execute('UPDATE whitelist SET username=?,steamid=?,lastConnection=? WHERE id=2',('old','76561198000000002','2000-01-01'))
                        db.execute('UPDATE whitelist SET '+field+'=? WHERE id=2',('prefix'+delimiter+'forged',));db.commit()
                    result=self.invoke('creationDateInit.sh')
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('AVERTISSEMENT',result.stderr)
                    content=ledger.read_bytes()
                    self.assertTrue(content.startswith(history))
                    self.assertNotIn(b'old;',content)
                    self.assertNotIn(b'prefix',content)
                    self.assertNotIn(b'forged',content)
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('UPDATE whitelist SET username=?,steamid=?,lastConnection=? WHERE id=2',('#comment','76561198000000002','2000-01-01'));db.commit()
        result=self.invoke('creationDateInit.sh')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('AVERTISSEMENT',result.stderr)
        self.assertNotIn(b'#comment',ledger.read_bytes())

    def test_ledger_busy_read_preserves_absence(self):
        ledger=self.base/'ledger.csv'
        with closing(sqlite3.connect(self.db)) as lock:
            lock.execute('BEGIN EXCLUSIVE')
            before=lock.execute('SELECT * FROM whitelist ORDER BY id').fetchall()
            result=self.invoke('creationDateInit.sh')
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('registre inchangé',result.stdout)
            self.assertIn('locked',result.stderr)
            self.assertFalse(ledger.exists())
            self.assertEqual(lock.execute('SELECT * FROM whitelist ORDER BY id').fetchall(),before)
            lock.rollback()

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
        self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
    def test_purge_read_and_write_lock_fail_closed(self):
        for transaction in ('BEGIN EXCLUSIVE','BEGIN IMMEDIATE'):
            with closing(sqlite3.connect(self.db)) as lock:
                lock.execute(transaction)
                before=lock.execute('SELECT * FROM whitelist ORDER BY 1').fetchall()
                p=self.invoke('purgeInactivePlayers.sh')
                self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
                if transaction=='BEGIN EXCLUSIVE':
                    self.assertIn('Lecture SQLite impossible',p.stderr)
                    self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
                else:
                    self.assertIn('Écriture SQLite impossible',p.stderr)
                    files=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
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
        backups=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
        p=self.invoke('purgeInactivePlayers.sh')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(list(self.db.parent.glob(self.db.name+'.pre-purge-*')),backups)
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
        files=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
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
        self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
    def test_purge_wal_backup_includes_committed_pages(self):
        with closing(sqlite3.connect(self.db)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute("INSERT INTO whitelist VALUES(4,'wal-old','secret','76561198000000004','2000-01-01','user','Wal')");writer.commit()
            before=self.rows(self.db,'whitelist')
            p=self.invoke('purgeInactivePlayers.sh')
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            files=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
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
source "$(dirname "$2")/../lib/common.sh"
source_env
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
                self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
            else:
                self.assertEqual(p.returncode,0,p.stdout+p.stderr)
                self.assertEqual([r[1] for r in self.rows(self.db,'whitelist')],['admin','kept'])
                backups=list(self.db.parent.glob(self.db.name+'.pre-purge-*'))
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
        configured=self.world/'Saves/Multiplayer'/self.db.stem/'players.db'
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
        self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
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
        self.assertFalse(list(self.db.parent.glob(self.db.name+'.pre-purge-*')))
        self.env.update(PZ_WORLD_LOCK_FD='9999',PZ_WORLD_LOCK_DEPTH='1',PZ_WORLD_LOCK_FILE=str(private/'world.lock'))
        p=self.invoke('purgeInactivePlayers.sh','--admitted-worker')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(self.rows(self.db,'whitelist'),before)

    def test_account_previews_hot_journal_preserve_sources(self):
        import hashlib
        for args,characters in [(('remove-account','old','--dry-run'),False),(('rename-account','old','new','--dry-run'),False),(('rename-account','old','new','--dry-run'),True)]:
            with self.subTest(args=args,characters=characters):
                case=Accounts();case.setUp()
                try:
                    path=case.players if characters else case.db
                    statement="UPDATE networkPlayers SET username=? WHERE id=1" if characters else "UPDATE whitelist SET password=? WHERE id=2"
                    code="import sqlite3,sys,os;d=sqlite3.connect(sys.argv[1]);d.execute('PRAGMA cache_size=1');d.execute('BEGIN IMMEDIATE');d.execute(sys.argv[2],('X'*200000,));os._exit(99)"
                    crashed=subprocess.run(['python3','-c',code,str(path),statement],env=case.env,capture_output=True,text=True,timeout=10)
                    self.assertEqual(crashed.returncode,99,crashed.stderr)
                    def image():
                        return {str(db)+suffix:hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None for db in (case.db,case.players) for suffix in ('','-journal','-wal','-shm') for p in [Path(str(db)+suffix)]}
                    before=image();result=case.whitelist_cli(*args)
                    self.assertEqual(image(),before,'preview mutated SQLite source: '+result.stdout+result.stderr)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('recovery',result.stderr)
                    self.assertNotIn("Rien n'a été modifié",result.stdout)
                finally:case.tearDown()

    def test_account_previews_clean_cli(self):
        for args in [('remove-account','old','--dry-run'),('rename-account','old','new','--dry-run')]:
            before={p:p.read_bytes() for p in self.world.rglob('*') if p.is_file()}
            result=self.whitelist_cli(*args)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn("Rien n'a été modifié",result.stdout)
            self.assertEqual({p:p.read_bytes() for p in self.world.rglob('*') if p.is_file()},before)

    def preview_helper(self,code):
        prefix="import sys,os,sqlite3,subprocess,json;from pathlib import Path;sys.path.insert(0,sys.argv[1]);import account_safety as a;db=Path(sys.argv[2]);players=Path(sys.argv[3]);"
        return subprocess.run(['python3','-c',prefix+code,str(self.repo/'data/scripts/lib'),str(self.db),str(self.players)],
            env=dict(self.env,PZ_SOURCE_DIR=str(self.world),TMPDIR=str(self.world)),capture_output=True,text=True,timeout=20)

    def preview_image(self):
        # Never open/close source in the SQLite lock holder: POSIX locks are per process.
        code="import sys,hashlib,json;from pathlib import Path;print(json.dumps({str(p):(hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_size,p.stat().st_mtime_ns,p.stat().st_ctime_ns) if p.exists() else None for db in sys.argv[1:] for suffix in ('','-journal','-wal','-shm') for p in [Path(db+suffix)]}))"
        return subprocess.check_output(['python3','-c',code,str(self.db),str(self.players)],env=self.env,text=True,timeout=10)

    def test_account_previews_wal_commits_and_residual_tail(self):
        for missing_shm in (False,True):
            case=Accounts();case.setUp();connections=[]
            try:
                for path,table in [(case.db,'whitelist'),(case.players,'networkPlayers')]:
                    if missing_shm:
                        code="import sqlite3,sys,os;d=sqlite3.connect(sys.argv[1]);d.execute('PRAGMA journal_mode=WAL');d.execute('UPDATE '+sys.argv[2]+\" SET username='wal-old' WHERE username='old'\");d.commit();os._exit(99)"
                        result=subprocess.run(['python3','-c',code,str(path),table],env=case.env,capture_output=True,text=True,timeout=10)
                        self.assertEqual(result.returncode,99,result.stderr);Path(str(path)+'-shm').unlink(missing_ok=True)
                    else:
                        d=sqlite3.connect(path,timeout=0);connections.append(d);d.execute('PRAGMA journal_mode=WAL')
                        d.execute('UPDATE '+table+" SET username='wal-old' WHERE username='old'");d.commit()
                    with Path(str(path)+'-wal').open('ab') as tail:tail.write(b'residual-tail')
                before=case.preview_image()
                for args in [('remove-account','wal-old','--dry-run'),('rename-account','wal-old','new','--dry-run')]:
                    result=case.whitelist_cli(*args)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('wal-old',result.stdout)
                    if args[0]=='rename-account':self.assertIn('1 personnage(s)',result.stdout)
                    self.assertEqual(case.preview_image(),before)
            finally:
                for d in connections:d.close()
                case.tearDown()

    def test_account_preview_existing_locks_refused(self):
        for path in (self.db,self.players):
            for begin in ('BEGIN EXCLUSIVE','BEGIN IMMEDIATE'):
                with closing(sqlite3.connect(path,timeout=0)) as writer:
                    writer.execute(begin);before=self.preview_image()
                    result=self.whitelist_cli('rename-account','old','new','--dry-run')
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('locked',result.stderr);self.assertEqual(self.preview_image(),before);writer.rollback()

    def test_account_preview_two_wal_guards_block_writers_and_checkpoints(self):
        connections=[]
        try:
            for path,table in [(self.db,'whitelist'),(self.players,'networkPlayers')]:
                d=sqlite3.connect(path,timeout=0);connections.append(d);d.execute('PRAGMA journal_mode=WAL')
                d.execute('UPDATE '+table+" SET username='old' WHERE username='old'");d.commit()
            before=self.preview_image()
            # Called at first private SQLite open, after both source guards exist,
            # and again at final common revalidation, before either guard releases.
            code='''
original=a.sqlite3.connect
check=a._check_preview_sources
calls=[]
def assert_guards():
 for path in (db,players):
  for sql in ('BEGIN IMMEDIATE','PRAGMA wal_checkpoint(TRUNCATE)'):
   script="import sqlite3,sys;d=sqlite3.connect(sys.argv[1],timeout=0);print(d.execute(sys.argv[2]).fetchall())"
   r=subprocess.run(['python3','-c',script,str(path),sql],capture_output=True,text=True,timeout=5)
   assert (r.returncode!=0 and 'locked' in r.stderr) if sql.startswith('BEGIN') else (r.returncode==0 and r.stdout.startswith('[(1,')),(path,sql,r.stdout,r.stderr)
 calls.append(True)
def connect(*args,**kwargs):
 assert_guards()
 return original(*args,**kwargs)
def checked(sources):
 if calls:assert_guards()
 return check(sources)
a.sqlite3.connect=connect;a._check_preview_sources=checked
a.rename_plan(db,players,'old','new')
assert len(calls)>=3,calls
'''
            result=self.preview_helper(code);self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertEqual(self.preview_image(),before)
            for path in (self.db,self.players):
                with closing(sqlite3.connect(path,timeout=0)) as writer:
                    writer.execute('BEGIN IMMEDIATE');result=self.preview_helper("a.rename_plan(db,players,'old','new')")
                    self.assertNotEqual(result.returncode,0);self.assertIn('locked',result.stderr);writer.rollback()
        finally:
            for d in connections:d.close()

    def test_account_preview_active_checkpoint_refused(self):
        with closing(sqlite3.connect(self.db,timeout=0)) as writer,closing(sqlite3.connect(self.db,timeout=0)) as reader:
            writer.execute('PRAGMA journal_mode=WAL');writer.execute("UPDATE whitelist SET password='first' WHERE id=2");writer.commit()
            reader.execute('BEGIN');reader.execute('SELECT * FROM whitelist').fetchall()
            writer.execute("UPDATE whitelist SET password='second' WHERE id=2");writer.commit()
            code="import sqlite3,sys;d=sqlite3.connect(sys.argv[1],timeout=10);print('ready',flush=True);print(d.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall())"
            checkpoint=subprocess.Popen(['python3','-c',code,str(self.db)],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                self.assertEqual(checkpoint.stdout.readline().strip(),'ready')
                probe="import os,fcntl,sys;fd=os.open(sys.argv[1]+'-shm',os.O_RDONLY);fcntl.lockf(fd,fcntl.LOCK_SH|fcntl.LOCK_NB)"
                for attempt in range(30):
                    observed=subprocess.run(['python3','-c',probe,str(self.db)],env=self.env,capture_output=True,text=True,timeout=10)
                    if observed.returncode and 'BlockingIOError' in observed.stderr:break
                else:self.fail('active checkpoint lock not observed')
                before=self.preview_image();result=self.whitelist_cli('rename-account','old','new','--dry-run')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('locked',result.stderr);self.assertEqual(self.preview_image(),before)
            finally:checkpoint.terminate();checkpoint.communicate(timeout=10);reader.rollback()

    def test_account_preview_existing_sidecar_changes_refused(self):
        for suffix in ('-wal','-shm'):
            for change in ('remove','replace'):
                case=Accounts();case.setUp()
                try:
                    sidecar=Path(str(case.db)+suffix);sidecar.write_bytes(b'initial')
                    hook="side=Path(str(db)+"+repr(suffix)+");side.unlink()"+('' if change=='remove' else ";side.write_bytes(b'replaced')")
                    code="original=a.os.pread\nchanged=False\ndef read(fd,size,offset):\n global changed\n if not changed:\n  changed=True\n  "+hook+"\n return original(fd,size,offset)\na.os.pread=read\na.remove(db,['old'],True)"
                    result=case.preview_helper(code);self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn('changed',result.stderr);self.assertNotIn('plan',result.stdout)
                finally:case.tearDown()

    def test_account_preview_changes_and_aliases_refused(self):
        hooks=["Path(str(db)+'-shm').write_bytes(b'new')", "db.write_bytes(db.read_bytes())", "(db.parent.rename(str(db.parent)+'.old'),Path(db.parent).mkdir(),__import__('shutil').copyfile(Path(str(db.parent)+'.old')/db.name,db))"]
        for hook in hooks:
            case=Accounts();case.setUp()
            try:
                code='''
original=a.os.pread
changed=False
def read(fd,size,offset):
 global changed
 if not changed:
  changed=True
  HOOK
 return original(fd,size,offset)
a.os.pread=read
a.remove(db,['old'],True)
'''.replace('HOOK',hook)
                result=case.preview_helper(code);self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('changed',result.stderr);self.assertNotIn('plan',result.stdout)
            finally:case.tearDown()
        result=self.preview_helper("a.rename_plan(db,db,'old','new')")
        self.assertNotEqual(result.returncode,0);self.assertIn('Aliased',result.stderr)
        Path(str(self.db)+'-wal').symlink_to(self.players)
        result=self.whitelist_cli('remove-account','old','--dry-run');self.assertNotEqual(result.returncode,0)
        Path(str(self.db)+'-wal').unlink()
        os.link(self.players,Path(str(self.db)+'-wal'))
        result=self.whitelist_cli('remove-account','old','--dry-run');self.assertNotEqual(result.returncode,0)
        Path(str(self.db)+'-wal').unlink()
        self.db.chmod(0o666)
        result=self.whitelist_cli('remove-account','old','--dry-run');self.assertNotEqual(result.returncode,0)

    def test_account_preview_private_temp_short_writes_and_cleanup(self):
        before=self.preview_image()
        code='''
original=a.os.write
created=[]
connect=a.sqlite3.connect
root=Path(os.environ['PZ_SOURCE_DIR']).resolve()
def opened(path,*args,**kwargs):
 p=Path(path);assert not p.resolve().is_relative_to(root),p
 assert p.parent.stat().st_mode & 0o777==0o700
 assert p.stat().st_mode & 0o777==0o600
 created.append(p.parent)
 return connect(path,*args,**kwargs)
def short(fd,data):return original(fd,data[:7])
a.os.write=short;a.sqlite3.connect=opened
fds=len(list(Path('/proc/self/fd').iterdir()))
a.remove(db,['old'],True)
assert created and all(not p.exists() for p in created)
assert len(list(Path('/proc/self/fd').iterdir()))==fds
'''
        result=self.preview_helper(code);self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertEqual(self.preview_image(),before)
        for target,failure in [("a.os.write","OSError(28,'No space left on device')"),("a.os.write","KeyboardInterrupt()"),("a.sqlite3.connect","sqlite3.OperationalError('fixture read failed')")]:
            code='''
created=[]
original=a.tempfile.TemporaryDirectory
class Temporary(original):
 def __enter__(self):
  path=super().__enter__();created.append(Path(path));return path
a.tempfile.TemporaryDirectory=Temporary
def fail(*args,**kwargs):raise FAILURE
TARGET=fail
fds=len(list(Path('/proc/self/fd').iterdir()))
try:a.remove(db,['old'],True)
except (OSError,KeyboardInterrupt,sqlite3.Error):pass
else:raise AssertionError('expected failure')
assert created and all(not p.exists() for p in created)
assert len(list(Path('/proc/self/fd').iterdir()))==fds
'''.replace('FAILURE',failure).replace('TARGET',target)
            result=self.preview_helper(code);self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertEqual(self.preview_image(),before)

    def test_account_previews_persist_cold_and_active_fallback(self):
        with closing(sqlite3.connect(self.db)) as d:
            d.execute('PRAGMA journal_mode=PERSIST');d.execute("UPDATE whitelist SET password='persist' WHERE id=2");d.commit()
        self.assertGreater(Path(str(self.db)+'-journal').stat().st_size,0)
        for active in (False,True):
            if active:self.set_state('active','running',999999,0)
            for command in ('remove-account','rename-account'):
                args=[command,'old']+(['new'] if command=='rename-account' else [])+([] if active else ['--dry-run'])
                before=self.preview_image();result=self.whitelist_cli(*args)
                self.assertEqual(result.returncode==0,not active,result.stdout+result.stderr)
                self.assertIn('plan',result.stdout);self.assertEqual(self.preview_image(),before)

    def test_account_readers_hot_and_clean_sources_unchanged(self):
        for hot in (False,True):
            for surface in ('auto-active','auto-inactive','list','manual-purge'):
                with self.subTest(hot=hot,surface=surface):
                    case=Accounts();case.setUp()
                    try:
                        ledger=case.base/'ledger.csv';ledger.write_text('# historical\nadmin;;1998-01-01\nold;;1998-01-01\nkept;;1998-01-01\n');csv=ledger.read_bytes()
                        if surface!='auto-inactive':case.set_state('active','running',999999,0)
                        if hot:
                            code="import sqlite3,sys,os;d=sqlite3.connect(sys.argv[1]);d.execute('PRAGMA cache_size=1');d.execute('BEGIN IMMEDIATE');d.execute(\"UPDATE whitelist SET password=? WHERE id=2\",('X'*200000,));os._exit(99)"
                            crashed=subprocess.run(['python3','-c',code,str(case.db)],env=case.env,capture_output=True,text=True,timeout=10)
                            self.assertEqual(crashed.returncode,99,crashed.stderr)
                        before=case.preview_image()
                        if surface.startswith('auto'):
                            args=['--dry-run','--days','30']+(['--force'] if surface=='auto-active' else [])
                            result=case.invoke('purgeInactivePlayers.sh',*args)
                        else:result=case.whitelist_cli(*(['list'] if surface=='list' else ['purge','30j']))
                        self.assertEqual(case.preview_image(),before,'reader mutated SQLite source: '+result.stdout+result.stderr)
                        self.assertEqual(ledger.read_bytes(),csv)
                        self.assertEqual(result.returncode==0,not hot,result.stdout+result.stderr)
                        if hot:
                            self.assertIn('recovery',result.stderr)
                            self.assertNotIn('Aucune modification effectuée',result.stdout)
                    finally:case.tearDown()

    def test_account_reader_ledger_wal_source_unchanged(self):
        for surface in ('ledger','manual-purge'):
            with self.subTest(surface=surface):
                case=Accounts();case.setUp()
                try:
                    ledger=case.base/'ledger.csv';ledger.write_text('# historical\nadmin;;1998-01-01\nwal-visible;;1998-01-01\nkept;;1998-01-01\n');csv=ledger.read_bytes()
                    code="import sqlite3,sys,os;d=sqlite3.connect(sys.argv[1]);d.execute('PRAGMA journal_mode=WAL');d.execute(\"UPDATE whitelist SET username='wal-visible' WHERE id=2\");d.commit();os._exit(99)"
                    crashed=subprocess.run(['python3','-c',code,str(case.db)],env=case.env,capture_output=True,text=True,timeout=10)
                    self.assertEqual(crashed.returncode,99,crashed.stderr);Path(str(case.db)+'-shm').unlink(missing_ok=True)
                    before=case.preview_image()
                    result=case.invoke('creationDateInit.sh') if surface=='ledger' else case.whitelist_cli('purge','30j')
                    self.assertEqual(case.preview_image(),before,'ledger/prelude mutated SQLite source: '+result.stdout+result.stderr)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertEqual(ledger.read_bytes(),csv)
                    if surface=='manual-purge':self.assertIn('wal-visible',result.stdout)
                finally:case.tearDown()

    def read_sql_helper(self,sql,*options):
        return subprocess.run(['python3',str(self.repo/'data/scripts/lib/account_safety.py'),'read-sql','--db',str(self.db),'--sql',sql,'--',*options],
            env=dict(self.env,PZ_SOURCE_DIR=str(self.world),TMPDIR=str(self.world)),capture_output=True,timeout=20)

    def test_account_reader_cli_format_and_errors_exact(self):
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('UPDATE whitelist SET displayName=? WHERE id=2',("世界 | O'Name",));db.commit()
        before=self.preview_image()
        with tempfile.TemporaryDirectory(dir=self.base) as tmp:
            reference=Path(tmp)/'reference.db';shutil.copyfile(self.db,reference)
            for options,sql in [(('-header','-column'),'SELECT id,username,displayName FROM whitelist ORDER BY id'),
                    ((),'SELECT username,steamid FROM whitelist ORDER BY id'),
                    (('-separator','\x1f'),"SELECT username,COALESCE(steamid,'') FROM whitelist ORDER BY id"),
                    (('-header','-column'),'SELECT username FROM whitelist WHERE 0'),
                    ((),'SELECT * FROM missing_table'),
                    ((),'SELECT username FROM whitelist; SELECT * FROM missing_table')]:
                with self.subTest(options=options,sql=sql):
                    expected=subprocess.run(['sqlite3',*options,str(reference),sql],env=self.env,capture_output=True,timeout=10)
                    observed=self.read_sql_helper(sql,*options)
                    self.assertEqual((observed.stdout,observed.stderr,observed.returncode),(expected.stdout,expected.stderr,expected.returncode))
        self.assertEqual(self.preview_image(),before)

    def test_account_reader_cli_guard_and_final_validation(self):
        actual=shutil.which('sqlite3');self.assertIsNotNone(actual)
        trace=self.base/'private-cli-path';self.env['ACCOUNT_CLI_TRACE']=str(trace)
        self.env['ACCOUNT_CLI_SOURCE']=str(self.db);self.env['ACCOUNT_CLI_REAL']=actual
        self.executable(self.bin/'sqlite3','''#!/usr/bin/env python3
import os,sys,subprocess
from pathlib import Path
source=Path(os.environ['ACCOUNT_CLI_SOURCE']);private=Path(sys.argv[-2])
assert private.resolve()!=source.resolve()
assert not private.resolve().is_relative_to(source.parent.parent.resolve())
Path(os.environ['ACCOUNT_CLI_TRACE']).write_text(str(private.parent))
code="import sqlite3,sys;d=sqlite3.connect(sys.argv[1],timeout=0);d.execute('BEGIN IMMEDIATE')"
writer=subprocess.run(['python3','-c',code,str(source)],capture_output=True,text=True)
assert writer.returncode!=0 and 'locked' in writer.stderr,writer.stderr
result=subprocess.run([os.environ['ACCOUNT_CLI_REAL'],*sys.argv[1:]],capture_output=True)
if os.environ.get('ACCOUNT_CLI_CHANGE')=='1':Path(str(source)+'-shm').write_bytes(b'concurrent')
sys.stdout.buffer.write(result.stdout);sys.stderr.buffer.write(result.stderr)
sys.stderr.write('fixture CLI diagnostic\\n')
sys.exit(result.returncode)
''')
        before=self.preview_image();result=self.read_sql_helper('SELECT username FROM whitelist')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn(b'old',result.stdout)
        self.assertEqual(result.stderr,b'fixture CLI diagnostic\n');self.assertEqual(self.preview_image(),before)
        self.assertFalse(Path(trace.read_text()).exists())
        self.env['ACCOUNT_CLI_CHANGE']='1'
        result=self.read_sql_helper('SELECT username FROM whitelist')
        self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,b'')
        self.assertIn(b'fixture CLI diagnostic',result.stderr);self.assertIn(b'changed',result.stderr)
        self.assertFalse(Path(trace.read_text()).exists())

    def test_account_reader_cli_signal_status(self):
        self.executable(self.bin/'sqlite3',"#!/usr/bin/env python3\nimport os,signal,sys\nsys.stderr.write('fixture interrupted\\n');sys.stderr.flush();os.kill(os.getpid(),signal.SIGTERM)\n")
        before=self.preview_image();result=self.read_sql_helper('SELECT 1')
        self.assertEqual(result.returncode,143);self.assertEqual(result.stdout,b'')
        self.assertEqual(result.stderr,b'fixture interrupted\n');self.assertEqual(self.preview_image(),before)

    def test_account_readers_wal_commits_and_cold_persist(self):
        for mode in ('wal-shm','wal-no-shm','persist'):
            for surface in ('auto-active','auto-inactive','list','manual-purge'):
                with self.subTest(mode=mode,surface=surface):
                    case=Accounts();case.setUp();keeper=None
                    try:
                        ledger=case.base/'ledger.csv';ledger.write_text('# historical\nadmin;;1998-01-01\nwal-visible;;1998-01-01\nkept;;1998-01-01\n');csv=ledger.read_bytes()
                        if surface!='auto-inactive':case.set_state('active','running',999999,0)
                        if mode=='wal-no-shm':
                            code="import sqlite3,sys,os;d=sqlite3.connect(sys.argv[1]);d.execute('PRAGMA journal_mode=WAL');d.execute(\"UPDATE whitelist SET username='wal-visible' WHERE id=2\");d.commit();os._exit(99)"
                            crashed=subprocess.run(['python3','-c',code,str(case.db)],env=case.env,capture_output=True,text=True,timeout=10)
                            self.assertEqual(crashed.returncode,99,crashed.stderr);Path(str(case.db)+'-shm').unlink(missing_ok=True)
                        else:
                            keeper=sqlite3.connect(case.db,timeout=0);keeper.execute('PRAGMA journal_mode='+('PERSIST' if mode=='persist' else 'WAL'))
                            keeper.execute("UPDATE whitelist SET username='wal-visible' WHERE id=2");keeper.commit()
                            if mode=='persist':keeper.close();keeper=None
                        before=case.preview_image()
                        if surface.startswith('auto'):
                            result=case.invoke('purgeInactivePlayers.sh','--dry-run','--days','30',*(['--force'] if surface=='auto-active' else []))
                        else:result=case.whitelist_cli(*(['list'] if surface=='list' else ['purge','30j']))
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertIn('wal-visible',result.stdout)
                        self.assertEqual(case.preview_image(),before);self.assertEqual(ledger.read_bytes(),csv)
                    finally:
                        if keeper:keeper.close()
                        case.tearDown()

if __name__=='__main__':
    os.umask(0o077);unittest.main()
