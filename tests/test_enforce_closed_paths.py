"""Real startup admission must never edit an INI through a restored link."""
from pathlib import Path
import json
import os
import shutil
import stat
import subprocess
from unittest.mock import patch
import unittest
import test_writing_start_admission as fixtures
import enforceClosedServer as editor


def snapshot(root):
    if root.is_symlink():return {'':('link',os.readlink(root))}
    result={}
    for base,dirs,files in os.walk(root,followlinks=False):
        for name in dirs+files:
            path=Path(base)/name;info=path.lstat()
            result[str(path.relative_to(root))]=('link',os.readlink(path)) if stat.S_ISLNK(info.st_mode) else ('directory',) if stat.S_ISDIR(info.st_mode) else ('file',path.read_bytes())
    return result


class ClosedPaths(unittest.TestCase):
    def setUp(self):
        self.case=fixtures.StartAdmission();self.case.setUp();self.addCleanup(self.case.tearDown)
        self.repo,self.world,self.ini=self.case.closure_fixture()
        self.outside=self.case.root/'outside';self.outside.mkdir()
        self.target=self.outside/'private.ini';self.target.write_bytes(b'private-setting=original\n')
    def invoke(self,name='enforceClosedServer.sh',*args):
        return subprocess.run(['bash',str(self.repo/'data/scripts/internal'/name),*args],env=self.case.env,capture_output=True,text=True,timeout=12)
    def rejected_unchanged(self):
        before=snapshot(self.world);outside=snapshot(self.outside)
        info=self.target.stat() if self.target.exists() else None
        result=self.invoke()
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(snapshot(self.world),before)
        self.assertEqual(snapshot(self.outside),outside)
        if info:
            current=self.target.stat()
            self.assertEqual((current.st_mode,current.st_mtime_ns,current.st_ctime_ns,current.st_nlink),(info.st_mode,info.st_mtime_ns,info.st_ctime_ns,info.st_nlink))
    def test_server_directory_link_refused_before_external_write(self):
        shutil.rmtree(self.world/'Server');self.target.rename(self.outside/'servertest.ini')
        (self.world/'Server').symlink_to(self.outside,target_is_directory=True)
        self.rejected_unchanged()
    def test_ini_link_refused_before_external_write(self):
        self.ini.unlink();self.ini.symlink_to(self.target)
        self.rejected_unchanged()
    def test_dangling_ini_link_does_not_create_external_target(self):
        self.target.unlink();self.ini.unlink();self.ini.symlink_to(self.target)
        self.rejected_unchanged()
        self.assertFalse(self.target.exists())
    def test_hardlinked_ini_refused_without_changing_external_metadata(self):
        self.ini.unlink();os.link(self.target,self.ini)
        self.rejected_unchanged()
    def test_world_root_link_refused(self):
        original=self.case.root/'relocated-world';self.world.rename(original)
        self.world.symlink_to(original,target_is_directory=True)
        before=snapshot(original);self.rejected_unchanged()
        self.assertEqual(snapshot(original),before)
    def test_old_independent_ini_setting_refuses_without_changing_either_file(self):
        import shlex
        with (self.repo/'.env').open('a') as stream:stream.write('PZ_INI_PATH='+shlex.quote(str(self.target))+'\n')
        before=snapshot(self.world)
        result=self.invoke()
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PZ_INI_PATH',result.stderr)
        self.assertEqual(self.target.read_bytes(),b'private-setting=original\n')
        self.assertEqual(snapshot(self.world),before)
    def test_explicit_override_link_still_refused(self):
        import shlex
        alias=self.outside/'alias.ini';alias.symlink_to(self.target)
        with (self.repo/'.env').open('a') as stream:stream.write('PZ_INI_PATH='+shlex.quote(str(alias))+'\n')
        self.rejected_unchanged()
    def test_explicit_override_parent_link_is_refused(self):
        import shlex
        alias=self.case.root/'alias-dir';alias.symlink_to(self.outside,target_is_directory=True)
        with (self.repo/'.env').open('a') as stream:stream.write('PZ_INI_PATH='+shlex.quote(str(alias/self.target.name))+'\n')
        self.rejected_unchanged()
    def test_refused_bus_preserves_ini_and_external_files(self):
        command=self.case.bin/'systemctl';command.write_text('#!/bin/sh\nexit 1\n')
        self.rejected_unchanged()
    def test_missing_key_after_unterminated_line_remains_a_separate_native_key(self):
        self.ini.write_bytes(b'Password=secret')
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.ini.read_bytes(),b'Password=secret\nOpen=false\n')
    def test_fresh_missing_world_is_seeded_through_owned_directories(self):
        shutil.rmtree(self.world)
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.ini.read_bytes(),b'Open=false\n')
        self.assertEqual(stat.S_IMODE(self.ini.stat().st_mode),0o600)
    def test_all_native_trimmed_keys_preserve_other_bytes_and_line_endings(self):
        self.ini.write_bytes(b'# Open=true\r\nPassword=\xffkeep\r\n\vOpen\f= true\r\nOpen=false\n Name = keep\nOpen=true')
        self.ini.chmod(0o640)
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.ini.read_bytes(),b'# Open=true\r\nPassword=\xffkeep\r\nOpen=false\r\nOpen=false\n Name = keep\nOpen=false')
        self.assertEqual(stat.S_IMODE(self.ini.stat().st_mode),0o640)
    def test_already_closed_keeps_inode_and_timestamps(self):
        self.ini.write_bytes(b'Open=false\r\nPassword=secret\n');os.utime(self.ini,(1800,1800))
        before=self.ini.stat();data=self.ini.read_bytes()
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        after=self.ini.stat()
        self.assertEqual((after.st_ino,after.st_mtime_ns,after.st_ctime_ns),(before.st_ino,before.st_mtime_ns,before.st_ctime_ns))
        self.assertEqual(self.ini.read_bytes(),data)
    def test_atomic_staging_fsync_failure_leaves_original_and_no_temporary(self):
        before=snapshot(self.world);info=self.ini.stat()
        with patch.object(editor.os,'fsync',side_effect=OSError('fixture storage failure')):
            with self.assertRaisesRegex(OSError,'storage failure'):editor.close_ini(self.ini)
        self.assertEqual(snapshot(self.world),before)
        self.assertEqual(self.ini.stat().st_mtime_ns,info.st_mtime_ns)
    def test_already_closed_leaf_change_is_not_reported_safe(self):
        self.ini.write_bytes(b'Open=false\n')
        transform=editor.closed_content
        def changed(data):
            self.ini.write_bytes(b'Open=true\n')
            return transform(data)
        with patch.object(editor,'closed_content',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'changed before publication'):editor.close_ini(self.ini)
        self.assertEqual(self.ini.read_bytes(),b'Open=true\n')
    def test_changed_leaf_before_publication_is_not_overwritten(self):
        transform=editor.closed_content
        def changed(data):
            self.ini.write_bytes(b'Open=true\nPassword=concurrent\n')
            return transform(data)
        with patch.object(editor,'closed_content',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'changed before publication'):editor.close_ini(self.ini)
        self.assertEqual(self.ini.read_bytes(),b'Open=true\nPassword=concurrent\n')

    def test_restore_link_then_startup_refuses_without_altering_recovery_bytes(self):
        backup=self.case.root/'backup';(backup/'Saves/Multiplayer/servertest').mkdir(parents=True)
        (backup/'Saves/Multiplayer/servertest/sentinel').write_bytes(b'offline fixture')
        (backup/'Server').mkdir();(backup/'Server/servertest.ini').symlink_to(self.target)
        restored=subprocess.run(['bash',str(self.repo/'data/scripts/backup/restoreZomboidData.sh'),str(backup)],env=self.case.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(restored.returncode,0,restored.stdout+restored.stderr)
        self.assertTrue(self.ini.is_symlink())
        journal=self.world.parent/('.'+self.world.name+'.pzm-transactions')
        records={p.name:p.read_bytes() for p in journal.iterdir()}
        self.assertTrue(all(json.loads(data)['state']=='complete' for data in records.values()))
        before=snapshot(self.world);outside=snapshot(self.outside)
        result=self.invoke('prepareWorldStart.sh')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(snapshot(self.world),before);self.assertEqual(snapshot(self.outside),outside)
        self.assertEqual({p.name:p.read_bytes() for p in journal.iterdir()},records)
        self.assertNotIn('ProjectWriting restart cleanup policy:',result.stdout)


if __name__=='__main__':unittest.main()
