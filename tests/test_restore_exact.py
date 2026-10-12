"""Real filesystem regression fixtures, with only service/error boundaries stubbed."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(os.environ.get("PZ_RESTORE_SCRIPT", Path(__file__).resolve().parents[1] / "data/scripts/backup/restoreZomboidData.sh"))


class RestoreExactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.live = self.root / "Zomboid"
        self.old = self.root / "old"
        self.env = dict(os.environ, PZ_HOME=str(self.root), PZ_SOURCE_DIR=str(self.live))
        source = SCRIPT.read_text()
        self.functions = "\n".join(
            re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)
            for name in ("backup_current_zomboid", "rollback_live")
        )

    def run_shell(self, command, prefix=""):
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\ndie() { echo \"$*\" >&2; exit 1; }\n"
             "assert_server_stopped_proven() { :; }\n" + prefix + "\n" + self.functions + "\n" + command],
            env=self.env, capture_output=True, text=True,
        )

    def world(self, directory, marker):
        (directory / "Saves/world").mkdir(parents=True)
        (directory / "Saves/world/original").write_text(marker)
        (directory / "empty").mkdir()
        (directory / "link").symlink_to("Saves/world/original")

    def snapshot(self, directory):
        return {
            str(path.relative_to(directory)): ("link", os.readlink(path)) if path.is_symlink()
            else ("dir",) if path.is_dir() else ("file", path.read_bytes())
            for path in directory.rglob("*")
        }

    @unittest.skipUnless(shutil.which("rsync"), "requires real rsync")
    def test_failed_restore_rollback_is_exact_and_keeps_recovery_copy(self):
        self.world(self.old, "original")
        self.world(self.live, "failed replacement")
        (self.live / "new-directory").mkdir()
        (self.live / "new-directory/partial").write_text("new")
        (self.live / "new-link").symlink_to("new-directory/partial")
        expected = self.snapshot(self.old)
        result = self.run_shell('rollback_live "$PZ_HOME/old"')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Rollback terminé", result.stdout)
        self.assertEqual(self.snapshot(self.live), expected)
        self.assertEqual(self.snapshot(self.old), expected)

    def test_rollback_copy_failure_preserves_recoverable_old(self):
        self.world(self.old, "original")
        self.world(self.live, "failed replacement")
        expected = self.snapshot(self.old)
        result = self.run_shell('rollback_live "$PZ_HOME/old"', 'rsync() { return 23; }')
        self.assertEqual(result.returncode, 1)
        self.assertIn("ET du rollback", result.stderr)
        self.assertEqual(self.snapshot(self.old), expected)

    def test_same_second_backups_are_separate_complete_worlds(self):
        self.world(self.live, "first")
        first = self.snapshot(self.live)
        result = self.run_shell(
            'backup_current_zomboid\n'
            'mkdir -p "$PZ_SOURCE_DIR/Saves/world"\n'
            'printf second > "$PZ_SOURCE_DIR/Saves/world/original"\n'
            'backup_current_zomboid',
            'date() { printf "%s\\n" "2026-10-12_12h00m00s"; }',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.root / "OLD").glob("ZomboidBROKEN_*"))
        self.assertEqual(len(backups), 2)
        snapshots = [self.snapshot(path) for path in backups]
        self.assertIn(first, snapshots)
        second = {"Saves": ("dir",), "Saves/world": ("dir",),
                  "Saves/world/original": ("file", b"second")}
        self.assertIn(second, snapshots)
        self.assertFalse(self.live.exists())

    def test_reserved_destination_cannot_nest_into_existing_backup(self):
        self.world(self.live, "live")
        self.world(self.old, "foreign")
        expected = self.snapshot(self.old)
        result = self.run_shell('backup_current_zomboid', 'mktemp() { printf "%s\\n" "$PZ_HOME/old"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(self.old), expected)
        self.assertEqual((self.live / "Saves/world/original").read_text(), "live")


if __name__ == "__main__":
    unittest.main()
