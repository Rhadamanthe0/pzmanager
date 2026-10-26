"""Readiness through real common.sh and console transport, with private FIFO/systemd fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServerReadiness(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.fifo = self.root / 'control'
        os.mkfifo(self.fifo)
        self.fd = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, self.fd)
        self.calls = self.root / 'calls'
        self.count = self.root / 'identity-count'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        FIXTURE_ROOT=str(self.root), FIXTURE_MODE='zero',
                        PZ_SERVICE_NAME='fixture.service', PZ_CONTROL_PIPE=str(self.fifo))
        self.command('systemctl', '''import os,pathlib,sys
root=pathlib.Path(os.environ['FIXTURE_ROOT']); args=sys.argv[1:]
with (root/'calls').open('a') as f: f.write('systemctl '+repr(args)+'\\n')
if 'is-active' in args: print('active')
elif 'ActiveEnterTimestamp' in args:
 print({'bad-timestamp':'unreadable', 'empty-timestamp':'', 'previous-frame':'2026-10-24 05:23:45.900 UTC'}.get(os.environ['FIXTURE_MODE'], '2026-10-24 05:23:45 UTC'))
else:
 p=root/'identity-count'; n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n))
 if os.environ['FIXTURE_MODE']=='error': sys.exit(1)
 mode=os.environ['FIXTURE_MODE']
 invocation=('b' if mode=='previous-frame' or (mode=='restart' and n>1) or (root/'boot-changed').exists() else 'a')*32
 if mode=='invalid-invocation': invocation='invalid'
 if mode=='identity-error':sys.exit(1)
 print('ActiveState=active\\nMainPID=10\\nInvocationID='+invocation+'\\nControlGroup=/fixture.service')
''')
        self.command('journalctl', '''import os,pathlib,sys
root=pathlib.Path(os.environ['FIXTURE_ROOT']); mode=os.environ['FIXTURE_MODE']; args=sys.argv[1:]
with (root/'calls').open('a') as f: f.write('journalctl '+repr(args)+'\\n')
if '-n' in args:
 if mode=='previous-frame':
  if not any(arg.endswith('='+'b'*32) for arg in args):print('LOG : General f:42 st:1> previous invocation')
  print('LOG : General f:0 st:2> current invocation')
 elif mode=='payload-frame':
  print('LOG : General f:0 st:123> command entered via server console (System.in): "servermsg f:42 st: f:19 st:"')
 elif mode=='native-frame-with-payload':
  print('LOG  : General      f:42 t:1,234 st:1\u202f234 at GameServer.main> servermsg f:0 st:999> loading')
 elif mode=='replaced-frame':
  print('LOG : General f:42 st:1> ready');(root/'boot-changed').touch()
 elif mode in ('invalid-invocation','identity-error'):print('LOG : General f:42 st:1> ready')
 elif mode=='noframe': print('LOG : Lua , 123> LuaNet: Initialization [DONE]')
 else: print('LOG : General f:'+('42' if mode=='frame' else '0')+' st:123> tick')
elif '--grep' in args: print('LOG : Lua f:0 st:1> LuaNet: Initialization [DONE]')
else:
 if mode=='zero-with-time': print('LOG : General f:0 t:1,234 st:1\\u202f235> command entered via server console (System.in): "players"')
 else: print('LOG : General f:0 st:123> command entered via server console (System.in): "players"')
 if mode=='zero-with-time': print('LOG : General f:0 t:1,234 st:1\\u202f236> Players connected (0):')
 elif mode in ('zero','restart'): print('LOG : General f:0 st:124> Players connected (0):')
 elif mode=='players': print('Players connected (2):\\n-alice\\n-bob')
 elif mode=='lua': print('LOG : Lua f:0 st:124> Players connected (0):')
 elif mode=='malformed': print('not Players connected (0):')
''')

    def command(self, name, source):
        path = self.bin / name
        path.write_text('#!/usr/bin/python3\n' + source)
        path.chmod(0o700)

    def run_ready(self, mode, timeout=1):
        self.env['FIXTURE_MODE'] = mode
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\nsource "$1"\nwait_for_server_ready "$2"',
                                 'readiness', str(ROOT / 'data/scripts/lib/common.sh'), str(timeout)],
                                env=self.env, capture_output=True, text=True, timeout=6)
        return result

    def test_positive_frame_needs_no_console_probe(self):
        result = self.run_ready('frame')
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(BlockingIOError):
            os.read(self.fd, 100)

    def test_frame_tokens_in_console_payload_do_not_prove_readiness(self):
        result=self.run_ready('payload-frame', timeout=3)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('fin de boot toujours non signalée',result.stderr)
        self.assertEqual(os.read(self.fd,100),b'players\n')
    def test_native_frame_prefix_wins_over_zero_payload_and_grouped_time(self):
        result=self.run_ready('native-frame-with-payload')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        with self.assertRaises(BlockingIOError):os.read(self.fd,100)
    def test_previous_invocation_frame_in_same_second_is_refused(self):
        result=self.run_ready('previous-frame')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('fin de boot toujours non signalée',result.stderr)
        calls=self.calls.read_text()
        self.assertIn('INVOCATION_ID='+'b'*32,calls)
        self.assertIn('_SYSTEMD_INVOCATION_ID='+'b'*32,calls)

    def test_invocation_replaced_after_positive_frame_is_refused(self):
        result=self.run_ready('replaced-frame')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertNotIn('poursuite',result.stdout)

    def test_unproven_invocation_is_refused_even_with_frame(self):
        for mode in ('identity-error','invalid-invocation'):
            with self.subTest(mode=mode):
                result=self.run_ready(mode)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)

    def test_unreadable_boot_timestamp_does_not_prove_readiness(self):
        for mode in ('bad-timestamp', 'empty-timestamp'):
            with self.subTest(mode=mode):
                result = self.run_ready(mode)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('horodatage', result.stderr)
        self.assertFalse(self.count.exists())
        self.assertNotIn('journalctl', self.calls.read_text())

    def test_idle_zero_players_is_ready(self):
        # Les sous-processus console et date +%s partagent le budget : trois
        # secondes évitent qu'une frontière de seconde épuise le cas positif.
        result = self.run_ready('zero', timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.read(self.fd, 100), b'players\n')

    def test_idle_players_with_native_time_prefix_is_ready(self):
        result=self.run_ready('zero-with-time',timeout=3)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(os.read(self.fd,100),b'players\n')
    def test_native_positive_players_is_ready(self):
        result = self.run_ready('players', timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.read(self.fd, 100), b'players\n')

    def test_unproven_or_changed_boot_is_refused(self):
        for mode in ('echo', 'lua', 'malformed', 'error', 'restart', 'noframe'):
            with self.subTest(mode=mode):
                self.count.unlink(missing_ok=True)
                result = self.run_ready(mode, timeout=3 if mode == 'restart' else 1)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                expected=('invocation' if mode in ('error','restart') else 'fin de boot toujours non signalée')
                self.assertIn(expected, result.stderr)
        self.assertNotIn('stop', self.calls.read_text())


if __name__ == '__main__':
    unittest.main()
