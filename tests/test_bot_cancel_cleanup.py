"""Nettoyage non annulable : le verrou reste tenu jusqu'à l'arrêt du processus.

Utilise le vrai `run_pzm`/`execute` avec `PZM = sys.executable` et uniquement
des processus Python jetables qui ignorent SIGTERM. Aucun vrai pzm, service,
réseau ni budget opérationnel.
"""
import asyncio
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from test_c10_bot_timeout import bot


def _state(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1][0]
    except OSError:
        return 'gone'


async def _wait_file(path, timeout=5.0):
    for _ in range(int(timeout / 0.01)):
        if path.exists():
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f'fichier absent : {path}')


class CleanupNotCancelable(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self._pzm = bot.PZM
        self._manager = bot.PZ_MANAGER_DIR
        self._timeout = bot.CMD_TIMEOUT
        self._grace = bot._TERM_GRACE
        self._lock = bot.run_lock
        self._tail = getattr(bot, '_queue_tail', None)
        bot.PZM = sys.executable
        bot.PZ_MANAGER_DIR = str(self.root)
        bot._TERM_GRACE = 1.0
        bot.CMD_TIMEOUT = 30
        bot.run_lock = asyncio.Lock()
        bot._queue_tail = None
        bot.ALLOWED_CHANNELS = {1}
        bot.ROLE_IDS = {2}
        self.events = []

    def tearDown(self):
        bot.PZM = self._pzm
        bot.PZ_MANAGER_DIR = self._manager
        bot.CMD_TIMEOUT = self._timeout
        bot._TERM_GRACE = self._grace
        bot.run_lock = self._lock
        bot._queue_tail = self._tail

    def _interaction(self):
        async def defer():
            pass

        async def send(*args, **kwargs):
            return SimpleNamespace(edit=self._noop, delete=self._noop)

        return SimpleNamespace(
            channel_id=1,
            user=SimpleNamespace(mention='<@1>', roles=[SimpleNamespace(id=2)]),
            channel=SimpleNamespace(id=1, send=send),
            response=SimpleNamespace(defer=defer, send_message=send),
            followup=SimpleNamespace(send=send))

    async def _noop(self, *args, **kwargs):
        pass

    def _stubborn_code(self, pidfile, termfile):
        return (
            'import os,signal,time\n'
            'from pathlib import Path\n'
            'def term(signum, frame):\n'
            f'    Path({str(termfile)!r}).write_text("TERM")\n'
            'signal.signal(signal.SIGTERM, term)\n'
            f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
            'time.sleep(60)\n')

    def _probe_code(self, pid, witness):
        return (
            'from pathlib import Path\n'
            'try:\n'
            f'    state = Path("/proc/{pid}/stat").read_text().rsplit(") ", 1)[1][0]\n'
            'except OSError:\n'
            '    state = "gone"\n'
            f'Path({str(witness)!r}).write_text(state)\n')

    def test_double_cancel_during_term_grace_keeps_lock_until_kill_and_reap(self):
        async def scenario():
            pidfile, termfile = self.root / 'pid', self.root / 'term'
            witness = self.root / 'probe'
            first = asyncio.create_task(bot.execute(
                self._interaction(), ['-c', self._stubborn_code(pidfile, termfile)]))
            await _wait_file(pidfile)
            pid = int(pidfile.read_text())
            try:
                second = asyncio.create_task(bot.execute(
                    self._interaction(), ['-c', self._probe_code(pid, witness)]))
                await asyncio.sleep(0.05)  # seconde demande admise et en attente
                first.cancel()
                await _wait_file(termfile)  # SIGTERM envoyé, grâce en cours
                first.cancel()              # seconde annulation pendant la grâce
                with self.assertRaises(asyncio.CancelledError):
                    await asyncio.wait_for(first, 5)
                await asyncio.wait_for(second, 5)
                self.assertIn(witness.read_text(), ('gone', 'Z', 'X'),
                              'la commande suivante a démarré avant l\'arrêt du groupe')
                self.assertIn(_state(pid), ('gone', 'Z', 'X'))
                self.assertFalse(bot.run_lock.locked())
                self.assertTrue(bot._queue_tail.done())
            finally:
                if _state(pid) not in ('gone', 'Z', 'X'):
                    import os
                    import signal
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

        asyncio.run(scenario())

    def test_cancel_during_timeout_cleanup_keeps_lock_until_kill_and_reap(self):
        async def scenario():
            bot.CMD_TIMEOUT = 0.3
            pidfile, termfile = self.root / 'pid', self.root / 'term'
            witness = self.root / 'probe'
            first = asyncio.create_task(bot.execute(
                self._interaction(), ['-c', self._stubborn_code(pidfile, termfile)]))
            await _wait_file(pidfile)
            pid = int(pidfile.read_text())
            try:
                second = asyncio.create_task(bot.execute(
                    self._interaction(), ['-c', self._probe_code(pid, witness)]))
                await _wait_file(termfile)  # timeout atteint, SIGTERM en cours
                first.cancel()              # annulation pendant le nettoyage
                with self.assertRaises(asyncio.CancelledError):
                    await asyncio.wait_for(first, 5)
                await asyncio.wait_for(second, 5)
                self.assertIn(witness.read_text(), ('gone', 'Z', 'X'))
                self.assertIn(_state(pid), ('gone', 'Z', 'X'))
                self.assertFalse(bot.run_lock.locked())
                self.assertTrue(bot._queue_tail.done())
            finally:
                if _state(pid) not in ('gone', 'Z', 'X'):
                    import os
                    import signal
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

        asyncio.run(scenario())

    def _check_asyncio_shutdown(self, mode):
        try:
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()),
                 mode, str(self.root)],
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((self.root / 'shutdown-result').read_text(), 'reaped')
        finally:
            # Also contain an old/broken implementation or a timed-out child.
            pidfile = self.root / 'shutdown-pid'
            if pidfile.exists():
                try:
                    os.killpg(int(pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_asyncio_shutdown_kills_and_reaps_before_loop_closes(self):
        self._check_asyncio_shutdown('--shutdown-child')

    def test_asyncio_shutdown_before_cleanup_starts_still_reaps(self):
        self._check_asyncio_shutdown('--shutdown-child-before-cleanup')


def _shutdown_child(root, wait_for_term):
    """Exercise the real asyncio.run shutdown in a disposable interpreter."""
    pidfile, termfile = root / 'shutdown-pid', root / 'shutdown-term'
    original_spawn = asyncio.create_subprocess_exec
    processes = []

    async def spawn(*args, **kwargs):
        proc = await original_spawn(*args, **kwargs)
        processes.append(proc)
        return proc

    async def noop(*args, **kwargs):
        pass

    async def main():
        bot.PZM = sys.executable
        bot.PZ_MANAGER_DIR = str(root)
        bot.CMD_TIMEOUT = 30
        bot._TERM_GRACE = 30
        bot.run_lock = asyncio.Lock()
        bot._queue_tail = None
        bot.authz_error = lambda _: None
        interaction = SimpleNamespace(
            response=SimpleNamespace(defer=noop),
            followup=SimpleNamespace(send=noop),
            channel=SimpleNamespace(send=noop), user='fixture', channel_id=0)
        code = (
            'import os,signal,time\nfrom pathlib import Path\n'
            f'signal.signal(signal.SIGTERM, lambda *args: Path({str(termfile)!r}).write_text("TERM"))\n'
            f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
            # More than the pipe/StreamReader buffer: shutdown must drain the
            # pipe after cancelling its original reader, not just await wait().
            'os.write(1, b"x" * 1048576)\n'
            'time.sleep(60)\n')
        command = asyncio.create_task(bot.execute(interaction, ['-c', code]))
        await _wait_file(pidfile)
        command.cancel()
        if wait_for_term:
            await _wait_file(termfile)
        # Return while cleanup waits for TERM: asyncio.run now cancels every
        # remaining task, including the original communicate/read tasks.

    asyncio.create_subprocess_exec = spawn
    try:
        asyncio.run(main())
        if not processes or processes[0].returncode is None:
            raise AssertionError('process still alive after asyncio.run shutdown')
        if _state(int(pidfile.read_text())) != 'gone':
            raise AssertionError('process was not reaped before loop closed')
        (root / 'shutdown-result').write_text('reaped')
    finally:
        asyncio.create_subprocess_exec = original_spawn
        if pidfile.exists():
            pid = int(pidfile.read_text())
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] in (
            '--shutdown-child', '--shutdown-child-before-cleanup'):
        _shutdown_child(Path(sys.argv[2]), sys.argv[1] == '--shutdown-child')
    else:
        unittest.main()
