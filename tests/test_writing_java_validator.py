"""Real cleanup/files/processes; compiler and proprietary PZ loader simulated."""
import json
import os
from contextlib import closing
from pathlib import Path
import sys
import pwd
import shutil
import subprocess
import tempfile
import shlex
import unittest
from unittest.mock import patch

import test_writing_restart_cleanup as fixture


class CompilerDependency(unittest.TestCase):
    def setUp(self):
        self.storage = fixture.OfflineCleanup('test_whole_plan_backup_sqlite_atomicity_and_idempotence')
        self.storage.setUp()
        self.addCleanup(self.storage.doCleanups)
        self.root = self.storage.root
        self.jar = self.root / 'projectzomboid.jar'
        self.jar.write_bytes(b'fixture path; compiler/PZ loader simulated')
        self.log = self.root / 'processes.jsonl'
        self.java = self.executable('jre/bin/java',
            "if sys.argv[1:]==['-version']:\n print('openjdk version \"25.0.1\"',file=sys.stderr)\n raise SystemExit(0)\n"
            "manifest=json.loads(Path(sys.argv[-1]).read_text())\n"
            "assert manifest['records']\n"
            "for record in manifest['records']:\n"
            " for side in ['before','after']:\n"
            "  blob=Path(record[side]).read_bytes()\n"
            "  assert int.from_bytes(blob[:4],'big')==len(blob)-4\n")
        self.compiler = self.executable('jdk/bin/javac', '')
        # These storage fixtures are synthetic, not real PZ terrain. Exercise
        # the complete-terrain orchestration separately below.
        terrain=patch.object(fixture.cleaner.JavaValidator,'validate_terrain')
        self.terrain_validation=terrain.start();self.addCleanup(terrain.stop)
        storage=patch.object(fixture.cleaner.JavaValidator,'validate_storage')
        storage.start();self.addCleanup(storage.stop)
        def native_envelopes(validator,stage,blob,kind,version,path):
            validator.tools()  # Compiler/JVM admission is real; native record decoding is a fixture.
            return fixture.synthetic_envelopes(blob)
        native=patch.object(fixture.cleaner.JavaValidator,'native_envelopes',native_envelopes)
        native.start();self.addCleanup(native.stop)

    def executable(self, name, body):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!' + sys.executable + '\nimport sys,json\nfrom pathlib import Path\n'
                        + 'with Path(' + repr(str(self.log)) + ').open("a") as log: '
                        + 'log.write(json.dumps(sys.argv)+"\\n")\n' + body)
        path.chmod(0o700)
        return path

    def validator(self, compiler=None):
        return fixture.cleaner.JavaValidator(self.jar, self.java, compiler)

    def apply(self, validator):
        return fixture.cleaner.cleanup(self.storage.world, self.storage.backups, validator=validator)

    def assert_refused(self, validator, message):
        before = self.storage.sources()
        with self.assertRaisesRegex(fixture.cleaner.CleanupError, message):
            self.apply(validator)
        self.assertEqual(self.storage.sources(), before)
        self.assertFalse(self.storage.backups.exists())

    def test_clean_world_needs_no_compiler_or_runtime(self):
        self.storage.path.write_bytes(fixture.chunk(fixture.nested(False)))
        import sqlite3
        with closing(sqlite3.connect(self.storage.world / 'players.db')) as db, db:
            db.execute('UPDATE networkPlayers SET data=?', (fixture.nested(False),))
        before = self.storage.sources()
        self.assertEqual(self.apply(fixture.cleaner.JavaValidator(
            self.jar, self.root / 'missing-java', self.root / 'missing-javac'))['files'], 0)
        self.assertEqual(self.storage.sources(), before)
        self.assertFalse(self.log.exists())

    def test_missing_compiler_explains_dependency_before_mutation(self):
        with patch.object(fixture.cleaner.shutil, 'which', return_value=None):
            self.assert_refused(self.validator(), 'PZ_WRITING_CLEANUP_JAVAC')

    def test_explicit_bad_override_never_falls_back(self):
        with patch.object(fixture.cleaner.shutil, 'which', return_value=str(self.compiler)) as lookup:
            self.assert_refused(self.validator(self.root / 'missing-javac'), 'missing-javac')
            lookup.assert_not_called()

    def test_path_jdk_with_bundled_jre_validates_then_preserves_recovery_copies(self):
        before = self.storage.sources()
        with patch.object(fixture.cleaner.shutil, 'which', return_value=str(self.compiler)):
            result = self.apply(self.validator())
        self.assertEqual(result['files'], 2)
        stage = Path(result['backup'])
        manifest = json.loads((stage / 'manifest.json').read_text())
        self.assertEqual(manifest['state'], 'complete')
        for entry in manifest['files']:
            self.assertEqual((stage / 'original' / entry['path']).read_bytes(), before[entry['path']])
        self.assertEqual(self.storage.path.read_bytes(), fixture.chunk(fixture.nested(False)))
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        compile_call = next(call for call in calls if call[0] == str(self.compiler))
        self.assertEqual(compile_call[1:3], ['--release', '25'])
        self.assertTrue(any('-Xmx512m' in call for call in calls))

    def test_runtime_sibling_precedes_path_compiler(self):
        sibling = self.executable('jre/bin/javac', '')
        with patch.object(fixture.cleaner.shutil, 'which', side_effect=AssertionError('PATH must not be used')):
            validator = self.validator()
            self.assertEqual(validator.tools(), '25')
            self.assertEqual(validator.javac, str(sibling))

    def test_old_compiler_and_loader_rejection_both_preserve_world(self):
        self.executable('jdk/bin/javac', 'raise SystemExit(2)\n')
        self.assert_refused(self.validator(self.compiler), 'validation failed')
        self.executable('jdk/bin/javac', '')
        self.executable('jre/bin/java',
            "if sys.argv[1:]==['-version']:\n print('openjdk version \"25.0.1\"',file=sys.stderr)\n raise SystemExit(0)\n"
            'raise SystemExit(3)\n')
        self.assert_refused(self.validator(self.compiler), 'validation failed')



