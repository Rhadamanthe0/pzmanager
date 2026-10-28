"""File Discord : ordre d'arrivée FIFO, lot atomique et source préservée.

Exerce les vraies fonctions `execute`, `run_single`, `run_batch` et
`_dispatch_pasted` du bot ; seuls les transports Discord et `run_pzm` sont des
doubles sans effet. Aucun serveur, aucun vrai pzm, aucun réseau.
"""
import asyncio
import unittest
from types import SimpleNamespace

from test_c10_bot_timeout import bot


class Status:
    def __init__(self, edits):
        self.edits = edits

    async def edit(self, *, content):
        self.edits.append(content)

    async def delete(self):
        pass


class Channel:
    """Transport Discord double : peut retenir ou refuser l'accusé."""

    def __init__(self, name, events, *, started=None, release=None,
                 fail=None, after_send=None):
        self.id = 1
        self.name = name
        self.events = events
        self.started = started
        self.release = release
        self.fail = fail
        self.after_send = after_send
        self.sent = []
        self.edits = []

    async def send(self, content, **kwargs):
        if self.fail == 'forbidden':
            raise bot.discord.Forbidden('cannot acknowledge')
        if self.fail == 'http':
            raise bot.discord.HTTPException('cannot acknowledge')
        self.sent.append(content)
        if self.started is not None:
            self.started.set()
        if self.release is not None:
            await self.release.wait()
        if self.after_send is not None:
            self.after_send.set()
        return Status(self.edits)

    async def delete(self):
        self.events.append(('deleted-channel', self.name))


class Source:
    def __init__(self, name, channel, author, events):
        self.name = name
        self.channel = channel
        self.author = author
        self.events = events

    async def delete(self):
        self.events.append(('deleted', self.name))


def _author():
    return SimpleNamespace(mention='<@1>', bot=False,
                           roles=[SimpleNamespace(id=2)])


def _interaction(channel, defer_done=None):
    async def defer():
        if defer_done is not None:
            defer_done.set()
    return SimpleNamespace(channel_id=1, user=_author(), channel=channel,
                           response=SimpleNamespace(defer=defer,
                                                    send_message=channel.send),
                           followup=channel)


