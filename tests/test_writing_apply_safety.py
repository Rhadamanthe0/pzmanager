#!/usr/bin/env python3
"""Binary-envelope and commit-boundary regressions; NOT native PZ fixtures."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'data/scripts/internal'))
import cleanWritingDrawings as writing


def string(text):
    raw = text.encode('utf-8')
    return b'\0' + struct.pack('>H', len(raw)) + raw


def table(entries):
    return b'\x02' + struct.pack('>i', len(entries)) + b''.join(k+v for k,v in entries)


def document(dirty=True):
    page = [(string('txt'), string('Texte à conserver intégralement'))]
    if dirty:
        page += [(string('ink'), table([(string('opaque'), string('drawing bytes'))])),
                 (string('sym'), table([]))]
    return string('NeatWriting') + table([
        (string('p'), table([(b'\x01'+struct.pack('>d',1), table(page))])),
        (string('title'), string('Titre préservé')),
        (string('otherMod'), table([(string('txt'), string('independent data'))]))])


def item(rid, ident, payload):
    body = struct.pack('>hBi', rid, 255, ident) + payload
    return struct.pack('>i', len(body)) + body


def floor_bag(rid=2, dirty=True, depth=1):
    inner = item(1, 111, b'BOOK:' + document(dirty))
    for i in range(depth):
        inner = item(rid if i == depth-1 else 2, 200+i,
                     b'BAG:' + struct.pack('>i', 1) + inner + b':BAG-END')
    following = item(9, 999, b'FOLLOWING-OBJECT-UNCHANGED')
    body = b'\0'*16 + inner + following + b'WORLD-TAIL'
    return b'\0' + struct.pack('>iiq', 249, len(body)+17, zlib.crc32(body)) + body, following


def registry(extra=None):
    return writing.Registry({1:'Base.Notebook',2:'Base.Bag_Schoolbag',
                             9:'UnrelatedMod.Item',**(extra or {})}, {})


def files(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}


class WritingEnvelopes(unittest.TestCase):
    def test_known_floor_bag_and_all_nested_lengths_shrink(self):
        for depth in (1, 2, 4):
            with self.subTest(depth=depth):
                blob, following = floor_bag(depth=depth)
                cleaned, metadata = writing.clean_blob(blob, registry(), chunk=True)
                expected, _ = floor_bag(dirty=False, depth=depth)
                self.assertEqual(cleaned, expected)
                self.assertEqual(len(metadata[0]['ancestors']), depth)
                self.assertIn(following, cleaned)
                self.assertIn('Texte à conserver intégralement'.encode(), cleaned)
                self.assertEqual(writing.clean_blob(cleaned, registry(), chunk=True), (cleaned, []))

    def test_unclassified_direct_mod_container_is_refused(self):
        blob, _ = floor_bag(rid=3)
        with self.assertRaises(writing.CleanupError):
            writing.clean_blob(blob, registry({3:'UnknownMod.NewBag'}), chunk=True)

    def test_unknown_registry_ancestor_is_refused(self):
        blob, _ = floor_bag(rid=3)
        with self.assertRaises(writing.CleanupError):
            writing.clean_blob(blob, registry(), chunk=True)

    def test_crc_header_bytes_cannot_be_mistaken_for_unknown_item(self):
        blob, _ = floor_bag()
        parser = writing.Parser(blob); parser.pos = blob.index(writing.MARKER)+len(writing.MARKER)-1
        doc_end = parser.value().end
        # Craft a valid checksum ending in ff whose preceding bytes look like
        # a covering record at offset 10. Chunk-header bytes are NOT items.
        prefix = struct.pack('>I', 256) + blob[21:]
        for nonce in range(65536):
            body = prefix + struct.pack('>I', nonce)
            crc = zlib.crc32(body)
            if crc & 255 == 255 and 14+(crc >> 24) >= doc_end:
                break
        else:
            self.fail('deterministic header fixture not found')
        candidate = b'\0'+struct.pack('>iiq',249,len(body)+17,crc)+body
        cleaned, _ = writing.clean_blob(candidate, registry(), chunk=True)
        expected, _ = floor_bag(dirty=False)
        expected_body = struct.pack('>I',256)+expected[21:]+struct.pack('>I',nonce)
        expected = b'\0'+struct.pack('>iiq',249,len(expected_body)+17,zlib.crc32(expected_body))+expected_body
        self.assertEqual(cleaned,expected)

    def test_script_classified_mod_container_preserves_all_other_bytes(self):
        blob, following = floor_bag(rid=3)
        known = registry({3:'EnabledMod.NewBag'})
        known.classes['EnabledMod.NewBag'] = 'container'
        cleaned, _ = writing.clean_blob(blob, known, chunk=True)
        expected, _ = floor_bag(rid=3, dirty=False)
        self.assertEqual(cleaned, expected)
        self.assertIn(following, cleaned)

    def test_clean_unknown_mod_bag_is_not_changed_or_rejected(self):
        blob, _ = floor_bag(rid=3, dirty=False)
        self.assertEqual(writing.clean_blob(blob, registry(), chunk=True), (blob, []))

    def test_unknown_unrelated_object_is_preserved(self):
        blob, following = floor_bag()
        known = registry(); del known[9]
        cleaned, _ = writing.clean_blob(blob, known, chunk=True)
        self.assertIn(following, cleaned)
        expected, _ = floor_bag(dirty=False)
        self.assertEqual(cleaned, expected)


class WritingApplyBoundary(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pz-writing-apply-safety-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.world = self.root / 'world'; self.world.mkdir(mode=0o700)
        self.stage = self.root / 'cleanup'; self.stage.mkdir(mode=0o700)
        self.entries = []
        self.original, _ = floor_bag()
        self.cleaned, _ = floor_bag(dirty=False)
        for x in (0,1):
            rel = Path(f'map/{x}/0.bin')
            (self.world / rel).parent.mkdir(parents=True, mode=0o700)
            (self.world / rel).write_bytes(self.original)
            self.entries.append(writing.stage_change(self.stage, self.world, rel, self.original, self.cleaned))
        (self.world / 'vehicles.db').write_bytes(b'vehicle unrelated sentinel')
        (self.world / 'unrelated.txt').write_bytes(b'untouched document')
        self.manifest = dict(schema=1,world=str(self.world),version=249,state='prepared',
                             files=self.entries,players=[])
        writing.write_manifest(self.stage,self.manifest)
        self.before = files(self.world)
        self.original_copies = files(self.stage / 'original')

    def recover(self, action=lambda: None):
        def read_only_protocol_double(stage, entries, players):
            action()
        return writing.recover(self.world,self.stage,read_only_protocol_double)

    def assert_pending(self):
        self.assertEqual(json.loads(writing.manifest_path(self.stage).read_text())['state'],'prepared')

    def test_staged_change_during_validation_is_refused_before_first_write(self):
        with self.assertRaises(writing.CleanupError):
            self.recover(lambda: (self.stage/'new/map/1/0.bin').write_bytes(b'unvalidated bytes'))
        self.assertEqual(files(self.world), self.before)
        self.assert_pending()

    def test_recovery_damage_during_validation_is_refused_before_first_write(self):
        with self.assertRaises(writing.CleanupError):
            self.recover(lambda: (self.stage/'original/map/1/0.bin').write_bytes(b'damaged recovery'))
        self.assertEqual(files(self.world), self.before)
        self.assert_pending()

    def test_world_change_during_validation_is_not_reported_complete(self):
        def change():
            (self.world/'map/1/0.bin').write_bytes(b'foreign live change')
        with self.assertRaises(writing.CleanupError):
            self.recover(change)
        expected = dict(self.before, **{'map/1/0.bin':b'foreign live change'})
        self.assertEqual(files(self.world), expected)
        self.assert_pending()

    def test_sidecar_appearing_during_validation_is_refused_before_first_write(self):
        with self.assertRaises(writing.CleanupError):
            self.recover(lambda: (self.world/'players.db-wal').write_bytes(b'new database write'))
        expected = dict(self.before, **{'players.db-wal':b'new database write'})
        self.assertEqual(files(self.world), expected)
        self.assert_pending()

    def test_corrupt_install_copy_does_not_replace_live(self):
        real = shutil.copyfileobj
        def corrupt(reader,writer,*args,**kwargs):
            real(reader,writer,*args,**kwargs)
            writer.write(b'not part of the validated image')
        with patch.object(writing.shutil,'copyfileobj',corrupt):
            with self.assertRaises(writing.CleanupError):
                self.recover()
        self.assertEqual(files(self.world), self.before)
        self.assertEqual(files(self.stage/'original'),self.original_copies)
        self.assert_pending()

    def test_recovery_durability_failure_precedes_every_live_write(self):
        real = os.fsync
        directory = self.stage.parent.stat()
        def fail_recovery_directory(fd):
            info = os.fstat(fd)
            if (info.st_dev,info.st_ino) == (directory.st_dev,directory.st_ino):
                raise OSError('injected recovery fsync failure')
            return real(fd)
        with patch.object(writing.os,'fsync',fail_recovery_directory):
            with self.assertRaisesRegex(OSError,'recovery fsync failure'):
                self.recover()
        self.assertEqual(files(self.world),self.before)
        self.assertEqual(files(self.stage/'original'),self.original_copies)
        self.assert_pending()

    def test_success_keeps_originals_unrelated_files_and_exact_new_images(self):
        self.assertEqual(self.recover(),2)
        expected = dict(self.before, **{f'map/{x}/0.bin':self.cleaned for x in (0,1)})
        self.assertEqual(files(self.world),expected)
        self.assertEqual(files(self.stage/'original'),self.original_copies)
        self.assertEqual(json.loads(writing.manifest_path(self.stage).read_text())['state'],'complete')

    def test_already_applied_file_is_not_rewritten(self):
        first = self.world/'map/0/0.bin'; first.write_bytes(self.cleaned)
        inode = first.stat().st_ino
        self.recover()
        self.assertEqual(first.stat().st_ino,inode)
        self.assertEqual(first.read_bytes(),self.cleaned)

    def test_failure_after_one_file_leaves_recoverable_prepared_manifest(self):
        real = writing.atomic_copy
        def fail_second(path,*args,**kwargs):
            if Path(path) == self.world/'map/1/0.bin':
                raise OSError('injected second-file failure')
            return real(path,*args,**kwargs)
        with patch.object(writing,'atomic_copy',fail_second):
            with self.assertRaises(OSError):self.recover()
        self.assert_pending()
        self.assertEqual((self.world/'map/0/0.bin').read_bytes(),self.cleaned)
        self.assertEqual((self.world/'map/1/0.bin').read_bytes(),self.original)
        self.assertEqual(files(self.stage/'original'),self.original_copies)
        # Explicitly invoked here on this disposable fixture only; not on a real world.
        self.recover()
        self.assertEqual((self.world/'map/1/0.bin').read_bytes(),self.cleaned)


class CleanWorldCompilerFree(unittest.TestCase):
    def test_existing_clean_saved_world_does_not_call_validator(self):
        with tempfile.TemporaryDirectory(prefix='pz-clean-no-jdk-') as tmp:
            root=Path(tmp);world=root/'world';world.mkdir(mode=0o700)
            (world/'WorldDictionaryReadable.lua').write_text('registryID = 1, fulltype = "Base.Notebook"')
            (world/'other.bin').write_bytes(b'no drawing data')
            with patch.object(writing.JavaValidator,'tools',side_effect=AssertionError('no compiler needed')):
                result=writing.cleanup(world,root/'recovery',validator=writing.JavaValidator('missing.jar','missing.java'))
            self.assertEqual(result['files'],0)
            self.assertFalse((root/'recovery').exists())

    def test_uninitialized_world_does_not_call_validator_or_create_anything(self):
        with tempfile.TemporaryDirectory(prefix='pz-empty-no-jdk-') as tmp:
            root=Path(tmp)
            with patch.object(writing.JavaValidator,'tools',side_effect=AssertionError('no compiler needed')):
                result=writing.cleanup(root/'absent',root/'recovery',validator=writing.JavaValidator('missing.jar','missing.java'))
            self.assertEqual(result['files'],0)
            self.assertEqual(list(root.iterdir()),[])


if __name__ == '__main__':
    unittest.main(verbosity=2)
