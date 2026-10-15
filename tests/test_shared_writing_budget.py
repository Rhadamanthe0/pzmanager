"""Entrées Python Writing : fixtures privées, vrai flock, aucun cgroup hôte modifié."""
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GROUP = "/user.slice/user-1005.slice/user@1005.service/pz.slice"


class WritingBudgetEntrypoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pz-writing-budget-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = self.root / "project"
        self.internal = self.project / "data/scripts/internal"
        self.lib = self.project / "data/scripts/lib"
        self.internal.mkdir(parents=True)
        self.lib.mkdir()
        for name in ('terrain_tiles.py','world_transaction.py'):
            shutil.copyfile(ROOT / 'data/scripts/lib' / name, self.lib / name)
        for name in ["cleanWritingDrawings.py", "writing_start_admission.py", "configureWritingTextOnly.py"]:
            shutil.copyfile(ROOT / "data/scripts/internal" / name, self.internal / name)
        self.proc = self.root / "proc_cgroup"
        self.proc.write_text("0::" + GROUP + "/pz-command-fixture.scope\n")
        self.cg = self.root / "cgroups"
        parent = self.cg / GROUP.lstrip("/")
        parent.mkdir(parents=True)
        (parent / "memory.max").write_text(str(20 * 1024 ** 3))
        (parent / "memory.swap.max").write_text("0")
        (parent / "memory.current").write_text("100")
        # Substitution dans CETTE copie uniquement. Aucun drapeau ENV de bypass.
        source = (ROOT / "data/scripts/lib/shared_memory_budget.py").read_text()
        source = source.replace('Path("/proc/self/cgroup")', "Path(" + repr(str(self.proc)) + ")")
        source = source.replace('Path("/sys/fs/cgroup")', "Path(" + repr(str(self.cg)) + ")")
        (self.lib / "shared_memory_budget.py").write_text(source)
        self.private = self.root / "runtime"
        self.private.mkdir(mode=0o700)
        self.lock = self.private / "world.lock"
        self.bus_called = self.root / "bus-called"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        bus = self.bin / "systemctl"
        bus.write_text("#!" + sys.executable + "\nfrom pathlib import Path\n"
                       + "Path(" + repr(str(self.bus_called)) + ").touch()\n"
                       + "print('ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0')\n")
        bus.chmod(0o700)
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "PZ_BUDGET_SCOPED": "1"}

    def invoke(self, name, *args):
        return subprocess.run([sys.executable, str(self.internal / name), *map(str, args)],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_outside_or_wrong_cap_refuses_every_python_entry_before_world_or_bus(self):
        for invalid in ["outside", "24g"]:
            if invalid == "outside":
                self.proc.write_text("0::/user.slice/user-1005.slice/session-30.scope\n")
            else:
                self.proc.write_text("0::" + GROUP + "/pz-command-fixture.scope\n")
                (self.cg / GROUP.lstrip("/") / "memory.max").write_text(str(24 * 1024 ** 3))
            for name, args in [
                ("cleanWritingDrawings.py", ["--world-dir", self.root / "absent-world",
                                             "--backup-dir", self.root / "absent-backup"]),
                ("writing_start_admission.py", ["run", "--lock-path", self.lock,
                                                "--unit", "probe.service", "--", "false"]),
                ("writing_start_admission.py", ["prepare", "--lock-path", self.lock,
                                                "--unit", "probe.service", "--pid", os.getpid(), "--fd", "9"]),
                ("writing_start_admission.py", ["clear", "--lock-path", self.lock, "--token", "0" * 32]),
                ("writing_start_admission.py", ["broker", "--lock-path", self.lock,
                                                "--unit", "probe.service", "--pid", os.getpid(),
                                                "--birth", "0", "--fd", "9", "--token", "0" * 32]),
            ]:
                with self.subTest(invalid=invalid, name=name, action=args[0]):
                    result = self.invoke(name, *args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("pz.slice", result.stderr)
                    self.assertFalse(self.bus_called.exists())
                    self.assertEqual(list(self.private.iterdir()), [])
                    self.assertFalse((self.root / "absent-backup").exists())

    def test_inside_offline_admission_preserves_real_world_fd_to_worker(self):
        done = self.root / "done"
        code = ("import os,sys; from pathlib import Path; sys.path.insert(0," + repr(str(self.internal))
                + "); from writing_start_admission import validate_worker_admission; "
                + "fd=validate_worker_admission(); os.fstat(fd); Path(" + repr(str(done))
                + ").write_text(str(fd))")
        result = self.invoke("writing_start_admission.py", "run", "--lock-path", self.lock,
                             "--unit", "probe.service", "--", sys.executable, "-c", code)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(done.read_text().isdigit())
        self.assertTrue(self.bus_called.exists())
        self.assertFalse((self.private / "writing-start.json").exists())

    def test_inside_cleaner_reaches_its_parser_without_touching_world(self):
        result = self.invoke("cleanWritingDrawings.py", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--world-dir", result.stdout)
        self.assertFalse(self.bus_called.exists())
        self.assertEqual(list(self.private.iterdir()), [])

    def test_missing_or_empty_world_needs_no_jdk_even_with_installed_jre(self):
        jar = self.root / "projectzomboid.jar"
        jar.write_bytes(b"synthetic path placeholder; never executed")
        empty = self.root / "empty-world"
        empty.mkdir(mode=0o700)
        for world in [self.root / "absent-world", empty]:
            with self.subTest(world=world.name):
                result = self.invoke("writing_start_admission.py", "run", "--lock-path", self.lock,
                                     "--unit", "probe.service", "--", sys.executable,
                                     self.internal / "cleanWritingDrawings.py", "--world-dir", world,
                                     "--backup-dir", self.root / "backups", "--jar", jar,
                                     "--java", "/usr/bin/true", "--javac", self.root / "missing-javac")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["files"], 0)
                self.assertFalse((self.root / "backups").exists())

    def test_populated_clean_world_skips_jdk_but_dirty_world_still_fails_before_mutation(self):
        fixture_file = ROOT / "tests/test_writing_restart_cleanup.py"
        spec = importlib.util.spec_from_file_location("writing_cleanup_fixture_for_budget", fixture_file)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        world = self.root / "populated-world"
        world.mkdir(mode=0o700)
        (world / "WorldDictionaryReadable.lua").write_text(
            '\n'.join(f'{{ registryID = {i}, fulltype = "{name}" }}' for i, name in fixture.REGISTRY.items()))
        script_dir = self.root / "scripts"
        script_dir.mkdir()
        (script_dir / "fixture.txt").write_text(
            "module Base { item Diary2 { Type = Literature, } item Bag_SurvivorBag { Type = Container, } }")
        item_file = world / "map/1/2.bin"
        item_file.parent.mkdir(parents=True)
        jar = self.root / "projectzomboid.jar"
        jar.write_bytes(b"synthetic path placeholder; never executed")
        for dirty in [False, True]:
            with self.subTest(dirty=dirty):
                original = fixture.chunk(fixture.nested(dirty))
                item_file.write_bytes(original)
                result = self.invoke("writing_start_admission.py", "run", "--lock-path", self.lock,
                                     "--unit", "probe.service", "--", sys.executable,
                                     self.internal / "cleanWritingDrawings.py", "--world-dir", world,
                                     "--backup-dir", self.root / "backups", "--jar", jar,
                                     "--java", "/usr/bin/true", "--javac", self.root / "missing-javac",
                                     "--scripts-dir", script_dir)
                self.assertEqual(result.returncode, int(dirty), result.stderr)
                if dirty:
                    self.assertIn("missing-javac", result.stderr)
                else:
                    self.assertEqual(json.loads(result.stdout)["files"], 0)
                self.assertEqual(item_file.read_bytes(), original)
                self.assertFalse((self.root / "backups").exists())


if __name__ == "__main__":
    unittest.main()
