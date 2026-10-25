"""Real command execution and bounded Discord sends, with local transport doubles."""
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from test_sec_markdown import bot


class Transport:
    def __init__(self, *, expired=False, deny_files=False):
        self.id = 1
        self.expired, self.deny_files = expired, deny_files
        self.contents, self.files, self.edits = [], [], []
        self.deleted = False

    def bounded(self, content):
        assert len(content.encode('utf-16-le')) // 2 <= 2000, f'content too long: {len(content)}'
        assert '\0' not in content
        if content.startswith('```\n'):
            assert content.endswith('\n```')
            assert content.count('```') == 2

    async def send(self, content, **kwargs):
        self.bounded(content)
        if self.expired:
            raise bot.discord.HTTPException('expired interaction')
        if 'file' in kwargs:
            if self.deny_files:
                raise bot.discord.Forbidden('attachments forbidden')
            self.files.append(kwargs['file'].fp.getvalue().decode())
        self.contents.append(content)
        return self

    async def edit(self, *, content):
        self.bounded(content)
        self.edits.append(content)

    async def delete(self):
        self.deleted = True


class Delivery(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        quiet = patch.object(bot.log, 'info')
        quiet.start()
        self.addCleanup(quiet.stop)
        self.calls = self.root / 'calls.jsonl'
        self.output = self.root / 'output.txt'
        self.output.write_text('complete-output-sentinel\n')
        fake = self.root / 'pzm'
        fake.write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                        f'with Path({str(self.calls)!r}).open("a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                        f'sys.stdout.write(Path({str(self.output)!r}).read_text())\n')
        fake.chmod(0o700)
        for name, value in {'PZM': str(fake), 'PZ_MANAGER_DIR': str(self.root),
                            'ALLOWED_CHANNELS': {1}, 'ROLE_IDS': {2},
                            'run_lock': asyncio.Lock()}.items():
            mocking = patch.object(bot, name, value)
            mocking.start()
            self.addCleanup(mocking.stop)
        self.author = SimpleNamespace(mention='<@123>', roles=[SimpleNamespace(id=2)])
        self.args = ['server', 'restart', 'now', '--reason', '``````' + '😀`*' * 1100 + '\nend']

    def assert_complete(self, channel):
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()], [self.args])
        self.assertTrue(channel.files)
        self.assertIn(bot.pzm_label(self.args), channel.files[-1])
        self.assertIn('complete-output-sentinel', channel.files[-1])

    def test_execute_expired_followup_delivers_complete_command_and_output_once(self):
        channel = Transport()
        async def defer(): pass
        interaction = SimpleNamespace(channel_id=1, user=self.author, channel=channel,
                                      response=SimpleNamespace(defer=defer),
                                      followup=Transport(expired=True))
        asyncio.run(bot.execute(interaction, self.args))
        self.assert_complete(channel)

    def test_pasted_queued_ack_and_update_are_bounded_and_command_runs_once(self):
        channel = Transport()
        source = Transport()
        source.channel, source.author = channel, self.author
        async def queued():
            await bot.run_lock.acquire()
            task = asyncio.create_task(bot.run_single(source, self.args))
            await asyncio.sleep(0)
            bot.run_lock.release()
            await task
        asyncio.run(queued())
        self.assertTrue(source.deleted)
        self.assertTrue(channel.edits)
        self.assert_complete(channel)

    def test_long_backtick_runs_in_real_stdout_survive_attachment_denied(self):
        self.args = ['help']
        for count in (6, 33, 1800):
            with self.subTest(count=count):
                self.calls.unlink(missing_ok=True)
                prefix = '😀' * 895 if count > 6 else ''
                output = prefix + '`' * count + '\ncomplete-output-sentinel\n'
                self.output.write_text(output)
                channel = Transport(deny_files=True)
                async def defer(): pass
                interaction = SimpleNamespace(channel_id=1, user=self.author, channel=channel,
                                              response=SimpleNamespace(defer=defer), followup=channel)
                asyncio.run(bot.execute(interaction, self.args))
                self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()], [self.args])
                restored = ''.join(content[4:-4] for content in channel.contents[1:])
                self.assertEqual(restored.replace('`\u200b', '`'), output)

    def test_attachment_bytes_keep_raw_long_label_and_backtick_output(self):
        output = 'raw-stdout\n' + '`' * 1200 + '😀\n'
        self.output.write_text(output)
        channel = Transport()
        async def defer(): pass
        interaction = SimpleNamespace(channel_id=1, user=self.author, channel=channel,
                                      response=SimpleNamespace(defer=defer), followup=channel)
        asyncio.run(bot.execute(interaction, self.args))
        expected = bot._result_header(bot.pzm_label(self.args), 0) + '\n\n' + output
        self.assertEqual(channel.files, [expected])
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()], [self.args])

    def test_attachment_denied_chunks_full_header_output_and_closes_fences(self):
        channel = Transport(deny_files=True)
        header = '✅ ' + ('😀' * 2100) + '\0\nheader-end'
        output = 'output-start\n' + '```\n😀' * 900 + '\noutput-end\n'
        asyncio.run(bot.deliver(channel.send, header, output))
        self.assertIn('header-end', ''.join(channel.contents))
        self.assertIn('output-end', ''.join(channel.contents))
        restored = ''.join(content[4:-4] for content in channel.contents[1:])
        restored = restored.replace('`\u200b', '`').replace('\\0', '\0')
        self.assertEqual(restored, header + '\n\n' + output)
        for content in channel.contents[1:]:
            self.assertTrue(content.startswith('```\n'))
            self.assertTrue(content.endswith('\n```'))


if __name__ == '__main__': unittest.main()
