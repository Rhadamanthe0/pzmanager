#!/usr/bin/env python3
"""Installer refusals preserve existing files before privileged work."""
import fcntl
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(os.environ['PZ_TEST_ROOT'])


def function(path, name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', path.read_text(), re.M | re.S).group()


class InstallGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)

    def bootstrap(self, target, *, late=False):
        source = ROOT / 'data/scripts/install.sh'
        text = source.read_text()
        home_line = 'readonly PZ_HOME="/home/${PZ_USER}"'
        self.assertIn(home_line, text)
        script = self.base / 'install.sh'
        script.write_text(text.replace(home_line, 'readonly PZ_HOME=' + shlex.quote(str(target.parent))))
        trace = self.base / 'trace'
        stage = self.base / 'stage'
        stage.mkdir(exist_ok=True)
        (stage / 'new').write_text('new clone')
        commands = '''
source "$1"
check_root() { :; }
check_os() { :; }
check_dependencies() { echo packages >> "$TRACE"; }
clone_repo() { TMP_DIR="$STAGE"; echo clone >> "$TRACE"; }
configure_env() { echo env >> "$TRACE"; }
stage_root_helpers() { echo helpers >> "$TRACE"; }
run_setup() { echo setup >> "$TRACE"; }
run_initial_config() { echo initial >> "$TRACE"; }
chown() { echo chown >> "$TRACE"; }
print_success() { echo success >> "$TRACE"; }
'''
        if late:
            commands += '''
mv() {
    mkdir -- "$INSTALL_DIR"
    printf late > "$INSTALL_DIR/sentinel"
    /bin/mv "$@"
}
'''
        return subprocess.run(['bash', '-c', commands + '\nmain', '_', str(script)],
                              env=dict(os.environ, TRACE=str(trace), STAGE=str(stage)),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_existing_targets_refused_before_setup(self):
        for kind in ('directory', 'file', 'link', 'dangling'):
            with self.subTest(kind=kind):
                home = self.base / kind
                home.mkdir()
                target = home / 'pzmanager'
                external = home / 'external'
                external.mkdir()
                (external / 'sentinel').write_text('unchanged')
                if kind == 'directory':
                    target.mkdir()
                    (target / 'world').write_text('world')
                elif kind == 'file':
                    target.write_text('existing')
                else:
                    target.symlink_to(external if kind == 'link' else home / 'missing')
                locks = [open(home / name, 'w') for name in ('WORLD', 'SERVERCTL')]
                for lock in locks:
                    self.addCleanup(lock.close)
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = self.bootstrap(target)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('pzm install zomboid', result.stderr)
                self.assertFalse((self.base / 'trace').exists())
                self.assertEqual((external / 'sentinel').read_text(), 'unchanged')
                self.assertFalse(list(home.glob('pzmanager.backup.*')))
                if kind == 'directory':
                    self.assertEqual((target / 'world').read_text(), 'world')
                elif kind == 'file':
                    self.assertEqual(target.read_text(), 'existing')
                else:
                    self.assertTrue(target.is_symlink())

    def test_fresh_bootstrap_uses_normal_path(self):
        home = self.base / 'home'
        home.mkdir()
        target = home / 'pzmanager'
        result = self.bootstrap(target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((target / 'new').read_text(), 'new clone')
        self.assertEqual((self.base / 'trace').read_text().splitlines(),
                         ['packages', 'clone', 'env', 'helpers', 'setup', 'chown', 'initial', 'success'])

    def test_target_appearing_at_move_is_not_replaced_or_chowned(self):
        home = self.base / 'home'
        home.mkdir()
        target = home / 'pzmanager'
        result = self.bootstrap(target, late=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((target / 'sentinel').read_text(), 'late')
        self.assertTrue((self.base / 'stage/new').is_file())
        trace = (self.base / 'trace').read_text()
        self.assertNotIn('chown', trace)
        self.assertNotIn('success', trace)

    def test_sudoers_failures_stop_and_preserve_previous_file(self):
        for source in ('setupSystem.sh', 'configurationInitiale.sh'):
            for failure in ('missing', 'visudo', 'publish', 'permission'):
                with self.subTest(source=source, failure=failure):
                    self.sudoers(source, failure)

    def test_sudoers_success_publishes_template(self):
        for source in ('setupSystem.sh', 'configurationInitiale.sh'):
            with self.subTest(source=source):
                self.sudoers(source, 'none')

    def sudoers(self, source, failure):
        base = self.base / (source + '-' + failure)
        scripts = base / 'data/scripts/install'
        templates = base / 'data/setupTemplates'
        scripts.mkdir(parents=True)
        templates.mkdir()
        if failure != 'missing':
            (templates / 'pzuser-sudoers').write_text('__PZ_USER__ __PZ_HOME__\n')
        destination = base / 'sudoers'
        destination.write_text('previous\n')
        original = destination.stat()
        definition = function(ROOT / 'data/scripts/install' / source, 'install_sudoers')
        # Only the fixed system destination is remapped; the function is otherwise exact.
        definition = definition.replace('local dest="/etc/sudoers.d/${PZ_USER}"',
                                        'local dest="$PZ_SUDOERS_DEST"')
        script = '''set -euo pipefail
SCRIPT_DIR="$1"; PZ_SUDOERS_DEST="$2"; PZ_USER=pzfixture; PZ_HOME=/home/pzfixture
visudo() { [[ "$FAILURE" != visudo ]]; }
chown() { [[ "$FAILURE" != permission ]]; }
mv() { [[ "$FAILURE" != publish ]] && /bin/mv "$@"; }
install() {
    [[ "$FAILURE" != publish && "$FAILURE" != permission ]] || return 74
    /bin/cp -- "${@: -2:1}" "${@: -1}"
    /bin/chmod 440 -- "${@: -1}"
}
''' + definition + '\ninstall_sudoers\necho REACHED_SUCCESS\n'
        result = subprocess.run(['bash', '-c', script, '_', str(scripts), str(destination)],
                                env=dict(os.environ, FAILURE=failure), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if failure == 'none':
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(destination.read_text(), 'pzfixture /home/pzfixture\n')
            self.assertEqual(destination.stat().st_mode & 0o777, 0o440)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('REACHED_SUCCESS', result.stdout)
            self.assertEqual(destination.read_text(), 'previous\n')
            self.assertEqual(destination.stat().st_ino, original.st_ino)
            self.assertEqual(destination.stat().st_mtime_ns, original.st_mtime_ns)
        self.assertFalse(list(base.glob('.*sudoers*')))


if __name__ == '__main__':
    unittest.main()
