#!/usr/bin/env python3
"""Local restore preserves other terrain/global state and recovers failed writes."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import signal
import struct
import zlib
import unittest
from unittest.mock import patch
from argparse import Namespace

ROOT = Path(os.environ.get('PZ_TEST_ROOT', Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('zone', ROOT / 'data/scripts/lib/restore_zone.py')
zone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zone)


def chunk(payload):
    return b'\0' + struct.pack('>iiq', 249, len(payload) + 17, zlib.crc32(payload)) + payload


class ZoneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.live = self.root / 'live/Saves/Multiplayer/world'
        self.source = self.root / 'backup/Saves/Multiplayer/world'
        for root in (self.live, self.source):
            (root / 'map/1').mkdir(parents=True)
            for rel, data in {'map_ver.bin': b'version', 'WorldDictionary.bin': b'dictionary',
                              'map/1/1.bin': b'old', 'map/1/2.bin': b'outside',
                              'players.db': b'player', 'vehicles.db': b'vehicle',
                              'metagrid/metacell_0_0.bin': b'cell'}.items():
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_bytes(chunk(data) if rel.startswith('map/') else data)
        (self.live / 'map/1/1.bin').write_bytes(chunk(b'broken'))
        (self.live / 'isoregiondata').mkdir()
        (self.live / 'isoregiondata/datachunk_1_1.bin').write_bytes(b'stale')
        self.args = Namespace(live_root=str(self.root / 'live'), backup_root=str(self.root),
                              recovery_root=str(self.root / 'OLD'), backup='backup',
                              x1=15, y1=15, x2=8, y2=8, save=None, apply=True)

    def tearDown(self):
        self.temp.cleanup()

    def state(self):
        return {str(p.relative_to(self.live)): p.read_bytes() for p in self.live.rglob('*') if p.is_file()}

    def test_apply_preserves_outside_and_globals_and_breaks_hardlinks(self):
        linked = self.root / 'linked-snapshot'
        os.link(self.live / 'map/1/1.bin', linked)
        before = self.state()
        zone.restore(self.args)
        after = self.state()
        self.assertEqual(after.pop('map/1/1.bin'), chunk(b'old'))
        before.pop('map/1/1.bin'); before.pop('isoregiondata/datachunk_1_1.bin')
        self.assertEqual(after, before)
        self.assertEqual(linked.read_bytes(), chunk(b'broken'))
        recovery = next((self.root / 'OLD').glob('zone-*'))
        self.assertEqual((recovery / 'before/Saves/Multiplayer/world/map/1/1.bin').read_bytes(), chunk(b'broken'))
        self.assertEqual((self.source / 'map/1/1.bin').read_bytes(), chunk(b'old'))

    def test_current_b42_without_map_ver_and_missing_live_terrain(self):
        (self.live / 'map_ver.bin').unlink()
        (self.source / 'map_ver.bin').unlink()
        (self.live / 'map/1/1.bin').unlink()
        zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), chunk(b'old'))

    def test_corrupt_live_checksum_can_be_recovered(self):
        data = (self.live / 'map/1/1.bin').read_bytes()
        (self.live / 'map/1/1.bin').write_bytes(data[:-1] + b'!')
        zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), chunk(b'old'))

    def test_source_chunk_integrity_is_required(self):
        for data in (b'bad', chunk(b'old')[:-1], chunk(b'old')[:-1] + b'!',
                     b'\0' + struct.pack('>i', 250) + chunk(b'old')[5:]):
            (self.source / 'map/1/1.bin').write_bytes(data)
            before = self.state()
            with self.assertRaises(ValueError): zone.restore(self.args)
            self.assertEqual(self.state(), before)
            self.assertFalse((self.root / 'OLD').exists())

    def test_preview_does_not_write(self):
        self.args.apply = False
        before = self.state()
        zone.restore(self.args)
        self.assertEqual(self.state(), before)
        self.assertFalse((self.root / 'OLD').exists())

    def test_failures_before_write(self):
        for kind in ('missing', 'version', 'dictionary', 'link', 'ambiguous', 'huge', 'negative', 'traversal'):
            with self.subTest(kind=kind):
                self.tearDown()
                self.setUp()
                before = self.state()
                if kind == 'missing': (self.source / 'map/1/1.bin').unlink()
                if kind == 'version': (self.source / 'map_ver.bin').write_bytes(b'other')
                if kind == 'dictionary': (self.source / 'WorldDictionary.bin').write_bytes(b'other')
                if kind == 'link':
                    (self.source / 'map/1/1.bin').unlink()
                    (self.source / 'map/1/1.bin').symlink_to(self.live / 'map/1/1.bin')
                if kind == 'ambiguous': (self.live.parent / 'other').mkdir()
                if kind == 'huge': self.args.x2 = self.args.y2 = 999999
                if kind == 'negative': self.args.x1 = -1
                if kind == 'traversal': self.args.save = '../world'
                with self.assertRaises((ValueError, OSError)): zone.restore(self.args)
                self.assertEqual(self.state(), before)
                self.assertFalse((self.root / 'OLD').exists())
                self.tearDown()

    def test_write_error_reverts_already_changed_files(self):
        before = self.state()
        real = zone.replace_file
        calls = 0
        def fail(source, dest):
            nonlocal calls
            calls += 1
            if calls == 1:
                real(source, dest)
                raise OSError('simulated failure after replacement')
            return real(source, dest)
        with patch.object(zone, 'replace_file', side_effect=fail):
            with self.assertRaises(OSError): zone.restore(self.args)
        self.assertEqual(self.state(), before)

    def test_exact_tiles_across_chunk_boundary(self):
        from test_terrain_tiles import fixture, fixture_index, FixtureIndexer, tiles
        for root, label in ((self.live, 'live'), (self.source, 'backup')):
            for x in (0, 1):
                path = root / f'map/{x}/1.bin'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(fixture(label))
        self.args.x1 = 7; self.args.x2 = 8
        self.args.y1 = self.args.y2 = 8
        (self.source / 'isoregiondata').mkdir()
        (self.source / 'isoregiondata/datachunk_1_1.bin').write_bytes(b'old whole chunk cache')
        with patch.object(tiles, 'NativeIndexer', FixtureIndexer):
            zone.restore(self.args)
        for x, selected in ((0, 56), (1, 0)):
            data = (self.live / f'map/{x}/1.bin').read_bytes()
            columns = tiles.checked_columns(data, fixture_index(data))
            for i, column in enumerate(columns):
                self.assertIn((b'backup' if i == selected else b'live') + b':tile=', column)
        self.assertFalse((self.live / 'isoregiondata/datachunk_1_1.bin').exists())
        self.assertEqual((self.live / 'map/1/2.bin').read_bytes(), chunk(b'outside'))

    def test_partial_chunk_missing_or_corrupt_live_is_refused(self):
        self.args.x1 = self.args.x2 = self.args.y1 = self.args.y2 = 8
        path = self.live / 'map/1/1.bin'
        for value in (None, b'broken', chunk(b'broken')[:-1]+b'!'):
            if value is None: path.unlink(missing_ok=True)
            else: path.write_bytes(value)
            before = self.state()
            with self.assertRaises(ValueError): zone.restore(self.args)
            self.assertEqual(self.state(), before)
            self.assertFalse((self.root / 'OLD').exists())

    def test_partial_native_refusal_before_any_world_write(self):
        self.args.x1 = self.args.x2 = self.args.y1 = self.args.y2 = 8
        before = self.state()
        with patch.object(zone, 'prepare_partial', side_effect=ValueError('unsupported native record')):
            with self.assertRaises(ValueError): zone.restore(self.args)
        self.assertEqual(self.state(), before)

    def test_partial_restore_write_failure_recovers_both_chunks(self):
        from test_terrain_tiles import fixture, FixtureIndexer, tiles
        for root, label in ((self.live, 'live'), (self.source, 'backup')):
            for x in (0, 1):
                path = root / f'map/{x}/1.bin'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(fixture(label))
        self.args.x1 = 7; self.args.x2 = 8; self.args.y1 = self.args.y2 = 8
        before = self.state()
        real = zone.replace_file
        calls = 0
        def fail(source, dest):
            nonlocal calls
            calls += 1
            real(source, dest)
            if calls == 2: raise OSError('failure after second chunk replacement')
        with patch.object(tiles, 'NativeIndexer', FixtureIndexer), patch.object(zone, 'replace_file', side_effect=fail):
            with self.assertRaises(OSError): zone.restore(self.args)
        self.assertEqual(self.state(), before)

    def test_staging_failure_keeps_world_intact(self):
        before = self.state()
        with patch.object(zone.shutil, 'copy2', side_effect=OSError('disk full')):
            with self.assertRaises(OSError): zone.restore(self.args)
        self.assertEqual(self.state(), before)

    def test_helper_rejects_abbreviated_apply(self):
        for option in ('--app', '--appl', '--a'):
            before = self.state()
            result = subprocess.run(['python3', str(ROOT / 'data/scripts/lib/restore_zone.py'),
                                     '--live-root', self.args.live_root, '--backup-root', self.args.backup_root,
                                     '--recovery-root', self.args.recovery_root,
                                     'backup', '8', '8', '15', '15', option], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.state(), before)
            self.assertFalse((self.root / 'OLD').exists())

    def test_repeated_signals_do_not_interrupt_recovery(self):
        before = self.state()
        worker = self.root / 'worker.py'
        applying = self.root / 'applying'
        recovering = self.root / 'recovering'
        worker.write_text(
            'import importlib.util, sys, time\n'
            'from pathlib import Path\n'
            f'spec = importlib.util.spec_from_file_location("zone", {str(ROOT / "data/scripts/lib/restore_zone.py")!r})\n'
            'zone = importlib.util.module_from_spec(spec); spec.loader.exec_module(zone)\n'
            'original = zone.replace_file\n'
            'calls = 0\n'
            'def slow(source, destination):\n'
            '    global calls\n'
            '    calls += 1\n'
            '    original(source, destination)\n'
            '    if calls == 1:\n'
            f'        Path({str(applying)!r}).touch()\n'
            '        time.sleep(10)\n'
            '    else:\n'
            f'        Path({str(recovering)!r}).touch()\n'
            '        time.sleep(0.5)\n'
            'zone.replace_file = slow\n'
            'zone.main()\n')
        child = subprocess.Popen(['python3', str(worker), '--live-root', self.args.live_root,
                                  '--backup-root', self.args.backup_root, '--recovery-root', self.args.recovery_root,
                                  'backup', '8', '8', '15', '15', '--apply'],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def wait_for(path):
            deadline = time.monotonic() + 3
            while not path.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(path.exists())
        try:
            wait_for(applying)
            self.assertNotEqual(self.state(), before)
            child.send_signal(signal.SIGTERM)
            wait_for(recovering)
            child.send_signal(signal.SIGTERM)
            child.send_signal(signal.SIGINT)
            child.communicate(timeout=3)
            self.assertNotEqual(child.returncode, 0)
            self.assertEqual(self.state(), before)
            import json
            manifest = next((self.root / 'OLD').glob('zone-*/manifest.json'))
            self.assertEqual(json.loads(manifest.read_text())['status'], 'reverted')
        finally:
            if child.poll() is None: child.kill(); child.communicate()

    def test_shell_state_guard_and_world_lock(self):
        # Copy the production shell + lock/state libs into a private harness.
        fixture = self.root / 'harness'
        lib = fixture / 'data/scripts/lib'; lib.mkdir(parents=True)
        scripts = fixture / 'data/scripts/backup'; scripts.mkdir()
        shutil.copy2(ROOT / 'data/scripts/backup/restoreZone.sh', scripts)
        for name in ('world_lock.sh', 'server_state.sh'):
            shutil.copy2(ROOT / 'data/scripts/lib' / name, lib)
        (lib / 'restore_zone.py').write_text('import os\nopen(os.environ["MARK"], "w").write("ran")\n')
        (lib / 'common.sh').write_text('source "${SCRIPT_DIR}/../lib/world_lock.sh"\nsource "${SCRIPT_DIR}/../lib/server_state.sh"\nsource_env() { :; }\ndie() { echo \"$*\" >&2; exit 1; }\n')
        bin_dir = fixture / 'bin'; bin_dir.mkdir()
        systemctl = bin_dir / 'systemctl'
        systemctl.write_text('#!/bin/bash\n[[ "$STATE" != error ]] || exit 1\necho "ActiveState=$STATE"\n')
        systemctl.chmod(0o755)
        runtime = fixture / 'runtime'; runtime.mkdir()
        mark = fixture / 'mark'
        env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                   XDG_RUNTIME_DIR=str(runtime), PZ_SOURCE_DIR='live', BACKUP_DIR='backups',
                   PZ_HOME=str(fixture), MARK=str(mark), PZ_WORLD_LOCK_DEPTH='0', PZ_WORLD_LOCK_FD='')
        for state in ('active', 'error', 'failed', 'activating', 'unknown', 'inactive'):
            result = subprocess.run(['bash', str(scripts / 'restoreZone.sh'), 'backup', '8', '8', '15', '15', '--apply'],
                                    env=dict(env, STATE=state), capture_output=True)
            self.assertEqual(result.returncode == 0, state == 'inactive', result.stderr)
            self.assertEqual(mark.exists(), state == 'inactive')
            mark.unlink(missing_ok=True)
        # Abbreviations and overrides cannot bypass the stopped-server check.
        for option in ('--app', '--appl', '--a', '--live-root', '--backup-root', '--recovery-root'):
            result = subprocess.run(['bash', str(scripts / 'restoreZone.sh'), 'backup', '8', '8', '15', '15', option],
                                    env=dict(env, STATE='active'), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(mark.exists())
        # TERM must not unlock the world while the child is recovering.
        (lib / 'restore_zone.py').write_text(
            'import os, signal, time\n'
            'from pathlib import Path\n'
            'def recover(*args):\n'
            '    Path(os.environ["MARK"] + ".recovering").touch()\n'
            '    time.sleep(0.4)\n'
            '    raise SystemExit(143)\n'
            'signal.signal(signal.SIGTERM, recover)\n'
            'Path(os.environ["MARK"]).touch()\n'
            'time.sleep(10)\n')
        child = subprocess.Popen(['bash', str(scripts / 'restoreZone.sh'), '--apply'],
                                 env=dict(env, STATE='inactive'), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not mark.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(mark.exists())
            child.send_signal(signal.SIGTERM)
            recovering = Path(str(mark) + '.recovering')
            while not recovering.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(recovering.exists())
            import fcntl
            with (runtime / 'pzmanager/world.lock').open('w') as probe:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            child.communicate(timeout=3)
            self.assertEqual(child.returncode, 143)
        finally:
            if child.poll() is None: child.kill(); child.communicate()
        mark.unlink(missing_ok=True)
        (runtime / 'pzmanager').mkdir(exist_ok=True)
        import fcntl
        with (runtime / 'pzmanager/world.lock').open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(['bash', str(scripts / 'restoreZone.sh'), '--apply'],
                                    env=dict(env, STATE='inactive'), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(mark.exists())


if __name__ == '__main__': unittest.main()