class JreOnlyStartup(unittest.TestCase):
    """Exercise the shipped shell/admission/configuration/cleanup chain offline."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='pz-jre-startup-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / 'repository'
        scripts = self.repo / 'data/scripts'
        shutil.copytree(Path(__file__).resolve().parents[1] / 'data/scripts', scripts)
        (self.repo / 'data/dataBackups').mkdir(mode=0o700)
        self.world = self.repo / 'Zomboid/Saves/Multiplayer/servertest'
        self.world.mkdir(parents=True)
        server = self.repo / 'Zomboid/Server'; server.mkdir()
        (server / 'servertest.ini').write_text('Mods=ProjectWriting\n')
        (server / 'servertest_SandboxVars.lua').write_text('SandboxVars = { VERSION = 5 }\n')
        self.install = self.repo / 'data/pzserver'
        (self.install / 'java').mkdir(parents=True)
        (self.install / 'media/scripts').mkdir(parents=True)
        (self.install / 'media/scripts/items.txt').write_text(
            'module Base { item Diary2 { ItemType = base:Literature, } }')
        (self.install / 'java/projectzomboid.jar').write_bytes(b'fixture; not loaded')
        runtime = self.install / 'jre64/bin'; runtime.mkdir(parents=True)
        self.java_log = self.root / 'java-invoked'
        java = runtime / 'java'
        java.write_text('#!' + sys.executable + '\nfrom pathlib import Path\nPath('
                        + repr(str(self.java_log)) + ').touch()\nraise SystemExit(99)\n')
        java.chmod(0o700)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        # Restricted PATH models an actual JRE-only installation, even on JDK CI hosts.
        for name in ['bash', 'python3', 'id', 'dirname', 'realpath', 'stat', 'mkdir',
                     'chmod', 'getent', 'flock', 'cat', 'date', 'readlink']:
            target = shutil.which(name)
            if target: (self.bin / name).symlink_to(target)
        systemctl = self.bin / 'systemctl'
        systemctl.write_text('#!/bin/bash\nprintf "ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0\\n"\n')
        systemctl.chmod(0o700)
        self.runtime = self.root / 'runtime'; self.runtime.mkdir(mode=0o700)
        values = dict(PZ_USER=pwd.getpwuid(os.getuid()).pw_name, JAVA_PATH=str(runtime.parent),
                      PZ_WRITING_TEXT_ONLY='1', PZ_SERVICE_NAME='fixture.service')
        env_file = self.repo / '.env'
        env_file.write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in values.items()))
        env_file.chmod(0o600)
        # Real budget reader, private cgroup evidence; no production guard is disabled.
        proc = self.root / 'proc-cgroup'; cg = self.root / 'cgroups'
        group = '/user.slice/user-1005.slice/user@1005.service/pz.slice'
        proc.write_text('0::' + group + '/fixture.scope\n')
        parent = cg / group.lstrip('/'); parent.mkdir(parents=True)
        for name, value in {'memory.max': str(20 * 2**30), 'memory.swap.max': '0', 'memory.current': '0'}.items():
            (parent / name).write_text(value)
        helper = scripts / 'lib/shared_memory_budget.py'
        helper.write_text(helper.read_text().replace('Path("/proc/self/cgroup")', 'Path(' + repr(str(proc)) + ')')
                          .replace('Path("/sys/fs/cgroup")', 'Path(' + repr(str(cg)) + ')'))
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('PZ_', 'BACKUP_', 'JAVA_', 'STEAM_', 'LOG_'))
                    and k not in {'BASH_ENV', 'ENV', 'XDG_RUNTIME_DIR'}}
        self.env.update(PATH=str(self.bin), XDG_RUNTIME_DIR=str(self.runtime))

    def start(self):
        return subprocess.run(['/bin/bash', str(self.repo / 'data/scripts/internal/configureWritingTextOnly.sh')],
                              env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=15)

    def add_chunk(self, dirty):
        path = self.world / 'map/1/2.bin'; path.parent.mkdir(parents=True)
        path.write_bytes(fixture.chunk(fixture.nested(dirty)))
        (self.world / 'WorldDictionaryReadable.lua').write_text('items = {\n' + ',\n'.join(
            f'{{ registryID = {i}, fulltype = "{name}", modID = "pz-vanilla", isModded = false }}'
            for i, name in fixture.REGISTRY.items()) + '\n}\nentities = {}\nscripts = {}\n')

    def world_bytes(self):
        return {str(p.relative_to(self.world)): p.read_bytes() for p in self.world.rglob('*') if p.is_file()}

    def test_empty_and_clean_world_start_without_javac(self):
        for populated in (False, True):
            with self.subTest(populated=populated):
                if populated: self.add_chunk(False)
                before = self.world_bytes()
                result = self.start()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.world_bytes(), before)
                self.assertFalse(self.java_log.exists())
                self.assertEqual(list((self.repo / 'data/dataBackups').rglob('manifest.json')), [])

    def test_dirty_world_requires_compiler_before_mutation(self):
        self.add_chunk(True)
        before = self.world_bytes()
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PZ_WRITING_CLEANUP_JAVAC', result.stdout + result.stderr)
        self.assertEqual(self.world_bytes(), before)
        self.assertFalse(self.java_log.exists())
        self.assertEqual(list((self.repo / 'data/dataBackups').rglob('manifest.json')), [])


class CompleteTerrainValidation(unittest.TestCase):
    def setUp(self):
        self.storage=fixture.OfflineCleanup('test_whole_plan_backup_sqlite_atomicity_and_idempotence')
        self.storage.setUp();self.addCleanup(self.storage.doCleanups)
        (self.storage.world/'WorldDictionary.bin').write_bytes(b'copied binary dictionary fixture')

    def test_native_chunk_failure_refuses_entire_cleanup_before_mutation(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        native=Mock();native.index.side_effect=ValueError('nested floor bag framing invalid')
        factory=Mock(return_value=native)
        validator=fixture.cleaner.JavaValidator('jar','java','javac',world=self.storage.world)
        before=self.storage.sources()
        with patch.dict(sys.modules,terrain_tiles=SimpleNamespace(NativeIndexer=factory)), \
             patch.object(validator,'tools',return_value='25'),patch.object(validator,'run'), \
             patch.object(validator,'native_envelopes',side_effect=lambda stage,blob,*a:fixture.synthetic_envelopes(blob)):
            with self.assertRaisesRegex(fixture.cleaner.CleanupError,'complete terrain validation failed'):
                fixture.cleaner.cleanup(self.storage.world,self.storage.backups,validator=validator)
        self.assertEqual(self.storage.sources(),before)
        self.assertFalse(self.storage.backups.exists())
        inputs=native.index.call_args.args[0]
        self.assertEqual([(e['x'],e['y']) for e in inputs],[(1,2),(1,2)])
        self.assertIn('/original/map/1/2.bin',inputs[0]['file'])
        self.assertIn('/new/map/1/2.bin',inputs[1]['file'])
        self.assertEqual(factory.call_args.kwargs,{'java':'java','javac':'javac','trace_items':True})

    def test_chunk_validation_requires_binary_dictionary_context(self):
        root=self.storage.root/'validation';root.mkdir()
        validator=fixture.cleaner.JavaValidator('jar','java','javac')
        with self.assertRaisesRegex(fixture.cleaner.CleanupError,'world dictionary'):
            validator.validate_terrain(root,[{'path':'map/1/2.bin'}],root)


if __name__ == '__main__':
    unittest.main()
