"""Missing observations remain unknown through collection, embed and CSV."""
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

    def collect(self, state, snapshot):
        with patch.object(bot, 'jvm_status', return_value={'pid': None, 'invocation':None, 'service_state':'unknown'}), \
             patch.object(bot, '_meminfo', return_value={}), \
             patch.object(bot, '_service_memory', return_value={}), \
             patch.object(bot, '_percpu_stat', return_value=None), \
             patch.object(bot, '_temps', return_value={}), \
             patch.object(bot, '_gc_heap', return_value=None), \
             patch.object(bot, '_recent_heapdump', return_value=None), \
             patch.object(bot, '_online_players', return_value=None), \
             patch.object(bot, '_default_iface', return_value=None), \
             patch.object(bot, '_server_ini_path', return_value=''), \
             patch.object(bot, '_prom_snapshot', return_value=snapshot):
            return bot.collect_stats(state)

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
