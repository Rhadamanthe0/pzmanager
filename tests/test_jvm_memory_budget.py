"""Un ancien Xmx20 ne doit pas démarrer sous un plafond total20."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "data/scripts/lib/jvm_memory_budget.py"
spec = importlib.util.spec_from_file_location("jvm_memory_budget", MODULE)
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class StartupBudget(unittest.TestCase):
    def test_default_minipc_and_smaller_host(self):
        self.assertEqual(budget.choose_heap_gib("", 32130864), 16)
        self.assertEqual(budget.choose_heap_gib("", 8 * 1024 ** 2), 4)
        self.assertEqual(budget.choose_heap_gib("", 128 * 1024 ** 2), 16)
        self.assertEqual(budget.choose_heap_gib("8", 32130864), 8)

    def test_invalid_or_obsolete_override_is_not_silently_clamped(self):
        for value in ["20", "17", "1", "0", "-1", "016", "2+14", "$(false)", "16g"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                budget.choose_heap_gib(value, 32130864)

    def test_heap_and_full_cgroup_budget(self):
        self.assertEqual(budget.validate_config({"vmArgs": ["-Xmx16g"]}, 20 * budget.GIB), 16 * budget.GIB)
        self.assertEqual(budget.validate_config({"vmArgs": ["-Xmx8g"]}, 12 * budget.GIB), 8 * budget.GIB)
        for args, limit in [(["-Xmx20g"], 20), (["-Xmx16g"], 18), (["-Xmx16g"], 24)]:
            with self.subTest(args=args, limit=limit), self.assertRaises(ValueError):
                budget.validate_config({"vmArgs": args}, limit * budget.GIB)

    def test_ambiguous_or_missing_effective_heap_is_rejected(self):
        with self.assertRaises(ValueError):
            budget.validate_config([], 20 * budget.GIB)
        for args in [[], ["-Xmx8g", "-Xmx16g"], ["-Xmx16g", "-XX:MaxHeapSize=20g"],
                     ["-Xmx16g", "-XX:MaxRAMPercentage=90"], ["-Xmx16g", "-Xms20g"], "-Xmx16g"]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                budget.validate_config({"vmArgs": args}, 20 * budget.GIB)

    def test_cgroup_ancestor_limit_is_not_ignored(self):
        with tempfile.TemporaryDirectory(prefix="pz-budget-cgroup-") as tmp:
            root = Path(tmp)
            (root / "groups/user/service").mkdir(parents=True)
            (root / "groups/user/service/memory.max").write_text(str(20 * budget.GIB))
            (root / "groups/user/memory.max").write_text(str(18 * budget.GIB))
            proc = root / "cgroup"
            proc.write_text("0::/user/service\n")
            limit = budget.cgroup_memory_max(proc, root / "groups")
            self.assertEqual(limit, 18 * budget.GIB)
            with self.assertRaises(ValueError):
                budget.validate_config({"vmArgs": ["-Xmx16g"]}, limit)
            (root / "groups/user/memory.max").write_text("max")
            self.assertEqual(budget.cgroup_memory_max(proc, root / "groups"), 20 * budget.GIB)
            (root / "groups/user/service/memory.max").write_text("max")
            with self.assertRaises(ValueError):
                budget.cgroup_memory_max(proc, root / "groups")
            (root / "groups/user/memory.max").write_text(str(20 * budget.GIB))
            self.assertEqual(budget.cgroup_memory_max(proc, root / "groups"), 20 * budget.GIB)
            proc.write_text("0::/user/../service\n")
            with self.assertRaises(ValueError):
                budget.cgroup_memory_max(proc, root / "groups")

    def test_check_cli_is_read_only_and_uses_actual_limit_by_default(self):
        with tempfile.TemporaryDirectory(prefix="pz-budget-cli-") as tmp:
            path = Path(tmp) / "ProjectZomboid64.json"
            original = json.dumps({"vmArgs": ["-Xmx20g"]})
            path.write_text(original)
            with patch.object(budget, "check_process"), \
                    patch.object(budget, "cgroup_memory_max", return_value=20 * budget.GIB) as current, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(budget.main(["check", str(path)]), 1)
                current.assert_called_once_with()
            self.assertEqual(path.read_text(), original)
            path.write_text(json.dumps({"vmArgs": ["-Xmx16g"]}))
            with patch.object(budget, "cgroup_memory_max", side_effect=AssertionError("offline only")), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(budget.main(["check", str(path), "--planned-limit", "20G"]), 0)

    def test_configure_jvm_refuses_old_override_before_any_write(self):
        with tempfile.TemporaryDirectory(prefix="pz-configure-budget-") as tmp:
            root = Path(tmp)
            internal = root / "scripts/internal"
            lib = root / "scripts/lib"
            internal.mkdir(parents=True)
            lib.mkdir()
            install = root / "pzserver"
            install.mkdir()
            logs = root / "logs"
            logs.mkdir()
            shutil.copyfile(ROOT / "data/scripts/internal/configureJvm.sh", internal / "configureJvm.sh")
            shutil.copyfile(MODULE, lib / "jvm_memory_budget.py")
            shutil.copyfile(ROOT / "data/scripts/lib/shared_memory_budget.py", lib / "shared_memory_budget.py")
            (lib / "common.sh").write_text("source_env() { :; }\n")
            config = install / "ProjectZomboid64.json"
            config.write_text(json.dumps({"vmArgs": ["-Xmx20g", "-Xms20g", "-XX:MaxHeapSize=20g"]}))
            backup = install / "ProjectZomboid64.json.bak"
            backup.write_text("previous backup sentinel")
            original = config.read_bytes()
            env = dict(os.environ, PZ_INSTALL_DIR=str(install), LOG_ZOMBOID_DIR=str(logs), PZ_XMX_GB="20")
            run = subprocess.run(["bash", str(internal / "configureJvm.sh")], env=env,
                                 capture_output=True, text=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("2 à 16", run.stderr)
            self.assertEqual(config.read_bytes(), original)
            self.assertEqual(backup.read_text(), "previous backup sentinel")
            env["PZ_XMX_GB"] = "16"
            run = subprocess.run(["bash", str(internal / "configureJvm.sh")], env=env,
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(config.read_text())
            self.assertEqual(budget.validate_config(result, 20 * budget.GIB), 16 * budget.GIB)
            self.assertEqual(backup.read_bytes(), original)
            self.assertFalse(any(arg.startswith("-Xms") for arg in result["vmArgs"]))

    def test_service_preflight_is_blocking_before_purge_and_launch(self):
        unit = (ROOT / "data/setupTemplates/zomboid.service").read_text()
        preflight = "ExecStartPre=/usr/bin/python3 %h/pzmanager/data/scripts/lib/jvm_memory_budget.py check %h/pzmanager/data/pzserver/ProjectZomboid64.json"
        self.assertIn(preflight, unit)
        self.assertLess(unit.index(preflight), unit.index("ExecStartPre=%h/pzmanager/data/scripts/internal/prepareWorldStart.sh"))
        self.assertLess(unit.index(preflight), unit.index("ExecStart="))
        self.assertIn("MemoryMax=20G", unit)
        self.assertNotIn("--planned-limit", unit)


if __name__ == "__main__":
    unittest.main()
