"""Queue UX through the real bot and local child processes, without Discord."""
import asyncio
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_bot_delivery as delivery

bot = delivery.bot


class ActionQueue(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.calls = self.root / 'calls'
        self.release = self.root / 'release'
        fake = self.root / 'pzm'
        fake.write_text(
            '#!/usr/bin/env python3\nimport json,sys,time\nfrom pathlib import Path\n'
            f'with Path({str(self.calls)!r}).open("a") as out: out.write(json.dumps(sys.argv[1:])+"\\n")\n'
            'if sys.argv[-1:] == ["--reason"]: print("--reason attend un texte"); raise SystemExit(2)\n'
            'print("⏳ Une autre opération est en cours ; votre demande attend.", flush=True)\n'
            f'while not Path({str(self.release)!r}).exists(): time.sleep(.01)\n'
            'print("▶️ Action en cours.", flush=True)\n'
            'print("result-sentinel", flush=True)\n'
            'raise SystemExit(7 if "fail" in sys.argv else 0)\n')
        fake.chmod(0o700)
        for name, value in {'PZM': str(fake), 'PZ_MANAGER_DIR': str(self.root),
                            'ALLOWED_CHANNELS': {1}, 'ROLE_IDS': {2},
                            'run_lock': asyncio.Lock(), '_restart_group': None,
                            'CMD_TIMEOUT': 10, '_TERM_GRACE': .2}.items():
            mocking = patch.object(bot, name, value)
            mocking.start()
            self.addCleanup(mocking.stop)
        self.author = SimpleNamespace(mention='<@123>', bot=False, roles=[SimpleNamespace(id=2)])
        self.tasks = []

    async def asyncTearDown(self):
        for task in self.tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)

    def interaction(self):
        channel = delivery.Transport()
        async def defer():
            pass
        return SimpleNamespace(channel_id=1, user=self.author, channel=channel,
                               response=SimpleNamespace(defer=defer), followup=channel)

    def start(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.append(task)
        return task

    def invocations(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    async def until(self, condition):
        async with asyncio.timeout(4):
            while not condition():
                await asyncio.sleep(.01)

    async def test_slash_restarts_share_process_progress_and_first_arguments(self):
        first, second = self.interaction(), self.interaction()
        original = ['server', 'restart', '5m', '--reason', 'premier motif']
        one = self.start(bot.execute(first, original))
        await self.until(lambda: len(self.invocations()) == 1)
        await self.until(lambda: any('votre demande attend' in line for line in first.channel.edits))
        self.assertFalse(one.done(), 'progress was only delivered after completion')
        two = self.start(bot.execute(second, ['server', 'restart', 'now', '--reason', 'second motif']))
        await self.until(lambda: any('regroupée' in line for line in second.channel.edits))
        self.assertEqual(self.invocations(), [original])
        self.release.touch()
        await asyncio.gather(one, two)
        self.assertEqual(self.invocations(), [original])
        self.assertIn('result-sentinel', '\n'.join(first.channel.contents))
        final = '\n'.join(second.channel.contents)
        self.assertIn('premier motif', final)
        self.assertIn('Un seul redémarrage', final)

    async def test_other_submission_is_a_barrier_and_keeps_execution_order(self):
        commands = [['server', 'restart', 'now'], ['help'], ['server', 'restart', 'now']]
        first = self.start(bot.execute(self.interaction(), commands[0]))
        await self.until(lambda: len(self.invocations()) == 1)
        second = self.start(bot.execute(self.interaction(), commands[1]))
        await asyncio.sleep(0)
        third = self.start(bot.execute(self.interaction(), commands[2]))
        await asyncio.sleep(.05)
        self.assertEqual(self.invocations(), commands[:1])
        self.release.touch()
        await asyncio.gather(first, second, third)
        self.assertEqual(self.invocations(), commands)

    async def test_batch_submission_is_a_barrier_and_keeps_its_items_together(self):
        restart = ['server', 'restart', 'now']
        one = self.start(bot.execute(self.interaction(), restart))
        await self.until(lambda: len(self.invocations()) == 1)
        source = delivery.Transport()
        source.channel, source.author = delivery.Transport(), self.author
        batch = [['help'], ['rcon', 'players']]
        two = self.start(bot.run_batch(source, batch))
        await asyncio.sleep(0)
        three = self.start(bot.execute(self.interaction(), restart))
        self.release.touch()
        await asyncio.gather(one, two, three)
        self.assertEqual(self.invocations(), [restart, *batch, restart])

    async def test_pasted_and_slash_share_result_even_when_first_request_is_cancelled(self):
        source = delivery.Transport()
        source.channel, source.author = delivery.Transport(), self.author
        first = self.start(bot.run_single(source, ['server', 'restart', 'now']))
        await self.until(lambda: len(self.invocations()) == 1)
        follower = self.interaction()
        second = self.start(bot.execute(follower, ['server', 'restart', 'now']))
        await self.until(lambda: any('regroupée' in line for line in follower.channel.edits))
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        self.release.touch()
        await second
        self.assertEqual(len(self.invocations()), 1)
        self.assertIn('result-sentinel', '\n'.join(follower.channel.contents))

    async def test_streaming_timeout_retains_partial_output_with_stalled_progress_transport(self):
        bot.CMD_TIMEOUT = .2
        started = asyncio.Event()
        async def stalled(text):
            started.set()
            await asyncio.Event().wait()
        code, output = await asyncio.wait_for(bot.run_pzm(['server', 'restart'], progress=stalled), timeout=2)
        self.assertEqual(code, 124)
        self.assertTrue(started.is_set())
        self.assertIn('votre demande attend', output)
        self.assertIn('partielle', output)

    async def test_shared_failure_reaches_every_request(self):
        first, second = self.interaction(), self.interaction()
        one = self.start(bot.execute(first, ['server', 'restart', '--reason', 'fail']))
        await self.until(lambda: len(self.invocations()) == 1)
        two = self.start(bot.execute(second, ['server', 'restart']))
        await self.until(lambda: any('regroupée' in line for line in second.channel.edits))
        self.release.touch()
        await asyncio.gather(one, two)
        self.assertEqual(len(self.invocations()), 1)
        for interaction in (first, second):
            self.assertIn('exit=7', '\n'.join(interaction.channel.contents))

    async def test_malformed_restart_is_not_given_another_requests_success(self):
        first, malformed = self.interaction(), self.interaction()
        one = self.start(bot.execute(first, ['server', 'restart', 'now']))
        await self.until(lambda: len(self.invocations()) == 1)
        two = self.start(bot.execute(malformed, ['server', 'restart', '--reason']))
        await asyncio.sleep(.05)
        self.release.touch()
        await asyncio.gather(one, two)
        self.assertEqual(len(self.invocations()), 2)
        self.assertIn('exit=2', '\n'.join(malformed.channel.contents))
        self.assertNotIn('Un seul redémarrage', '\n'.join(malformed.channel.contents))

    async def test_expired_wait_is_removed_before_it_can_execute(self):
        await bot.run_lock.acquire()
        try:
            interaction = self.interaction()
            with patch.dict(os.environ, PZ_SERVER_QUEUE_TIMEOUT='1'):
                await bot.execute(interaction, ['server', 'restart', 'now'])
            self.assertIn('annulée avant exécution', '\n'.join(interaction.channel.contents))
        finally:
            bot.run_lock.release()
        await asyncio.sleep(.05)
        self.assertEqual(self.invocations(), [])

    async def test_cancelled_last_request_does_not_execute_after_slot_is_released(self):
        await bot.run_lock.acquire()
        try:
            interaction = self.interaction()
            task = self.start(bot.execute(interaction, ['server', 'restart', 'now']))
            await self.until(lambda: bool(interaction.channel.contents))
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        finally:
            bot.run_lock.release()
        await asyncio.sleep(.05)
        self.assertEqual(self.invocations(), [])


if __name__ == '__main__':
    unittest.main()
