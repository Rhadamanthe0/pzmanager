"""Real account entrypoints refuse restored SQLite aliases before access."""
from contextlib import closing
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import unittest

import test_accounts_safety as accounts
import test_writing_start_admission as startup


class AccountPaths(unittest.TestCase):
    def setUp(self):
        self.case=accounts.Accounts();self.case.setUp();self.addCleanup(self.case.tearDown)
        self.external=self.case.base/'external.db'
        self.case.db.rename(self.external)
    def invoke(self,*args):
        return self.case.invoke(*args,input='oui\n')
    def unchanged(self,before):
        self.assertEqual(self.external.read_bytes(),before)
    def test_symlink_database_refused_by_all_account_entrypoints(self):
        self.case.db.symlink_to(self.external)
        before=self.external.read_bytes()
        for script,args in (
            ('manageWhitelist.sh',('list',)),
            ('manageWhitelist.sh',('remove-account','old')),
            ('manageWhitelist.sh',('rename-account','old','new')),
            ('manageWhitelist.sh',('resetpassword','old')),
            ('manageWhitelist.sh',('purge','30j','--delete')),
            ('purgeInactivePlayers.sh',()),
            ('creationDateInit.sh',()),
        ):
            with self.subTest(script=script,args=args):
                result=self.invoke(script,*args)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.unchanged(before)
    def test_linked_parent_refused(self):
        self.external.rename(self.case.db)
        alias=self.case.base/'alias';alias.symlink_to(self.case.base,target_is_directory=True)
        with (self.case.repo/'.env').open('a') as stream:
            stream.write('PZ_DB_PATH='+shlex.quote(str(alias/self.case.db.name))+'\n')
        before=self.case.db.read_bytes()
        result=self.invoke('manageWhitelist.sh','resetpassword','old')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.case.db.read_bytes(),before)
    def test_hardlinked_database_refused(self):
        os.link(self.external,self.case.db);before=self.external.read_bytes();info=self.external.stat()
        result=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.unchanged(before)
        after=self.external.stat()
        self.assertEqual((after.st_nlink,after.st_mtime_ns,after.st_ctime_ns),(info.st_nlink,info.st_mtime_ns,info.st_ctime_ns))
    def test_dangling_database_link_refused_without_creating_target(self):
        self.external.unlink();self.case.db.symlink_to(self.external)
        result=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(self.external.exists())
    def test_fifo_database_refused_without_blocking(self):
        os.mkfifo(self.case.db,0o600)
        result=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
    def test_linked_sqlite_sidecars_refused_before_access_or_ledger(self):
        self.external.rename(self.case.db)
        target=self.case.base/'external-sidecar';target.write_bytes(b'private sidecar sentinel')
        for suffix in ('-wal','-shm','-journal'):
            with self.subTest(suffix=suffix):
                alias=Path(str(self.case.db)+suffix);alias.symlink_to(target)
                before=self.case.db.read_bytes();info=target.stat()
                result=self.invoke('purgeInactivePlayers.sh')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(self.case.db.read_bytes(),before)
                self.assertEqual(target.read_bytes(),b'private sidecar sentinel')
                after=target.stat()
                self.assertEqual((after.st_mtime_ns,after.st_ctime_ns,after.st_nlink),(info.st_mtime_ns,info.st_ctime_ns,info.st_nlink))
                self.assertFalse((self.case.base/'ledger.csv').exists())
                alias.unlink()
    def test_fifo_or_hardlinked_sidecars_refused_without_external_change(self):
        self.external.rename(self.case.db)
        target=self.case.base/'external-sidecar';target.write_bytes(b'private sidecar sentinel')
        for suffix in ('-wal','-shm','-journal'):
            for kind in ('fifo','hardlink'):
                with self.subTest(suffix=suffix,kind=kind):
                    alias=Path(str(self.case.db)+suffix)
                    if kind=='fifo':os.mkfifo(alias,0o600)
                    else:os.link(target,alias)
                    before=self.case.db.read_bytes();info=target.stat()
                    result=self.invoke('creationDateInit.sh')
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(self.case.db.read_bytes(),before)
                    after=target.stat()
                    self.assertEqual((after.st_mtime_ns,after.st_ctime_ns,after.st_nlink),(info.st_mtime_ns,info.st_ctime_ns,info.st_nlink))
                    self.assertFalse((self.case.base/'ledger.csv').exists())
                    alias.unlink()
    def test_missing_database_does_not_allow_linked_sidecar(self):
        alias=Path(str(self.case.db)+'-journal');alias.symlink_to(self.external)
        result=self.invoke('purgeInactivePlayers.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
    def test_explicit_regular_database_outside_world_still_mutates(self):
        self.external.rename(self.case.db)
        self.assertNotIn(self.case.world,self.case.db.parents)
        result=self.invoke('manageWhitelist.sh','resetpassword','old')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        with closing(sqlite3.connect(self.case.db)) as database:
            self.assertEqual(database.execute("SELECT password FROM whitelist WHERE username='old'").fetchone(),('',))
    def test_linked_character_database_refused_before_any_rename(self):
        self.external.rename(self.case.db)
        character=self.case.base/'external-players.db';self.case.players.rename(character)
        self.case.players.symlink_to(character)
        before=self.case.db.read_bytes();chars=character.read_bytes()
        result=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.case.db.read_bytes(),before);self.assertEqual(character.read_bytes(),chars)
    def test_linked_character_directory_refused_before_any_rename(self):
        self.external.rename(self.case.db)
        directory=self.case.players.parent;target=self.case.base/'external-save';directory.rename(target)
        directory.symlink_to(target,target_is_directory=True)
        before=self.case.db.read_bytes();chars=(target/'players.db').read_bytes()
        result=self.invoke('manageWhitelist.sh','rename-account','old','new')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.case.db.read_bytes(),before);self.assertEqual((target/'players.db').read_bytes(),chars)
    def test_direct_python_remove_refuses_database_alias(self):
        self.case.db.symlink_to(self.external);before=self.external.read_bytes()
        result=subprocess.run(['python3',str(self.case.repo/'data/scripts/lib/account_safety.py'),'remove','--db',str(self.case.db),'old'],env=self.case.env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.external.read_bytes(),before)
    def test_direct_python_rename_refuses_attached_database_alias(self):
        self.external.rename(self.case.db)
        target=self.case.base/'external-players.db';self.case.players.rename(target)
        self.case.players.symlink_to(target);before=self.case.db.read_bytes();chars=target.read_bytes()
        result=subprocess.run(['python3',str(self.case.repo/'data/scripts/lib/account_safety.py'),'rename','--db',str(self.case.db),'--players',str(self.case.players),'old','new'],env=self.case.env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.case.db.read_bytes(),before);self.assertEqual(target.read_bytes(),chars)


