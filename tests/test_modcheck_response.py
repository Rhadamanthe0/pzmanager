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


if __name__ == '__main__':
    unittest.main()