class QueueOrder(unittest.TestCase):
    def setUp(self):
        self._lock = bot.run_lock
        self._tail = getattr(bot, '_queue_tail', None)
        self._run = bot.run_pzm
        self._deliver = bot.deliver
        bot.run_lock = asyncio.Lock()
        bot._queue_tail = None
        bot.ALLOWED_CHANNELS = {1}
        bot.ROLE_IDS = {2}
        self.events = []

        async def fake_run(args):
            self.events.append(('exec', args[0]))
            return 0, 'ok'

        async def fake_deliver(send, header, output, **kwargs):
            await send(header)

        bot.run_pzm = fake_run
        bot.deliver = fake_deliver

    def tearDown(self):
        bot.run_lock = self._lock
        bot._queue_tail = self._tail
        bot.run_pzm = self._run
        bot.deliver = self._deliver

    def test_arrival_order_beats_slow_ack_across_batch_single_and_slash(self):
        async def scenario():
            events = self.events
            a_started, a_release = asyncio.Event(), asyncio.Event()
            b_done, c_done = asyncio.Event(), asyncio.Event()
            a_channel = Channel('A', events, started=a_started, release=a_release)
            b_channel = Channel('B', events, after_send=b_done)
            c_channel = Channel('C', events, after_send=c_done)
            a_source = Source('A', a_channel, _author(), events)
            b_source = Source('B', b_channel, _author(), events)

            await bot.run_lock.acquire()  # une commande est déjà en cours
            a = asyncio.create_task(bot.run_batch(
                a_source, [['batch-1'], ['batch-2']]))
            await a_started.wait()        # A est admis, son accusé est retenu
            b = asyncio.create_task(bot.run_single(b_source, ['single']))
            await b_done.wait()           # B est admis après A
            c = asyncio.create_task(bot.execute(
                _interaction(c_channel, defer_done=c_done), ['slash']))
            await c_done.wait()           # C est admis après B
            self.assertEqual(events, [], 'une commande a démarré avant son tour')

            bot.run_lock.release()
            a_release.set()
            await asyncio.wait_for(asyncio.gather(a, b, c), 5)

            executed = [value for kind, value in events if kind == 'exec']
            self.assertEqual(executed, ['batch-1', 'batch-2', 'single', 'slash'])

        asyncio.run(scenario())

    def test_refused_ack_keeps_source_and_runs_nothing(self):
        for failure in ('forbidden', 'http'):
            with self.subTest(failure=failure):
                async def scenario():
                    events = self.events
                    events.clear()
                    channel = Channel('C', events, fail=failure)
                    source = Source('C', channel, _author(), events)
                    await bot.run_single(source, ['server', 'status'])
                    self.assertEqual(events, [], 'commande fantôme exécutée/supprimée')
                    self.assertFalse(bot.run_lock.locked())

                    # La place abandonnée ne doit pas bloquer la demande suivante.
                    ok_channel = Channel('D', events)
                    await bot.run_single(
                        Source('D', ok_channel, _author(), events), ['help'])
                    self.assertEqual([v for k, v in events if k == 'exec'], ['help'])

                asyncio.run(scenario())

    def test_cancelled_waiter_cannot_let_later_command_overtake_running_one(self):
        async def scenario():
            events = self.events
            a_started, a_release = asyncio.Event(), asyncio.Event()
            run_started, run_release = asyncio.Event(), asyncio.Event()
            a_channel = Channel('A', events, started=a_started, release=a_release)
            b_channel = Channel('B', events)
            c_channel = Channel('C', events)
            a_source = Source('A', a_channel, _author(), events)
            b_source = Source('B', b_channel, _author(), events)

            async def fake_run(args):
                events.append(('exec', args[0]))
                if args[0] == 'A':
                    run_started.set()
                    await run_release.wait()
                return 0, 'ok'

            bot.run_pzm = fake_run
            await bot.run_lock.acquire()
            a = asyncio.create_task(bot.run_single(a_source, ['A']))
            await a_started.wait()
            b = asyncio.create_task(bot.run_single(b_source, ['B']))
            await asyncio.sleep(0)        # B est admis et attend A
            c = asyncio.create_task(bot.execute(_interaction(c_channel), ['C']))
            await asyncio.sleep(0)        # C est admis et attend B

            b.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await b
            bot.run_lock.release()
            a_release.set()
            await asyncio.wait_for(run_started.wait(), 5)
            await asyncio.sleep(0.05)
            self.assertNotIn(('exec', 'C'), events,
                             'C a démarré avant la fin de A malgré B annulé')
            run_release.set()
            await asyncio.wait_for(asyncio.gather(a, c), 5)

            executed = [value for kind, value in events if kind == 'exec']
            self.assertEqual(executed, ['A', 'C'])
            self.assertFalse(bot.run_lock.locked())
            self.assertTrue(bot._queue_tail.done())

        asyncio.run(scenario())

    def test_cancelled_while_waiting_lock_before_start_keeps_source_and_releases_place(self):
        async def scenario():
            events = self.events
            await bot.run_lock.acquire()
            a_channel = Channel('A', events)
            a_source = Source('A', a_channel, _author(), events)
            a = asyncio.create_task(bot.run_single(a_source, ['A']))
            await asyncio.sleep(0)  # A a accusé et attend le verrou
            a.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await a
            self.assertEqual(events, [])
            self.assertTrue(bot.run_lock.locked())  # verrou initial toujours tenu
            bot.run_lock.release()

            b_channel = Channel('B', events)
            await asyncio.wait_for(
                bot.run_single(Source('B', b_channel, _author(), events), ['B']), 5)
            self.assertEqual([v for k, v in events if k == 'exec'], ['B'])
            self.assertFalse(bot.run_lock.locked())
            self.assertTrue(bot._queue_tail.done())

        asyncio.run(scenario())

    def test_cancelled_before_start_keeps_source_and_releases_place(self):
        async def scenario():
            events = self.events
            a_started, a_release = asyncio.Event(), asyncio.Event()
            a_channel = Channel('A', events, started=a_started, release=a_release)
            a_source = Source('A', a_channel, _author(), events)
            a = asyncio.create_task(bot.run_single(a_source, ['A']))
            await a_started.wait()
            a.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await a
            self.assertNotIn(('deleted', 'A'), events)
            self.assertFalse(bot.run_lock.locked())

            b_channel = Channel('B', events)
            await asyncio.wait_for(
                bot.run_single(Source('B', b_channel, _author(), events), ['B']), 5)
            self.assertEqual([v for k, v in events if k == 'exec'], ['B'])
            self.assertTrue(bot._queue_tail.done())

        asyncio.run(scenario())


if __name__ == '__main__':
    unittest.main()
