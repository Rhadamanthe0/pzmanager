"""Read-only mod removal checks against synthetic PZ readable dictionaries."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'data/scripts/internal'))
import checkWorldMods as checker

DICTIONARY = '''items = {}
entities = {{ registryID=1, fulltype="Base.LogCabinWall", modID="Izbushka",
isModded=true, removed=false, existsAsVanilla=false }}
objects = {0 = "Tree"}
sprites = {}
strings = {}
}
scripts = { SpriteConfigs = {{name="Base.LogCabinWall",isLoaded=true}} }
'''


class ModRemoval(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dictionary = self.root / 'WorldDictionaryReadable.lua'
        self.dictionary.write_text(DICTIONARY)
        self.ini = self.root / 'candidate.ini'

    def test_removed_mod_required_by_client_is_refused(self):
        self.ini.write_text('Mods=\\Other\n')
        with self.assertRaisesRegex(ValueError, 'Izbushka.*Base.LogCabinWall'):
            checker.require_compatible(self.dictionary, self.ini)
        self.assertEqual(self.dictionary.read_text(), DICTIONARY)

    def test_restoring_mod_resolves_requirement(self):
        self.ini.write_text('Mods=\\Other;\\Izbushka\n')
        self.assertEqual(checker.require_compatible(self.dictionary, self.ini)['required_missing'], {})

    def test_game_supported_line_whitespace_and_duplicate_detection(self):
        self.ini.write_text('  Mods=\\Izbushka  \n')
        self.assertEqual(checker.require_compatible(self.dictionary,self.ini)['required_missing'],{})
        self.ini.write_text('Mods=\\Izbushka\n\tMods=\\Other\n')
        with self.assertRaisesRegex(ValueError,'exactly one Mods='):
            checker.check(self.dictionary,self.ini)

    def test_removed_flag_does_not_hide_loaded_script(self):
        self.dictionary.write_text(DICTIONARY.replace('removed=false', 'removed=true'))
        self.ini.write_text('Mods=\\Other\n')
        with self.assertRaises(ValueError):
            checker.require_compatible(self.dictionary, self.ini)

    def test_historical_items_warn_without_blocking(self):
        self.dictionary.write_text(DICTIONARY.replace('isLoaded=true', 'isLoaded=false'))
        self.ini.write_text('Mods=\\Other\n')
        report = checker.require_compatible(self.dictionary, self.ini)
        self.assertEqual(report['required_missing'], {})
        self.assertIn('Izbushka', report['historical_missing'])

    def test_unknown_script_state_and_missing_or_invalid_identity_are_refused(self):
        self.ini.write_text('Mods=\\Other\n')
        cases = ['isLoaded="unknown"', 'isLoaded="true"', 'isLoaded=1',
                 'isLoaded=nil', '', 'isLoaded={}', 'isLoaded=true, isLoaded=false']
        for value in cases:
            with self.subTest(flag=value):
                self.dictionary.write_text(DICTIONARY.replace('isLoaded=true', value))
                with self.assertRaises(ValueError):
                    checker.check(self.dictionary, self.ini)
        for value in ['', 'name=""', 'name="   "', 'name=12', 'name=false', 'name={}']:
            for state in ('true', 'false'):
                with self.subTest(name=value, loaded=state):
                    self.dictionary.write_text(DICTIONARY.replace('name="Base.LogCabinWall",', value + ',' if value else '')
                                               .replace('isLoaded=true', 'isLoaded=' + state))
                    with self.assertRaises(ValueError):
                        checker.check(self.dictionary, self.ini)

    def test_owner_identity_and_modded_flag_types_are_required_even_for_enabled_mod(self):
        self.ini.write_text('Mods=\\Izbushka\n')
        for key, original, replacements in [
                ('fulltype', '"Base.LogCabinWall"', ['""', '42', 'false', '{}']),
                ('modID', '"Izbushka"', ['""', '42', 'nil', '{}']),
                ('isModded', 'true', ['"true"', '0', 'nil', '{}'])]:
            for value in replacements:
                with self.subTest(key=key, value=value):
                    self.dictionary.write_text(DICTIONARY.replace(key+'='+original, key+'='+value))
                    with self.assertRaises(ValueError):
                        checker.check(self.dictionary, self.ini)
            self.dictionary.write_text(DICTIONARY.replace(key+'='+original+',', ''))
            with self.assertRaises(ValueError):
                checker.check(self.dictionary, self.ini)

    def test_new_static_fields_do_not_change_supported_loaded_or_historical_contract(self):
        self.ini.write_text('Mods=\\Other\n')
        self.dictionary.write_text(DICTIONARY.replace('isLoaded=true', 'isLoaded=false, futureField={"extra"}'))
        self.assertIn('Izbushka', checker.require_compatible(self.dictionary, self.ini)['historical_missing'])

    def test_loaded_script_without_assessable_owner_is_unknown_not_compatible(self):
        self.ini.write_text('Mods=\\Other\n')
        orphan = 'items={} entities={} scripts={SpriteConfigs={{name="Base.Orphan",isLoaded=true}}}'
        self.dictionary.write_text(orphan)
        with self.assertRaisesRegex(ValueError, 'no assessable dictionary owner'):
            checker.require_compatible(self.dictionary, self.ini)
        self.assertEqual(self.dictionary.read_text(), orphan)
        self.dictionary.write_text(orphan.replace('isLoaded=true', 'isLoaded=false'))
        self.assertEqual(checker.require_compatible(self.dictionary, self.ini)['required_missing'], {})

    def test_loaded_script_with_unavailable_nonmodded_origin_is_not_treated_as_compatible(self):
        self.ini.write_text('Mods=\\Other\n')
        self.dictionary.write_text(DICTIONARY.replace('isModded=true', 'isModded=false'))
        with self.assertRaisesRegex(ValueError, 'no assessable dictionary owner'):
            checker.require_compatible(self.dictionary, self.ini)

    def test_new_world_and_malformed_existing_dictionary(self):
        self.ini.write_text('Mods=\\Other\n')
        self.dictionary.unlink()
        self.assertEqual(checker.require_compatible(self.dictionary, self.ini)['required_missing'], {})
        self.dictionary.write_text('items = {}')
        with self.assertRaises(ValueError):
            checker.require_compatible(self.dictionary, self.ini)

    def test_saved_world_without_dictionary_is_refused(self):
        self.ini.write_text('Mods=\\Other\n')
        self.dictionary.unlink()
        (self.root/'players.db').write_bytes(b'saved data')
        with self.assertRaisesRegex(ValueError, 'lacks a readable dictionary'):
            checker.require_compatible(self.dictionary, self.ini)

    def test_startup_checks_removal_before_mutating_configuration_even_when_writing_disabled(self):
        import configureWritingTextOnly as config
        import writing_start_admission as admission
        self.ini.write_text('Mods=\\Other\n')
        argv = ['configureWritingTextOnly.py', '--install-dir', str(self.root),
                '--sandbox-file', str(self.root/'sandbox.lua'), '--ini-file', str(self.ini),
                '--cleanup-world', str(self.root), '--cleanup-backups', str(self.root/'backups'), '--mode', '0']
        with patch.object(sys, 'argv', argv), patch.object(admission, 'validate_worker_admission', return_value=0), \
                patch.object(config, 'configure') as mutate:
            self.assertEqual(config.main(), 1)
        mutate.assert_not_called()

    def test_startup_refuses_malformed_script_before_mutating_configuration(self):
        import configureWritingTextOnly as config
        import writing_start_admission as admission
        self.ini.write_text('Mods=\\Other\n')
        argv = ['configureWritingTextOnly.py', '--install-dir', str(self.root),
                '--sandbox-file', str(self.root/'sandbox.lua'), '--ini-file', str(self.ini),
                '--cleanup-world', str(self.root), '--cleanup-backups', str(self.root/'backups'), '--mode', '0']
        for broken in (DICTIONARY.replace('name="Base.LogCabinWall",', ''),
                       DICTIONARY.replace('isLoaded=true', 'isLoaded="unknown"'),
                       'items={} entities={} scripts={SpriteConfigs={{name="Base.Orphan",isLoaded=true}}}'):
            self.dictionary.write_text(broken)
            with patch.object(sys, 'argv', argv), patch.object(admission, 'validate_worker_admission', return_value=0), \
                    patch.object(config, 'configure') as mutate:
                self.assertEqual(config.main(), 1)
            mutate.assert_not_called()
            self.assertEqual(self.dictionary.read_text(), broken)
            self.assertFalse((self.root/'backups').exists())


if __name__ == '__main__':
    unittest.main()
