"""Crash admission and durable intent on real private Linux files."""
import json
import contextlib
import io
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'data/scripts/lib'),str(ROOT/'data/scripts/internal')]
import world_transaction as txn
import writing_start_admission as admission

class WorldTransaction(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.world=self.root/'Zomboid';self.world.mkdir()
        self.recovery=self.root/'recovery';self.recovery.mkdir()
        (self.world/'a').write_bytes(b'old-a');(self.world/'b').write_bytes(b'old-b')
        self.files=[dict(path=n,before=txn.digest(self.world/n),after=__import__('hashlib').sha256(('new-'+n).encode()).hexdigest()) for n in ('a','b')]
    def begin(self):return txn.begin(self.world,'test',self.recovery,self.files)
    def test_check_is_read_only_and_no_compiler_needed(self):
        txn.check_clean(self.world);self.assertFalse(txn.location(self.world)[1].exists())
    def test_actual_sigkill_leaves_pending_and_admission_refuses_before_work(self):
        child=os.fork()
        if child==0:
            self.begin();(self.world/'a').write_bytes(b'new-a');os.kill(os.getpid(),signal.SIGKILL)
        _,status=os.waitpid(child,0);self.assertTrue(os.WIFSIGNALED(status))
        with self.assertRaisesRegex(ValueError,'unfinished'):txn.check_clean(self.world)
        with patch.dict(os.environ,PZ_SOURCE_DIR=str(self.world)),patch.object(admission,'unit_state',side_effect=AssertionError('must reject before running work')):
            with self.assertRaisesRegex(ValueError,'unfinished'):admission.run(None)
        self.assertEqual((self.world/'a').read_bytes(),b'new-a');self.assertEqual((self.world/'b').read_bytes(),b'old-b')
    def test_false_completion_and_wrong_recovery_are_refused(self):
        token=self.begin()
        with self.assertRaises(ValueError):txn.finish(self.world,token,'complete')
        with self.assertRaises(ValueError):txn.pending_for(self.world,self.root/'other')
        with self.assertRaises(ValueError):txn.check_clean(self.world)
        txn.finish(self.world,token,'reverted');txn.check_clean(self.world)
    def test_success_requires_all_files_and_retains_record(self):
        token=self.begin()
        for n in ('a','b'):(self.world/n).write_bytes(('new-'+n).encode())
        txn.finish(self.world,token,'complete');txn.check_clean(self.world)
        self.assertEqual(json.loads((txn.location(self.world)[1]/(token+'.json')).read_text())['state'],'complete')
    def test_durability_failure_keeps_gate_closed(self):
        token=self.begin()
        with patch.object(txn.os,'fsync',side_effect=OSError('storage error')):
            with self.assertRaises(OSError):txn.finish(self.world,token,'reverted')
        with self.assertRaises(ValueError):txn.check_clean(self.world)

    def test_targeted_file_sync_persists_only_selected_content_and_rejects_escape(self):
        synced=[];original=txn.os.fsync
        def sync(fd):
            synced.append(os.readlink('/proc/self/fd/'+str(fd)));original(fd)
        def command(name):
            with patch.object(sys,'argv',['world_transaction.py','sync','--world',str(self.world),'--file',name]),contextlib.redirect_stderr(io.StringIO()):
                return txn.main()
        with patch.object(txn.os,'fsync',sync):
            self.assertEqual(command('a'),0)
        self.assertIn(str(self.world/'a'),synced)
        self.assertIn(str(self.world),synced)
        self.assertNotIn(str(self.world/'b'),synced)
        (self.world/'linked').symlink_to(self.recovery,target_is_directory=True)
        (self.recovery/'outside').write_bytes(b'outside')
        for name in ('../recovery/outside',str(self.recovery/'outside'),'linked/outside','missing'):
            with self.subTest(name=name):self.assertNotEqual(command(name),0)
    def test_symlink_and_public_state_directory_refused(self):
        state=txn.location(self.world)[1];state.symlink_to(self.recovery)
        with self.assertRaises((OSError,ValueError)):self.begin()
        state.unlink();state.mkdir();state.chmod(0o755)
        with self.assertRaises((OSError,ValueError)):self.begin()
    def test_corrupted_record_cannot_escape_world_or_open_gate(self):
        token=self.begin();path=txn.location(self.world)[1]/(token+'.json')
        record=json.loads(path.read_text());record['files'][0]['path']='../outside'
        path.write_text(json.dumps(record));path.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'Invalid transaction path'):txn.check_clean(self.world)
        with self.assertRaisesRegex(ValueError,'Invalid transaction path'):txn.finish(self.world,token,'reverted')
        self.assertFalse((self.root/'outside').exists())

    def test_absent_nested_paths_can_complete_and_revert(self):
        plan=[dict(path='missing/cache/file',before=None,after=None)]
        token=txn.begin(self.world,'zone',self.recovery,plan)
        txn.finish(self.world,token,'complete');txn.check_clean(self.world)
        self.assertFalse((self.world/'missing').exists())
    def test_tree_plan_survives_world_directory_missing(self):
        after=self.root/'staged';after.mkdir();(after/'new').write_bytes(b'new')
        token=txn.begin(self.world,'full',self.recovery,after_tree=after)
        self.world.rename(self.root/'OLD')
        with self.assertRaisesRegex(ValueError,'unfinished'):txn.check_clean(self.world)
        after.rename(self.world);txn.finish(self.world,token,'complete');txn.check_clean(self.world)
    def test_revert_can_verify_originally_absent_world(self):
        absent=self.root/'not-created';staged=self.root/'staged';staged.mkdir()
        (staged/'a').write_bytes(b'new')
        token=txn.begin(absent,'full',self.recovery,after_tree=staged)
        txn.finish(absent,token,'reverted');txn.check_clean(absent)
        self.assertFalse(absent.exists())

    def test_directory_plan_binds_selected_tree_and_preserves_other_data(self):
        import shutil
        (self.world/'Saves').mkdir();(self.world/'Saves/old').write_bytes(b'old')
        staged=self.root/'staged';(staged/'Saves').mkdir(parents=True);(staged/'Saves/new').write_bytes(b'new')
        token=txn.begin(self.world,'full',self.recovery,after_tree=staged,trees=['Saves'])
        with self.assertRaises(ValueError):txn.finish(self.world,token,'complete')
        (self.world/'Saves').rename(self.recovery/'Saves');(staged/'Saves').rename(self.world/'Saves')
        txn.finish(self.world,token,'complete');txn.check_clean(self.world)
        self.assertEqual((self.world/'a').read_bytes(),b'old-a')
        self.assertEqual((self.recovery/'Saves/old').read_bytes(),b'old')

    def test_dangling_selected_root_cannot_complete_absent_reversion(self):
        staged=self.root/'staged';(staged/'Lua').mkdir(parents=True)
        token=txn.begin(self.world,'full',self.recovery,after_tree=staged,trees=['Lua'])
        (self.world/'Lua').symlink_to(self.root/'absent-target',target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'symlink'):
            txn.finish(self.world,token,'reverted')
        record=json.loads((txn.location(self.world)[1]/(token+'.json')).read_text())
        self.assertEqual(record['state'],'prepared')
        with self.assertRaisesRegex(ValueError,'unfinished'):txn.check_clean(self.world)

    def test_internal_symlinks_remain_part_of_tree_fingerprint(self):
        directory=self.world/'Lua';directory.mkdir()
        link=directory/'cache';link.symlink_to(self.root/'absent-target')
        before=txn.tree_digest(directory)
        link.unlink();link.symlink_to(self.root/'another-target')
        self.assertNotEqual(txn.tree_digest(directory),before)

    def test_directory_plan_refuses_unplanned_paths_and_mixed_record(self):
        for paths in (['../escape'],['Saves','Saves'],[],['Logs']):
            with self.subTest(paths=paths):
                with self.assertRaises(ValueError):txn.begin(self.world,'full',self.recovery,after_tree=self.root,trees=paths)
        token=self.begin();path=txn.location(self.world)[1]/(token+'.json')
        record=json.loads(path.read_text());record['trees']={'Saves':{'before':None,'after':None}}
        path.write_text(json.dumps(record));path.chmod(0o600)
        with self.assertRaises(ValueError):txn.check_clean(self.world)

    def test_directory_plan_refuses_changed_image_and_sync_failure(self):
        staged=self.root/'staged';(staged/'Lua').mkdir(parents=True);(staged/'Lua/roles').write_bytes(b'new')
        token=txn.begin(self.world,'full',self.recovery,after_tree=staged,trees=['Lua'])
        (staged/'Lua').rename(self.world/'Lua');(self.world/'Lua/roles').write_bytes(b'changed')
        with self.assertRaises(ValueError):txn.finish(self.world,token,'complete')
        (self.world/'Lua/roles').write_bytes(b'new')
        with patch.object(txn.os,'fsync',side_effect=OSError('disk error')):
            with self.assertRaises(OSError):txn.finish(self.world,token,'complete')
        with self.assertRaises(ValueError):txn.check_clean(self.world)
        txn.finish(self.world,token,'complete');txn.check_clean(self.world)


if __name__=='__main__':unittest.main()
