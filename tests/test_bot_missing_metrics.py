"""Missing observations remain unknown through collection, embed and CSV."""
from contextlib import ExitStack
import io
import json
import os
import subprocess
import time
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_sec_markdown import bot, _serveur, _champ_serveur
import service_process as sp


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
                now=None, prom_text=None, gc_log=None, invocation=None):
        real_open = open

        def fixture_open(path, *args, **kwargs):
            fixtures = {
                '/proc/meminfo': meminfo,
                '/proc/net/route': 'Iface Destination\nfixture0 00000000\n' if netdev else None,
                '/proc/net/dev': netdev,
                '/fixture.ini': 'MaxPacketsPerSecond=100\n',
            }
            if gc_log is not None and str(path) == str(gc_log):
                return real_open(path, *args, **kwargs)
            if str(path) not in fixtures or fixtures[str(path)] is None:
                raise OSError('unavailable fixture: ' + str(path))
            return io.StringIO(fixtures[str(path)])

        with ExitStack() as stack:
            stack.enter_context(patch('builtins.open', side_effect=fixture_open))
            for name, value in {
                'jvm_status': {'pid': None, 'invocation': invocation, 'service_state': 'unknown'},
                '_service_memory': {}, '_percpu_stat': None, '_temps': {},
                '_gc_heap': None, '_recent_heapdump': None, '_online_players': None,
                '_server_ini_path': '/fixture.ini',
            }.items():
                if name != '_gc_heap' or gc_log is None:
                    stack.enter_context(patch.object(bot, name, return_value=value))
            if gc_log is not None:
                stack.enter_context(patch.object(bot, 'GC_LOG_PATH', str(gc_log)))
            if now is not None:
                stack.enter_context(patch.object(bot.time, 'monotonic', return_value=now))
            if prom_text is None:
                stack.enter_context(patch.object(bot, '_prom_snapshot', return_value=snapshot))
            else:
                stack.enter_context(patch.object(bot, 'PROMETHEUS_URL', 'http://fixture.invalid'))
                stack.enter_context(patch.object(bot.urllib.request, 'urlopen',
                                                return_value=io.BytesIO(prom_text.encode())))
            return bot.collect_stats(state)

    def test_prometheus_restart_waits_for_comparable_boot_but_nic_remains_host_wide(self):
        def dev(n):return f'fixture0: 0 {n} 0 0 0 0 0 0 0 {n} 0 0 0 0 0 0\n'
        def prom(n):return (f'packet_send_bytes_count {n}\npacket_send_bytes_sum {n*1024}\n'
                           f'packet_receive_bytes_count{{client="alice"}} {n}\n'
                           f'packet_receive_bytes_sum {n*1024}\n')
        state={}
        first=self.collect(state,invocation='a'*32,now=100,netdev=dev(100),prom_text=prom(1000))
        self.assertIsNone(first['game_net'])
        restarted=self.collect(state,invocation='b'*32,now=110,netdev=dev(200),prom_text=prom(200))
        self.assertIsNone(restarted['game_net'])
        row=dict(zip(bot._CSV_HEADER,bot._csv_row(restarted)))
        self.assertEqual(row['game_pps_sent'],'');self.assertEqual(row['game_pps_recv'],'')
        self.assertEqual(restarted['net']['pps'],20)
        current=self.collect(state,invocation='b'*32,now=120,netdev=dev(260),prom_text=prom(240))
        self.assertEqual(current['game_net']['pps_sent'],4)
        self.assertEqual(current['game_net']['pps_recv'],4)
        self.assertEqual(current['game_net']['recv_pps_max_client'],4)
        self.assertEqual(current['net']['pps'],12)

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

    def test_heap_capacity_is_observed_or_unknown_without_ram_heuristic(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'gc.log'
            for ram in (32130864, 64 * 1048576):
                for configured in ('', '24'):
                    with self.subTest(ram=ram, configured=configured):
                        log.write_text('[gc] GC(1) Major Collection (Timer) 9000M(55%)->8192M(50%) 1.0s\n')
                        with patch.object(bot, 'GC_LOG_PATH', str(log)), \
                             patch.dict(bot.os.environ, {'PZ_XMX_GB': configured}):
                            observed = self.collect({}, meminfo=f'MemTotal: {ram} kB\n', gc_log=log)
                            self.assertIsNone(bot._xmx_gb())
                            view = _serveur('fixture')
                            view.update(observed)
                            field = next(f['value'] for f in bot._monitoring_embed(view).fields
                                         if f['name'] == '🧠 RAM de PZ')
                            self.assertIn('8.0 / — Go', field)
                            self.assertIn('**50%**', field)
                            row = dict(zip(bot._CSV_HEADER, bot._csv_row(view)))
                            self.assertEqual(row['heap_pct'], '50')
                            self.assertEqual(row['heap_used_mb'], '8192')
            for capacity in ('16384M', '16G'):
                with self.subTest(capacity=capacity), patch.object(bot, 'GC_LOG_PATH', str(log)):
                    log.write_text('Max Capacity: ' + capacity + '\nSoft Max Capacity: 8192M\n')
                    self.assertEqual(bot._xmx_gb(), 16)
                    rotated = log.with_suffix('.log.1')
                    log.rename(rotated)
                    log.write_text('[gc] GC(2) Minor Collection (Timer) 9000M(55%)->8192M(50%) 1.0s\n')
                    self.assertIsNone(bot._xmx_gb(), 'rotated header must not become a current observation')

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


class PlayerSessionCounter(unittest.TestCase):

    def test_slow_metric_preserves_current_session_players(self):
        with tempfile.TemporaryDirectory() as temporary:
            user = Path(temporary) / 'sessionB_user.txt'
            user.write_text('76561198000000001 "bob" fully connected (fixture)\n')
            born = int(subprocess.check_output(
                ['stat', '-c', '%W', '--', str(user)], text=True))
            self.assertGreater(born, 0)
            # Keep birth strictly after boot, outside the ambiguous birth second.
            boot = born - 1.5
            clock = {'now': born + 0.5}
            previous, rows = {}, []
            with ExitStack() as stack:
                stack.enter_context(patch.object(bot, 'PZ_LOGS_DIR', temporary))
                stack.enter_context(patch.object(bot, 'jvm_status', side_effect=lambda _: dict(
                    pid=123, service_state='active', invocation='b' * 32)))
                stack.enter_context(patch.object(bot, '_proc_uptime_seconds',
                                                side_effect=lambda _: clock['now'] - boot))
                stack.enter_context(patch.object(bot.time, 'time',
                                                side_effect=lambda: clock['now']))
                for name, value in {
                    '_meminfo': {}, '_proc_status': {}, '_proc_cpu_jiffies': None,
                    '_service_memory': {}, '_percpu_stat': None, '_temps': {},
                    '_gc_heap': None, '_recent_heapdump': None, '_default_iface': None,
                    '_prom_snapshot': None, '_server_ini_path': '',
                }.items():
                    stack.enter_context(patch.object(bot, name, return_value=value))

                def collect(stage):
                    observed = bot.collect_stats(previous)
                    rows.append(dict(
                        stage=stage, players=observed['players'],
                        embed=_champ_serveur(bot._monitoring_embed(observed)),
                        csv_players=dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))['players'],
                    ))

                def slow_metric():
                    clock['now'] += 3  # Controlled metric delay, no real sleep.
                    return None

                collect('before_delay')
                with patch.object(bot, '_recent_heapdump', side_effect=slow_metric):
                    collect('three_second_metric')
                collect('after_delay')
            print(json.dumps(rows, ensure_ascii=False, indent=2), flush=True)
            for row in rows:
                with self.subTest(stage=row['stage']):
                    self.assertEqual(row['players'], 1)
                    self.assertEqual(row['csv_players'], '1')
                    self.assertIn('**1** joueur', row['embed'])

    def test_old_session_is_replayed_after_proven_stop_and_new_boot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            logs = root / 'logs'
            logs.mkdir()
            old = logs / 'sessionA_user.txt'
            old.write_text('76561198000000000 "alice" fully connected (fixture)\n')
            os.utime(old, (time.time() - 1800,) * 2)
            bins = root / 'bin'
            bins.mkdir()
            state = root / 'bus.json'
            proc = root / 'proc'
            proc.mkdir()
            cg = root / 'cgroup'
            cg.mkdir()
            group = '/user.slice/fixture/pz.slice/zomboid.service'
            leaf = cg / group.lstrip('/')
            leaf.mkdir(parents=True)
            for pid in (123, 456):
                p = proc / str(pid)
                p.mkdir()
                (p / 'status').write_text('Uid: ' + ' '.join([str(os.getuid())] * 4) + '\nVmRSS: 100 kB\n')
                (p / 'cgroup').write_text('0::' + group + '\n')
                (p / 'comm').write_text('java\n')
                (p / 'cmdline').write_bytes(b'java\x00zombie.network.GameServer\x00')
            command = bins / 'systemctl'
            command.write_text('#!/usr/bin/python3\nimport os,json\nfrom pathlib import Path\ns=json.loads(Path(os.environ["PLAYER_STATE"]).read_text())\nfor k,v in s.items():print(k+"="+str(v))\n')
            command.chmod(0o700)
            rows = []
            previous = {}
            boot_b = time.time()
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, PATH=str(bins) + ':' + os.environ['PATH'], PLAYER_STATE=str(state)))
                stack.enter_context(patch.object(bot, 'PZ_LOGS_DIR', str(logs)))
                stack.enter_context(patch.object(bot, 'PZ_SERVICE_NAME', 'zomboid.service'))
                stack.enter_context(patch.object(bot, 'jvm_status', side_effect=lambda unit: sp.jvm_status(unit, cgroup_root=cg, proc_root=proc)))
                stack.enter_context(patch.object(bot, '_proc_uptime_seconds', side_effect=lambda pid: 3600 if pid == 123 else time.time() - boot_b))
                for name, value in {
                    '_meminfo': {}, '_proc_status': {}, '_proc_cpu_jiffies': None,
                    '_service_memory': {}, '_percpu_stat': None, '_temps': {},
                    '_gc_heap': None, '_recent_heapdump': None, '_default_iface': None,
                    '_prom_snapshot': None, '_server_ini_path': '',
                }.items():
                    stack.enter_context(patch.object(bot, name, return_value=value))

                def collect(label, active, iid, pid, prev):
                    fields = dict(ActiveState=active, MainPID=str(pid or 0), InvocationID=iid or '', ControlGroup=group if pid else '')
                    state.write_text(json.dumps(fields))
                    (leaf / 'cgroup.procs').write_text(str(pid) + '\n' if pid else '')
                    observed = bot.collect_stats(prev)
                    row = dict(
                        label=label, service_state=observed['service_state'],
                        pid=observed['pid'], invocation=observed['invocation'],
                        uptime=observed['uptime'], players=observed['players'],
                        embed=next(f['value'] for f in bot._monitoring_embed(observed).fields
                                   if f['name'] == 'Serveur'),
                        csv_players=dict(zip(bot._CSV_HEADER, bot._csv_row(observed)))['players'],
                        online=sorted(prev.get('online', set())),
                    )
                    rows.append(row)
                    return row
                self.assertEqual(collect('bot_attaches_mid_A', 'active', 'a' * 32, 123, previous)['players'], 1)
                stopped = collect('proven_inactive', 'inactive', None, None, previous)
                starting = collect('activating_B', 'activating', 'b' * 32, None, previous)
                os.utime(old, None)  # Touching an old file does not establish a new session.
                resumed = collect('active_B_without_its_log', 'active', 'b' * 32, 456, previous)
                self.assertIsNone(collect('fresh_bot_B_without_log', 'active', 'b' * 32, 456, {})['players'])
                cold = collect('fresh_bot_proven_inactive', 'inactive', None, None, {})
                self.assertEqual(stopped['service_state'], 'inactive')
                self.assertIsNone(stopped['pid'])
                self.assertEqual(starting['service_state'], 'activating')
                self.assertEqual(resumed['invocation'], 'b' * 32)
                for row in (stopped, cold):
                    self.assertEqual(row['players'], 0)
                    self.assertEqual(row['csv_players'], '0')
                    self.assertIn('**0** joueurs', row['embed'])
                for row in (starting, resumed):
                    self.assertIsNone(row['players'])
                    self.assertEqual(row['csv_players'], '')
                    self.assertNotIn('👥', row['embed'])
                # GNU stat reports whole seconds; create B beyond the boot second.
                time.sleep(1.1)
                current = logs / 'sessionB_user.txt'
                current.write_text('76561198000000001 "bob" fully connected (fixture)\n')
                new = collect('new_B_log_nominal_rotation', 'active', 'b' * 32, 456, previous)
                self.assertEqual(new['online'], ['76561198000000001'])
                self.assertEqual(new['players'], 1)
                self.assertEqual(collect('bot_attaches_mid_B', 'active', 'b' * 32, 456, {})['players'], 1)
                with patch.object(bot, '_proc_uptime_seconds', return_value=None):
                    self.assertIsNone(collect('missing_process_age', 'active', 'b' * 32, 456, previous)['players'])
                with patch.object(bot.subprocess, 'check_output', side_effect=OSError('birth time unavailable')):
                    self.assertIsNone(collect('missing_birth_time', 'active', 'b' * 32, 456, previous)['players'])
                with patch.object(bot.subprocess, 'check_output', return_value='0'):
                    self.assertIsNone(collect('unsupported_birth_time', 'active', 'b' * 32, 456, previous)['players'])
                with patch.object(bot.subprocess, 'check_output', return_value=str(int(time.time()) + 3600)):
                    self.assertIsNone(collect('future_birth_time', 'active', 'b' * 32, 456, previous)['players'])
                with patch.object(bot.subprocess, 'check_output', side_effect=subprocess.TimeoutExpired('stat', 2)):
                    self.assertIsNone(collect('birth_time_timeout', 'active', 'b' * 32, 456, previous)['players'])
                self.assertEqual(collect('birth_time_recovers', 'active', 'b' * 32, 456, previous)['players'], 1)
                with patch('builtins.open', side_effect=PermissionError):
                    self.assertIsNone(collect('unreadable_log', 'active', 'b' * 32, 456, previous)['players'])
                self.assertEqual(collect('readable_again', 'active', 'b' * 32, 456, previous)['players'], 1)
                with current.open('a') as output:
                    output.write('76561198000000001 "bob" disconnected player (fixture)\n')
                self.assertEqual(collect('disconnect_B', 'active', 'b' * 32, 456, previous)['players'], 0)
                with current.open('a') as output:
                    output.write('76561198000000001 "bob" fully connected (fixture)\n')
                self.assertEqual(collect('reconnect_B', 'active', 'b' * 32, 456, previous)['players'], 1)
                self.assertIsNone(collect('unknown_bus', 'invalid', None, None, previous)['players'])
                self.assertEqual(collect('bus_recovers_same_B', 'active', 'b' * 32, 456, previous)['players'], 1)
            print(json.dumps(rows, ensure_ascii=False, indent=2), flush=True)

if __name__ == '__main__':
    unittest.main()
