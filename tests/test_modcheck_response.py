"""Statut asynchrone : vrais choix du modcheck, effets externes simulés."""
from pathlib import Path
import os
import json
import sys
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ModStatus(unittest.TestCase):
    def run_check(self, output, failure=False):
        source = (ROOT / 'data/scripts/admin/triggerMaintenanceOnModUpdate.sh').read_text()
        function = re.search(r'^check_mods\(\) \{.*?^\}', source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts/admin').mkdir(parents=True)
            (root / 'scripts/internal').mkdir()
            (root / 'response').write_text(output)
            stub = root / 'scripts/internal/sendCommand.sh'
            stub.write_text('#!/bin/bash\ncat "$PRIVATE_RESPONSE"\nexit "$PRIVATE_RC"\n')
            stub.chmod(0o700)
            script = ('set -euo pipefail\n'
                      'log_event() { printf "log:%s\\n" "$*"; }\n'
                      'notify() { printf "notify:%s\\n" "$*"; }\n'
                      'note_console_silence() { printf "silent:%s\\n" "$1"; }\n'
                      + function + '\nif check_mods; then echo update:yes; else echo update:no; fi\n')
            env = dict(os.environ, SCRIPT_DIR=str(root / 'scripts/admin'),
                       PRIVATE_RESPONSE=str(root / 'response'), PRIVATE_RC='1' if failure else '0')
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True,
                                    text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_confirmed_status_controls_update_only(self):
        for status, update in [('Mods need update', 'yes'), ('Mods updated', 'no')]:
            result = self.run_check('CheckModsNeedUpdate: ' + status)
            self.assertIn('update:' + update, result)
            self.assertIn('silent:0', result)
            self.assertNotIn('ERROR', result)

    def test_pending_status_does_not_claim_success_or_update(self):
        result = self.run_check('CheckModsNeedUpdate: Checking...')
        self.assertIn('update:no', result)
        self.assertIn('no final status', result)
        self.assertNotIn('OK -', result)
        self.assertNotIn('silent:1', result)

    def test_acknowledged_timeout_is_not_a_silent_console(self):
        result = self.run_check('Commande reçue: checkModsNeedUpdate '
                                '(aucun statut final capturé dans le délai borné)')
        self.assertIn('update:no', result)
        self.assertIn('silent:0', result)
        self.assertIn('no final status', result)
        self.assertNotIn('OK -', result)
        self.assertNotIn('silent:1', result)

    def test_unacknowledged_timeout_preserves_silence_detection(self):
        result = self.run_check('Commande envoyée: checkModsNeedUpdate '
                                '(aucune sortie capturée dans le délai borné)')
        self.assertIn('update:no', result)
        self.assertIn('silent:1', result)
        self.assertNotIn('OK -', result)

    def test_only_workshop_default_wait_is_extended_and_override_preserved(self):
        source = (ROOT / 'data/scripts/internal/sendCommand.sh').read_text()
        fragment = source[source.index('output_timeout=8'):]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / 'python3'
            fake.write_text('#!' + sys.executable + '\nimport json,sys;print(json.dumps(sys.argv[1:]))\n')
            fake.chmod(0o700)
            for command, override, expected in [('players', None, '8'),
                                               ('quit', None, '8'),
                                               ('checkModsNeedUpdate', None, '30'),
                                               ('checkModsNeedUpdate', '5', '5'),
                                               ('players', '20', '20')]:
                with self.subTest(command=command, override=override):
                    env = dict(os.environ, CMD=command, PZ_SERVICE_NAME='fixture.service',
                               PZ_CONTROL_PIPE='/private/unused', SCRIPT_DIR=str(root),
                               NO_OUTPUT='false', PATH=str(root) + os.pathsep + os.environ['PATH'])
                    env.pop('PZ_CONSOLE_OUTPUT_TIMEOUT', None)
                    if override is not None:
                        env['PZ_CONSOLE_OUTPUT_TIMEOUT'] = override
                    result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + fragment],
                                            env=env, capture_output=True, text=True, timeout=3)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    arguments = json.loads(result.stdout)
                    self.assertEqual(arguments[arguments.index('--output-timeout') + 1], expected)
                    self.assertEqual(arguments[-1], command)

    def test_transport_failure_cannot_start_maintenance(self):
        result = self.run_check('CheckModsNeedUpdate: Mods need update', failure=True)
        self.assertIn('update:no', result)
        self.assertIn('RCON failed', result)
        self.assertIn('notify:ERROR', result)
        self.assertNotIn('OK -', result)


