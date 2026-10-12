"""Console et JVM : frontières simulées, vrais fichiers et FIFO privés."""
from pathlib import Path
import os
import sys
import tempfile
import threading
import time
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'data/scripts/lib'))
import console_command as console
import service_process as process
import stop_diagnostics as stop

ID = ('a' * 32, 10, '/user.slice/user-1005.slice/user@1005.service/pz.slice/zomboid.service')
ECHO = 'LOG : General f:1 st:1\u202f234> command entered via server console (System.in): "players"\n'


class Console(unittest.TestCase):
    def test_exact_echo_and_interleaved_connection(self):
        self.assertEqual(console.response(ECHO + 'ConnectionManager: connect\nChatMessage{noise}\n'
                                         'LOG : General f:1 st:1\u202f235> Players connected (2):\n-player\n', 'players'),
                         'Players connected (2):\n-player')
        self.assertEqual(console.response(ECHO.replace('"players"', '"servermsg players"') + 'Message sent.\n', 'players'), '')
        self.assertEqual(console.response(ECHO + 'unrelated game tick\n', 'players'), '')

    def test_next_command_does_not_supply_a_response(self):
        text = ECHO + ECHO.replace('"players"', '"save"') + 'Players connected (9):\n'
        self.assertEqual(console.response(text, 'players'), '')

    def test_delayed_response_is_collected_without_rewriting(self):
        polls = [subprocess.CompletedProcess([], 0, stdout=ECHO),
                 subprocess.CompletedProcess([], 0, stdout=ECHO + 'Players connected (3):\n')]
        with patch.object(console, 'identity', return_value=ID), patch.object(console, 'write_fifo') as write, \
             patch.object(console.subprocess, 'run', side_effect=polls) as journal, patch.object(console.time, 'sleep'):
            self.assertIn('Players connected (3)', console.execute('zomboid.service', Path('/unused'), 'players'))
        write.assert_called_once()
        self.assertEqual(journal.call_count, 2)
        self.assertIn('_SYSTEMD_INVOCATION_ID=' + ID[0], journal.call_args.args[0])

    def test_restart_or_bus_failure_refuses_response(self):
        for fresh in [('b' * 32, *ID[1:]), ValueError('bus')]:
            with self.subTest(fresh=fresh), patch.object(console, 'identity', side_effect=[ID, fresh]), \
                 patch.object(console, 'write_fifo'), patch.object(console.subprocess, 'run',
                 return_value=subprocess.CompletedProcess([], 0, stdout=ECHO + 'Players connected (3):\n')):
                with self.assertRaises(ValueError):
                    console.execute('zomboid.service', Path('/unused'), 'players')

    def test_missing_response_and_missing_reader_are_bounded(self):
        with patch.object(console, 'identity', return_value=ID), patch.object(console, 'write_fifo'), \
             patch.object(console.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=ECHO)):
            start = time.monotonic()
            self.assertIn('délai borné', console.execute('zomboid.service', Path('/unused'), 'players', output_timeout=.03))
            self.assertLess(time.monotonic() - start, .2)
        with tempfile.TemporaryDirectory() as tmp:
            fifo = Path(tmp) / 'control'; os.mkfifo(fifo)
            start = time.monotonic()
            with self.assertRaises(OSError):
                console.write_fifo(fifo, 'players', .03)
            self.assertLess(time.monotonic() - start, .2)

    def test_real_fifo_atomic_and_nonfifo_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            fifo = Path(tmp) / 'control'; os.mkfifo(fifo)
            fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            try:
                console.write_fifo(fifo, 'players', .2)
                self.assertEqual(os.read(fd, 100), b'players\n')
                with self.assertRaises(ValueError): console.write_fifo(fifo, 'x' * 100000, .2)
            finally: os.close(fd)
            regular = Path(tmp) / 'regular'; regular.write_text('preserve')
            with self.assertRaises(ValueError): console.write_fifo(regular, 'players', .2)
            self.assertEqual(regular.read_text(), 'preserve')


class Process(unittest.TestCase):
    def test_only_current_uid_service_and_game_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cg = root / 'cgroup'; proc = root / 'proc'
            group = cg / ID[2].lstrip('/'); (group / 'nested').mkdir(parents=True)
            (group / 'cgroup.procs').write_text('100\n200\n300\n400\n500\n')
            (group / 'nested/cgroup.procs').write_text('600\n')
            for pid, comm, uid, actual, rss, cmd in [
                (100, 'ProjectZomboid6', os.getuid(), ID[2], 4000, ''),
                (200, 'java', os.getuid(), '/other.service', 999999, 'zombie.network.GameServer'),
                (300, 'ProjectZomboid6', os.getuid() + 1, ID[2], 999999, ''),
                (400, 'java', os.getuid(), ID[2], 999999, 'unrelated.Tool'),
                (500, 'ProjectZomboid6', os.getuid(), ID[2] + '-other', 999999, ''),
                (600, 'java', os.getuid(), ID[2] + '/nested', 5000, 'zombie.network.GameServer')]:
                p = proc / str(pid); p.mkdir(parents=True)
                (p / 'comm').write_text(comm); (p / 'cmdline').write_text(cmd)
                (p / 'cgroup').write_text('0::' + actual + '\n')
                (p / 'status').write_text(f'Uid:\t{uid}\t{uid}\t{uid}\t{uid}\nVmRSS:\t{rss} kB\n')
            self.assertEqual(process.find_in_group(ID[2], os.getuid(), cg, proc), 600)
            with patch.object(process, 'identity', side_effect=[ID, ('b' * 32, *ID[1:])]):
                self.assertIsNone(process.find_jvm('zomboid.service', cgroup_root=cg, proc_root=proc))
            for invalid in ['', '/', '/group/../other']:
                self.assertIsNone(process.find_in_group(invalid, os.getuid(), cg, proc))

    def test_missing_or_ambiguous_identity_is_not_a_process(self):
        valid = 'ActiveState=active\nMainPID=10\nInvocationID=' + ID[0] + '\nControlGroup=' + ID[2] + '\n'
        for bad in [valid + 'MainPID=20\n', valid.replace('active', 'inactive'), valid.replace('active', 'activating'), valid.replace('MainPID=10', 'MainPID=0'), valid.replace(ID[2], '/')]:
            with patch.object(process.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=bad)):
                with self.assertRaises(ValueError): process.identity('zomboid.service')


