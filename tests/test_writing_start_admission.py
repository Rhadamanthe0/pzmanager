"""WORLD start admission: disposable state, mocked bus and real Linux flock/SCM_RIGHTS."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'data/scripts/internal/writing_start_admission.py'
sys.path.insert(0, str(HELPER.parent))
spec = importlib.util.spec_from_file_location('writing_admission_tested', HELPER)
admission = importlib.util.module_from_spec(spec); spec.loader.exec_module(admission)


class StartAdmission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pz-writing-admission-')
        self.root = Path(self.tmp.name)
        self.private = self.root / 'runtime'; self.private.mkdir(mode=0o700)
        self.lock = self.private / 'world.lock'
        self.state = self.root / 'state.json'
        self.bin = self.root / 'bin'; self.bin.mkdir()
        mock = self.bin / 'systemctl'
        mock.write_text('#!' + sys.executable + '\nimport os,json\n'
                        'd=json.load(open(os.environ["WRITING_TEST_STATE"]))\n'
                        'for k,v in d.items(): print(k+"="+str(v))\n')
        mock.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        WRITING_TEST_STATE=str(self.state))
        self.processes = []
        self.original_marker = None
        self.set_state('inactive', 'dead', 0, 0)

    def tearDown(self):
        # Stop only the broker created by this fixture; marker tampering never selects a PID.
        if self.original_marker:
            pid = self.original_marker['broker']
            if admission.live(pid, self.original_marker['broker_birth']):
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
        self.tmp.cleanup()

    def set_state(self, active, sub, main, control):
        self.state.write_text(json.dumps(dict(ActiveState=active, SubState=sub,
                                             MainPID=main, ControlPID=control)))

    def invoke(self, *args):
        return subprocess.run([sys.executable, str(HELPER), *map(str,args)],
                              env=self.env, capture_output=True, text=True, timeout=8)

    def wait_file(self, path, process=None):
        deadline=time.monotonic()+5
        while not path.exists():
            if process and process.poll() is not None:
                self.fail('Fixture exited early: '+str(process.returncode))
            if time.monotonic()>deadline: self.fail('Fixture timeout: '+path.name)
            time.sleep(.02)

    def busy(self):
        with open(self.lock, 'rb') as stream:
            try: fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: return True
            return False

    def prepare_owner(self):
        ready=self.root/'owner-ready'; release=self.root/'owner-release'
        script='''set -euo pipefail
exec 201>"$1"
chmod 600 "$1"
flock -n 201
"$2" "$3" prepare --lock-path "$1" --pid "$$" --fd 201 --unit probe.service > "$4"
touch "$5"
while [[ ! -f "$6" ]]; do sleep .02; done
"$2" "$3" clear --lock-path "$1" --token "$(cat "$4")"
'''
        with open(self.root/'owner.stderr','w') as error_stream:
            process=subprocess.Popen(['/bin/bash','-c',script,'bash',str(self.lock),sys.executable,
                 str(HELPER),str(self.root/'token'),str(ready),str(release)],env=self.env,
                 stdout=subprocess.DEVNULL,stderr=error_stream)
        self.processes.append(process);self.wait_file(ready,process)
        self.original_marker=json.loads((self.private/admission.MARKER).read_text())
        return process,release

    def test_inactive_offline_command_runs_with_real_world_fd(self):
        done=self.root/'done'
        code='import os,pathlib,sys; sys.path.insert(0,'+repr(str(HELPER.parent))+'); from writing_start_admission import validate_worker_admission; fd=validate_worker_admission(); pathlib.Path(os.environ["WRITING_TEST_DONE"]).write_text(str(fd)); os.fstat(fd)'
        self.env['WRITING_TEST_DONE']=str(done)
        result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--',sys.executable,'-c',code)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(done.read_text().isdigit())
        self.assertFalse(self.busy())

    def test_worker_cannot_claim_an_uninherited_world_fd(self):
        self.lock.touch(mode=0o600)
        self.env.update(PZ_WORLD_LOCK_FD='999999', PZ_WORLD_LOCK_DEPTH='1',
                        PZ_WORLD_LOCK_FILE=str(self.lock), PZ_SERVICE_NAME='probe.service')
        code='import sys; sys.path.insert(0,'+repr(str(HELPER.parent))+'); from writing_start_admission import validate_worker_admission; validate_worker_admission()'
        result=subprocess.run([sys.executable,'-c',code],env=self.env,
                              capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.busy())

    def test_direct_worker_rejects_hardlinked_world_with_real_locked_fd(self):
        self.lock.touch(mode=0o600)
        extra=self.private/'same-inode.lock';os.link(self.lock,extra)
        done=self.root/'worker-mutated'
        code='import sys; from pathlib import Path; sys.path.insert(0,'+repr(str(HELPER.parent))+'); from writing_start_admission import validate_worker_admission; validate_worker_admission(); Path('+repr(str(done))+').touch()'
        with open(self.lock,'rb') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            identity=(os.fstat(stream.fileno()).st_dev,os.fstat(stream.fileno()).st_ino)
            env=dict(self.env,PZ_WORLD_LOCK_FD=str(stream.fileno()),PZ_WORLD_LOCK_DEPTH='1',
                     PZ_WORLD_LOCK_FILE=str(self.lock),PZ_SERVICE_NAME='probe.service')
            result=subprocess.run([sys.executable,'-c',code],env=env,pass_fds=(stream.fileno(),),
                                  capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Untrusted WORLD lock file',result.stderr)
            self.assertFalse(done.exists());self.assertTrue(self.busy())
            self.assertEqual((self.lock.stat().st_dev,self.lock.stat().st_ino),identity)
            extra.unlink()
            result=subprocess.run([sys.executable,'-c',code],env=env,pass_fds=(stream.fileno(),),
                                  capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(done.exists());self.assertTrue(self.busy())

    def test_bus_error_refuses_before_command(self):
        (self.bin/'systemctl').write_text('#!/bin/sh\necho "Failed to connect to bus" >&2\nexit 1\n')
        done=self.root/'forbidden'
        result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--',
                           sys.executable,'-c',f'from pathlib import Path; Path({str(done)!r}).touch()')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(done.exists())

    def test_active_and_unrelated_start_pre_are_refused_before_command(self):
        for state in [('active','running',1234,0),('activating','start-pre',1234,os.getpid()),
                      ('activating','start-pre',0,999999999),('inactive','dead',0,1234)]:
            with self.subTest(state=state):
                self.set_state(*state)
                done=self.root/'forbidden'
                done.unlink(missing_ok=True)
                result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--',
                                   sys.executable,'-c',f'from pathlib import Path; Path({str(done)!r}).touch()')
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(done.exists())

    def test_inactive_scope_cannot_bypass_live_world_lock(self):
        owner,release=self.prepare_owner()
        self.assertTrue(self.busy())
        result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--','/bin/true')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('world operation',result.stderr)
        release.touch();self.assertEqual(owner.wait(timeout=5),0,(self.root/'owner.stderr').read_text())
        self.assertFalse(self.busy())

    def test_scm_rights_handoff_survives_owner_sigkill_until_worker_exit(self):
        owner,_=self.prepare_owner()
        # Existing CLI uses the same live inode, historically 0664 under umask002.
        self.lock.chmod(0o664)
        lock_identity=(self.lock.stat().st_dev,self.lock.stat().st_ino)
        activated=self.root/'activate';started=self.root/'worker-started';release=self.root/'worker-release'
        self.env.update(WRITING_TEST_STARTED=str(started),WRITING_TEST_RELEASE=str(release),
                        WRITING_TEST_ACTIVATE=str(activated))
        worker_code='''import os,pathlib,time
fd=int(os.environ['PZ_WORLD_LOCK_FD']);os.fstat(fd)
pathlib.Path(os.environ['WRITING_TEST_STARTED']).touch()
while not pathlib.Path(os.environ['WRITING_TEST_RELEASE']).exists(): time.sleep(.02)
'''
        args=[sys.executable,str(HELPER),'run','--lock-path',str(self.lock),'--unit','probe.service',
              '--',sys.executable,'-c',worker_code]
        launcher='import os,pathlib,time,sys\np=pathlib.Path(os.environ["WRITING_TEST_ACTIVATE"])\nwhile not p.exists(): time.sleep(.01)\nos.execv(sys.executable,sys.argv[1:])'
        worker=subprocess.Popen([sys.executable,'-c',launcher,*args],env=self.env,
                                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.processes.append(worker)
        self.set_state('activating','start-pre',0,worker.pid);activated.touch()
        self.wait_file(started,worker)
        self.assertEqual(stat.S_IMODE(self.lock.stat().st_mode),0o600)
        self.assertEqual((self.lock.stat().st_dev,self.lock.stat().st_ino),lock_identity)
        self.assertTrue(self.busy())
        owner.kill();owner.wait(timeout=3)
        self.assertTrue(self.busy(),'WORLD disappeared while the offline worker was still alive')
        release.touch();self.assertEqual(worker.wait(timeout=5),0)
        self.assertFalse(self.busy())

    def test_offline_or_boot_secures_existing_or_new_lock_under_umask002(self):
        for existing in [False,True]:
            for startup in [False,True]:
                with self.subTest(existing=existing,startup=startup):
                    self.lock.unlink(missing_ok=True)
                    if existing:
                        self.lock.touch();self.lock.chmod(0o664)
                        identity=(self.lock.stat().st_dev,self.lock.stat().st_ino)
                    else:identity=None
                    if startup:
                        (self.bin/'systemctl').write_text('#!'+sys.executable+'\nimport os\n'
                            'print("ActiveState=activating\\nSubState=start-pre\\nMainPID=0\\nControlPID="+str(os.getppid()))\n')
                    else:
                        (self.bin/'systemctl').write_text('#!'+sys.executable+'\n'
                            'print("ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0")\n')
                    code='import os,sys,stat; sys.path.insert(0,'+repr(str(HELPER.parent))+'); from writing_start_admission import validate_worker_admission; fd=validate_worker_admission(); assert stat.S_IMODE(os.fstat(fd).st_mode)==0o600'
                    result=subprocess.run([sys.executable,str(HELPER),'run','--lock-path',str(self.lock),
                        '--unit','probe.service','--',sys.executable,'-c',code],env=self.env,
                        capture_output=True,text=True,timeout=8,preexec_fn=lambda:os.umask(0o002))
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertEqual(stat.S_IMODE(self.lock.stat().st_mode),0o600)
                    if identity:self.assertEqual((self.lock.stat().st_dev,self.lock.stat().st_ino),identity)
                    self.assertFalse(self.busy())

    def test_untrusted_world_file_or_parent_is_rejected_before_chmod(self):
        self.lock.touch(mode=0o664);self.lock.chmod(0o664)
        original_stat=os.fstat;identity=self.lock.stat().st_ino
        def foreign_file(fd):
            info=original_stat(fd)
            if info.st_ino==identity:
                return SimpleNamespace(st_uid=os.getuid()+1,st_mode=info.st_mode,st_nlink=info.st_nlink)
            return info
        args=SimpleNamespace(lock_path=str(self.lock),unit='probe.service',command=['/bin/true'])
        with patch.object(admission,'unit_state',return_value=dict(ActiveState='inactive',SubState='dead',MainPID=0,ControlPID=0)),\
             patch.object(admission.os,'fstat',side_effect=foreign_file),patch.object(admission.os,'fchmod') as chmod:
            with self.assertRaises(admission.ConfigurationError):admission.run(args)
            chmod.assert_not_called()
        outside=self.root/'outside-lock';outside.write_text('preserved');outside.chmod(0o664)
        self.lock.unlink();self.lock.symlink_to(outside)
        result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--','/bin/true')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(outside.read_text(),'preserved');self.assertEqual(stat.S_IMODE(outside.stat().st_mode),0o664)
        self.lock.unlink();self.private.rmdir();self.private.symlink_to(self.root)
        result=self.invoke('run','--lock-path',self.lock,'--unit','probe.service','--','/bin/true')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'world.lock').exists())

    def test_forged_owner_birth_fd_inode_broker_and_unit_are_refused(self):
        owner,release=self.prepare_owner();info=self.lock.stat();data=self.original_marker
        admission.validate_marker(data,info,'probe.service')
        replacements={'pid':1,'birth':data['birth']+1,'fd':999999,'dev':data['dev']+1,
                      'ino':data['ino']+1,'broker':1,'broker_birth':data['broker_birth']+1,
                      'unit':'other.service'}
        for key,value in replacements.items():
            with self.subTest(field=key):
                forged=dict(data,**{key:value})
                with self.assertRaises((admission.ConfigurationError,OSError)):
                    admission.validate_marker(forged,info,'probe.service')
        release.touch();self.assertEqual(owner.wait(timeout=5),0,(self.root/'owner.stderr').read_text())

    def test_marker_symlink_and_public_permissions_are_refused(self):
        owner,release=self.prepare_owner();marker=self.private/admission.MARKER
        original=marker.read_bytes();outside=self.root/'outside';outside.write_bytes(original)
        marker.unlink();marker.symlink_to(outside)
        directory_fd=os.open(self.private,os.O_RDONLY|os.O_DIRECTORY)
        try:
            with self.assertRaises(OSError): admission.read_marker(directory_fd)
            marker.unlink();marker.write_bytes(original);marker.chmod(0o644)
            with self.assertRaises(admission.ConfigurationError): admission.read_marker(directory_fd)
        finally:os.close(directory_fd)
        self.assertEqual(outside.read_bytes(),original)
        marker.chmod(0o600);release.touch();self.assertEqual(owner.wait(timeout=5),0,(self.root/'owner.stderr').read_text())


if __name__ == '__main__': unittest.main()
