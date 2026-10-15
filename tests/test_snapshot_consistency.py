"""Offline provenance is distinct from copy success; all inputs are private."""
import contextlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'data/scripts/lib'))
import snapshot_consistency as snapshot

class SnapshotConsistency(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.stage=self.root/'stage';self.stage.mkdir()
        with contextlib.closing(sqlite3.connect(self.stage/'players.db')) as db:
            db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');db.commit()
        self.stopped=dict(ok=True,LoadState='loaded',ActiveState='inactive',SubState='dead',MainPID='0',ControlPID='0',InvocationID='old',unit='fixture.service')
    def test_stopped_valid_sqlite_can_be_certified(self):
        self.assertEqual(snapshot.write(self.stage,self.stopped,self.stopped,True),'stopped')
        self.assertEqual(json.loads((self.stage/snapshot.NAME).read_text())['consistency'],'stopped')
    def test_active_error_unknown_and_changed_invocation_refused_when_required(self):
        for change in [dict(ActiveState='active',MainPID='123'),dict(ok=False),dict(MainPID=''),dict(InvocationID='new')]:
            with self.subTest(change=change):
                with self.assertRaises(ValueError):snapshot.write(self.stage,self.stopped,dict(self.stopped,**change),True)
                self.assertFalse((self.stage/snapshot.NAME).exists())
    def test_hot_copy_explicitly_reports_best_effort(self):
        active=dict(self.stopped,ActiveState='active',MainPID='123')
        self.assertEqual(snapshot.write(self.stage,active,active),'best-effort')
    def test_unavailable_probe_preserves_normal_best_effort_copy(self):
        with patch.object(snapshot.subprocess,'run',side_effect=subprocess.TimeoutExpired('fixture',10)):
            unknown=snapshot.probe('fixture.service')
        self.assertFalse(snapshot.stopped(unknown))
        with self.assertRaises(ValueError):snapshot.write(self.stage,unknown,unknown,True)
        self.assertFalse((self.stage/snapshot.NAME).exists())
        self.assertEqual(snapshot.write(self.stage,unknown,unknown),'best-effort')
    def test_sidecars_and_broken_sqlite_never_certified(self):
        for kind in ['wal','corrupt']:
            with self.subTest(kind=kind):
                wal=self.stage/'players.db-wal'
                if kind=='wal':wal.write_bytes(b'uncommitted')
                else:wal.unlink();(self.stage/'players.db').write_bytes(b'broken')
                with self.assertRaises(ValueError):snapshot.write(self.stage,self.stopped,self.stopped,True)
                self.assertFalse((self.stage/snapshot.NAME).exists())
    def test_metadata_symlink_not_followed(self):
        target=self.root/'unrelated';target.write_text('preserve')
        (self.stage/snapshot.NAME).symlink_to(target)
        with self.assertRaises((OSError,ValueError)):snapshot.write(self.stage,self.stopped,self.stopped,True)
        self.assertEqual(target.read_text(),'preserve')
    def test_failed_sync_never_reports_success(self):
        with patch.object(snapshot.os,'fsync',side_effect=OSError('disk')):
            with self.assertRaises(OSError):snapshot.write(self.stage,self.stopped,self.stopped,True)

if __name__=='__main__':unittest.main()
