#!/usr/bin/env python3
"""Regression tests: ZIP-backed exact-zone recovery, boundaries and security."""
from argparse import Namespace
import importlib.util
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

ROOT = Path(os.environ.get('PZ_TEST_ROOT', Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('zone', ROOT / 'data/scripts/lib/restore_zone.py')
zone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zone)
import zone_zip


def chunk(payload):
    return b'\0' + struct.pack('>iiq', 249, len(payload) + 17,
                                 zlib.crc32(payload)) + payload


class ZipZoneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.live = self.root / 'live/Saves/Multiplayer/world'
        self.snap = self.root / 'snapshot/Saves/Multiplayer/world'
        self.offsite = self.root / 'fullBackups'
        self.offsite.mkdir()
        for root in (self.live, self.snap):
            (root / 'map/1').mkdir(parents=True)
            for rel, value in {'WorldDictionary.bin': b'dictionary',
                               'map_ver.bin': b'version', 'map/1/1.bin': chunk(b'old')} .items():
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
        (self.live / 'map/1/1.bin').write_bytes(chunk(b'current'))
        (self.live / 'players.db').write_bytes(b'leave players untouched')
        self.archive = self.offsite / 'backup.zip'
        self.args = Namespace(live_root=str(self.root / 'live'),
                              backup_root=str(self.root),
                              archive_root=str(self.offsite),
                              recovery_root=str(self.root / 'OLD'),
                              backup=str(self.archive),
                              x1=8, y1=8, x2=15, y2=15, save=None, apply=True)
        self.write_zip()

    def tearDown(self):
        self.tmp.cleanup()

    def game_entries(self):
        prefix = 'zomboid/Saves/Multiplayer/world/'
        return {prefix + str(path.relative_to(self.snap)): path.read_bytes()
                for path in self.snap.rglob('*') if path.is_file()}

    def write_zip(self, extras=None, remove=(), bad_symlink=None):
        entries = self.game_entries()
        for name in remove:
            entries.pop(name)
        entries.update(extras or {})
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('config/home/example/.env', 'secret=do-not-extract')
            archive.writestr('../escape-marker', 'malicious but irrelevant')
            for name, value in entries.items():
                if name == bad_symlink:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, '../../etc/passwd')
                else:
                    archive.writestr(name, value)

    def assert_no_stage(self):
        self.assertEqual(list(self.offsite.glob('.pz-restore-zone-*')), [])

    def test_zip_applies_full_chunks_and_does_not_unpack_secrets(self):
        zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), chunk(b'old'))
        self.assertEqual((self.live / 'players.db').read_bytes(), b'leave players untouched')
        self.assert_no_stage()
        self.assertFalse((self.root / 'escape-marker').exists())
        self.assertFalse((self.offsite / 'config').exists())
        manifest = next((self.root / 'OLD').glob('zone-rollback-*/manifest.json'))
        self.assertIn(str(self.archive), manifest.read_text())

    def test_zip_preview_from_basename_is_read_only(self):
        self.args.backup = self.archive.name
        self.args.apply = False
        before = (self.live / 'map/1/1.bin').read_bytes()
        zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), before)
        self.assertFalse((self.root / 'OLD').exists())
        self.assert_no_stage()

    def test_incomplete_zip_is_rejected_before_mutation(self):
        rel = 'zomboid/Saves/Multiplayer/world/map/1/1.bin'
        self.write_zip(remove=(rel,))
        with self.assertRaisesRegex(ValueError, 'Carte Build 42'):
            zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), chunk(b'current'))
        self.assertFalse((self.root / 'OLD').exists())
        self.assert_no_stage()

    def test_invalid_zip_and_symlinks_are_rejected(self):
        self.archive.write_bytes(b'not a zip')
        with self.assertRaisesRegex(ValueError, 'ZIP illisible'):
            zone.restore(self.args)
        self.assert_no_stage()
        rel = 'zomboid/Saves/Multiplayer/world/map/1/1.bin'
        self.write_zip(bad_symlink=rel)
        with self.assertRaisesRegex(ValueError, 'non régulière'):
            zone.restore(self.args)
        self.assert_no_stage()

    def test_duplicate_map_entry_is_rejected(self):
        rel = 'zomboid/Saves/Multiplayer/world/map/1/1.bin'
        with zipfile.ZipFile(self.archive, 'a') as archive:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                archive.writestr(rel, chunk(b'bad duplicate'))
        with self.assertRaisesRegex(ValueError, 'dupliquée'):
            zone.restore(self.args)
        self.assert_no_stage()

    def test_member_limit_does_not_fill_disk(self):
        with patch.object(zone_zip, 'MAX_MEMBER_BYTES', 2):
            with self.assertRaisesRegex(ValueError, 'volumineuse'):
                zone.restore(self.args)
        self.assert_no_stage()
        self.assertFalse((self.root / 'OLD').exists())

    def test_archive_is_not_implicitly_applied(self):
        self.args.apply = False
        zone.restore(self.args)
        self.assertEqual((self.live / 'map/1/1.bin').read_bytes(), chunk(b'current'))
        self.assert_no_stage()

    def test_partial_chunk_restoration_from_zip(self):
        from test_terrain_tiles import fixture, FixtureIndexer, tiles, fixture_index
        (self.snap / 'map/1/1.bin').write_bytes(fixture('backup'))
        (self.live / 'map/1/1.bin').write_bytes(fixture('current'))
        self.args.x1 = self.args.x2 = 8
        self.args.y1 = self.args.y2 = 8
        self.write_zip()
        with patch.object(tiles, 'NativeIndexer', FixtureIndexer):
            zone.restore(self.args)
        data = (self.live / 'map/1/1.bin').read_bytes()
        columns = tiles.checked_columns(data, fixture_index(data))
        self.assertIn(b'backup:tile=', columns[0])
        self.assertIn(b'current:tile=', columns[1])
        self.assert_no_stage()


if __name__ == '__main__':
    unittest.main()
