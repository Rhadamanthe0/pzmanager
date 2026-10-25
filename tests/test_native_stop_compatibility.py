"""A config migration must never prevent the existing game's graceful quit."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest
import test_native_configuration as native


class StopCompatibility(unittest.TestCase):
    def setUp(self):
        self.case=native.NativeConfiguration();self.case.setUp()
        self.addCleanup(self.case.tmp.cleanup)
        shutil.copy2(native.ROOT/'pzm',self.case.repo/'pzm')
        self.state=self.case.base/'service.json'
        self.events=self.case.base/'events.jsonl'
        self.commands=self.case.base/'commands.jsonl'
        self.ready=self.case.base/'reader-ready'
        self.case.env.update(STOP_TEST_STATE=str(self.state),STOP_TEST_EVENTS=str(self.events),
                             STOP_TEST_REPO=str(self.case.repo),STOP_TEST_COMMANDS=str(self.commands))
        self.game=None
        self.addCleanup(self.cleanup_game)
        self.case.executable(self.case.bin/'systemctl','''#!/usr/bin/env python3
import json,os,subprocess,sys,time
from pathlib import Path
args=sys.argv[1:];path=Path(os.environ['STOP_TEST_STATE']);state=json.loads(path.read_text())
with open(os.environ['STOP_TEST_EVENTS'],'a') as out:out.write(json.dumps(args)+'\\n')
if 'is-active' in args:sys.exit(0 if state['ActiveState']=='active' else 3)
if 'stop' in args:
 state.update(ActiveState='deactivating',SubState='stop');temporary=path.with_suffix('.bus-tmp');temporary.write_text(json.dumps(state));temporary.replace(path)
 result=subprocess.run(['bash',str(Path(os.environ['STOP_TEST_REPO'])/'data/scripts/internal/stopServer.sh')])
 if result.returncode:sys.exit(result.returncode)
 deadline=time.monotonic()+3
 while json.loads(path.read_text())['ActiveState']!='inactive' and time.monotonic()<deadline:time.sleep(.01)
 sys.exit(0 if json.loads(path.read_text())['ActiveState']=='inactive' else 1)
if 'show' in args:
 keys=[]
 for i,arg in enumerate(args):
  if arg=='-p':keys.extend(args[i+1].split(','))
  elif arg.startswith('--property='):keys.extend(arg.split('=',1)[1].split(','))
 for key in keys:print(str(state[key]) if '--value' in args else key+'='+str(state[key]))
 sys.exit(0)
sys.exit(88)
''')
        self.case.executable(self.case.bin/'journalctl','''#!/usr/bin/env python3
import os,sys
if '--since' not in sys.argv:
 mode=os.environ.get('STOP_TEST_FRAME_MODE','with-t')
 print('diagnostic without a native frame' if mode=='missing' else 'LOG : General f:42 st:2> running' if mode=='without-t' else 'LOG : General f:42 t:1 st:2> running')
else:
 print('LOG : General f:42 t:1 st:2> running')
 print('LOG : General f:42 t:1 st:2> command entered via server console (System.in): "players"')
 if os.environ.get('STOP_TEST_UNKNOWN_PLAYERS')!='1':print('LOG : General f:42 t:1 st:2> Players connected (0):')
''')
        self.case.executable(self.case.bin/'sleep','#!/bin/sh\nexit 0\n')
        self.write_state('inactive',0)

    def write_state(self,active,pid):
        temporary=self.state.with_suffix('.initial-tmp')
        temporary.write_text(json.dumps(dict(LoadState='loaded',ActiveState=active,
            SubState='running' if active=='active' else 'dead',MainPID=str(pid),ControlPID='0',
            InvocationID='a'*32,ControlGroup='/fixture/zomboid.service',Result='success',
            ActiveEnterTimestamp='2026-01-01 00:00:00 UTC')))
        temporary.replace(self.state)

    def start_reader(self):
        code='''import json,os,sys,time
from pathlib import Path
pipe,state,commands,ready=map(Path,sys.argv[1:]);fd=os.open(pipe,os.O_RDWR|os.O_NONBLOCK)
ready.touch();pending=b''
while True:
 try:data=os.read(fd,4096)
 except BlockingIOError:data=b''
 pending+=data
 while b'\\n' in pending:
  line,pending=pending.split(b'\\n',1);command=line.decode()
  with commands.open('a') as out:out.write(json.dumps(command)+'\\n')
  if command=='quit':
   current=json.loads(state.read_text());current.update(ActiveState='inactive',SubState='dead',MainPID='0',ControlPID='0');temporary=state.with_suffix('.game-tmp');temporary.write_text(json.dumps(current));temporary.replace(state);os.close(fd);sys.exit(0)
 time.sleep(.01)
'''
        self.game=subprocess.Popen([sys.executable,'-c',code,str(self.case.pipe),str(self.state),str(self.commands),str(self.ready)])
        deadline=time.monotonic()+3
        while not self.ready.exists() and self.game.poll() is None and time.monotonic()<deadline:time.sleep(.01)
        self.assertTrue(self.ready.exists(),'private game FIFO reader did not reach precondition')
        self.write_state('active',self.game.pid)

    def cleanup_game(self):
        if self.game and self.game.poll() is None:
            self.game.terminate();self.game.wait(timeout=3)

    def invoke(self,*args):
        return subprocess.run(['bash',str(self.case.repo/'pzm'),'server',*args],env=self.case.env,
                              cwd=self.case.game,capture_output=True,text=True,timeout=12)

    def test_cli_and_execstop_keep_graceful_quit_before_strict_backup_refusal(self):
        self.case.write_env({'PZ_INI_PATH':str(self.case.base/'obsolete.ini')})
        self.start_reader()
        before=self.case.db.read_bytes();config=(self.case.repo/'.env').read_bytes()
        result=self.invoke('stop','30s','--silent')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(self.state.read_text())['ActiveState'],'inactive',result.stdout+result.stderr)
        self.game.wait(timeout=3);self.assertEqual(self.game.returncode,0)
        commands=[json.loads(line) for line in self.commands.read_text().splitlines()]
        self.assertIn('players',commands)
        self.assertTrue(any(command.startswith('servermsg ') for command in commands))
        self.assertEqual(commands[-1],'quit')
        self.assertIn('Serveur arrêté',result.stdout)
        self.assertIn('sauvegarde',result.stdout)
        self.assertIn('PZ_INI_PATH',result.stderr)
        events=[json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertEqual(sum('stop' in event for event in events),1)
        self.assertFalse(any('kill' in event or 'start' in event or 'restart' in event for event in events))
        self.assertEqual(self.case.db.read_bytes(),before)
        self.assertEqual((self.case.repo/'.env').read_bytes(),config)

    def test_unused_relative_world_and_install_paths_do_not_block_execstop(self):
        self.case.write_env({'PZ_SOURCE_DIR':'old-relative-world','PZ_INSTALL_DIR':'old-relative-install',
                             'PZ_DB_PATH':str(self.case.base/'obsolete.db')})
        self.start_reader()
        state=json.loads(self.state.read_text());state.update(ActiveState='deactivating',SubState='stop')
        self.state.write_text(json.dumps(state))
        result=subprocess.run(['bash',str(self.case.repo/'data/scripts/internal/stopServer.sh')],
                              env=self.case.env,cwd=self.case.game,capture_output=True,text=True,timeout=12)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.game.wait(timeout=3)
        self.assertEqual([json.loads(line) for line in self.commands.read_text().splitlines()],['quit'])

    def test_status_remains_available_but_start_restart_and_sql_stay_strict(self):
        self.case.write_env({'PZ_DB_PATH':str(self.case.base/'obsolete.db')})
        before=self.case.db.read_bytes()
        status=self.invoke('status');self.assertEqual(status.returncode,0,status.stdout+status.stderr)
        for action in ('start','restart'):
            with self.subTest(action=action):
                result=self.invoke(action,'now')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('PZ_DB_PATH',result.stderr)
        result=subprocess.run(['bash',str(self.case.repo/'data/scripts/admin/manageWhitelist.sh'),'list'],
                              env=self.case.env,capture_output=True,text=True,timeout=12)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PZ_DB_PATH',result.stderr)
        self.assertEqual(self.case.db.read_bytes(),before)
        self.assertFalse(self.case.capture.exists())

    def test_unknown_players_and_optional_last_frame_do_not_abort_a_ready_server_stop(self):
        for mode in ('with-t','without-t','missing'):
            with self.subTest(frame=mode):
                # Each variant is a new private service/process and filesystem.
                case=StopCompatibility();case.setUp()
                try:
                    case.case.env.update(STOP_TEST_UNKNOWN_PLAYERS='1',STOP_TEST_FRAME_MODE=mode,
                                         PZ_CONSOLE_OUTPUT_TIMEOUT='0.2',PZ_BACKUP_CPU_SCOPED='1')
                    case.start_reader()
                    result=case.invoke('stop','now','--silent')
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(json.loads(case.state.read_text())['ActiveState'],'inactive')
                    self.assertIn('comptage players reste indéterminé',result.stdout)
                    if mode!='missing':self.assertIn('dernière frame observée : f:42',result.stdout)
                    commands=[json.loads(line) for line in case.commands.read_text().splitlines()]
                    self.assertEqual(commands,['players','quit'])
                    events=[json.loads(line) for line in case.events.read_text().splitlines()]
                    self.assertFalse(any('kill' in event or 'start' in event or 'restart' in event for event in events))
                finally:case.doCleanups()


if __name__=='__main__':
    os.umask(0o077)
    unittest.main()
