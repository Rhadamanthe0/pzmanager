#!/usr/bin/env python3
"""Regression tests on disposable synthetic worlds; no installed PZ engine.

The native double models the index protocol, NOT game deserialization. Files,
CRC/SHA checks, splicing, copy failures and rollback are exercised for real.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'data/scripts/lib'))
import restore_zone as zone
import terrain_tiles as tiles


def synthetic_terrain(tag):
    # Deliberately synthetic: it is not a loadable PZ square representation.
    body = bytearray(struct.pack('>iii', 0, 0, 0))
    for i in range(64):
        body.extend(struct.pack('>QBB', 0, tag, i))
    body.extend(bytes((tag,)) * 7)  # chunk-wide suffix kept by partial splices
    return b'\0' + struct.pack('>iiq', 249, 17 + len(body), zlib.crc32(body)) + body


def synthetic_index(blob):
    return {'sha256': hashlib.sha256(blob).hexdigest(), 'min_level': 0,
            'max_level': 0, 'level_offset': 17,
            'columns': [[29 + 10*i, 39 + 10*i, '0'] for i in range(64)]}


def snapshot(root):
    return {str(p.relative_to(root)): p.read_bytes()
            for p in root.rglob('*') if p.is_file()}


class WorldSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pz-data-safety-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.live = self.root / 'live/Saves/Multiplayer/test'
        self.source = self.root / 'backup/Saves/Multiplayer/test'
        self.recovery = self.root / 'OLD'
        for root, tag in ((self.live, 20), (self.source, 10)):
            (root / 'map').mkdir(parents=True)
            (root / 'WorldDictionary.bin').write_bytes(b'synthetic equal dictionary')
            for x in range(4):
                (root / 'map' / str(x)).mkdir()
                (root / 'map' / str(x) / '0.bin').write_bytes(synthetic_terrain(tag+x))
            (root / 'isoregiondata').mkdir()
            for x in range(4):
                (root / f'isoregiondata/datachunk_{x}_0.bin').write_bytes(bytes((tag, x)))
            (root / 'players.db').write_bytes(b'untouched player sentinel')
            (root / 'vehicles.db').write_bytes(b'untouched Humvee sentinel')
            (root / 'outside.txt').write_bytes(b'untouched text outside selection')
        self.args = SimpleNamespace(x1=0, y1=0, x2=7, y2=7, apply=True,
                                    recovery_root=str(self.recovery), staging_root=str(self.root))
        self.before = snapshot(self.live)
        self.backup_before = snapshot(self.source)
        self.calls = []
        self.reject = lambda entry: False
        owner = self

        class SyntheticNative:
            def __init__(self, root, dictionary, **kwargs):
                self.dictionary = Path(dictionary)
            def index(self, entries):
                owner.calls.extend(dict(entry) for entry in entries)
                for entry in entries:
                    if owner.reject(entry):
                        raise ValueError('synthetic engine rejects complete file')
                return [synthetic_index(Path(entry['file']).read_bytes()) for entry in entries]

        for mod in (zone, tiles):
            p = patch.object(mod, 'NativeIndexer', SyntheticNative)
            p.start(); self.addCleanup(p.stop)

    def run_restore(self):
        return zone.restore_source(self.args, self.root / 'backup', 'test', self.live, self.source)

    def assert_sources_unchanged(self):
        self.assertEqual(snapshot(self.source), self.backup_before)

    def assert_untouched(self):
        after = snapshot(self.live)
        for name in ('players.db', 'vehicles.db', 'outside.txt', 'WorldDictionary.bin',
                     'map/3/0.bin', 'isoregiondata/datachunk_3_0.bin'):
            self.assertEqual(after[name], self.before[name], name)
        self.assert_sources_unchanged()

    def inject_at_ready(self, action):
        real = Path.write_text
        def write(path, data, *args, **kwargs):
            result = real(path, data, *args, **kwargs)
            if path.name == '.manifest.pending' and json.loads(data)['status'] == 'ready':
                action(path.parent)
            return result
        p = patch.object(Path, 'write_text', write)
        p.start(); self.addCleanup(p.stop)

    def test_whole_chunk_native_refusal_precedes_every_world_write(self):
        self.reject = lambda entry: True
        with self.assertRaisesRegex(ValueError, 'synthetic engine rejects'):
            self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_full_interior_chunk_of_partial_rectangle_is_validated(self):
        self.args.x1, self.args.x2 = 1, 22  # partial edge, full interior, partial edge
        self.reject = lambda entry: entry['x'] == 1
        with self.assertRaisesRegex(ValueError, 'synthetic engine rejects'):
            self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_missing_staged_terrain_is_not_permission_to_delete_live(self):
        self.inject_at_ready(lambda root: (root / 'staged/map/0/0.bin').unlink())
        with self.assertRaises((OSError, ValueError)):
            self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_changed_staged_terrain_is_refused_before_first_write(self):
        self.inject_at_ready(lambda root: (root / 'staged/map/0/0.bin').write_bytes(synthetic_terrain(99)))
        with self.assertRaises((OSError, ValueError)):
            self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_changed_live_after_validation_is_not_silently_overwritten(self):
        change = synthetic_terrain(98)
        self.inject_at_ready(lambda root: (self.live / 'map/0/0.bin').write_bytes(change))
        with self.assertRaises((OSError, ValueError)):
            self.run_restore()
        expected = dict(self.before, **{'map/0/0.bin': change})
        self.assertEqual(snapshot(self.live), expected)
        self.assert_sources_unchanged()

    def test_recovery_copy_damage_is_refused_before_first_write(self):
        self.inject_at_ready(lambda root: (root / 'before/Saves/Multiplayer/test/map/0/0.bin').write_bytes(b'damaged copy'))
        with self.assertRaises((OSError, ValueError)):
            self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_corruption_during_install_copy_never_replaces_valid_live_file(self):
        real = shutil.copy2
        injected = []
        def copy(source, target, *args, **kwargs):
            result = real(source, target, *args, **kwargs)
            dest = Path(target)
            if not injected and self.live in dest.parents and dest.name.startswith('.zone-'):
                dest.write_bytes(b'broken install copy')
                injected.append(True)
            return result
        with patch.object(zone.shutil, 'copy2', copy):
            with self.assertRaises((OSError, ValueError)):
                self.run_restore()
        self.assertTrue(injected)
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_partial_source_copy_corruption_is_refused_before_world_write(self):
        self.args.x1, self.args.x2 = 2, 4
        real = shutil.copy2
        injected = []
        def copy(source, target, *args, **kwargs):
            result = real(source, target, *args, **kwargs)
            if ('source' in Path(target).parts and 'map' in Path(target).parts
                    and not injected):
                Path(target).write_bytes(synthetic_terrain(99))
                injected.append(True)
            return result
        with patch.object(zone.shutil, 'copy2', copy):
            with self.assertRaises((OSError, ValueError)):
                self.run_restore()
        self.assertTrue(injected)
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_recovery_directory_durability_failure_precedes_world_writes(self):
        real = os.fsync
        def fsync(fd):
            name = os.readlink('/proc/self/fd/' + str(fd))
            if name.endswith('/before/Saves/Multiplayer'):
                raise OSError('injected recovery-directory durability failure')
            return real(fd)
        with patch.object(zone.os, 'fsync', fsync):
            with self.assertRaisesRegex(OSError, 'durability failure'):
                self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()

    def test_rollback_preserves_external_write_after_partial_apply(self):
        self.args.x2 = 15
        real = zone.replace_file
        external = synthetic_terrain(98)
        injected = []
        def replace(source, destination, *args, **kwargs):
            if (Path(destination) == self.live / 'map/1/0.bin'
                    and 'staged' in Path(source).parts and not injected):
                injected.append(True)
                (self.live / 'map/0/0.bin').write_bytes(external)
                raise OSError('injected install failure with external write')
            return real(source, destination, *args, **kwargs)
        with patch.object(zone, 'replace_file', replace):
            with self.assertRaises((OSError, ValueError)):
                self.run_restore()
        self.assertTrue(injected)
        self.assertEqual((self.live / 'map/0/0.bin').read_bytes(), external)
        self.assert_sources_unchanged()
        manifest = json.loads(next(self.recovery.glob('.zone-rollback-*/manifest.json')).read_text())
        self.assertEqual(manifest['status'], 'rollback-failed')

    def test_whole_chunk_success_installs_validated_bytes_only(self):
        self.run_restore()
        self.assertTrue(any('/staged/map/0/0.bin' in e['file'] for e in self.calls))
        self.assertEqual((self.live / 'map/0/0.bin').read_bytes(), self.backup_before['map/0/0.bin'])
        self.assert_untouched()

    def test_partial_success_keeps_every_unselected_column(self):
        self.args.x1, self.args.x2 = 2, 4
        self.run_restore()
        result = (self.live / 'map/0/0.bin').read_bytes()
        columns = tiles.checked_columns(result, synthetic_index(result))
        before = tiles.checked_columns(self.before['map/0/0.bin'], synthetic_index(self.before['map/0/0.bin']))
        source = tiles.checked_columns(self.backup_before['map/0/0.bin'], synthetic_index(self.backup_before['map/0/0.bin']))
        self.assertEqual(columns, [source[i] if 2 <= i // 8 <= 4 else before[i] for i in range(64)])
        self.assertEqual(result[-7:], self.before['map/0/0.bin'][-7:])
        self.assertFalse((self.live / 'isoregiondata/datachunk_0_0.bin').exists())
        self.assert_untouched()

    def test_intentional_missing_source_iso_is_the_only_deletion(self):
        (self.source / 'isoregiondata/datachunk_0_0.bin').unlink()
        self.backup_before = snapshot(self.source)
        self.run_restore()
        self.assertFalse((self.live / 'isoregiondata/datachunk_0_0.bin').exists())
        self.assert_untouched()

    def test_mid_operation_failure_restores_previous_bytes(self):
        self.args.x2 = 15
        real = zone.replace_file
        injected = []
        def replace(source, destination, *args, **kwargs):
            if (Path(destination) == self.live / 'map/1/0.bin'
                    and 'staged' in Path(source).parts and not injected):
                injected.append(True)
                raise OSError('injected install failure')
            return real(source, destination, *args, **kwargs)
        with patch.object(zone, 'replace_file', replace):
            with self.assertRaisesRegex(OSError, 'injected install failure'):
                self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assert_sources_unchanged()
        self.assertEqual(list(self.recovery.iterdir()), [])
        zone.transactions.check_clean(self.live.parents[2])
        state=zone.transactions.location(self.live.parents[2])[1]
        [record]=state.glob('*.json')
        self.assertEqual(json.loads(record.read_text())['state'], 'reverted')

    def test_hardlinked_backup_not_modified_by_restore(self):
        target = self.live / 'map/0/0.bin'
        extra = self.root / 'saved-hardlink.bin'
        os.link(target, extra)
        self.run_restore()
        self.assertEqual(extra.read_bytes(), self.before['map/0/0.bin'])
        self.assertNotEqual(target.stat().st_ino, extra.stat().st_ino)
        self.assert_sources_unchanged()

    def test_preview_does_not_need_compiler_or_create_recovery(self):
        self.args.apply = False
        self.run_restore()
        self.assertEqual(snapshot(self.live), self.before)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.recovery.exists())


class NativeProtocolSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pz-native-protocol-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.path = self.root / 'copied-terrain.bin'
        self.blob = synthetic_terrain(7)
        self.path.write_bytes(self.blob)
        self.native = tiles.NativeIndexer.__new__(tiles.NativeIndexer)
        self.native.trace_items=False
        self.native.root = self.root
        self.native.sequence = 0
        self.native.script_context = {'mods': [], 'mod_roots': []}
        self.native.dictionary = self.root / 'dictionary'
        self.native.java = 'unused-double'
        self.native.classpath = 'unused-double'
        self.entries = [{'file': str(self.path), 'x': 0, 'y': 0}]

    def run_with_result(self, indexes, mutate=None):
        def run(command, label):
            (self.root / (label + '-result.json')).write_text(json.dumps({'chunks': indexes}))
            if mutate:
                mutate()
            return b''
        with patch.object(self.native, 'run', run):
            return self.native.index(self.entries)

    def test_response_for_different_bytes_is_not_validation(self):
        index = synthetic_index(synthetic_terrain(99))
        with self.assertRaises(ValueError):
            self.run_with_result([index])

    def test_file_change_while_native_reads_is_refused(self):
        replacement = synthetic_terrain(99)
        with self.assertRaises(ValueError):
            self.run_with_result([synthetic_index(replacement)], lambda: self.path.write_bytes(replacement))

    def test_incomplete_column_index_is_not_validation(self):
        index = synthetic_index(self.blob)
        index['columns'].pop()
        with self.assertRaises(ValueError):
            self.run_with_result([index])

    def test_correct_response_passes_without_resaving_any_byte(self):
        expected = synthetic_index(self.blob)
        self.assertEqual(self.run_with_result([expected]), [expected])
        self.assertEqual(self.path.read_bytes(), self.blob)

    def test_wrong_result_count_is_refused(self):
        with self.assertRaises(ValueError):
            self.run_with_result([])


if __name__ == '__main__':
    unittest.main(verbosity=2)
