"""Real pzm/FIFO/SQLite whitelist results; only the game and bus are fixtures."""
import os
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import threading
import time
import unittest
import test_accounts_safety as fixtures
ROOT=fixtures.ROOT


class WhitelistConsole(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.Accounts();self.fixture.setUp();self.addCleanup(self.fixture.tearDown)
        f=self.fixture
        shutil.copy2(ROOT/'pzm',f.repo/'pzm')
        self.pipe=f.base/'console';os.mkfifo(self.pipe,0o600)
        self.fd=os.open(self.pipe,os.O_RDWR|os.O_NONBLOCK);self.addCleanup(os.close,self.fd)
        self.journal=f.base/'journal';self.journal.write_text('')
        self.commands=[]
        with closing(sqlite3.connect(f.db)) as db:db.execute('CREATE TABLE bannedid(steamid TEXT, reason TEXT)');db.commit()
        with (f.repo/'.env').open('a') as stream:stream.write('PZ_CONTROL_PIPE='+str(self.pipe)+'\n')
        f.env.update(PZ_CONSOLE_OUTPUT_TIMEOUT='.3',PZ_PIPE_WRITE_TIMEOUT='.3')
        f.executable(f.bin/'systemctl',"#!/bin/bash\nprintf 'ActiveState=active\\nMainPID=1234\\nInvocationID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\nControlGroup=/fixture/zomboid.service\\n'\n")
        f.executable(f.bin/'journalctl','#!/bin/bash\ncat '+str(self.journal)+'\n')
    def game(self,mode='success',mutate=True,ban_result=None,ban_mutate=True):
        stop=threading.Event()
        def consume():
            deadline=time.monotonic()+5
            while time.monotonic()<deadline and not stop.is_set():
                try:line=os.read(self.fd,4096).decode().strip()
                except BlockingIOError:line=''
                if not line:time.sleep(.005);continue
                command,sid=line.split();self.commands.append(command)
                if mutate and mode!='error' and (command!='banid' or ban_mutate):
                    with closing(sqlite3.connect(self.fixture.db)) as db:
                        if command=='addsteamid':db.execute('INSERT INTO allowedsteamid VALUES(?)',(sid,))
                        elif command=='removesteamid':db.execute('DELETE FROM allowedsteamid WHERE steamid=?',(sid,))
                        else:db.execute('INSERT INTO bannedid VALUES(?,?)',(sid,''))
                        db.commit()
                echo='command entered via server console (System.in): "'+line+'"\n'
                result={'addsteamid':f'SteamID {sid} added to allowed SteamIDs',
                        'removesteamid':f'SteamID {sid} removed from allowed SteamIDs',
                        'banid':ban_result if ban_result is not None else f'System banned SteamID {sid}()'}[command]
                self.journal.write_text(echo+(result+'\n' if mode=='success' else 'Server is not in Steam mode\n' if mode=='error' else ''))
                if command=='banid' or mode!='success':return
        thread=threading.Thread(target=consume,daemon=True);thread.start()
        self.addCleanup(lambda:(stop.set(),thread.join(timeout=1)))
    def invoke(self,*args):
        f=self.fixture
        return subprocess.run(['bash',str(f.repo/'pzm'),'whitelist',*args],env=f.env,capture_output=True,text=True,timeout=10)
    def assert_indeterminate(self,result):
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('indéterminé',result.stderr)
        self.assertNotIn('✓',result.stdout)
    def test_unconsumed_fifo_cannot_authorize(self):
        self.assert_indeterminate(self.invoke('add','76561198000000099'))
    def test_echo_only_cannot_authorize_even_if_database_changed(self):
        self.game('echo');self.assert_indeterminate(self.invoke('add','76561198000000099'))
    def test_native_error_cannot_authorize(self):
        self.game('error');self.assert_indeterminate(self.invoke('add','76561198000000099'))
    def test_success_line_without_database_effect_cannot_authorize(self):
        self.game(mutate=False);self.assert_indeterminate(self.invoke('add','76561198000000099'))
    def test_confirmed_add_and_idempotent_add(self):
        self.game();first=self.invoke('add','76561198000000099')
        self.assertEqual(first.returncode,0,first.stdout+first.stderr);self.assertIn('✓ SteamID autorisé',first.stdout)
        second=self.invoke('add','76561198000000099')
        self.assertEqual(second.returncode,0,second.stdout+second.stderr);self.assertIn('déjà autorisé',second.stdout)
        self.assertEqual(self.commands,['addsteamid'])
    def test_remove_already_absent_and_banned_is_idempotent(self):
        with closing(sqlite3.connect(self.fixture.db)) as db:
            db.execute('INSERT INTO bannedid VALUES(?,?)',('76561198000000099',''));db.commit()
        result=self.invoke('remove','76561198000000099','--ban')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('déjà retiré',result.stdout);self.assertIn('déjà banni',result.stdout)
        with self.assertRaises(BlockingIOError):os.read(self.fd,4096)
    def test_unconsumed_fifo_cannot_remove_or_ban(self):
        self.assert_indeterminate(self.invoke('remove','76561198000000002','--ban'))
    def check_ban_reply(self,reply,success,mutate=True):
        sid='76561198000000099'
        self.game(ban_result=reply,ban_mutate=mutate)
        result=self.invoke('remove',sid,'--ban')
        if success:
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('✓ SteamID banni',result.stdout)
        else:self.assert_indeterminate(result)
        with closing(sqlite3.connect(self.fixture.db)) as db:
            self.assertEqual(db.execute('SELECT EXISTS(SELECT 1 FROM bannedid WHERE steamid=?)',(sid,)).fetchone()[0],int(mutate))
    def test_silent_ban_is_indeterminate(self):
        self.assert_indeterminate(self.invoke('remove','76561198000000099','--ban'))
    def test_echo_only_ban_is_indeterminate(self):
        self.game('echo');self.assert_indeterminate(self.invoke('remove','76561198000000099','--ban'))
    def test_native_ban_reply_with_account_names(self):
        self.check_ban_reply('System banned SteamID 76561198000000099(alice, )',True)
    def test_native_ban_reply_with_names_and_reason(self):
        self.check_ban_reply('System banned SteamID 76561198000000099(alice, bob, )Reason: access revoked',True)
    def test_native_ban_ack_without_effect_is_indeterminate(self):
        self.check_ban_reply('System banned SteamID 76561198000000099()',False,mutate=False)
    def test_neighbor_steamid_ban_ack_is_indeterminate(self):
        self.check_ban_reply('System banned SteamID 76561198000000098()',False)
    def test_other_payload_containing_ban_ack_is_indeterminate(self):
        self.check_ban_reply('Error: System banned SteamID 76561198000000099()',False)
    def test_unban_reply_is_indeterminate(self):
        self.check_ban_reply('System unbanned SteamID 76561198000000099()',False)
    def test_native_ban_error_is_indeterminate(self):
        self.check_ban_reply('Server is not in Steam mode',False,mutate=False)

    def test_confirmed_remove_and_ban(self):
        self.game();result=self.invoke('remove','76561198000000002','--ban')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('✓ SteamID banni',result.stdout);self.assertIn('✓ SteamID retiré',result.stdout)
        self.assertEqual(self.commands,['removesteamid','banid'])
        with closing(sqlite3.connect(self.fixture.db)) as db:
            self.assertEqual(db.execute('SELECT * FROM allowedsteamid').fetchall(),[])
            self.assertEqual(db.execute('SELECT steamid FROM bannedid').fetchall(),[('76561198000000002',)])


if __name__=='__main__':unittest.main()
