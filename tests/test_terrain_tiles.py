"""Exact column selection, untouched bytes and fail-closed native index contracts.

Fixtures have length-prefixed opaque square data, NOT the proprietary PZ layout.
Only NativeIndexer is substituted; production splice/staging/recovery are exercised.
Real PZ-reader integration is run separately against private snapshot copies.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(os.environ.get('PZ_TEST_ROOT', Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(ROOT / 'data/scripts/lib'))
import terrain_tiles as tiles


def fixture(tag, floors=(-2, 0, 3), empty=()):
    # The merger preserves opaque prefixes/suffixes; only the floor offset is known.
    payload = bytearray(b'PREFIX' + struct.pack('>iii', max(floors), min(floors), 0))
    for i in range(64):
        active = () if i in empty else floors
        payload.extend(struct.pack('>Q', sum(1 << (z+32) for z in active)))
        for z in active:
            value = f'{tag}:tile={i}:floor={z}'.encode()
            payload.extend(struct.pack('>I', len(value)) + value)
    payload.extend(b'SUFFIX:' + tag.encode())
    return b'\0' + struct.pack('>iiq', 249, len(payload)+17, zlib.crc32(payload)) + payload


def fixture_index(blob):
    hi, lo = struct.unpack_from('>ii', blob, 23)
    pos = 35
    columns = []
    for i in range(64):
        start = pos
        flags, = struct.unpack_from('>Q', blob, pos); pos += 8
        for z in range(lo, hi+1):
            if flags & (1 << (z+32)):
                size, = struct.unpack_from('>I', blob, pos); pos += size+4
        columns.append([start, pos, str(flags)])
    return dict(sha256=hashlib.sha256(blob).hexdigest(), level_offset=23,
                min_level=lo, max_level=hi, columns=columns)


class FixtureIndexer:
    def __init__(self, root, dictionary): pass
    def index(self, files): return [fixture_index(Path(f['file']).read_bytes()) for f in files]


class TileTests(unittest.TestCase):
    def test_one_column_all_floors_and_raw_neighbours(self):
        source, live = fixture('backup', (-3, 0, 5)), fixture('current', (-1, 0, 2))
        a, b = fixture_index(source), fixture_index(live)
        result = tiles.merge_columns(source, live, a, b, [17])
        c = fixture_index(result)
        expected = tiles.checked_columns(live, b)
        expected[17] = tiles.checked_columns(source, a)[17]
        self.assertEqual(tiles.checked_columns(result, c), expected)
        self.assertEqual((c['min_level'], c['max_level']), (-3, 5))
        self.assertEqual(result[c['columns'][-1][1]:], live[b['columns'][-1][1]:])
        # Only envelope checksum/length and min/max levels change outside columns.
        self.assertEqual(result[17:23], live[17:23])
        self.assertEqual(result[31:c['columns'][0][0]], live[31:b['columns'][0][0]])
        self.assertNotIn(b'current:tile=17:', result)

    def test_absent_saved_column_removes_all_current_floors(self):
        source, live = fixture('saved', empty=(17,)), fixture('live')
        result = tiles.merge_columns(source, live, fixture_index(source), fixture_index(live), [17])
        self.assertEqual(tiles.checked_columns(result, fixture_index(result))[17], b'\0'*8)
        self.assertIn(b'live:tile=16:', result)
        self.assertIn(b'live:tile=18:', result)

    def test_invalid_or_stale_index_refused(self):
        source, live = fixture('saved'), fixture('live')
        good = fixture_index(source)
        bads = []
        for key, value in [('sha256', 'bad'), ('min_level', -33), ('max_level', 32), ('columns', [])]:
            bad = copy.deepcopy(good); bad[key] = value; bads.append(bad)
        bad = copy.deepcopy(good); bad['columns'][1][0] += 1; bads.append(bad)
        bad = copy.deepcopy(good); bad['columns'][2][2] = '1'; bads.append(bad)
        for bad in bads:
            with self.assertRaises(ValueError): tiles.merge_columns(source, live, bad, fixture_index(live), [0])
        for selection in ([], [-1], [64], [True]):
            with self.assertRaises(ValueError): tiles.merge_columns(source, live, good, fixture_index(live), selection)

    def test_staged_output_is_reloaded_and_checked(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for name in ('source', 'current'):
                (root/name).write_bytes(fixture(name))
            entry=dict(source=root/'source', current=root/'current', output=root/'output', x=1, y=1, selected=[8])
            with patch.object(tiles, 'NativeIndexer', FixtureIndexer):
                tiles.prepare_partial(root, root/'dictionary', [entry])
            result=(root/'output').read_bytes()
            self.assertIn(b'source:tile=8:', result)
            self.assertIn(b'current:tile=9:', result)
            class BrokenIndexer(FixtureIndexer):
                def index(self, files):
                    if any(f['file'].endswith('output') for f in files):
                        (root/'output').write_bytes(fixture('unexpected'))
                    return super().index(files)
            with patch.object(tiles, 'NativeIndexer', BrokenIndexer), self.assertRaises(ValueError):
                tiles.prepare_partial(root, root/'dictionary', [entry])


class NativeToolContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / 'game'
        (self.install / 'java').mkdir(parents=True)
        (self.install / 'java/projectzomboid.jar').write_bytes(b'simulated game-reader executable contract')
        (self.install / 'media').mkdir()
        (self.install / 'stdlib.lua').touch()
        bin_dir = self.install / 'jre64/bin'; bin_dir.mkdir(parents=True)
        self.log = self.root / 'calls.jsonl'
        prelude = ('#!' + sys.executable + '\nimport os,sys,json\nfrom pathlib import Path\n'
                   + 'fd=os.environ.get("PZ_WORLD_LOCK_FD")\nif fd: os.fstat(int(fd))\n'
                   + 'with Path(' + repr(str(self.log)) + ').open("a") as f: f.write(json.dumps(sys.argv)+"\\n")\n')
        self.java = bin_dir / 'java'
        self.java.write_text(prelude + "if sys.argv[1:]==['-version']: print('openjdk version \"25.0.1\"'); raise SystemExit(0)\n")
        self.java.chmod(0o700)
        self.javac = bin_dir / 'javac'; self.javac.write_text(prelude); self.javac.chmod(0o700)
        env = dict(os.environ, PZ_INSTALL_DIR=str(self.install))
        for name in ('PZ_RESTORE_JAVA', 'PZ_RESTORE_JAVAC', 'PZ_WORLD_LOCK_FD'):
            env.pop(name, None)
        self.env_patch = patch.dict(os.environ, env, clear=True); self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_runtime_target_compiler_and_inherited_world_lock(self):
        read, write = os.pipe()
        try:
            os.environ['PZ_WORLD_LOCK_FD'] = str(read)
            tiles.NativeIndexer(self.root/'native', self.root/'dictionary')
        finally:
            os.close(read); os.close(write)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        compiled = next(c for c in calls if c[0] == str(self.javac))
        self.assertEqual(compiled[1:3], ['--release', '25'])

    def test_explicit_invalid_compiler_has_no_fallback(self):
        os.environ['PZ_RESTORE_JAVAC'] = str(self.root/'missing-javac')
        with patch.object(tiles.shutil, 'which', side_effect=AssertionError('must not fall back')):
            with self.assertRaisesRegex(ValueError, 'PZ_RESTORE_JAVAC'):
                tiles.NativeIndexer(self.root/'native', self.root/'dictionary')
        self.assertFalse(self.log.exists())

    def test_jre_only_missing_compiler_refuses(self):
        self.javac.unlink()
        with patch.object(tiles.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'JDK'):
                tiles.NativeIndexer(self.root/'native', self.root/'dictionary')

    def test_compiler_failure_is_not_ignored(self):
        self.javac.write_text('#!' + sys.executable + '\nraise SystemExit(2)\n')
        with self.assertRaisesRegex(ValueError, 'compile, code 2'):
            tiles.NativeIndexer(self.root/'native', self.root/'dictionary')


if __name__ == '__main__': unittest.main()
