"""Character restores use the real admission and never mutate a live alias."""
import os
from pathlib import Path
import shlex
import shutil
import stat
import unittest

import test_character_data_safety as fixtures

ROOT=Path(os.environ['PZ_TEST_ROOT'])


def fingerprint(path):
    info=path.stat()
    return path.read_bytes(),info.st_mode,info.st_uid,info.st_gid,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_nlink


class CharacterPaths(unittest.TestCase):
    def setUp(self):
        self.case=fixtures.CharacterDataSafety();self.case.setUp();self.addCleanup(self.case.doCleanups)
        self.case.database(self.case.source);self.case.database(self.case.live)
        with fixtures.connection(self.case.source) as db:
            db.execute("UPDATE networkPlayers SET data=x'010203' WHERE username='selected'")
        scripts=self.case.script.parent.parent
        shutil.copytree(ROOT/'data/scripts',scripts,dirs_exist_ok=True)
        self.native_marker=self.case.root/'native-called'
        # Opaque synthetic blobs: only the native engine boundary is replaced.
        (scripts/'lib/character_preflight.py').write_text('import os,sys\nfrom pathlib import Path\nPath(os.environ["CHARACTER_NATIVE_MARKER"]).touch()\nsys.exit(int(os.environ.get("CHARACTER_NATIVE_DOUBLE_FAILURE","0")))\n')
        manager=scripts.parents[1]
        values=dict(PZ_SOURCE_DIR=str(self.case.root/'live'),PZ_HOME=str(self.case.root),PZ_SERVER_NAME='test',BACKUP_DIR=str(self.case.root/'backups'))
        (manager/'.env').write_text('\n'.join(k+'='+shlex.quote(v) for k,v in values.items())+'\n')
        runtime=self.case.root/'runtime';runtime.mkdir(mode=0o700)
        binary=self.case.root/'bin';binary.mkdir()
        control=binary/'systemctl'
        control.write_text('''#!/bin/bash
if [[ " $* " == *" is-active "* ]]; then exit 3; fi
printf '%s\n' LoadState=loaded ActiveState=inactive SubState=dead MainPID=0 ControlPID=0 Result=success InvocationID=fixture
''');control.chmod(0o700)
        self.case.env.update(PATH=str(binary)+':'+os.environ['PATH'],XDG_RUNTIME_DIR=str(runtime),CHARACTER_NATIVE_MARKER=str(self.native_marker))

    def rejected_unchanged(self,target,*args):
        before=fingerprint(target);source=fingerprint(self.case.source)
        result=self.case.run_restore(*args)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(fingerprint(target),before)
        self.assertEqual(fingerprint(self.case.source),source)
        self.assertFalse(self.native_marker.exists(),'unsafe target reached the native engine')

    def test_live_saves_parent_link_refused(self):
        original=self.case.root/'live/Saves';outside=self.case.root/'external-saves'
        original.rename(outside);original.symlink_to(outside,target_is_directory=True)
        self.rejected_unchanged(outside/'Multiplayer/test/players.db')

    def test_live_multiplayer_parent_link_refused(self):
        original=self.case.root/'live/Saves/Multiplayer';outside=self.case.root/'external-multiplayer'
        original.rename(outside);original.symlink_to(outside,target_is_directory=True)
        self.rejected_unchanged(outside/'test/players.db')

    def test_live_leaf_link_refused(self):
        outside=self.case.root/'external-players.db';self.case.live.rename(outside)
        self.case.live.symlink_to(outside)
        self.rejected_unchanged(outside)

    def test_live_hardlink_refused_without_external_metadata_change(self):
        outside=self.case.root/'external-players.db';self.case.live.rename(outside)
        os.link(outside,self.case.live)
        self.rejected_unchanged(outside)

    def test_live_fifo_refused_without_blocking(self):
        self.case.live.unlink();os.mkfifo(self.case.live,0o600)
        result=self.case.run_restore()
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(stat.S_ISFIFO(self.case.live.lstat().st_mode))
        self.assertFalse(self.native_marker.exists())

    def test_live_sidecars_refused_including_read_only_preview(self):
        for suffix in ('-wal','-shm','-journal'):
            for kind in ('regular','symlink','hardlink','fifo'):
                with self.subTest(suffix=suffix,kind=kind):
                    outside=self.case.root/'external-sidecar';outside.write_bytes(b'forensic sidecar')
                    sidecar=Path(str(self.case.live)+suffix)
                    if kind=='regular':sidecar.write_bytes(b'forensic sidecar')
                    elif kind=='symlink':sidecar.symlink_to(outside)
                    elif kind=='hardlink':os.link(outside,sidecar)
                    else:os.mkfifo(sidecar,0o600)
                    before=fingerprint(outside)
                    self.rejected_unchanged(self.case.live,'--dry-run')
                    self.assertEqual(fingerprint(outside),before)
                    sidecar.unlink();outside.unlink()

    def test_native_refusal_still_precedes_mutation(self):
        before=fingerprint(self.case.live);source=fingerprint(self.case.source)
        self.case.env['CHARACTER_NATIVE_DOUBLE_FAILURE']='1'
        result=self.case.run_restore()
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(self.native_marker.exists())
        self.assertIn('destination intacte',result.stderr)
        self.assertEqual(fingerprint(self.case.live),before);self.assertEqual(fingerprint(self.case.source),source)

    def test_regular_target_accepts_latest_backup_root_link_and_shared_snapshot_file(self):
        backup=self.case.root/'snapshot';world=backup/'Saves/Multiplayer/test';world.mkdir(parents=True)
        shared=self.case.root/'shared-snapshot.db';self.case.source.rename(shared)
        os.link(shared,world/'players.db')
        latest=self.case.root/'latest';latest.symlink_to(backup,target_is_directory=True)
        self.case.source=latest
        before=fingerprint(shared)
        result=self.case.run_restore()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(fingerprint(shared),before)
        self.assertTrue(self.native_marker.exists())
        with fixtures.connection(self.case.live) as db:
            self.assertEqual(db.execute("SELECT data FROM networkPlayers WHERE username='selected'").fetchone()[0],b'\x01\x02\x03')
            self.assertEqual(db.execute("SELECT data FROM networkPlayers WHERE username='outside'").fetchone()[0],b'opaque-outside')


if __name__=='__main__':unittest.main()
