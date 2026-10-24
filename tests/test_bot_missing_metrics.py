"""Missing observations remain unknown through collection, embed and CSV."""
from contextlib import ExitStack
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_sec_markdown import bot, _serveur, _champ_serveur


class MissingMetrics(unittest.TestCase):
    def snapshot(self, text):
        with patch.object(bot, 'PROMETHEUS_URL', 'http://fixture.invalid'), \
             patch.object(bot.urllib.request, 'urlopen', return_value=io.BytesIO(text.encode())):
            return bot._prom_snapshot()

    def test_missing_network_series_are_unknown(self):
        snapshot = self.snapshot('performance{parameter="fps"} 100\n')
        for key in ('send_c', 'recv_c', 'send_b', 'recv_b'):
            self.assertIsNone(snapshot[key], key)
        self.assertEqual(snapshot['fps'], 10)

    def test_observed_zero_is_preserved_and_invalid_values_are_unknown(self):
        for value, expected in (('0', 0), ('invalid', None), ('NaN', None), ('+Inf', None)):
            with self.subTest(value=value):
                snapshot = self.snapshot('packet_send_bytes_count{client="a"} ' + value + '\n')
                self.assertEqual(snapshot['send_c'], expected)
                self.assertIsNone(snapshot['recv_c'])

    def test_missing_player_log_is_unknown_and_real_empty_session_is_zero(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(bot, 'PZ_LOGS_DIR', temporary):
            state = {}
            self.assertIsNone(bot._online_players(state))
            user = Path(temporary) / 'session_user.txt'
            user.write_text('')
            self.assertEqual(bot._online_players(state), 0)
            user.write_text('76561198000000000 "alice" fully connected (fixture)\n')
            self.assertEqual(bot._online_players(state), 1)
            with user.open('a') as output:
                output.write('76561198000000000 "alice" disconnected player (fixture)\n')
            self.assertEqual(bot._online_players(state), 0)
            user.unlink()
            self.assertIsNone(bot._online_players(state))

    def test_unreadable_player_log_is_unknown_then_replayed_on_recovery(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(bot, 'PZ_LOGS_DIR', temporary):
            user = Path(temporary) / 'session_user.txt'
            user.write_text('76561198000000000 "alice" fully connected (fixture)\n')
            state = {}
            self.assertEqual(bot._online_players(state), 1)
            with patch('builtins.open', side_effect=PermissionError):
                self.assertIsNone(bot._online_players(state))
            self.assertEqual(bot._online_players(state), 1)
            user.unlink()
            self.assertIsNone(bot._online_players(state))
            user.write_text('')
            self.assertEqual(bot._online_players(state), 0)

    def collect(self, state, snapshot=None, *, meminfo=None, netdev=None,
                now=None, prom_text=None):
        def fixture_open(path, *args, **kwargs):
            fixtures = {
                '/proc/meminfo': meminfo,
                '/proc/net/route': 'Iface Destination\nfixture0 00000000\n' if netdev else None,
                '/proc/net/dev': netdev,
                '/fixture.ini': 'MaxPacketsPerSecond=100\n',
            }
            if str(path) not in fixtures or fixtures[str(path)] is None:
                raise OSError('unavailable fixture: ' + str(path))
            return io.StringIO(fixtures[str(path)])

        with ExitStack() as stack:
            stack.enter_context(patch('builtins.open', side_effect=fixture_open))
            for name, value in {
                'jvm_status': {'pid': None, 'invocation': None, 'service_state': 'unknown'},
                '_service_memory': {}, '_percpu_stat': None, '_temps': {},
                '_gc_heap': None, '_recent_heapdump': None, '_online_players': None,
                '_server_ini_path': '/fixture.ini',
            }.items():
                stack.enter_context(patch.object(bot, name, return_value=value))
            if now is not None:
                stack.enter_context(patch.object(bot.time, 'monotonic', return_value=now))
            if prom_text is None:
                stack.enter_context(patch.object(bot, '_prom_snapshot', return_value=snapshot))
            else:
                stack.enter_context(patch.object(bot, 'PROMETHEUS_URL', 'http://fixture.invalid'))
                stack.enter_context(patch.object(bot.urllib.request, 'urlopen',
                                                return_value=io.BytesIO(prom_text.encode())))
            return bot.collect_stats(state)

    def test_machine_memory_missing_partial_zero_and_nominal(self):
        cases = (
            (None, '—', '— Go', '', '', False),
            ('MemTotal: 8388608 kB\n', '—', '— Go', '', '', False),
            ('MemAvailable: 4194304 kB\n', '—', '4.0 Go', '4096', '', False),
            ('MemAvailable: 0 kB\n', '—', '0.0 Go', '0', '', True),
            ('MemTotal: 8388608 kB\nMemAvailable: 0 kB\n', '**100%**', '0.0 Go', '0', '100.0', True),
            ('MemTotal: 8388608 kB\nMemAvailable: 8388608 kB\n', '**0%**', '8.0 Go', '8192', '0.0', False),
            ('MemTotal: 8388608 kB\nMemAvailable: 4194304 kB\n', '**50%**', '4.0 Go', '4096', '50.0', False),
        )
        for meminfo, used, available, csv_available, csv_used, warning in cases:
            with self.subTest(meminfo=meminfo):
                observed = self.collect({}, meminfo=meminfo)
                memory_alerts = [a for a in bot._status(observed)[1] if 'RAM système' in a]
                self.assertEqual(bool(memory_alerts), warning)
                field = next(f['value'] for f in bot._monitoring_embed(observed).fields
                             if f['name'] == '🖥️ RAM de la machine')
                self.assertIn(used + ' utilisée', field)
                self.assertIn(available, field)
                if not meminfo or 'MemTotal' not in meminfo:
                    self.assertTrue(field.endswith('/ —'), field)
                else:
                    self.assertTrue(field.endswith('/ 8.0'), field)
                row = dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))
                self.assertEqual(row['ram_avail_mb'], csv_available)
                self.assertEqual(row['ram_used_pct'], csv_used)

    def test_nic_proxy_has_no_ratio_to_client_cap_and_prometheus_keeps_its_ratio(self):
        def dev(packets):
            return f'fixture0: 0 {packets} 0 0 0 0 0 0 0 {packets} 0 0 0 0 0 0\n'

        state = {}
        self.collect(state, netdev=dev(0), now=1)
        observed = self.collect(state, netdev=dev(100), now=2)
        self.assertEqual(observed['net']['pps'], 200)
        text = _champ_serveur(bot._monitoring_embed(observed))
        self.assertIn('**200** paq/s (NIC proxy)', text)
        self.assertNotIn('%', text)
        row = dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))
        self.assertEqual(len(bot._csv_row(observed)), len(bot._CSV_HEADER))
        self.assertEqual(row['net_pps'], '200')
        self.assertEqual(row['max_pps'], '100')
        self.assertEqual(row['pps_pct'], '')
        self.assertEqual(row['recv_cap_pct'], '')

        for sent, received, percentage in ((0, 0, '0.0'), (10, 50, '50.0')):
            with self.subTest(sent=sent, received=received):
                state = {}
                self.collect(state, netdev=dev(0), now=1, prom_text=(
                    'packet_send_bytes_count 0\npacket_receive_bytes_count{client="alice"} 0\n'))
                observed = self.collect(state, netdev=dev(100), now=2, prom_text=(
                    f'packet_send_bytes_count {sent}\n'
                    f'packet_receive_bytes_count{{client="alice"}} {received}\n'))
                text = _champ_serveur(bot._monitoring_embed(observed))
                self.assertIn(f'**{sent}**↑/**{received}**↓ paq/s', text)
                self.assertIn(f'max **{float(percentage):.0f}%** du cap', text)
                self.assertNotIn('NIC', text)
                row = dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))
                self.assertEqual(row['recv_cap_pct'], percentage)
                self.assertEqual(row['pps_pct'], '')

    def test_missing_counters_never_become_rates_in_embed_or_csv(self):
        state = {}
        known = self.snapshot('packet_send_bytes_count 0\npacket_receive_bytes_count 0\npacket_send_bytes_sum 0\npacket_receive_bytes_sum 0\n')
        missing = self.snapshot('performance{parameter="fps"} 100\n')
        self.collect(state, known)
        observed = self.collect(state, missing)
        self.assertIsNone(observed['game_net'])
        self.assertIsNone(self.collect(state, known)['game_net'])
        observed = self.collect(state, known)
        self.assertEqual(observed['game_net']['pps_sent'], 0)
        self.assertEqual(observed['game_net']['pps_recv'], 0)
        absent = self.collect(state, missing)
        view = _serveur('fixture')
        view.update(absent)
        self.assertNotIn('paq/s', _champ_serveur(bot._monitoring_embed(view)))
        row = dict(zip(bot._CSV_HEADER, bot._csv_row(absent)))
        self.assertEqual(row['game_pps_sent'], '')
        self.assertEqual(row['game_pps_recv'], '')
        self.assertEqual(row['players'], '')

    def test_partial_network_metrics_render_without_inventing_other_direction(self):
        state = {}
        self.collect(state, self.snapshot('packet_send_bytes_count 5\n'))
        observed = self.collect(state, self.snapshot('packet_send_bytes_count 5\n'))
        self.assertEqual(observed['game_net']['pps_sent'], 0)
        self.assertIsNone(observed['game_net']['pps_recv'])
        view = _serveur('fixture')
        view.update(observed)
        text = _champ_serveur(bot._monitoring_embed(view))
        self.assertIn('**0**↑', text)
        self.assertIn('—', text)
        row = dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))
        self.assertEqual(row['game_pps_sent'], '0')
        self.assertEqual(row['game_pps_recv'], '')


if __name__ == '__main__':
    unittest.main()
