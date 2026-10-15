"""Real SQLite character copies: reject schema loss and source journal mutation."""
import os
from contextlib import contextmanager
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COLS = "id INTEGER PRIMARY KEY, world TEXT, username TEXT, playerIndex INTEGER, name TEXT, steamid TEXT, x REAL, y REAL, z REAL, worldversion INTEGER, data BLOB, isDead INTEGER, splitUsername STRING"

@contextmanager
def connection(path):
    db = sqlite3.connect(path)
    try:
        with db: yield db
    finally: db.close()

class CharacterDataSafety(unittest.TestCase):
    def setUp(self):
        if not shutil.which('sqlite3'): self.skipTest('real sqlite3 required')
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        script = self.root/'repo/data/scripts/backup/restoreCharacter.sh'
        script.parent.mkdir(parents=True)
        shutil.copy2(os.environ.get('PZ_CHARACTER_RESTORE_SCRIPT', ROOT/'data/scripts/backup/restoreCharacter.sh'), script)
        lib = script.parent.parent/'lib'; lib.mkdir()
        (lib/'common.sh').write_text("""
source_env() { :; }
require_sqlite() { :; }
die() { echo "$*" >&2; exit 1; }
server_is_active() { return 1; }
acquire_world_lock() { :; }
assert_server_stopped_proven() { :; }
release_world_lock() { :; }
log() { echo "$*"; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
""")
        self.script = script
        self.live = self.root/'live/Saves/Multiplayer/test/players.db'
        self.source = self.root/'source/players.db'; self.source.parent.mkdir()
        self.live.parent.mkdir(parents=True)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('PZ_', 'BACKUP_', 'DISCORD_')) and k not in ('BASH_ENV','ENV')}
        self.env.update(PZ_SOURCE_DIR=str(self.root/'live'), BACKUP_DIR=str(self.root), PZ_SERVER_NAME='test')

    def database(self, path, extra=''):
        with connection(path) as db:
            db.execute('CREATE TABLE networkPlayers ('+COLS+extra+')')
            for user in ('selected','outside'):
                db.execute("INSERT INTO networkPlayers(world,username,data,worldversion) VALUES('test',?,?,249)",(user, b'opaque-'+user.encode()))

    def run_restore(self, *args):
        return subprocess.run(['bash',str(self.script),'selected',str(self.source),*args],env=self.env,capture_output=True,text=True,timeout=10)

    def test_unknown_source_column_refused_without_losing_metadata(self):
        self.database(self.live); self.database(self.source, ', mod_state TEXT DEFAULT \'unknown\'')
        with connection(self.source) as db: db.execute("UPDATE networkPlayers SET mod_state='precious'")
        before=self.live.read_bytes(); source=self.source.read_bytes()
        result=self.run_restore()
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertIn('Schéma incompatible',result.stderr)
        self.assertEqual(self.live.read_bytes(),before);self.assertEqual(self.source.read_bytes(),source)

    def test_unknown_destination_column_refused_instead_of_default_reset(self):
        self.database(self.source);self.database(self.live, ', mod_state TEXT DEFAULT \'reset\'')
        with connection(self.live) as db: db.execute("UPDATE networkPlayers SET mod_state='precious'")
        before=self.live.read_bytes()
        result=self.run_restore()
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertEqual(self.live.read_bytes(),before)

    def test_source_sidecars_refused_without_opening_or_mutating_source(self):
        self.database(self.source);self.database(self.live)
        for suffix in ('-wal','-shm','-journal'):
            with self.subTest(suffix=suffix):
                side=Path(str(self.source)+suffix);side.write_bytes(b'forensic-journal-sentinel')
                before={p.name:p.read_bytes() for p in self.source.parent.iterdir()}
                live=self.live.read_bytes(); result=self.run_restore('--dry-run')
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertIn('SQLite',result.stderr)
                self.assertEqual({p.name:p.read_bytes() for p in self.source.parent.iterdir()},before)
                self.assertEqual(self.live.read_bytes(),live); side.unlink()

    def test_source_change_after_schema_cannot_change_the_prepared_row(self):
        self.database(self.source);self.database(self.live)
        real=shutil.which('sqlite3');bin_dir=self.root/'bin';bin_dir.mkdir()
        wrapper=bin_dir/'sqlite3'
        wrapper.write_text('#!/usr/bin/python3\nimport os,subprocess,sys,sqlite3\nfrom pathlib import Path\n'
            + 'code=subprocess.call('+repr([real])+'+sys.argv[1:])\n'
            + 'stamp=Path(__file__).with_name("changed")\n'
            + 'if not stamp.exists() and any("PRAGMA table_info" in arg for arg in sys.argv):\n'
            + '    stamp.touch()\n'
            + '    db=sqlite3.connect('+repr(str(self.source))+')\n'
            + '    db.execute("UPDATE networkPlayers SET data=? WHERE username=?",(b"changed-after-prepare","selected"));db.commit();db.close()\n'
            + 'sys.exit(code)\n')
        wrapper.chmod(0o700);self.env['PATH']=str(bin_dir)+':'+os.environ['PATH']
        result=self.run_restore();self.assertEqual(result.returncode,0,result.stderr)
        with connection(self.live) as db:
            self.assertEqual(db.execute("SELECT data FROM networkPlayers WHERE username='selected'").fetchone()[0],b'opaque-selected')

    def test_copy_with_quoted_uri_path_preserves_source_and_unselected_row(self):
        self.source=self.source.parent/"source ?#%'é.db"
        self.database(self.source);self.database(self.live)
        with connection(self.source) as db: db.execute("UPDATE networkPlayers SET data=x'010203', splitUsername='preserve-split-player' WHERE username='selected'")
        source=self.source.read_bytes(); result=self.run_restore()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.source.read_bytes(),source)
        self.assertEqual(sorted(p.name for p in self.source.parent.iterdir()),[self.source.name])
        with connection(self.live) as db:
            self.assertEqual(db.execute("SELECT data,splitUsername FROM networkPlayers WHERE username='selected'").fetchone(),(b'\x01\x02\x03','preserve-split-player'))
            self.assertEqual(db.execute("SELECT data FROM networkPlayers WHERE username='outside'").fetchone()[0],b'opaque-outside')

if __name__=='__main__': unittest.main()
