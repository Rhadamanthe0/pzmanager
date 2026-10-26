"""Cleanup owner with real isolated-runner/process groups; systemctl simulated.

No native PID1 claim: all unit paths and bus transport are private fixtures.
"""
import importlib.util
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(os.environ['PZ_TEST_ROOT'])


@unittest.skipUnless(os.geteuid()==0,'root-owned cleanup fixture required')
class Cleanup(unittest.TestCase):
    def setUp(self):
        self.base=Path(tempfile.mkdtemp(prefix='ssh-cleanup-',dir='/run'))
        self.addCleanup(shutil.rmtree,self.base)
        self.run=self.base/'run';self.run.mkdir()
        self.units=self.run/'systemd/system';self.units.mkdir(parents=True)
        self.unrelated=self.units/'existing-ssh.socket';self.unrelated.write_text('pre-existing unrelated fixture')
        self.state=self.base/'state';self.state.mkdir()
        self.control=self.base/'systemctl'
        self.control.write_text('''#!/usr/bin/python3
import sys,pathlib
base=pathlib.Path('''+repr(str(self.base))+''')
units=base/'run/systemd/system';state=base/'state'
a=sys.argv[1:]
with (state/'calls').open('a') as f:f.write(repr(a)+'\\n')
verb=a[0]
if verb=='show':
 name=a[-1];prop=a[a.index('-p')+1]
 mode=(state/'after-stop').read_text() if (state/'stopped').exists() and (state/'after-stop').exists() else 'inactive'
 if mode=='bus-error':raise SystemExit('controlled state bus failure')
 if prop=='LoadState':print('unknown-load' if mode=='load-unknown' else 'loaded' if (state/name).exists() else 'not-found')
 elif prop=='ActiveState':print(mode)
 else:raise SystemExit('unexpected property')
elif verb=='daemon-reload':
 for p in units.iterdir():(state/p.name).touch()
 for p in state.iterdir():
  if p.name.endswith(('.socket','.service')) and not (units/p.name).exists():p.unlink()
elif verb=='stop':
 if (state/'fail-stop').exists():raise SystemExit('controlled stop failure')
 (state/'stopped').touch()
 if (state/'gc-stop').exists():
  for name in a[2:]:(state/name).unlink(missing_ok=True)
elif verb=='reset-failed':
 if any(not (state/name).exists() for name in a[2:]):raise SystemExit('Unit not loaded')
 if (state/'fail-reset').exists():raise SystemExit('controlled reset failure')
 (state/'after-stop').write_text('inactive')
else:raise SystemExit('unexpected '+repr(a))
''');self.control.chmod(0o700)
        self.project=self.base/'project'
        shutil.copytree(ROOT,self.project)
        subprocess.run(['git','init','-q',str(self.project)],check=True)
        subprocess.run(['git','-C',str(self.project),'add','-f','.'],check=True)
        helper=self.project/'tests/ssh_socket_supervisor.py'
        helper.write_text(helper.read_text().replace("RUN = Path('/run')",'RUN = Path('+repr(str(self.run))+')').replace("SYSTEMCTL = Path('/usr/bin/systemctl')",'SYSTEMCTL = Path('+repr(str(self.control))+')'))
        self.helper=helper
        spec=importlib.util.spec_from_file_location('supervisor',helper)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)
        self.registry=self.run/'pz-ssh-authority-ci-1-1.json'
        self.native=self.project/'tests/test_ssh_socket_activation.py'
        self.native.write_text('''import importlib.util,os,pathlib,signal,time
root=pathlib.Path(os.environ['PZ_TEST_ROOT'])
spec=importlib.util.spec_from_file_location('supervisor',root/'tests/ssh_socket_supervisor.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
p=pathlib.Path(os.environ['SSH_AUTHORITY_REGISTRY'])
s.register_test(p);s.publish(p);s.systemctl('daemon-reload')
mode=os.environ['SSH_AUTHORITY_SCENARIO']
print('CONTROLLED_'+mode.upper()+'_READY',flush=True)
if mode=='term':os.kill(os.getpid(),signal.SIGTERM)
if mode=='kill':
 if os.environ.get('FIXTURE_TIMEOUT'):
  signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)
 os.kill(os.getpid(),signal.SIGKILL)
if mode=='command-failure':raise SystemExit(1)
''')
        self.env=dict(os.environ,SSH_AUTHORITY_HOSTED_TEST='github-hosted',GITHUB_ACTIONS='true')

    def execute(self,scenario,**extra):
        return subprocess.run([sys.executable,str(self.helper),'run','--registry',str(self.registry),'--results',str(self.base/('results-'+scenario)),'--scenario',scenario],env=dict(self.env,**extra),text=True,capture_output=True,timeout=30)

    def assert_clean(self):
        self.assertFalse(self.registry.exists())
        self.assertEqual(list(self.units.iterdir()),[self.unrelated])
        self.assertEqual(self.unrelated.read_text(),'pre-existing unrelated fixture')
        self.assertEqual(list(self.run.glob('pz-ssh-authority-*')),[])
        # Unrelated files never appear in stop/reset-failed commands.
        calls=(self.state/'calls').read_text()
        self.assertNotIn('existing-ssh.socket',calls)

    def test_minimal_and_interrupted_groups_are_cleaned(self):
        for scenario in ('normal','term','kill','command-failure'):
            with self.subTest(scenario=scenario):
                result=self.execute(scenario)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assert_clean()
                self.module.cleanup(self.registry)  # idempotent after success

    def test_runner_timeout_kills_group_but_owner_cleans(self):
        # Shorten only clock constants in this private runner copy. Production
        # runner bytes are untouched; the real TERM->KILL group path executes.
        runner=self.project/'tests/run-isolated.py'
        runner.write_text(runner.read_text().replace('process.wait(timeout=180)','process.wait(timeout=.5)').replace('process.wait(timeout=5)','process.wait(timeout=.1)'))
        result=self.execute('kill',FIXTURE_TIMEOUT='1')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Expected controlled interruption',result.stderr)
        log=(self.base/'results-kill/test_ssh_socket_activation.py.log').read_text()
        self.assertIn('Suite timed out after 180 seconds; process group terminated.',log)
        self.assert_clean()

    def test_failed_stop_preserves_ledger_and_retry(self):
        (self.state/'fail-stop').touch()
        result=self.execute('normal')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('controlled stop failure',result.stderr)
        self.assertTrue(self.registry.exists())
        self.assertEqual(len(list(self.units.iterdir())),5)
        data=self.module.load(self.registry)
        self.assertEqual(len(data['owned']),4)
        (self.state/'fail-stop').unlink()
        self.module.cleanup(self.registry)
        self.assert_clean()

    def test_stop_unloads_units_without_stale_reset(self):
        (self.state/'gc-stop').touch()
        result=self.execute('normal')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assert_clean()
        calls=[__import__('ast').literal_eval(line) for line in (self.state/'calls').read_text().splitlines()]
        self.assertFalse(any(call[0]=='reset-failed' for call in calls))

    def test_failed_or_unknown_post_stop_states_preserve_retry(self):
        for mode in ('failed','active','load-unknown','bus-error','unknown'):
            with self.subTest(mode=mode):
                (self.state/'after-stop').write_text(mode)
                result=self.execute('normal')
                if mode=='failed':
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn("['reset-failed',",(self.state/'calls').read_text())
                    self.assert_clean()
                else:
                    self.assertNotEqual(result.returncode,0)
                    self.assertTrue(self.registry.exists())
                    self.assertEqual(len(list(self.units.iterdir())),5)
                    (self.state/'after-stop').write_text('inactive')
                    self.module.cleanup(self.registry)
                    self.assert_clean()
        (self.state/'after-stop').write_text('failed')
        (self.state/'fail-reset').touch()
        result=self.execute('normal')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('controlled reset failure',result.stderr)
        self.assertTrue(self.registry.exists())
        (self.state/'fail-reset').unlink()
        self.module.cleanup(self.registry)
        self.assert_clean()

    def test_publish_transfers_only_both_result_trees(self):
        public=Path(tempfile.mkdtemp(prefix='ssh-result-access-',dir='/run'))
        public.chmod(0o755);self.addCleanup(shutil.rmtree,public)
        first=public/'pz-test-results';second=public/'pz-ssh-socket-results'
        foreign=public/'unrelated';foreign.mkdir(mode=0o700)
        for directory in (first,second):
            directory.mkdir(mode=0o700)
            (directory/'probe.log').write_text('private test result')
        (first/'summary.json').write_text(json.dumps({'suites':89,'failures':[]}))
        binary=public/'bin';binary.mkdir()
        (binary/'sudo').write_text('#!/bin/sh\nexec "$@"\n');(binary/'sudo').chmod(0o755)
        (binary/'id').write_text('#!/bin/sh\ncase "$1" in -u|-g) echo 65533;; *) exit 2;; esac\n');(binary/'id').chmod(0o755)
        block=(ROOT/'.github/workflows/tests.yml').read_text().split('      - name: Publish test summary\n',1)[1].split('      - name: Retain test results\n',1)[0].split('        run: |\n',1)[1]
        script='\n'.join(line[10:] if line.startswith('          ') else line for line in block.splitlines())+'\n'
        result=subprocess.run(['bash','-e','-c',script],env=dict(os.environ,PATH=str(binary)+':'+os.environ['PATH'],RESULTS=str(first),SSH_RESULTS=str(second),GITHUB_STEP_SUMMARY=str(public/'summary')),text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        for directory in (first,second):
            scan=subprocess.run(['/usr/bin/setpriv','--reuid','65533','--regid','65533','--clear-groups',sys.executable,'-c','import os,sys;print(list(os.scandir(sys.argv[1])))',str(directory)],capture_output=True,text=True,timeout=5)
            self.assertEqual(scan.returncode,0,scan.stderr)
            self.assertEqual(directory.stat().st_uid,65533)
        self.assertEqual(foreign.stat().st_uid,0)
        self.assertEqual(foreign.stat().st_mode&0o777,0o700)

    def test_initial_socket_errors_remove_only_our_empty_directory(self):
        neighbor=self.run/'pz-ssh-authority-foreign';neighbor.mkdir()
        (neighbor/'keep').write_text('foreign evidence')
        for boundary in ('constructor','bind'):
            with self.subTest(boundary=boundary):
                error=OSError(errno.ENOBUFS,'controlled initial reservation failure')
                if boundary=='constructor':
                    replacement=mock.Mock(side_effect=error)
                else:
                    replacement=mock.MagicMock()
                    replacement.return_value.__enter__.return_value.bind.side_effect=error
                with mock.patch.object(self.module.socket,'socket',replacement):
                    with self.assertRaisesRegex(OSError,'controlled initial reservation failure'):
                        self.module.run(self.registry,self.base/'unused-results','normal')
                self.module.cleanup(self.registry)
                self.assertEqual(list(self.run.glob('pz-ssh-authority-*')),[neighbor])
                self.assertEqual((neighbor/'keep').read_text(),'foreign evidence')
                self.assertFalse((self.state/'calls').exists())
        # A pre-existing partial ledger must refuse before allocating a nonce.
        partial=self.registry.with_suffix('.new')
        partial.write_text('prior useful evidence');partial.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'Registry already exists'):
            self.module.create_registry(self.registry)
        self.assertEqual(partial.read_text(),'prior useful evidence')
        self.assertEqual(set(self.run.glob('pz-ssh-authority-*')),{neighbor,partial})
        partial.unlink()
        # Failed publication retains partial evidence and its known directory.
        def interrupted_save(path,data,exclusive=False):
            partial=path.with_suffix('.new')
            partial.write_text('{');partial.chmod(0o600)
            raise OSError('controlled publication failure')
        with mock.patch.object(self.module,'save',side_effect=interrupted_save):
            with self.assertRaisesRegex(OSError,'controlled publication failure'):
                self.module.create_registry(self.registry)
        partial=self.registry.with_suffix('.new')
        self.assertEqual(partial.read_text(),'{')
        retained=[p for p in self.run.glob('pz-ssh-authority-*') if p.is_dir() and p!=neighbor]
        self.assertEqual(len(retained),1)
        self.assertEqual(list(retained[0].iterdir()),[])
        # Only the fixture knows and removes this simulated incomplete phase.
        partial.unlink();retained[0].rmdir()
        # mkdir failure grants no ownership over an existing nonce directory.
        nonce='a'*32
        collision=self.run/('pz-ssh-authority-'+nonce);collision.mkdir()
        (collision/'keep').write_text('foreign collision')
        with mock.patch.object(self.module.uuid,'uuid4',return_value=mock.Mock(hex=nonce)):
            with self.assertRaises(FileExistsError):self.module.create_registry(self.registry)
        self.assertEqual((collision/'keep').read_text(),'foreign collision')
        # A published valid ledger and its directory must survive a new call.
        data=self.module.create_registry(self.registry)
        original=self.registry.read_bytes()
        with self.assertRaisesRegex(ValueError,'Registry already exists'):
            self.module.create_registry(self.registry)
        self.assertEqual(self.registry.read_bytes(),original)
        self.assertTrue(Path(data['base']).is_dir())
        self.module.cleanup(self.registry)

    def test_atomic_partial_ledger_and_foreign_collision(self):
        data=self.module.create_registry(self.registry)
        # A partial .new left beside the authoritative full registry is safe
        # to replace; a malformed sole ledger remains visible and refuses.
        partial=self.registry.with_suffix('.new');partial.write_text('{');partial.chmod(0o600)
        self.module.save(self.registry,data)
        file=self.units/next(iter(data['units']))
        file.write_text('existing-ssh.socket foreign bytes');file.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'Foreign unit collision'):self.module.cleanup(self.registry)
        self.assertEqual(file.read_text(),'existing-ssh.socket foreign bytes')
        self.assertFalse((self.state/'calls').exists())
        file.unlink();self.module.cleanup(self.registry)
        self.assertFalse(self.registry.exists())
        partial.write_text('{');partial.chmod(0o600)
        with self.assertRaises(json.JSONDecodeError):self.module.cleanup(self.registry)
        self.assertEqual(partial.read_text(),'{')


if __name__=='__main__':unittest.main()