class BuildCheckMarker(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.runtime=self.root/'runtime';self.runtime.mkdir(mode=0o700)
        self.private=self.runtime/'pzmanager';self.private.mkdir(mode=0o700)
        self.marker=self.private/'server-update-check.stamp'
        self.target=self.root/'outside';self.target.write_text('preserved')
        self.username='fixture-'+self.root.name
        self.legacy=Path('/tmp')/('pzmanager-server-update-check-'+self.username+'.stamp')
        self.addCleanup(self.legacy.unlink,missing_ok=True)
        self.bin=self.root/'bin';self.bin.mkdir()
        identity=self.bin/'id';identity.write_text('#!/bin/sh\nif [ "$*" = -un ]; then echo "$FIXTURE_USER"; else exec /usr/bin/id "$@"; fi\n');identity.chmod(0o700)
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],FIXTURE_USER=self.username,
                      XDG_RUNTIME_DIR=str(self.runtime),SERVER_UPDATE_CHECK_INTERVAL='3600')

    def check(self):
        source=(ROOT/'data/scripts/admin/triggerMaintenanceOnModUpdate.sh').read_text()
        function=re.search(r'^server_update_check_due\(\) \{.*?^\}',source,re.M|re.S).group()
        declarations='\n'.join(re.findall(r'^readonly SERVER_UPDATE_(?:MARKER|CHECK_INTERVAL)=.*$',source,re.M))
        script='set -euo pipefail\nsource "$1"\nlog_event() { echo "$*"; }\n'+declarations+'\n'+function+'\nif server_update_check_due; then echo build-checked; else echo build-deferred; fi\n'
        return subprocess.run(['bash','-c',script,'marker',str(ROOT/'data/scripts/lib/common.sh')],
                              env=self.env,capture_output=True,text=True,timeout=4)

    def test_legacy_hostile_future_marker_cannot_suppress_check(self):
        os.utime(self.target,(4102444800,4102444800));self.legacy.symlink_to(self.target)
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('build-checked',result.stdout)
        self.assertTrue(self.legacy.is_symlink())
        self.assertEqual(self.target.read_text(),'preserved')
        self.assertEqual(int(self.target.stat().st_mtime),4102444800)
        self.assertTrue(self.marker.is_file())

    def test_private_marker_symlink_is_refused_without_touching_target(self):
        self.marker.symlink_to(self.target);before=self.target.stat().st_mtime_ns
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('build-deferred',result.stdout)
        self.assertTrue(self.marker.is_symlink())
        self.assertEqual(self.target.stat().st_mtime_ns,before)
        self.assertEqual(self.target.read_text(),'preserved')

    def test_future_private_marker_is_rearmed_and_recent_marker_defers(self):
        self.marker.touch(mode=0o600);os.utime(self.marker,(4102444800,4102444800))
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('build-checked',result.stdout)
        self.assertLess(self.marker.stat().st_mtime,4102444800)
        again=self.check();self.assertEqual(again.returncode,0,again.stderr)
        self.assertIn('build-deferred',again.stdout)

    def test_recent_private_marker_defers_without_changing_inode(self):
        self.marker.touch(mode=0o600);before=self.marker.stat()
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('build-deferred',result.stdout)
        after=self.marker.stat();self.assertEqual((after.st_ino,after.st_mtime_ns),(before.st_ino,before.st_mtime_ns))


if __name__ == '__main__':
    unittest.main()
