"""Real SQLite selection and frozen copies; proprietary reader explicitly doubled."""
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'data/scripts/lib'))
import character_preflight as gate

class CharacterNativePreflight(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.world=self.root/'world';self.world.mkdir()
        self.dictionary=self.world/'WorldDictionary.bin';self.dictionary.write_bytes(b'copied native dictionary fixture')
        self.db=self.root/'players.db'
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE TABLE networkPlayers(id INTEGER,username TEXT,worldversion INTEGER,data BLOB)')
            db.executemany('INSERT INTO networkPlayers VALUES(?,?,?,?)',[(1,"selected'",249,b'entire selected blob'),(2,'outside',249,b'outside opaque blob')])
        self.reader=patch.object(gate,'NativeIndexer');self.native=self.reader.start().return_value;self.addCleanup(self.reader.stop)
        self.native.dictionaries.return_value=[{'registries':{'items':{'1':'Base.Book'}}}]*2
    def validate(self):gate.validate(self.db,self.dictionary,self.world,"selected'",self.root/'stage')
    def test_entire_selected_blob_is_private_and_other_user_not_passed_to_reader(self):
        before=self.db.read_bytes();dictionary=self.dictionary.read_bytes();self.validate()
        entries=self.native.storage.call_args.args[0];self.assertEqual(len(entries),1)
        path=Path(entries[0]['file']);self.assertEqual(path.read_bytes(),b'entire selected blob')
        self.assertTrue(path.is_relative_to(self.root/'stage'));self.assertEqual(entries[0]['version'],249)
        self.assertEqual(self.db.read_bytes(),before);self.assertEqual(self.dictionary.read_bytes(),dictionary)
    def test_unknown_version_refused_before_native_work(self):
        with sqlite3.connect(self.db) as db:db.execute('UPDATE networkPlayers SET worldversion=250')
        with self.assertRaisesRegex(ValueError,'version'):self.validate()
        self.native.storage.assert_not_called()
    def test_dictionary_meaning_change_refused_before_native_storage(self):
        self.native.dictionaries.return_value=[{'registries':{'items':{'1':'Base.Book'}}},{'registries':{'items':{'1':'Base.Bag'}}}]
        with self.assertRaisesRegex(ValueError,'identifiers'):self.validate()
        self.native.storage.assert_not_called()
    def test_native_refusal_propagates_without_sql_mutation(self):
        before=self.db.read_bytes();self.native.storage.side_effect=ValueError('genuine loader refused')
        with self.assertRaisesRegex(ValueError,'loader refused'):self.validate()
        self.assertEqual(self.db.read_bytes(),before)
    def test_dictionary_change_during_reader_is_refused(self):
        self.native.storage.side_effect=lambda entries:self.dictionary.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'changed'):self.validate()

if __name__=='__main__':unittest.main()