class RestoredDatabase(unittest.TestCase):
    def test_full_restore_then_start_refuses_external_database_alias(self):
        case=startup.StartAdmission();case.setUp();self.addCleanup(case.tearDown)
        repo,world,ini=case.closure_fixture()
        external=case.root/'external.db'
        shutil.copy2(world/'db/servertest.db',external)
        backup=case.root/'backup';(backup/'Saves/Multiplayer/servertest').mkdir(parents=True)
        (backup/'Saves/Multiplayer/servertest/sentinel').write_bytes(b'fixture')
        (backup/'Server').mkdir();(backup/'Server/servertest.ini').write_text('Open=true\n')
        (backup/'db').mkdir();(backup/'db/servertest.db').symlink_to(external)
        before=external.read_bytes()
        external_info=external.stat()
        restored=subprocess.run(['bash',str(repo/'data/scripts/backup/restoreZomboidData.sh'),str(backup)],env=case.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(restored.returncode,0,restored.stdout+restored.stderr)
        self.assertTrue((world/'db/servertest.db').is_symlink())
        journal=world.parent/('.'+world.name+'.pzm-transactions')
        recovery={p.name:p.read_bytes() for p in journal.iterdir()}
        ini_before=ini.read_bytes()
        result=subprocess.run(['bash',str(repo/'data/scripts/internal/prepareWorldStart.sh')],env=case.env,capture_output=True,text=True,timeout=15)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(external.read_bytes(),before)
        after=external.stat()
        self.assertEqual((after.st_mtime_ns,after.st_ctime_ns,after.st_nlink),(external_info.st_mtime_ns,external_info.st_ctime_ns,external_info.st_nlink))
        self.assertEqual(ini.read_bytes(),ini_before)
        self.assertEqual({p.name:p.read_bytes() for p in journal.iterdir()},recovery)
        self.assertNotIn('ProjectWriting restart cleanup policy:',result.stdout)


if __name__=='__main__':unittest.main()
