"""Exécute une copie du détecteur avec journaux et services simulés."""
import os
import json
import fcntl
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class StallwatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.state_dir = self.runtime / 'pzmanager'
        self.state_dir.mkdir(mode=0o700)
        self.logs = self.root / 'logs'
        self.logs.mkdir()
        scripts = self.root / 'scripts'
        (scripts / 'internal').mkdir(parents=True)
        (scripts / 'lib').mkdir()
        self.script = scripts / 'internal/watchServerStall.sh'
        shutil.copyfile(Path(__file__).resolve().parents[1] /
                        'data/scripts/internal/watchServerStall.sh', self.script)
        world = Path(__file__).resolve().parents[1] / 'data/scripts/lib/world_lock.sh'
        (scripts / 'lib/common.sh').write_text(f'source "{world}"\n' + '''source_env() { :; }
server_is_active() { [[ ! -e "$TEST_ROOT/killed" ]]; }
notify() { :; }
log() { printf '%s\\n' "$*"; }
''')
        common=(Path(__file__).resolve().parents[1]/'data/scripts/lib/common.sh').read_text()
        frame='game_log_frame() {'+common.split('game_log_frame() {',1)[1].split('\n}',1)[0]+'\n}\n'
        with (scripts/'lib/common.sh').open('a') as out:out.write(frame)
        commands = self.root / 'bin'
        commands.mkdir()
        for name, body in {
            'python3': 'case "${1:-}" in */service_process.py) echo 123 ;; *) exec /usr/bin/python3 "$@" ;; esac',
            'journalctl': '''exec /usr/bin/python3 -c '
import json,os,sys
stamp=os.environ.get("TEST_STAMP","2000")
message=os.environ.get("TEST_MESSAGE","LOG : General f:"+os.environ.get("TEST_FRAME","42")+" st:123> native tick")
if "json" in sys.argv:print(json.dumps({"__REALTIME_TIMESTAMP":stamp+"000000","MESSAGE":message}))
else:print(stamp+".000 host prog: "+message)
' "$@"''',
            'curl': "echo 'game{parameter=\"players\"} 1'",
        }.items():
            command = commands / name
            command.write_text('#!/bin/sh\n' + body + '\n')
            command.chmod(0o700)
        self.commands = commands
        self.env = {**os.environ, 'TEST_ROOT':str(self.root), 'PZ_SERVICE_NAME':'fixture.service', 'PZ_MANAGER_DIR':str(self.root), 'PATH': str(commands) + ':' + os.environ['PATH'],
                    'XDG_RUNTIME_DIR': str(self.runtime), 'LOG_ZOMBOID_DIR': str(self.logs),
                    'LOG_RETENTION_DAYS': '7', 'PZ_PROMETHEUS_PORT': '1',
                    'STALL_WATCH_SAMPLES': '100'}

    def run_watch(self):
        return subprocess.run(['bash', str(self.script)], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def prepare_restart(self):
        self.env['STALL_WATCH_SAMPLES'] = '1'
        self.identity = self.root / 'invocation'
        self.identity.write_text('a' * 32)
        for name, source in {
            'systemctl': "#!/usr/bin/python3\nimport os,pathlib,sys\nroot=pathlib.Path(os.environ['TEST_ROOT']); args=sys.argv[1:]\nif 'kill' in args: (root/'killed').touch()\nelif 'show' in args and '--value' not in args:\n print('LoadState=loaded\\nActiveState=failed\\nMainPID=0\\nControlPID=0\\nInvocationID='+(root/'invocation').read_text()+'\\nActiveEnterTimestampMonotonic=1000')\nelif 'InvocationID' in args: print((root/'invocation').read_text())\nelif 'MainPID' in args: print('123')\nelif 'ActiveEnterTimestampMonotonic' in args: print('1000')\n",
            'jcmd': '#!/usr/bin/python3\nimport os,pathlib\nroot=pathlib.Path(os.environ[\'TEST_ROOT\']); path=root/\'dump-count\'\nn=int(path.read_text())+1 if path.exists() else 1; path.write_text(str(n))\nif os.environ.get(\'TEST_CHANGE_ID\'): (root/\'invocation\').write_text(\'b\'*32)\nprint(\'"main" cpu=\'+str(n*10000)+\'ms elapsed=\'+str(n*10)+\'s runnable\')\n',
            'top': '#!/bin/sh\nexit 0\n',
            'sleep': '#!/bin/sh\nexit 0\n',
        }.items():
            path = self.commands / name
            path.write_text(source)
            path.chmod(0o700)
        pzm = self.root / 'pzm'
        pzm.write_text('#!/bin/sh\necho restart > "$TEST_ROOT/restarted"\n')
        pzm.chmod(0o700)
        state = self.state_dir / 'stallwatch.state'
        state.write_text('123 42 1999 0 ' + 'a' * 32 + ' 123 1000\n')
        return state

    def admin_notification_route(self,conclusive):
        self.prepare_restart()
        root=Path(__file__).resolve().parents[1]
        helper=self.root/'data/scripts/internal';helper.mkdir(parents=True)
        lib=self.root/'data/scripts/lib';lib.mkdir()
        shutil.copy2(root/'data/scripts/internal/sendDiscord.sh',helper/'sendDiscord-real.sh')
        (lib/'common.sh').write_text('source_env() { DISCORD_WEBHOOK="$TEST_PUBLIC_WEBHOOK"; }\n')
        common=root/'data/scripts/lib/common.sh'
        source=common.read_text();notify='notify() {'+source.split('notify() {',1)[1].split('\n}',1)[0]+'\n}\n'
        with (self.root/'scripts/lib/common.sh').open('a') as stream:stream.write(notify)
        wrapper=helper/'sendDiscord.sh'
        wrapper.write_text("#!/usr/bin/python3\nimport json,os,pathlib,sys\nroot=pathlib.Path(os.environ['TEST_ROOT'])\nwith (root/'notifications').open('a') as stream:stream.write(json.dumps({'program':'sendDiscord','arguments':sys.argv[1:]})+'\\n')\nos.execv('/bin/bash',['/bin/bash',str(pathlib.Path(__file__).with_name('sendDiscord-real.sh')),*sys.argv[1:]])\n")
        wrapper.chmod(0o700)
        curl=self.commands/'curl';curl.write_text('#!/usr/bin/python3\nimport json,os,pathlib,sys\nargs=sys.argv[1:]\nif args[-1].endswith(\'/metrics\'):\n print(\'game{parameter="players"} 1\');raise SystemExit(0)\nfields={}\nfor line in sys.stdin.read().split(\'\\n\'):\n if line.strip():\n  key,_,value=line.partition(\'=\');fields[key.strip()]=json.loads(value.strip())\nwith (pathlib.Path(os.environ[\'TEST_ROOT\'])/\'notifications\').open(\'a\') as stream:stream.write(json.dumps({\'program\':\'curl\',\'arguments\':args,\'target\':fields[\'url\']})+\'\\n\')\nprint(\'204\',end=\'\')\n')
        curl.chmod(0o700)
        self.env.update(PZ_MANAGER_ROOT=str(self.root),TEST_PUBLIC_WEBHOOK='https://discord.invalid/PUBLIC-TOKEN',
                        DISCORD_ADMIN_WEBHOOK='https://discord.invalid/ADMIN-TOKEN',STALL_AUTO_RESTART='0')
        if not conclusive:
            jcmd=self.commands/'jcmd';jcmd.write_text('#!/usr/bin/python3\nprint(\'"main" cpu=100ms elapsed=10s waiting\')\n');jcmd.chmod(0o700)
        result=self.run_watch();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        records=[json.loads(line) for line in (self.root/'notifications').read_text().splitlines()]
        expected=['https://discord.invalid/PUBLIC-TOKEN','https://discord.invalid/ADMIN-TOKEN'] if conclusive else ['https://discord.invalid/ADMIN-TOKEN']
        self.assertEqual([entry['target'] for entry in records if entry['program']=='curl'],expected)
        for entry in records:
            arguments=json.dumps(entry['arguments'])
            self.assertNotIn('ADMIN-TOKEN',arguments)
            self.assertNotIn('PUBLIC-TOKEN',arguments)
        self.assertNotIn('ADMIN-TOKEN',result.stdout+result.stderr)

    def test_native_time_frame_progress_updates_state_without_dump(self):
        state=self.prepare_restart()
        for frame,stamp in [('43','2000'),('44','2001'),('44','2001')]:
            self.env.update(TEST_STAMP=stamp,TEST_MESSAGE='LOG : General f:'+frame+' t:1,234 st:1\u202f235> native tick')
            result=self.run_watch()
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(state.read_text().split()[1:4],[frame,stamp,'0'])
        self.assertFalse((self.root/'dump-count').exists())
        self.assertFalse((self.root/'killed').exists())
        self.assertFalse((self.root/'restarted').exists())
    def test_zero_native_frame_with_payload_tokens_never_dumps_or_kills(self):
        state=self.prepare_restart()
        self.env['TEST_MESSAGE']='LOG : General f:0 t:1,234 st:1234> command entered via server console (System.in): "servermsg f:42 st:999>"'
        result=self.run_watch()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(state.read_text().split()[1:4],['0','2000','0'])
        self.assertFalse((self.root/'dump-count').exists())
        self.assertFalse((self.root/'killed').exists())
        self.assertFalse((self.root/'restarted').exists())
    def test_conclusive_admin_notification_uses_private_environment(self):
        self.admin_notification_route(True)

    def test_nonconclusive_admin_notification_uses_private_environment(self):
        self.admin_notification_route(False)

    def test_world_contention_retries_without_wasted_dump(self):
        state = self.prepare_restart()
        with (self.state_dir / 'world.lock').open('w') as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_watch()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('verrou monde occupé', result.stdout)
            self.assertEqual(state.read_text().split()[3], '0')
            self.assertFalse((self.root / 'dump-count').exists())
            self.assertFalse((self.root / 'killed').exists())
        self.env['TEST_STAMP'] = '2001'
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'dump-count').read_text(), '3')
        self.assertTrue((self.root / 'killed').exists())
        self.assertTrue((self.root / 'restarted').exists())

    def test_changed_identity_after_capture_refuses_kill(self):
        self.prepare_restart()
        self.env['TEST_CHANGE_ID'] = '1'
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('invocation changée', result.stdout)
        self.assertFalse((self.root / 'killed').exists())

    def test_partial_identity_is_rejected_before_signal_and_positive_fallback_survives(self):
        modes={
            'nominal':True,'iid-stable-enter-missing':True,'replaced-visible':False,
            'replaced-hidden':False,'fallback-positive':True,'fallback-zero':False,
            'fallback-source-switch':False,'fallback-pid-zero':False,
            'fallback-pid-missing':False,'fallback-initial-enter-missing':False,
            'fallback-epoch-positive':True,
        }
        for mode,allowed in modes.items():
            with self.subTest(mode=mode):
                case=StallwatchTests();case.setUp()
                try:
                    state=case.prepare_restart()
                    bus=case.commands/'systemctl'
                    bus.write_text('''#!/usr/bin/python3
import os,sys
from pathlib import Path
root=Path(os.environ['TEST_ROOT']);args=sys.argv[1:]
mode=os.environ['TEST_IDENTITY_MODE'];captured=(root/'dump-count').exists()
actual=(root/'invocation').read_text()
if 'kill' in args:(root/'killed').touch();sys.exit(0)
def iid():
 if mode.startswith('fallback-') or mode=='replaced-hidden' and captured:return ''
 return actual
def mono():
 if mode=='fallback-zero':return '0'
 if mode=='fallback-epoch-positive':return ''
 if mode=='fallback-initial-enter-missing' and not captured:return ''
 if captured and mode in ('replaced-hidden','iid-stable-enter-missing','fallback-source-switch'):return ''
 return '1000'
def epoch():
 return '1970-01-01 00:16:40 UTC' if mode=='fallback-epoch-positive' or mode=='fallback-source-switch' and captured else ''
if 'show' in args and '--value' not in args:
 fields=dict(LoadState='loaded',ActiveState='failed',MainPID='0',ControlPID='0',InvocationID='' if mode.startswith('fallback-') else actual,ActiveEnterTimestampMonotonic='1000' if mode in ('replaced-hidden','iid-stable-enter-missing') else mono(),ActiveEnterTimestamp=epoch())
 for key,value in fields.items():print(key+'='+value)
elif 'InvocationID' in args:print(iid())
elif 'MainPID' in args:print('0' if mode=='fallback-pid-zero' else '' if mode=='fallback-pid-missing' and captured else '123')
elif 'ActiveEnterTimestampMonotonic' in args:print(mono())
elif 'ActiveEnterTimestamp' in args:print(epoch())
''')
                    case.env['TEST_IDENTITY_MODE']=mode
                    if mode.startswith('replaced-'):case.env['TEST_CHANGE_ID']='1'
                    result=case.run_watch()
                    self.assertEqual((case.root/'dump-count').read_text(),'3')
                    self.assertEqual((case.root/'killed').exists(),allowed,result.stdout+result.stderr)
                    self.assertEqual((case.root/'restarted').exists(),allowed,result.stdout+result.stderr)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    if not allowed:
                        self.assertEqual(state.read_text().split()[3],'0')
                finally:case.doCleanups()

    def refuse_first_kill(self):
        state=self.prepare_restart()
        path=self.commands/'systemctl'
        source=path.read_text()
        needle="if 'kill' in args: (root/'killed').touch()"
        self.assertIn(needle,source)
        path.write_text(source.replace(needle,"""if 'kill' in args:
 count=root/'kill-count';n=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(n))
 if n==1:sys.exit(1)
 (root/'killed').touch()"""))
        result=self.run_watch()
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('SIGKILL refusé',result.stdout)
        self.assertEqual((self.root/'dump-count').read_text(),'3')
        self.assertEqual((self.root/'kill-count').read_text(),'1')
        self.assertFalse((self.root/'killed').exists())
        self.assertFalse((self.root/'restarted').exists())
        return state

    def test_refused_kill_retries_only_after_a_new_complete_diagnostic(self):
        self.refuse_first_kill()
        self.env['TEST_STAMP']='2001'
        result=self.run_watch()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.root/'dump-count').read_text(),'6')
        self.assertEqual((self.root/'kill-count').read_text(),'2')
        self.assertTrue((self.root/'killed').exists())
        self.assertTrue((self.root/'restarted').exists())

    def test_retry_rechecks_world_and_changed_invocation_before_kill(self):
        state=self.refuse_first_kill()
        self.env['TEST_STAMP']='2001'
        with (self.state_dir/'world.lock').open('w') as holder:
            fcntl.flock(holder,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=self.run_watch()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('verrou monde occupé',result.stdout)
        self.assertEqual(state.read_text().split()[3],'0')
        self.assertEqual((self.root/'dump-count').read_text(),'3')
        self.assertEqual((self.root/'kill-count').read_text(),'1')
        self.env.update(TEST_STAMP='2002',TEST_CHANGE_ID='1')
        result=self.run_watch()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('invocation changée',result.stdout)
        self.assertEqual((self.root/'dump-count').read_text(),'6')
        self.assertEqual((self.root/'kill-count').read_text(),'1')
        self.assertFalse((self.root/'killed').exists())
        self.assertFalse((self.root/'restarted').exists())

    def test_diagnostic_only_captures_with_world_busy(self):
        self.prepare_restart()
        self.env['STALL_AUTO_RESTART'] = '0'
        with (self.state_dir / 'world.lock').open('w') as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'dump-count').read_text(), '3')
        self.assertFalse((self.root / 'killed').exists())

    def test_untrusted_state_is_not_evaluated(self):
        marker = self.root / 'executed'
        state = self.state_dir / 'stallwatch.state'
        state.write_text(f'123 42 1999 a[$(touch {marker})]\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(state.read_text(), '123 42 2000 0 - 0 0\n')

    def test_untrusted_cooldown_is_not_evaluated(self):
        marker = self.root / 'executed'
        (self.state_dir / 'stallwatch.cooldown').write_text(f'a[$(touch {marker})]\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_decimal_state_and_private_permissions(self):
        state = self.state_dir / 'stallwatch.state'
        state.write_text('123 42 1999 08\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.read_text(), '123 42 2000 9 - 0 0\n')
        state.unlink()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_startup_frame_zero_never_counts_as_a_stall(self):
        self.env['TEST_FRAME'] = '0'
        state = self.state_dir / 'stallwatch.state'
        state.write_text('123 0 1999 99\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.read_text(), '123 0 2000 0 - 0 0\n')

    def test_unproven_readiness_refuses_shutdown(self):
        # Extract only the function into a scratch shell: no production setup.
        source = (Path(__file__).resolve().parents[1] /
                  'data/scripts/core/pz.sh').read_text()
        function = source.split('shutdown_server() {', 1)[1].split('\n}', 1)[0]
        harness = ('shutdown_server() {' + function + '\n}\n' +
                   'try_acquire_maintenance_lock() { :; }\n'
                   'shutdown_server_state() { echo active; }\n'
                   'wait_for_server_ready() { echo called > "$TEST_ROOT/readiness-attempt"; return 1; }\n'
                   'log() { :; }\n'
                   'systemctl() { echo unexpected-systemctl; }\n'
                   'shutdown_server stop\n')
        result = subprocess.run(['bash', '-eu', '-c', harness],env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((self.root/'readiness-attempt').read_text(),'called\n')
        self.assertNotIn('unexpected-systemctl', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_nonprivate_runtime_is_refused(self):
        self.runtime.chmod(0o755)
        self.assertNotEqual(self.run_watch().returncode, 0)
        self.assertFalse((self.state_dir / 'stallwatch.state').exists())

    def test_symlink_state_directory_is_refused(self):
        self.state_dir.rmdir()
        self.state_dir.symlink_to(self.logs, target_is_directory=True)
        self.assertNotEqual(self.run_watch().returncode, 0)
        self.assertEqual(list(self.logs.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
