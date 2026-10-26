"""Effective systemd commands must share the caller's real configuration root."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import test_writing_start_admission as fixtures


def row(path,arguments=None,ignore=False):
    return [str(path),[str(path)] if arguments is None else arguments,ignore,0,0,0,0,0,0,0]


def metadata(rows):
    return json.dumps({'type':'a(sasbttttuii)','data':rows})


class NativeStartupUnit(unittest.TestCase):
    def fixture(self):
        case=fixtures.StartAdmission();case.setUp();self.addCleanup(case.tearDown)
        repo,world,ini=case.closure_fixture()
        case.set_state('activating','start-pre',0,os.getpid())
        return case,repo,world,ini

    def test_old_base_worker_old_prepare_and_overridden_new_unit_refuse_before_mutation(self):
        for label,worker,command in [
            ('base-standalone','enforceClosedServer.sh','old-base-inline'),
            ('pr-prepare','prepareWorldStart.sh','old-pr-inline'),
            ('new-unit-old-execstart-dropin','prepareWorldStart.sh','local-inline-dropin'),
        ]:
            with self.subTest(label=label):
                case,repo,world,ini=self.fixture()
                case.env['STARTUP_TEST_EXECSTART']=metadata([row('/bin/sh',['/bin/sh','-c',command])])
                before=(ini.read_bytes(),(world/'db/servertest.db').read_bytes())
                result=subprocess.run(['bash',str(repo/'data/scripts/internal'/worker)],env=case.env,
                                      capture_output=True,text=True,timeout=12)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Lanceur effectif',result.stderr)
                self.assertEqual((ini.read_bytes(),(world/'db/servertest.db').read_bytes()),before)

    def test_cli_cannot_prepare_handoff_for_a_foreign_manager_root(self):
        case,repo,world,ini=self.fixture()
        foreign=case.root/'other-repository/data/scripts/internal/startServer.sh'
        case.env['STARTUP_TEST_EXECSTART']=metadata([row(foreign)])
        with case.lock.open('w') as lock:
            case.lock.chmod(0o600);fcntl.flock(lock,fcntl.LOCK_EX)
            result=subprocess.run([sys.executable,str(case.helper),'prepare','--lock-path',str(case.lock),
                '--pid',str(os.getpid()),'--fd',str(lock.fileno()),'--unit','probe.service'],
                env=case.env,capture_output=True,text=True,timeout=10,pass_fds=(lock.fileno(),))
            marker=case.private/fixtures.admission.MARKER
            if marker.exists():case.original_marker=json.loads(marker.read_text())
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('Lanceur effectif',result.stderr)
            self.assertFalse(marker.exists(),'a broker was prepared for another repository')
        self.assertEqual(ini.read_text(),'Open=true\nMods=\n')

    def test_typed_metadata_and_readonly_preflight_are_checked_before_every_worker(self):
        for kind in ('extra-argument','changed-argv0','ignored-error','multiple-starts',
                     'missing-preflight','preflight-after-world-worker','wrong-check-argument',
                     'unknown-schema','bad-row-type','invalid-unit-object','bus-refused','oversized'):
            with self.subTest(kind=kind):
                case,repo,world,ini=self.fixture()
                launcher=repo/'data/scripts/internal/startServer.sh'
                prepare=launcher.with_name('prepareWorldStart.sh')
                if kind=='extra-argument':
                    case.env['STARTUP_TEST_EXECSTART']=metadata([row(launcher,[str(launcher),'--check'])])
                elif kind=='changed-argv0':
                    case.env['STARTUP_TEST_EXECSTART']=metadata([row(launcher,['foreign-argv-zero'])])
                elif kind=='ignored-error':
                    case.env['STARTUP_TEST_EXECSTART']=metadata([row(launcher,ignore=True)])
                elif kind=='multiple-starts':
                    case.env['STARTUP_TEST_EXECSTART']=metadata([row(launcher),row('/bin/true')])
                elif kind=='missing-preflight':
                    case.env['STARTUP_TEST_PRE']=metadata([row(prepare)])
                elif kind=='preflight-after-world-worker':
                    case.env['STARTUP_TEST_PRE']=metadata([row(launcher.with_name('enforceClosedServer.sh')),
                        row(launcher,[str(launcher),'--check']),row(prepare)])
                elif kind=='wrong-check-argument':
                    case.env['STARTUP_TEST_PRE']=metadata([row(launcher,[str(launcher),'--check-other']),row(prepare)])
                elif kind=='unknown-schema':
                    case.env['STARTUP_TEST_EXECSTART']='{"type":"s","data":["private-metadata-secret"]}'
                elif kind=='bad-row-type':
                    value=row(launcher);value[-1]=False
                    case.env['STARTUP_TEST_EXECSTART']=metadata([value])
                elif kind=='invalid-unit-object':
                    case.env['STARTUP_TEST_OBJECT']='{"type":"o","data":["/../private-metadata-secret"]}'
                elif kind=='bus-refused':
                    case.env['STARTUP_TEST_BUS_ERROR']='property'
                else:
                    case.env['STARTUP_TEST_EXECSTART']='private-metadata-secret'+'x'*66000
                before=(ini.read_bytes(),(world/'db/servertest.db').read_bytes())
                result=subprocess.run(['bash',str(repo/'data/scripts/internal/enforceClosedServer.sh')],
                    env=case.env,capture_output=True,text=True,timeout=12)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Lanceur effectif',result.stderr)
                self.assertNotIn('private-metadata-secret',result.stdout+result.stderr)
                self.assertEqual((ini.read_bytes(),(world/'db/servertest.db').read_bytes()),before)

    def test_offline_worker_does_not_require_or_query_a_game_unit(self):
        case,repo,world,ini=self.fixture()
        case.set_state('inactive','dead',0,0)
        calls=case.root/'busctl-calls'
        case.env.update(STARTUP_TEST_BUS_ERROR='manager',STARTUP_TEST_BUS_CALLS=str(calls))
        result=subprocess.run(['bash',str(repo/'data/scripts/internal/enforceClosedServer.sh')],
            env=case.env,capture_output=True,text=True,timeout=12)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Open=false',ini.read_text())
        self.assertFalse(calls.exists())

    def test_authenticated_handoff_refuses_each_different_launch_setting(self):
        for key in fixtures.admission.LAUNCH_KEYS:
            with self.subTest(key=key):
                case,repo,world,ini=self.fixture()
                owner,release=case.prepare_owner()
                before=(ini.read_bytes(),(world/'db/servertest.db').read_bytes())
                case.env[key]+='-different'
                if key=='PZ_SOURCE_DIR':Path(case.env[key]).mkdir()
                result=case.invoke('run','--lock-path',case.lock,'--unit','probe.service',
                    '--','bash',str(repo/'data/scripts/internal/prepareWorldStart.sh'),'--admitted-worker')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('configuration differs',result.stderr)
                self.assertEqual((ini.read_bytes(),(world/'db/servertest.db').read_bytes()),before)
                self.assertTrue(case.busy(),'refusal released the CLI WORLD lock')
                release.touch();self.assertEqual(owner.wait(timeout=5),0,(case.root/'owner.stderr').read_text())

    def test_missing_malformed_or_oversized_profile_cannot_authorize_handoff(self):
        for kind in ('missing','wrong-type','extra-key','oversized-marker'):
            with self.subTest(kind=kind):
                case,repo,world,ini=self.fixture()
                owner,release=case.prepare_owner()
                marker=case.private/fixtures.admission.MARKER
                data=json.loads(marker.read_text())
                if kind=='missing':data.pop('launch')
                elif kind=='wrong-type':data['launch']['PZ_SOURCE_DIR']=False
                elif kind=='extra-key':data['launch']['unexpected']='value'
                else:data['padding']='x'*65537
                marker.write_text(json.dumps(data))
                before=(ini.read_bytes(),(world/'db/servertest.db').read_bytes())
                result=case.invoke('run','--lock-path',case.lock,'--unit','probe.service',
                    '--','bash',str(repo/'data/scripts/internal/prepareWorldStart.sh'),'--admitted-worker')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual((ini.read_bytes(),(world/'db/servertest.db').read_bytes()),before)
                self.assertTrue(case.busy())
                marker.write_text(json.dumps(case.original_marker))
                release.touch();self.assertEqual(owner.wait(timeout=5),0,(case.root/'owner.stderr').read_text())

    def test_dead_legacy_marker_without_profile_is_replaced_without_replacing_world_lock(self):
        case,repo,world,ini=self.fixture()
        case.lock.touch(mode=0o600);info=case.lock.stat()
        data=dict(pid=999999999,birth=0,fd=201,dev=info.st_dev,ino=info.st_ino,
                  broker=999999999,broker_birth=0,unit='probe.service',token='a'*32)
        (case.private/fixtures.admission.MARKER).write_text(json.dumps(data))
        owner,release=case.prepare_owner()
        self.assertEqual((case.lock.stat().st_dev,case.lock.stat().st_ino),(info.st_dev,info.st_ino))
        self.assertIn('launch',case.original_marker)
        self.assertTrue(case.busy())
        release.touch();self.assertEqual(owner.wait(timeout=5),0,(case.root/'owner.stderr').read_text())


if __name__=='__main__':
    os.umask(0o077)
    unittest.main()
