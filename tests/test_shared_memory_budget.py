"""Vrais validateurs sur faux cgroups privés : aucun cgroup hôte modifié."""
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "data/scripts/lib"))
def load_original(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "data/scripts/lib" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


shared = load_original("shared_guard_original", "shared_memory_budget.py")
migration = load_original("budget_migration_original", "install_shared_budget.py")
import jvm_memory_budget as jvm

GROUP = "/user.slice/user-1005.slice/user@1005.service/pz.slice"


class SharedGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pz-shared-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cg = self.root / "cgroup"
        self.group = self.cg / GROUP.lstrip("/")
        self.group.mkdir(parents=True)
        (self.group / "memory.max").write_text(str(shared.BUDGET))
        (self.group / "memory.swap.max").write_text("0")
        (self.group / "memory.current").write_text("100")
        self.proc = self.root / "proc_cgroup"
        self.proc.write_text("0::" + GROUP + "/zomboid.service/control\n")

    def test_same_parent_for_game_bot_and_nested_backup(self):
        for leaf in ["zomboid.service/control", "pz-discord-bot.service", "pz-backup-cpu-123.scope"]:
            self.proc.write_text("0::" + GROUP + "/" + leaf + "\n")
            self.assertEqual(shared.check_process(self.proc, self.cg), self.group)
        # Un flag de routage ne constitue aucune preuve d'appartenance.
        with patch.dict(os.environ, PZ_BUDGET_SCOPED="1"):
            self.proc.write_text("0::/user.slice/user-1005.slice/session-30.scope\n")
            with self.assertRaises(ValueError):
                shared.check_process(self.proc, self.cg)

    def test_wrong_parent_swap_limit_and_missing_controller_fail_closed(self):
        for value in ["max", str(24 * shared.GIB), str(19 * shared.GIB), "invalid"]:
            (self.group / "memory.max").write_text(value)
            with self.subTest(limit=value), self.assertRaises(ValueError):
                shared.check_process(self.proc, self.cg)
        (self.group / "memory.max").write_text(str(shared.BUDGET))
        (self.group / "memory.swap.max").write_text("1024")
        with self.assertRaises(ValueError):
            shared.check_process(self.proc, self.cg)
        (self.group / "memory.swap.max").unlink()
        with self.assertRaises(OSError):
            shared.check_process(self.proc, self.cg)
        for group in ["/pz.slice/game", "/session-30.scope/pz.slice/game",
                      GROUP + "/../other", GROUP.replace("user@1005.service", "user@bad.service")]:
            with self.subTest(group=group), self.assertRaises(ValueError):
                shared.slice_group(group)

    def test_tighter_ancestor_rejects_heap_even_with_named_shared_20(self):
        leaf = self.group / "zomboid.service"
        leaf.mkdir()
        (leaf / "memory.max").write_text(str(20 * shared.GIB))
        parent = self.group.parent
        (parent / "memory.max").write_text(str(18 * shared.GIB))
        # Toutes les autres limites d'ancêtres sont illimitées.
        while parent.parent != self.cg:
            parent = parent.parent
            (parent / "memory.max").write_text("max")
        self.proc.write_text("0::" + GROUP + "/zomboid.service\n")
        limit = jvm.cgroup_memory_max(self.proc, self.cg)
        with self.assertRaises(ValueError):
            jvm.validate_config({"vmArgs": ["-Xmx16g"]}, limit)

    def test_identity_is_read_only_and_bot_split_refuses_before_any_copy(self):
        env_file = self.root / "env"
        env_file.write_text('export PZ_USER="$(id -un)"\nPZ_GAME_USER="${PZ_USER}"\n')
        shared.check_identity(env_file, user="pzuser")
        env_file.write_text('PZ_GAME_USER=pzgame\nPZ_MANAGER_USER=pzmgr\n')
        original = env_file.read_bytes()
        with self.assertRaises(ValueError):
            shared.check_identity(env_file, user="pzuser")
        self.assertEqual(env_file.read_bytes(), original)
        env_file.write_text('PZ_GAME_USER="$(touch sentinel)"\n')
        with self.assertRaises(ValueError):
            shared.check_identity(env_file, user="pzuser")
        self.assertFalse((self.root / "sentinel").exists())
        # Vrai bootstrap bot copié ; identité refusée avant mkdir/installation.
        project = self.root / "project"
        installer = project / "data/scripts/install"
        lib = project / "data/scripts/lib"
        installer.mkdir(parents=True)
        lib.mkdir()
        import shutil
        for filename in ["shared_memory_budget.py"]:
            shutil.copyfile(ROOT / "data/scripts/lib" / filename, lib / filename)
        script = installer / "setupDiscordBot.sh"
        shutil.copyfile(ROOT / "data/scripts/install/setupDiscordBot.sh", script)
        (project / ".env").write_text('PZ_GAME_USER=pzgame\nPZ_MANAGER_USER=pzmgr\n')
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake_id = bin_dir / "id"
        fake_id.write_text('#!/bin/sh\necho 1005\n')
        fake_id.chmod(0o755)
        home = self.root / "home"
        home.mkdir()
        result = subprocess.run(["bash", str(script)], env={**os.environ, "HOME": str(home),
                                "PATH": str(bin_dir) + ":" + os.environ["PATH"]},
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("split multi-UID", result.stderr)
        self.assertEqual(list(home.iterdir()), [])

    def test_all_services_socket_and_cpu_scope_are_placed(self):
        templates = ROOT / "data/setupTemplates"
        services = list(templates.glob("*.service"))
        self.assertEqual({p.name for p in services}, set(migration.UNITS))
        for p in services:
            # Parse active Service directives, preserving ExecStartPre order and
            # systemd's empty-assignment reset; comments cannot satisfy the guard.
            section = None
            directives = {}
            preflight = []
            for line in p.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith(("#", ";")):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1]
                    continue
                if section != "Service":
                    continue
                key, sep, value = line.partition("=")
                if not sep:
                    continue
                key, value = key.strip(), value.strip()
                directives[key] = value
                if key == "ExecStartPre":
                    if value:
                        preflight.append(shlex.split(value))
                    else:
                        preflight.clear()
            self.assertEqual(directives.get("Slice"), "pz.slice", p.name)
            self.assertTrue(preflight, p.name)
            if p.name == "zomboid.service":
                # The helper checks the actually launched JSON before world
                # preparation. Its real guard is exercised by NativeConfiguration.
                self.assertEqual(preflight[0], [
                    "%h/pzmanager/data/scripts/internal/startServer.sh", "--check"])
            else:
                self.assertEqual(preflight[0], ["/usr/bin/python3",
                    "%h/pzmanager/data/scripts/lib/shared_memory_budget.py", "check"], p.name)
        self.assertIn("Slice=pz.slice", (templates / "zomboid.socket").read_text())
        self.assertIn("--slice=pz.slice", (ROOT / "data/scripts/backup/dataBackup.sh").read_text())
        self.assertNotIn("user-1005.slice", (templates / "pz.slice").read_text())


class BudgetMigration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pz-shared-install-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.units = self.root / "units"
        self.units.mkdir()
        for unit in [*migration.UNITS, "zomboid.socket"]:
            (self.units / unit).write_text("local unit sentinel\n")
        self.archives = self.root / "private"

    def response(self, *args, **kwargs):
        return subprocess.CompletedProcess([], 0, stdout="inactive\n")

    def test_archives_preserve_custom_units_and_dropins_no_start(self):
        custom = self.units / "zomboid.service.d/custom.conf"
        custom.parent.mkdir()
        custom.write_text("[Service]\nCPUWeight=1000\n")
        with patch.object(migration.subprocess, "run", side_effect=self.response) as bus:
            archive = migration.install(ROOT / "data/setupTemplates", self.units, self.archives)
        self.assertEqual(custom.read_text(), "[Service]\nCPUWeight=1000\n")
        self.assertEqual((self.units / "zomboid.service").read_text(), "local unit sentinel\n")
        self.assertIn("[Socket]\nSlice=pz.slice", (self.units / "zomboid.socket.d/90-pz-shared-budget.conf").read_text())
        manifest = json.loads((archive / "manifest.json").read_text())
        self.assertEqual(len(manifest["applied"]), 11)
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all("start" not in call.args[0] for call in bus.call_args_list))
        row = next(row for row in manifest["rows"] if row["path"] == str(custom))
        self.assertEqual(Path(row["archive"]).read_bytes(), custom.read_bytes())

    def test_live_service_or_bus_failure_refuses_before_writing(self):
        for error in [None, subprocess.CalledProcessError(1, "systemctl")]:
            with patch.object(migration.subprocess, "run", side_effect=error,
                              return_value=subprocess.CompletedProcess([], 0, stdout="active\n")):
                with self.assertRaises((ValueError, subprocess.SubprocessError)):
                    migration.install(ROOT / "data/setupTemplates", self.units, self.archives)
            self.assertFalse((self.units / "pz.slice").exists())
            self.assertFalse(self.archives.exists())

    def test_symlink_refused_and_concurrent_changes_do_not_get_overwritten(self):
        target = self.units / "pz.slice"
        target.symlink_to(self.root / "outside")
        with patch.object(migration.subprocess, "run", side_effect=self.response):
            with self.assertRaises(ValueError):
                migration.install(ROOT / "data/setupTemplates", self.units, self.archives)
        target.unlink()
        original = migration.tempfile.NamedTemporaryFile

        def changing(*args, **kwargs):
            result = original(*args, **kwargs)
            (self.units / "zomboid.service").write_text("concurrent owner\n")
            return result

        with patch.object(migration.subprocess, "run", side_effect=self.response), \
                patch.object(migration.tempfile, "NamedTemporaryFile", side_effect=changing):
            with self.assertRaises(ValueError):
                migration.install(ROOT / "data/setupTemplates", self.units, self.archives)
        self.assertEqual((self.units / "zomboid.service").read_text(), "concurrent owner\n")


if __name__ == "__main__":
    unittest.main()