class JvmStatus(unittest.TestCase):
    def test_bus_failure_and_non_game_active_process_are_unknown(self):
        with patch.object(process, 'properties', side_effect=OSError('bus')):
            self.assertEqual(process.jvm_status('zomboid.service')['service_state'], 'unknown')
        fields = dict(ActiveState='active', MainPID='10', InvocationID=ID[0], ControlGroup=ID[2])
        with patch.object(process, 'properties', return_value=fields), patch.object(process, 'identity', return_value=ID), \
             patch.object(process, 'find_in_group', return_value=None):
            self.assertEqual(process.jvm_status('zomboid.service')['service_state'], 'unknown')

    def test_starting_and_proven_inactive_are_not_confused(self):
        for state, expected in [('activating', 'activating'), ('deactivating', 'deactivating'), ('inactive', 'inactive'), ('failed', 'inactive')]:
            fields = dict(ActiveState=state, MainPID='0', InvocationID='', ControlGroup='')
            with patch.object(process, 'properties', return_value=fields):
                self.assertEqual(process.jvm_status('zomboid.service')['service_state'], expected)


class SlowStop(unittest.TestCase):
    def test_already_exited_game_no_fifo_write_or_monitor(self):
        argv = ['stop_diagnostics.py', 'stop', '--unit', 'zomboid.service', '--pipe', '/unused', '--logs', '/unused']
        with patch.object(sys, 'argv', argv), patch.object(stop, 'identity', return_value=(ID[0], 0, ID[2])), \
             patch.object(stop, 'write_fifo') as write, patch.object(stop.subprocess, 'Popen') as spawn:
            self.assertEqual(stop.main(), 0)
        write.assert_not_called(); spawn.assert_not_called()

    def test_bus_or_monitor_failure_does_not_prevent_quit(self):
        argv = ['stop_diagnostics.py', 'stop', '--unit', 'zomboid.service', '--pipe', '/unused', '--logs', '/unused']
        with patch.object(sys, 'argv', argv), patch.object(stop, 'identity', side_effect=ValueError('bus')), \
             patch.object(stop, 'write_fifo') as write, patch.object(stop.subprocess, 'Popen') as spawn:
            self.assertEqual(stop.main(), 0)
            write.assert_called_once(); spawn.assert_not_called()
        with patch.object(sys, 'argv', argv), patch.object(stop, 'identity', return_value=ID), \
             patch.object(stop, 'write_fifo') as write, patch.object(stop.subprocess, 'Popen', side_effect=OSError('resource')):
            self.assertEqual(stop.main(), 0)
            write.assert_called_once()

    def test_monitor_returns_promptly_when_main_pid_exits(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(.08)'])
        try:
            start = time.monotonic()
            with patch.object(stop, 'same', return_value=True):
                self.assertFalse(stop.wait_until_slow('probe.service', (ID[0], child.pid, ID[2]), 60))
            self.assertLess(time.monotonic() - start, .5)
        finally: child.wait()

    def test_slow_tool_is_interrupted_when_main_pid_exits(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'jcmd'
            fake.write_text('#!' + sys.executable + '\nimport time; time.sleep(30)\n'); fake.chmod(0o700)
            main = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(.12)'])
            try:
                start = time.monotonic()
                with (Path(tmp) / 'capture').open('w') as output, patch.object(stop, 'same', return_value=True):
                    stop.capture_threads(str(fake), 10, output, 'probe.service', (ID[0], main.pid, ID[2]))
                self.assertLess(time.monotonic() - start, .6)
            finally: main.wait()

    def test_normal_stop_and_new_generation_leave_no_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            logs = Path(tmp)
            with patch.object(stop, 'wait_until_slow', return_value=False):
                stop.watch('zomboid.service', ID, logs, None, delay=.01)
            self.assertEqual(list(logs.iterdir()), [])

    def test_slow_stop_captures_bounded_dumps_without_kill_or_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            logs = Path(tmp)
            with patch.object(stop, 'same', return_value=True), patch.object(stop, 'find_in_group', return_value=os.getpid()), \
                 patch.object(stop, 'capture_threads') as command, patch.object(stop, 'wait_until_slow', return_value=True):
                stop.watch('zomboid.service', ID, logs, '/fixture/jcmd', delay=0)
            calls = command.call_args_list
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(c.args[:2] == ('/fixture/jcmd', os.getpid()) for c in calls))
            capture = next(logs.glob('stop-stall-*.txt'))
            self.assertEqual(capture.stat().st_mode & 0o777, 0o600)
            self.assertIn('Capture 2', capture.read_text())


if __name__ == '__main__': unittest.main()
