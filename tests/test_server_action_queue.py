"""Real WORLD contention and pz.sh lifecycle with disposable service boundaries."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServerActionQueue(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manager = self.root / 'manager'
        self.scripts = self.manager / 'data/scripts'
        for name in ('lib', 'internal', 'core'):
            shutil.copytree(ROOT / 'data/scripts' / name, self.scripts / name)
        (self.scripts / 'backup').mkdir()
        common = self.scripts / 'lib/common.sh'
        common.write_text(common.read_text() + '''
source_env() { apply_env_defaults "$@"; }
notify() { :; }
wait_for_server_ready() { return 0; }
''')
        backup = self.scripts / 'backup/dataBackup.sh'
        backup.write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/world_lock.sh"
acquire_world_lock --required
echo backup >> "$FIXTURE_ROOT/events"
''')
        backup.chmod(0o700)
        send = self.scripts / 'internal/sendCommand.sh'
        send.write_text('#!/bin/bash\necho "Players connected (0):"\n')
        send.chmod(0o700)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.runtime = self.root / 'runtime'; self.runtime.mkdir(mode=0o700)
        self.state = self.runtime / 'pzmanager'; self.state.mkdir(mode=0o700)
        self.world = self.root / 'world'; self.world.mkdir()
        self.lock = os.open(self.state / 'world.lock', os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, self.lock)
        self.events = self.root / 'events'
        (self.root / 'service-state').write_text('active')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        FIXTURE_ROOT=str(self.root), XDG_RUNTIME_DIR=str(self.runtime),
                        PZ_HOME=str(self.root / 'home'), PZ_MANAGER_DIR=str(self.manager),
                        PZ_SOURCE_DIR=str(self.world), PZ_SERVER_QUEUE_TIMEOUT='10')
        for key in ('PZ_WORLD_LOCK_FD', 'PZ_WORLD_LOCK_DEPTH', 'SERVERCTL_LOCK_FD'):
            self.env.pop(key, None)
        self.command('systemctl', '''import os,pathlib,sys,time
r=pathlib.Path(os.environ['FIXTURE_ROOT']);a=sys.argv[1:];state=r/'service-state'
if 'stop' in a or 'start' in a:
 action='stop' if 'stop' in a else 'start'
 with (r/'events').open('a') as stream:stream.write(action+'\\n')
 while (r/'block-worker').exists():time.sleep(.02)
 if os.environ.get('FIXTURE_START_FAIL') and action=='start':raise SystemExit(7)
 state.write_text('inactive' if action=='stop' else 'active')
elif 'is-active' in a:raise SystemExit(0 if state.read_text()=='active' else 3)
else:
 active=state.read_text()=='active'
 print('LoadState=loaded\\nActiveState='+('active' if active else 'inactive')+'\\nSubState='+('running' if active else 'dead')+'\\nMainPID='+('42' if active else '0')+'\\nControlPID=0\\nInvocationID='+'a'*32)
''')
        self.command('sleep', 'pass')
        self.command('python3', '''import os,sys
a=sys.argv[1:]
if a and a[0].endswith('/writing_start_admission.py') and a[1] in ('prepare','clear'):
 if a[1]=='prepare':print('fixture')
else:os.execv('/usr/bin/python3',['/usr/bin/python3',*a])
''')
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def command(self, name, source):
        path = self.bin / name
        path.write_text('#!/usr/bin/python3\n' + source + '\n')
        path.chmod(0o700)

    def cleanup_processes(self):
        for process in self.processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()

    def start(self, action='restart', **env):
        process = subprocess.Popen(['bash', str(self.scripts / 'core/pz.sh'), action, 'now', '--silent'],
                                   env=dict(self.env, **env), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.processes.append(process)
        return process

    def jobs(self):
        path = self.state / 'server-actions.json'
        return json.loads(path.read_text()) if path.exists() else []

    def wait_for(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.02)
        self.fail('fixture condition timed out')

    def output(self, process, timeout=10):
        out, _ = process.communicate(timeout=timeout)
        return process.returncode, out

    def test_two_restarts_wait_for_backup_then_share_one_real_lifecycle(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start()
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        self.assertFalse(self.events.exists(), 'no stop, backup or start before WORLD is free')
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        for process in (first, second):
            code, out = self.output(process)
            self.assertEqual(code, 0, out)
        self.assertEqual(self.events.read_text().splitlines(), ['stop', 'backup', 'start'])
        self.assertIn('Redémarrage regroupé', self.output(second)[1])

    def test_stop_between_restarts_is_a_fifo_barrier(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        processes = []
        for number, action in enumerate(('restart', 'stop', 'restart'), 1):
            processes.append(self.start(action))
            self.wait_for(lambda: len(self.jobs()) == number)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        for process in processes:
            code, out = self.output(process)
            self.assertEqual(code, 0, out)
        self.assertEqual(self.events.read_text().splitlines(), ['stop', 'backup', 'start', 'stop', 'backup', 'backup', 'start'])

    def test_profile_change_does_not_share_a_restart(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start()
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start(PZ_SERVER_NAME='different')
        self.wait_for(lambda: len(self.jobs()) == 2)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        for process in (first, second):
            code, out = self.output(process)
            self.assertEqual(code, 0, out)
        self.assertEqual(self.events.read_text().splitlines().count('start'), 2)

    def test_expired_or_cancelled_pending_request_never_runs_later(self):
        for cancelled in (False, True):
            with self.subTest(cancelled=cancelled):
                fcntl.flock(self.lock, fcntl.LOCK_EX)
                process = self.start(PZ_SERVER_QUEUE_TIMEOUT='1' if not cancelled else '10')
                self.wait_for(lambda: any(j['state'] == 'pending' for j in self.jobs()))
                if cancelled: process.terminate()
                code, out = self.output(process)
                self.assertNotEqual(code, 0, out)
                fcntl.flock(self.lock, fcntl.LOCK_UN)
                time.sleep(.25)
                self.assertFalse(self.events.exists())

    def test_follower_cancellation_keeps_original_request(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start()
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        second.terminate()
        code, out = self.output(second)
        self.assertNotEqual(code, 0)
        self.assertIn('peut continuer', out)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.assertEqual(self.output(first)[0], 0)
        self.assertEqual(self.events.read_text().splitlines().count('start'), 1)

    def test_remaining_budget_expires_pending_leader_and_shared_result(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start(PZ_SERVER_QUEUE_TIMEOUT='10', PZ_SERVER_QUEUE_REMAINING='1')
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        for process in (first, second):
            code, out = self.output(process)
            self.assertEqual(code, 124, out)
            self.assertIn('expirée', out)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.assertFalse(self.events.exists())

    def test_running_follower_cancellation_is_bounded_when_registry_mutex_is_busy(self):
        (self.root / 'block-worker').touch()
        first = self.start()
        self.wait_for(lambda: self.events.exists())
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        progress = bytearray()
        deadline = time.monotonic() + 3
        while 'Redémarrage partagé en cours.'.encode() not in progress and time.monotonic() < deadline:
            readable, _, _ = select.select([second.stdout], [], [], .1)
            if readable:
                progress.extend(os.read(second.stdout.fileno(), 4096))
        self.assertIn('Redémarrage partagé en cours.'.encode(), progress)
        mutex = os.open(self.state / 'server-actions.lock', os.O_RDWR)
        try:
            fcntl.flock(mutex, fcntl.LOCK_EX)
            started = time.monotonic()
            second.terminate()
            code, out = self.output(second, timeout=8)
            self.assertEqual(code, 130, out)
            self.assertLess(time.monotonic() - started, 8)
            self.assertIn('Nettoyage de la file différé', out)
            self.assertNotIn('ne sera pas exécutée', out)
            self.assertIsNone(first.poll(), 'cancelling follower must not kill the leader')
        finally:
            fcntl.flock(mutex, fcntl.LOCK_UN)
            os.close(mutex)
            (self.root / 'block-worker').unlink()
        self.assertEqual(self.output(first)[0], 0)
        self.assertEqual(self.events.read_text().splitlines().count('start'), 1)

    def test_dead_pending_owner_is_not_replayed_for_follower(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start()
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        first.kill(); first.wait()
        code, out = self.output(second)
        self.assertEqual(code, 130, out)
        self.assertIn('aucune reprise automatique', out)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.assertFalse(self.events.exists())

    def test_shared_failure_keeps_failure_status(self):
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        first = self.start(FIXTURE_START_FAIL='1')
        self.wait_for(lambda: len(self.jobs()) == 1)
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.assertEqual(self.output(first)[0], 7)
        code, out = self.output(second)
        self.assertEqual(code, 7, out)
        self.assertIn('échoué', out)

    def test_pending_timeout_does_not_expire_a_running_shared_restart(self):
        (self.root / 'block-worker').touch()
        first = self.start(PZ_SERVER_QUEUE_TIMEOUT='1')
        self.wait_for(lambda: self.events.exists())
        second = self.start(PZ_SERVER_QUEUE_TIMEOUT='1')
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        progress = bytearray()
        deadline = time.monotonic() + 3
        while 'Redémarrage partagé en cours.'.encode() not in progress and time.monotonic() < deadline:
            readable, _, _ = select.select([second.stdout], [], [], .1)
            if readable:
                progress.extend(os.read(second.stdout.fileno(), 4096))
        self.assertIn('▶️ Redémarrage partagé en cours.'.encode(), progress)
        self.assertEqual(progress.count('▶️'.encode()), 1)
        time.sleep(1.2)
        self.assertIsNone(second.poll())
        (self.root / 'block-worker').unlink()
        for process in (first, second):
            code, out = self.output(process)
            self.assertEqual(code, 0, out)

    def test_dead_running_owner_leaves_world_with_its_descendants(self):
        (self.root / 'block-worker').touch()
        first = self.start()
        self.wait_for(lambda: self.events.exists())
        second = self.start()
        self.wait_for(lambda: len(self.jobs()[0]['waiters']) == 2)
        first.kill(); first.wait()
        code, out = self.output(second)
        self.assertEqual(code, 130, out)
        with self.assertRaises(BlockingIOError):
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        third = self.start('start')
        self.wait_for(lambda: any(j['action'] == 'start' for j in self.jobs()))
        time.sleep(.3)
        self.assertEqual(self.events.read_text().splitlines(), ['stop'])
        (self.root / 'block-worker').unlink()
        self.assertEqual(self.output(third)[0], 0)
        self.output(first)

    def test_invalid_arguments_are_refused_before_queue_registration(self):
        process = subprocess.Popen(['bash', str(self.scripts / 'core/pz.sh'), 'restart', '--reason'],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        self.processes.append(process)
        code, out = self.output(process)
        self.assertNotEqual(code, 0, out)
        self.assertIn('--reason attend', out)
        self.assertFalse((self.state / 'server-actions.json').exists())

    def test_corrupt_or_linked_queue_state_is_refused_without_service_calls(self):
        path = self.state / 'server-actions.json'
        target = self.root / 'target'; target.write_text('[]'); target.chmod(0o600)
        for variant in ('corrupt', 'symlink', 'hardlink', 'public'):
            with self.subTest(variant=variant):
                path.unlink(missing_ok=True)
                if variant == 'symlink': path.symlink_to(target)
                elif variant == 'hardlink': os.link(target, path)
                else:
                    path.write_text('{' if variant == 'corrupt' else '[]')
                    path.chmod(0o644 if variant == 'public' else 0o600)
                code, out = self.output(self.start())
                self.assertNotEqual(code, 0, out)
                self.assertFalse(self.events.exists())
        self.assertEqual(target.read_text(), '[]')

    def test_invalid_inherited_fd_is_refused_not_queued(self):
        code, out = self.output(self.start(PZ_WORLD_LOCK_FD='999', PZ_WORLD_LOCK_DEPTH='1'))
        self.assertNotEqual(code, 0, out)
        self.assertIn('réentrance', out)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.state / 'server-actions.json').exists())

    def test_queue_capacity_refuses_without_corrupting_existing_requests(self):
        identity = dict(pid=os.getpid(), birth=int(Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]))
        path = self.state / 'server-actions.json'
        for dimension in ('jobs', 'waiters'):
            with self.subTest(dimension=dimension):
                job = dict(id='0' * 32, action='start', scope='0' * 64, owner=identity,
                           waiters=[identity], state='pending', code=0, summary='')
                if dimension == 'jobs':
                    jobs = [dict(job, id=f'{number:032x}') for number in range(1024)]
                else:
                    # Matching launch profile: a new restart joins this job.
                    profile = {key: self.env.get(key, '') for key in
                               ('PZ_SOURCE_DIR', 'PZ_SERVER_NAME', 'PZ_INSTALL_DIR', 'PZ_CONTROL_PIPE', 'PZ_MANAGER_DIR')}
                    profile.update(PZ_SERVER_NAME='servertest', PZ_INSTALL_DIR=str(self.manager / 'data/pzserver'),
                                   PZ_CONTROL_PIPE=str(self.manager / 'data/pzserver/zomboid.control'),
                                   service='zomboid.service', script=str(self.scripts / 'core/pz.sh'))
                    import hashlib
                    job.update(action='restart', scope=hashlib.sha256(json.dumps(profile, sort_keys=True).encode()).hexdigest(),
                               waiters=[identity] * 1024)
                    jobs = [job]
                before = json.dumps(jobs, ensure_ascii=False).encode()
                path.write_bytes(before); path.chmod(0o600)
                code, out = self.output(self.start())
                self.assertNotEqual(code, 0, out)
                self.assertIn('File pleine', out)
                self.assertEqual(path.read_bytes(), before)
                self.assertFalse(self.events.exists())


if __name__ == '__main__':
    unittest.main()
