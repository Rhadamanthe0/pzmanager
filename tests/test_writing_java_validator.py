"""Real cleanup/files/processes; compiler and proprietary PZ loader simulated."""
import json
import os
from pathlib import Path
import sys
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
        with sqlite3.connect(self.storage.world / 'players.db') as db:
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


if __name__ == '__main__':
    unittest.main()
