import os
import stat
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'data/scripts/internal'))
import configureWritingTextOnly as installer

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.previous_umask = os.umask(0o077)
        self.temp = tempfile.TemporaryDirectory(prefix='pz-writing-installer-test-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.install = self.root/'game'; self.install.mkdir(mode=0o755)
        self.ini = self.root/'server.ini'; self.ini.write_text('Mods=Something;ProjectWriting;Another\n')
        self.sandbox = self.root/'server_SandboxVars.lua'
        self.sandbox.write_text('SandboxVars = {\n    VERSION = 5,\n    Zombies = 4,\n    ProjectWriting = {\n        Freehand = true, -- preserve this comment\n        VanillaMap = false,\n        Other = "keep { text }",\n    },\n}\n')
        self.sandbox.chmod(0o644)
        self.source = self.root/'source.lua'; self.source.write_text('-- server guard\nprint("guard")\n')
        self.target = self.install.joinpath(*installer.GUARD_PARTS)/installer.GUARD_NAME
    def tearDown(self):
        self.temp.cleanup()
        os.umask(self.previous_umask)
    def run_install(self, mode=1):
        return installer.configure(self.install, self.sandbox, self.ini, self.source, mode)
    def assert_refused_unchanged(self):
        sandbox = self.sandbox.read_bytes(); source = self.source.read_bytes()
        before = list(self.install.rglob('*'))
        with self.assertRaises((installer.ConfigurationError, OSError)): self.run_install()
        self.assertEqual(self.sandbox.read_bytes(), sandbox)
        self.assertEqual(self.source.read_bytes(), source)
        self.assertEqual(list(self.install.rglob('*')), before)
    def test_enable_preserves_original_text_and_options(self):
        before=self.sandbox.read_text()
        self.assertEqual(self.run_install(), 'enabled')
        self.assertFalse(self.target.exists()); self.assertNotIn(installer.BEGIN_MARKER, self.sandbox.read_text())
        self.assertFalse((self.install/'media').exists())
        self.assertEqual(installer.strip_managed_guard(self.sandbox.read_text()), before.replace('Freehand = true', 'Freehand = false').replace('VanillaMap = false', 'VanillaMap = true'))
    def test_exact_mod_tokens(self):
        for value in ('ProjectWritingExtra', 'MyProjectWriting', 'projectwriting', 'Something;ProjectWriting_42', ''):
            with self.subTest(value=value):
                self.ini.write_text('Mods='+value+'\n')
                self.target.parent.mkdir(parents=True, exist_ok=True); self.target.parent.chmod(0o755); self.target.parent.parent.chmod(0o755); self.target.parent.parent.parent.chmod(0o755); self.target.write_text('old guard')
                before=self.sandbox.read_bytes()
                self.assertEqual(self.run_install(), 'disabled')
                self.assertFalse(self.target.exists()); self.assertEqual(self.sandbox.read_bytes(),before)
    def test_enable_removes_previous_continuous_guard(self):
        base=self.sandbox.read_text()
        self.sandbox.write_text(installer.append_managed_guard(base, 'Events.OnTickEvenPaused.Add(function() end)\n'))
        self.assertEqual(self.run_install(), 'enabled')
        self.assertNotIn(installer.BEGIN_MARKER, self.sandbox.read_text())
        self.assertNotIn('Events.OnTickEvenPaused', self.sandbox.read_text())
        self.assertIn('Freehand = false', self.sandbox.read_text())

    def test_mode_zero_no_source_or_sandbox_needed(self):
        self.target.parent.mkdir(parents=True); self.target.parent.chmod(0o755); self.target.parent.parent.chmod(0o755); self.target.parent.parent.parent.chmod(0o755); self.target.write_text('old guard')
        self.source.unlink(); self.sandbox.unlink(); self.ini.unlink()
        self.assertEqual(self.run_install(mode=0), 'disabled'); self.assertFalse(self.target.exists())
    def test_build42_prefixed_mod_id_enables_existing_policy(self):
        self.ini.write_text('Mods=\\Something;\\ProjectWriting;\\Another\n')
        self.assertEqual(self.run_install(), 'enabled')
        self.assertIn('Freehand = false', self.sandbox.read_text())
        self.assertFalse(self.target.exists())
        for token in ['\\ProjectWritingAddon', 'Other\\ProjectWriting', '\\\\ProjectWriting']:
            self.assertFalse(installer.mod_enabled('Mods=' + token + '\n'))

    def test_disabled_removes_only_symlink_itself(self):
        self.target.parent.mkdir(parents=True)
        outside=self.root/'outside.lua'; outside.write_text('protected')
        self.target.symlink_to(outside); self.ini.write_text('Mods=SomethingElse\n')
        before=self.sandbox.read_bytes()
        self.run_install(); self.assertFalse(self.target.is_symlink()); self.assertEqual(outside.read_text(),'protected'); self.assertEqual(self.sandbox.read_bytes(),before)
    def test_idempotent_native_options_and_no_auto_lua(self):
        self.run_install(); before=self.sandbox.read_bytes(); sbtime=self.sandbox.stat().st_mtime_ns
        self.run_install(); self.assertEqual(self.sandbox.read_bytes(),before); self.assertEqual(self.sandbox.stat().st_mtime_ns,sbtime)
        self.assertFalse((self.install/'media').exists())
    def test_legacy_checksum_filenames_removed_on_enable_and_disable(self):
        self.target.parent.mkdir(parents=True)
        for name in installer.LEGACY_GUARD_NAMES: (self.target.parent/name).write_text('old guard')
        self.run_install()
        self.assertTrue(all(not (self.target.parent/name).exists() for name in installer.LEGACY_GUARD_NAMES))
        enabled_base=installer.strip_managed_guard(self.sandbox.read_text())
        for name in installer.LEGACY_GUARD_NAMES: (self.target.parent/name).write_text('old guard')
        self.sandbox.write_text(installer.append_managed_guard(enabled_base, self.source.read_text()))
        self.run_install(mode=0)
        self.assertTrue(all(not (self.target.parent/name).exists() for name in installer.LEGACY_GUARD_NAMES))
        self.assertEqual(self.sandbox.read_text(),enabled_base)
        self.assertIn('Freehand = false',enabled_base); self.assertIn('VanillaMap = true',enabled_base)
    def test_mod_absent_strips_footer_preserves_native_flags(self):
        self.run_install(); base=installer.strip_managed_guard(self.sandbox.read_text())
        self.sandbox.write_text(installer.append_managed_guard(base, self.source.read_text()))
        self.ini.write_text('Mods=SomethingElse\n'); self.source.unlink()
        self.run_install(); self.assertEqual(self.sandbox.read_text(),base)
    def test_mod_absent_leaves_unrelated_dynamic_sandbox_untouched(self):
        self.ini.write_text('Mods=SomethingElse\n')
        original = 'SandboxVars = { Zombies = 3 }\nSandboxVars.Zombies = customValue()\n'
        self.sandbox.write_text(original)
        before = self.sandbox.stat().st_mtime_ns
        self.assertEqual(self.run_install(), 'disabled')
        self.assertEqual(self.sandbox.read_text(), original)
        self.assertEqual(self.sandbox.stat().st_mtime_ns, before)
    def test_guard_source_is_never_loaded(self):
        self.run_install(); self.source.write_text('-- replacement guard\nprint("replacement")\n')
        self.run_install(); result=self.sandbox.read_text()
        self.assertNotIn(installer.BEGIN_MARKER,result); self.assertNotIn('print("guard")',result); self.assertNotIn(self.source.read_text(),result)
    def test_add_absent_block_preserves_comments_and_long_strings(self):
        original='-- {{{\nSandboxVars = {\n VERSION = 5,\n Label = [=[ text } -- { " ]=], -- }\n --[[ { ProjectWriting = { false } } ]]\n}\n'
        self.sandbox.write_text(original); self.run_install()
        changed=self.sandbox.read_text()
        self.assertIn('Label = [=[ text } -- { " ]=]',changed)
        self.assertIn('--[[ { ProjectWriting = { false } } ]]',changed)
        self.assertIn('ProjectWriting = { Freehand = false, VanillaMap = true }',changed)
        self.run_install(); self.assertEqual(self.sandbox.read_text(),changed)
    def test_add_missing_keys_without_trailing_delimiter(self):
        self.sandbox.write_text('SandboxVars={ProjectWriting={Other=true -- closing comment\n},VERSION=5}\n')
        self.run_install(); parsed=installer.StaticTableParser(installer.lex(installer.strip_managed_guard(self.sandbox.read_text()))).sandbox()
        block=parsed.entries['ProjectWriting']; self.assertEqual(block.entries['Other'].kind,'true'); self.assertEqual(block.entries['Freehand'].kind,'false'); self.assertEqual(block.entries['VanillaMap'].kind,'true')
        self.assertIn('-- closing comment',self.sandbox.read_text())
    def test_missing_one_key_bracket_keys_and_semicolons(self):
        self.sandbox.write_text('SandboxVars = { ["ProjectWriting"] = { ["Freehand"] = true; Note = "\\\" }" }; VERSION=5; }; --fin\n')
        self.run_install(); result=self.sandbox.read_text()
        self.assertIn('["Freehand"] = false',result); self.assertIn('VanillaMap = true',result); self.assertIn('--fin',result)
        self.run_install(); self.assertEqual(self.sandbox.read_text(),result)
    def test_refuse_dynamic_values_and_malformed_syntax(self):
        values=('SandboxVars = {ProjectWriting=Options}', 'SandboxVars = {ProjectWriting={Freehand=not true}}', 'SandboxVars = {ProjectWriting={Freehand=true,VanillaMap=fn()}}', 'SandboxVars={ProjectWriting={Freehand=true}}; doSomething()', 'SandboxVars={ProjectWriting={Freehand="true"}}', 'SandboxVars={X=1+2, ProjectWriting={}}', 'SandboxVars={ProjectWriting={', 'SandboxVars={X="bad\nstring"}', 'SandboxVars={X=[=[bad}', 'SandboxVars={ --[[ bad }')
        for value in values:
            with self.subTest(value=value): self.sandbox.write_text(value); self.assert_refused_unchanged()
    def test_refuse_duplicate_blocks_and_options(self):
        values=('SandboxVars={ProjectWriting={},ProjectWriting={}}','SandboxVars={ProjectWriting={Freehand=true,Freehand=false}}','SandboxVars={ProjectWriting={Freehand=true,["Freehand"]=false}}','SandboxVars={ProjectWriting={Freehand=true,["Free\\104and"]=false}}','SandboxVars={ProjectWriting={Other=1,Other=2}}','SandboxVars={ProjectWriting={Freehand=true,[ [[\nFreehand]] ]=false}}')
        for value in values:
            with self.subTest(value=value): self.sandbox.write_text(value); self.assert_refused_unchanged()
    def test_missing_guard_is_not_needed(self):
        self.source.unlink()
        self.assertEqual(self.run_install(), 'enabled')
        self.assertFalse((self.install/'media').exists())
        self.assertNotIn(installer.BEGIN_MARKER, self.sandbox.read_text())
    def test_deprecated_source_is_ignored(self):
        self.source.unlink(); self.source.symlink_to(self.ini)
        self.assertEqual(self.run_install(), 'enabled')
        self.assertNotIn(installer.BEGIN_MARKER, self.sandbox.read_text())
    def test_sandbox_symlink_refuses(self):
        actual=self.root/'actual.lua'; self.sandbox.rename(actual); self.sandbox.symlink_to(actual)
        self.assert_refused_unchanged(); self.assertEqual(actual.read_bytes(),self.sandbox.read_bytes())
    def test_legacy_symlink_cleanup_does_not_touch_target(self):
        self.target.parent.mkdir(parents=True)
        outside=self.root/'protected.lua'; outside.write_text('protected')
        for name in installer.LEGACY_GUARD_NAMES: (self.target.parent/name).symlink_to(outside)
        self.run_install()
        self.assertEqual(outside.read_text(),'protected')
        self.assertTrue(all(not (self.target.parent/name).is_symlink() for name in installer.LEGACY_GUARD_NAMES))
    def test_ambiguous_managed_blocks_refuse_without_mutation(self):
        base=installer.strip_managed_guard(self.sandbox.read_text())
        begin=installer.BEGIN_MARKER; end=installer.END_MARKER
        for suffix in (begin+'\nprint("x")\n', end+'\n', begin+'\n'+begin+'\n'+end+'\n',begin+'\n'+end+'\n'+begin+'\n'+end+'\n',end+'\n'+begin+'\n'):
            with self.subTest(suffix=suffix): self.sandbox.write_text(base+suffix); self.assert_refused_unchanged()
        self.sandbox.write_text('SandboxVars={\n'+begin+'\n'+end+'\n}\n'); self.assert_refused_unchanged()
    def test_managed_markers_in_long_strings_are_preserved(self):
        self.sandbox.write_text('SandboxVars={ Label=[=[\n'+installer.BEGIN_MARKER+'\n'+installer.END_MARKER+'\n]=],VERSION=5}\n')
        base=self.sandbox.read_text(); self.run_install()
        stripped=installer.strip_managed_guard(self.sandbox.read_text())
        self.assertIn('Label=[=[\n'+installer.BEGIN_MARKER+'\n'+installer.END_MARKER+'\n]=]',stripped)
        self.run_install(); self.run_install(mode=0)
        self.assertEqual(installer.strip_managed_guard(self.sandbox.read_text()),self.sandbox.read_text())
    def test_legacy_directory_refuses_without_mutating_sandbox(self):
        self.target.parent.mkdir(parents=True); self.target.mkdir()
        self.assert_refused_unchanged()
    def test_install_directory_symlink_refuses(self):
        actual=self.root/'actual-game'; self.install.rename(actual); self.install.symlink_to(actual); self.assert_refused_unchanged()
    def test_subdirectory_symlink_refuses(self):
        actual=self.root/'external-media'; actual.mkdir(); (self.install/'media').symlink_to(actual); self.assert_refused_unchanged(); self.assertEqual(list(actual.iterdir()),[])
    def test_unsafe_directory_and_sandbox_permissions_refuse(self):
        self.install.chmod(0o777); self.assert_refused_unchanged(); self.install.chmod(0o755)
        media=self.install/'media'; media.mkdir(); media.chmod(0o777); self.assert_refused_unchanged(); media.chmod(0o755)
        self.sandbox.chmod(0o666); self.assert_refused_unchanged()
    def test_private_ancestor_allows_standard_group_writable_install(self):
        self.install.chmod(0o775)
        self.target.parent.mkdir(parents=True)
        for directory in (self.target.parent, self.target.parent.parent, self.target.parent.parent.parent): directory.chmod(0o775)
        self.sandbox.chmod(0o664)
        self.assertEqual(self.run_install(), 'enabled')
        self.assertEqual(stat.S_IMODE(self.install.stat().st_mode),0o775)
        self.assertEqual(stat.S_IMODE(self.target.parent.stat().st_mode),0o775)
        self.assertEqual(stat.S_IMODE(self.sandbox.stat().st_mode),0o664)
    def test_private_tmp_namespace_root_ownership(self):
        real_fstat = os.fstat
        def mapped_fstat(fd):
            info = real_fstat(fd)
            if info.st_uid != 0:
                return info
            fields = list(info)
            fields[4] = 65534
            return os.stat_result(fields)
        with patch.object(installer, 'namespace_root_uid', return_value=65534), patch.object(installer.os, 'fstat', side_effect=mapped_fstat):
            self.assertEqual(self.run_install(), 'enabled')
            self.assertFalse(installer.trusted_owner(65533))
        self.assertFalse(self.target.exists()); self.assertNotIn(installer.BEGIN_MARKER, self.sandbox.read_text())
    def test_group_writable_path_without_private_ancestor_refuses(self):
        self.root.chmod(0o755); self.install.chmod(0o775)
        self.assert_refused_unchanged()
    def test_duplicate_mod_ini_refuses_without_mutation(self):
        self.ini.write_text('Mods=ProjectWriting\nMods=SomethingElse\n'); self.assert_refused_unchanged()
    def test_crlf_preserved(self):
        self.sandbox.write_bytes(b'SandboxVars = {\r\n    ProjectWriting = { Freehand = true },\r\n}\r\n')
        self.run_install(); changed=self.sandbox.read_bytes()
        self.assertNotIn(b'\n', changed.replace(b'\r\n',b'')); self.assertIn(b'Freehand = false',changed); self.assertIn(b'VanillaMap = true',changed)

if __name__=='__main__': unittest.main()
