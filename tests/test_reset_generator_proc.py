"""Real procfs disappearance while stopping a private generator session."""
import errno
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(os.environ['PZ_TEST_ROOT'])
HELPER=ROOT/'data/scripts/lib/reset_generator.py'
spec=importlib.util.spec_from_file_location('reset_generator_tested',HELPER)
generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)

class GeneratorProc(unittest.TestCase):
    def test_nonmember_reaped_after_proc_open_does_not_abort_real_stop(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temporary:
            base=Path(temporary);metadata=base/'identity.json';cachedir=str(base/'stage')
            anchor=subprocess.Popen(['python3',str(HELPER),'launch','--metadata',str(metadata),'-cachedir='+cachedir,'--','/bin/sleep','60'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            victim=subprocess.Popen(['/bin/sleep','60'])
            args=SimpleNamespace(pid=anchor.pid,metadata=str(metadata),cachedir=cachedir)
            observed=[];original=Path.read_text
            try:
                deadline=time.monotonic()+5
                while not metadata.exists() and anchor.poll() is None and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(metadata.exists(),'private generator never published identity')
                generator.identity(args)
                target=Path('/proc')/str(victim.pid)/'stat'
                self.assertNotEqual(generator.process(victim.pid)['sid'],anchor.pid)
                def disappearing(path,*a,**kw):
                    if path==target and victim.poll() is None:
                        fd=os.open(path,os.O_RDONLY)
                        try:
                            victim.kill();victim.wait()
                            try:return os.read(fd,65536).decode()
                            except OSError as error:
                                observed.append(error.errno)
                                raise
                        finally:os.close(fd)
                    return original(path,*a,**kw)
                with patch.object(Path,'read_text',disappearing):
                    self.assertEqual(generator.stop(args),0)
                self.assertEqual(observed,[errno.ESRCH])
                anchor.wait(timeout=5)
                self.assertIsNotNone(anchor.returncode)
            finally:
                if victim.poll() is None:victim.kill()
                victim.wait()
                if anchor.poll() is None:
                    generator.stop(args)
                anchor.wait(timeout=5)
    def test_direct_identity_and_permission_errors_stay_fail_closed(self):
        with patch.object(generator,'process',side_effect=PermissionError(errno.EACCES,'fixture')):
            with self.assertRaises(PermissionError):generator.members(dict(sid=-1,pgid=-1))

if __name__=='__main__':unittest.main()
