#!/usr/bin/env python3
"""Run the real restore shell + rsync on a disposable Linux copy.

Only common.sh's environment, lock and service-state boundary is doubled.
No systemctl invocation or production path is used by these tests.
"""
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def snapshot(root):
    return {str(p.relative_to(root)): p.read_bytes()
            for p in root.rglob('*') if p.is_file()}


class FullRestorePreflight(unittest.TestCase):
    def setUp(self):
        if not shutil.which('rsync'):
            self.skipTest('existing rsync executable is required; no package is installed')
        self.tmp = tempfile.TemporaryDirectory(prefix='pz-full-restore-preflight-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'; self.home.mkdir()
        self.live = self.home / 'Zomboid'
        self.backup = self.root / 'backup'; self.backup.mkdir()
        self.repo = self.root / 'repo'
        (self.repo / 'data/scripts/backup').mkdir(parents=True)
        (self.repo / 'data/scripts/lib').mkdir()
        self.script = self.repo / 'data/scripts/backup/restoreZomboidData.sh'
        shutil.copy2(ROOT / 'data/scripts/backup/restoreZomboidData.sh', self.script)
        self.calls = self.root / 'calls.log'
        (self.repo / 'data/scripts/lib/common.sh').write_text('''
source_env() { :; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
acquire_world_lock() { echo WORLD >> "$TEST_CALLS"; }
release_world_lock() { echo RELEASE >> "$TEST_CALLS"; }
assert_server_stopped_proven() {
    echo "STOPPED_PROOF:$TEST_STATE" >> "$TEST_CALLS"
    [[ "$TEST_STATE" == inactive ]] || die "Service non prouvé arrêté : $TEST_STATE"
}
require_server_stopped() { assert_server_stopped_proven "$@"; }
mv() { printf 'MV:%s\\n' "$*" >> "$TEST_CALLS"; command mv "$@"; }
''')
        self.env = dict(os.environ, PZ_HOME=str(self.home), PZ_SOURCE_DIR=str(self.live),
                        BACKUP_DIR=str(self.root), PZ_USER=pwd.getpwuid(os.getuid()).pw_name,
                        TEST_CALLS=str(self.calls), TEST_STATE='inactive')
        # Neutralize inherited host overrides; this test tree is the only root.
        for name in ('BASH_ENV', 'ENV', 'PZ_WORLD_LOCK_FD', 'SERVERCTL_LOCK_FD'):
            self.env.pop(name, None)
        self.valid_backup()

    def valid_backup(self):
        world = self.backup / 'Saves/Multiplayer/test'
        world.mkdir(parents=True, exist_ok=True)
        (world / 'sentinel.bin').write_bytes(b'synthetic offline backup, not a real world')

    def live_world(self):
        world = self.live / 'Saves/Multiplayer/test'
        world.mkdir(parents=True)
        (world / 'current.bin').write_bytes(b'current unrelated data')

    def run_restore(self):
        return subprocess.run(['bash', str(self.script), str(self.backup)], cwd=self.repo,
                              env=self.env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=20)

    def test_absent_live_directory_does_not_bypass_stopped_proof(self):
        for state in ('active', 'unknown', 'bus-error'):
            with self.subTest(state=state):
                # Every scenario starts with its own clean simulated live tree.
                if self.live.exists():
                    shutil.rmtree(self.live)
                self.calls.unlink(missing_ok=True)
                self.env['TEST_STATE'] = state
                before = snapshot(self.backup)
                result = self.run_restore()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('STOPPED_PROOF:' + state, self.calls.read_text())
                self.assertFalse(self.live.exists())
                self.assertFalse((self.home / 'OLD').exists())
                self.assertEqual(snapshot(self.backup), before)

    def test_existing_live_active_is_refused_control(self):
        self.live_world()
        before = snapshot(self.live)
        self.env['TEST_STATE'] = 'active'
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('STOPPED_PROOF:active', self.calls.read_text())
        self.assertEqual(snapshot(self.live), before)

    def test_structure_known_to_fail_final_check_is_refused_before_moving_live(self):
        self.live_world()
        before = snapshot(self.live)
        shutil.rmtree(self.backup / 'Saves')
        (self.backup / 'Server').mkdir()
        (self.backup / 'Server/test.ini').write_text('only configuration, not a world\n')
        source = snapshot(self.backup)
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('MV:', self.calls.read_text(), result.stdout)
        self.assertFalse((self.home / 'OLD').exists(), result.stdout)
        self.assertEqual(snapshot(self.live), before)
        self.assertEqual(snapshot(self.backup), source)

    def test_non_directory_under_saves_is_refused_before_moving_live(self):
        self.live_world()
        before = snapshot(self.live)
        shutil.rmtree(self.backup / 'Saves')
        (self.backup / 'Saves').mkdir()
        (self.backup / 'Saves/not-a-world').write_text('not a directory')
        result = self.run_restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('MV:', self.calls.read_text(), result.stdout)
        self.assertEqual(snapshot(self.live), before)

    def test_stopped_absent_live_can_restore(self):
        source = snapshot(self.backup)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('STOPPED_PROOF:inactive', self.calls.read_text())
        self.assertEqual(snapshot(self.live), source)
        self.assertEqual(snapshot(self.backup), source)

    def test_stopped_existing_live_retains_original_recovery(self):
        self.live_world()
        before = snapshot(self.live)
        source = snapshot(self.backup)
        result = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stdout)
        recovered = list((self.home / 'OLD').glob('ZomboidBROKEN_*'))
        self.assertEqual(len(recovered), 1)
        self.assertEqual(snapshot(recovered[0]), before)
        self.assertEqual(snapshot(self.live), source)
        self.assertEqual(snapshot(self.backup), source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
