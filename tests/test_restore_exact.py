"""Real filesystem regression fixtures, with only service/error boundaries stubbed."""
import os
from pathlib import Path
import re
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
        self.staging = self.root / ".restore-staging-test"
        self.env = dict(os.environ, PZ_HOME=str(self.root), PZ_SOURCE_DIR=str(self.live),
                        PZ_USER=os.environ.get("USER", "nobody"))
        source = SCRIPT.read_text()
        self.functions = "\n".join(
            re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)
            for name in ("prepare_previous_dir", "restore_previous_dirs", "rollback_live",
                         "restore_zomboid_data", "validate_restored_live")
        )
        self.globals = re.search(r"^readonly RESTORED_DIRS=.*$", source, re.M).group(0)

    def run_shell(self, command, prefix=""):
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\ndie() { echo \"$*\" >&2; exit 1; }\n"
             "assert_server_stopped_proven() { :; }\n" + self.globals + "\n"
             f"STAGING_DIR={str(self.staging)!r}\nBACKUP_PATH=backup\nPREVIOUS_DIR=''\n"
             "MOVED_DIRS=()\nINSTALLED_DIRS=()\nSWAP_IN_PROGRESS=false\n"
             + self.functions + "\n" + prefix + "\n" + command],
            env=self.env, capture_output=True, text=True,
        )

    def world(self, directory, marker):
        (directory / "Saves/world").mkdir(parents=True)
        (directory / "Saves/world/original").write_text(marker)
        (directory / "Saves/empty").mkdir()
        (directory / "Saves/link").symlink_to("world/original")
        (directory / "Lua/Aegis").mkdir(parents=True)
        (directory / "Lua/Aegis/roles.txt").write_text(marker)

    def snapshot(self, directory):
        return {
            str(path.relative_to(directory)): ("link", os.readlink(path)) if path.is_symlink()
            else ("dir",) if path.is_dir() else ("file", path.read_bytes())
            for path in directory.rglob("*")
        }

    def previous(self):
        return list(self.root.glob(".restore-previous-*"))

    def test_success_replaces_backed_up_dirs_keeps_others_and_drops_copy(self):
        self.world(self.live, "original")
        (self.live / "Logs").mkdir()
        (self.live / "Logs/console.txt").write_text("keep")
        self.world(self.staging, "restored")
        result = self.run_shell("prepare_previous_dir\nrestore_zomboid_data")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.live / "Saves/world/original").read_text(), "restored")
        self.assertEqual((self.live / "Lua/Aegis/roles.txt").read_text(), "restored")
        self.assertEqual((self.live / "Logs/console.txt").read_text(), "keep")
        self.assertEqual(self.previous(), [])

    def test_failed_restore_rollback_is_exact_and_drops_copy(self):
        self.world(self.live, "original")
        (self.live / "Logs").mkdir()
        expected = self.snapshot(self.live)
        self.world(self.staging, "failed replacement")
        (self.staging / "Saves/new-directory").mkdir()
        (self.staging / "Saves/new-directory/partial").write_text("new")
        (self.staging / "Saves/new-link").symlink_to("new-directory/partial")
        result = self.run_shell("prepare_previous_dir\nrestore_zomboid_data",
                                "validate_restored_live() { return 1; }")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("remise en place", result.stderr)
        self.assertEqual(self.snapshot(self.live), expected)
        self.assertEqual(self.previous(), [])

    def test_rollback_failure_keeps_recoverable_copy(self):
        self.world(self.live, "original")
        expected = self.snapshot(self.live)
        self.world(self.staging, "failed replacement")
        result = self.run_shell(
            "prepare_previous_dir\nrestore_zomboid_data",
            "validate_restored_live() { return 1; }\n"
            'mv() { [[ "$3" != "$PREVIOUS_DIR"/* ]] || return 1; command mv "$@"; }')
        self.assertEqual(result.returncode, 1)
        self.assertIn("ET du rollback", result.stderr)
        [previous] = self.previous()
        self.assertIn(str(previous), result.stderr)
        self.assertEqual(self.snapshot(previous), expected)

    def test_reserved_destination_cannot_nest_into_existing_directory(self):
        self.world(self.live, "live")
        expected_live = self.snapshot(self.live)
        foreign = self.root / "foreign"
        self.world(foreign, "foreign")
        expected = self.snapshot(foreign)
        self.world(self.staging, "restored")
        result = self.run_shell("prepare_previous_dir\nrestore_zomboid_data",
                                f'mktemp() {{ printf "%s\\n" {str(foreign)!r}; }}')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(foreign), expected)
        self.assertEqual(self.snapshot(self.live), expected_live)


if __name__ == "__main__":
    unittest.main()
