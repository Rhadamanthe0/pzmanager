"""Exécute une copie du détecteur avec journaux et services simulés."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class StallwatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.state_dir = self.runtime / 'pzmanager'
        self.state_dir.mkdir(mode=0o700)
        self.logs = self.root / 'logs'
        self.logs.mkdir()
        scripts = self.root / 'scripts'
        (scripts / 'internal').mkdir(parents=True)
        (scripts / 'lib').mkdir()
        self.script = scripts / 'internal/watchServerStall.sh'
        shutil.copyfile(Path(__file__).resolve().parents[1] /
                        'data/scripts/internal/watchServerStall.sh', self.script)
        (scripts / 'lib/common.sh').write_text('''source_env() { :; }
server_is_active() { return 0; }
log() { printf '%s\\n' "$*"; }
''')
        commands = self.root / 'bin'
        commands.mkdir()
        for name, body in {
            'pgrep': 'echo 123',
            'journalctl': 'echo "2000.000 f:${TEST_FRAME:-42} st:ready"' ,
            'curl': "echo 'game{parameter=\"players\"} 1'",
        }.items():
            command = commands / name
            command.write_text('#!/bin/sh\n' + body + '\n')
            command.chmod(0o700)
        self.env = {**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH'],
                    'XDG_RUNTIME_DIR': str(self.runtime), 'LOG_ZOMBOID_DIR': str(self.logs),
                    'LOG_RETENTION_DAYS': '7', 'PZ_PROMETHEUS_PORT': '1',
                    'STALL_WATCH_SAMPLES': '100'}

    def run_watch(self):
        return subprocess.run(['bash', str(self.script)], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_untrusted_state_is_not_evaluated(self):
        marker = self.root / 'executed'
        state = self.state_dir / 'stallwatch.state'
        state.write_text(f'123 42 1999 a[$(touch {marker})]\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(state.read_text(), '123 42 2000 0\n')

    def test_untrusted_cooldown_is_not_evaluated(self):
        marker = self.root / 'executed'
        (self.state_dir / 'stallwatch.cooldown').write_text(f'a[$(touch {marker})]\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_decimal_state_and_private_permissions(self):
        state = self.state_dir / 'stallwatch.state'
        state.write_text('123 42 1999 08\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.read_text(), '123 42 2000 9\n')
        state.unlink()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_startup_frame_zero_never_counts_as_a_stall(self):
        self.env['TEST_FRAME'] = '0'
        state = self.state_dir / 'stallwatch.state'
        state.write_text('123 0 1999 99\n')
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.read_text(), '123 0 2000 0\n')

    def test_nonprivate_runtime_is_refused(self):
        self.runtime.chmod(0o755)
        self.assertNotEqual(self.run_watch().returncode, 0)
        self.assertFalse((self.state_dir / 'stallwatch.state').exists())

    def test_symlink_state_directory_is_refused(self):
        self.state_dir.rmdir()
        self.state_dir.symlink_to(self.logs, target_is_directory=True)
        self.assertNotEqual(self.run_watch().returncode, 0)
        self.assertEqual(list(self.logs.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
