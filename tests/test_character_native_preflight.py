"""Real SQLite selection and frozen copies; proprietary reader explicitly doubled."""
from contextlib import closing
from pathlib import Path
import sqlite3
import os
import subprocess
import shlex
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
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('CREATE TABLE networkPlayers(id INTEGER,username TEXT,worldversion INTEGER,data BLOB)')
            db.executemany('INSERT INTO networkPlayers VALUES(?,?,?,?)',[(1,"selected'",249,b'entire selected blob'),(2,'outside',249,b'outside opaque blob')])
        self.reader=patch.object(gate,'NativeIndexer');self.native=self.reader.start().return_value;self.addCleanup(self.reader.stop)
        self.native.dictionaries.return_value=[{'registries':{'items':{'1':'Base.Book'}}}]*2
    def validate(self):gate.validate(self.db,self.dictionary,self.world,"selected'",self.root/'stage')
    def test_unexported_env_tool_overrides_reach_native_child(self):
        common=Path(__file__).resolve().parents[1]/'data/scripts/lib/common.sh'
        command='source '+shlex.quote(str(common))+"\nPZ_RESTORE_JAVA=/private/java\nPZ_RESTORE_JAVAC=/private/javac\napply_env_defaults\n"
        command+=shlex.quote(sys.executable)+" -c 'import os; print(os.environ.get(\"PZ_RESTORE_JAVA\")); print(os.environ.get(\"PZ_RESTORE_JAVAC\"))'"
        env={k:v for k,v in os.environ.items() if not k.startswith(('PZ_','BACKUP_','DISCORD_')) and k not in ('BASH_ENV','ENV')}
        result=subprocess.run(['bash','-euc',command],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'/private/java\n/private/javac\n')

    def test_entire_selected_blob_is_private_and_other_user_not_passed_to_reader(self):
        before=self.db.read_bytes();dictionary=self.dictionary.read_bytes();self.validate()
        entries=self.native.storage.call_args.args[0];self.assertEqual(len(entries),1)
        path=Path(entries[0]['file']);self.assertEqual(path.read_bytes(),b'entire selected blob')
        self.assertTrue(path.is_relative_to(self.root/'stage'));self.assertEqual(entries[0]['version'],249)
        self.assertEqual(self.db.read_bytes(),before);self.assertEqual(self.dictionary.read_bytes(),dictionary)
    def test_unknown_version_refused_before_native_work(self):
        with closing(sqlite3.connect(self.db)) as db, db:db.execute('UPDATE networkPlayers SET worldversion=250')
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
