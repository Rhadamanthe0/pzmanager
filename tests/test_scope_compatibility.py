#!/usr/bin/env python3
"""The real scope wrapper preserves literal argv and FDs on supported releases."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['PZ_TEST_ROOT'])


class ScopeCompatibility(unittest.TestCase):
    def test_legacy_and_current_scopes_preserve_arguments_and_lock(self):
        for version in (249, 252, 254, 257):
            with self.subTest(version=version), tempfile.TemporaryDirectory(dir=ROOT.parent) as temporary:
                base = Path(temporary)
                library = base / 'lib'; library.mkdir()
                for name in ('run_in_pz_slice.sh', 'systemd_scope.sh'):
                    source = ROOT / 'data/scripts/lib' / name
                    if source.exists(): shutil.copy2(source, library / name)
                binary = base / 'bin'; binary.mkdir()
                mocks = {
                    'id': '#!/bin/bash\necho 1005\n',
                    'python3': '#!/bin/bash\ncase "${2:-}" in inside) [[ "${MOCK_PHASE:-outside}" == inside ]];; check) exit 0;; *) exit 99;; esac\n',
                    'systemctl': '#!/bin/bash\nexit "${MOCK_BUS_FAILURE:-0}"\n',
                    'systemd-run': r'''#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
    [[ "${MOCK_HELP_FAILURE:-0}" == 0 ]] || exit 7
    if [[ "${MOCK_HELP_MALFORMED:-0}" != 0 ]]; then printf '%s\n' 'unrecognized help'; exit 0; fi
    printf '%s\n' '  --scope'
    if (( MOCK_VERSION >= 254 )); then printf '%s\n' '  --expand-environment=BOOL'; fi
    exit 0
fi
printf '%s\0' "$@" > "$MOCK_SCOPE_ARGS"
if (( MOCK_VERSION < 254 )) && [[ " $* " == *' --expand-environment=no '* ]]; then exit 64; fi
while [[ "${1:-}" != /bin/bash ]]; do [[ $# -gt 0 ]] || exit 99; shift; done
MOCK_PHASE=inside exec "$@"
'''}
                for name, content in mocks.items():
                    (binary / name).write_text(content); (binary / name).chmod(0o700)
                task = base / 'task.sh'
                task.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$MOCK_RESULT"\nprintf inherited >&"$MOCK_LOCK_FD"\n')
                argv = ['space arg', '$literal', '`literal`', '"quote"', "'quote'"]
                environment = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'], MOCK_VERSION=str(version),
                                   MOCK_SCOPE_ARGS=str(base / 'scope-args'), MOCK_RESULT=str(base / 'result'))
                with (base / 'lock').open('w') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    environment['MOCK_LOCK_FD'] = str(lock.fileno())
                    command = ['bash', str(library / 'run_in_pz_slice.sh'), 'bash', str(task), *argv]
                    result = subprocess.run(command, env=environment, pass_fds=(lock.fileno(),), capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((base / 'result').read_bytes().split(b'\0')[:-1], [value.encode() for value in argv])
                    self.assertEqual((base / 'lock').read_text(), 'inherited')
                    options = (base / 'scope-args').read_bytes().split(b'\0')
                    self.assertEqual(b'--expand-environment=no' in options, version >= 254)
                    self.assertIn(b'--scope', options); self.assertIn(b'--slice=pz.slice', options)
                    for failure in ('MOCK_BUS_FAILURE', 'MOCK_HELP_FAILURE', 'MOCK_HELP_MALFORMED'):
                        (base / 'result').unlink()
                        rejected = subprocess.run(command, env=dict(environment, **{failure: '7'}), pass_fds=(lock.fileno(),), capture_output=True, text=True)
                        self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
                        self.assertFalse((base / 'result').exists())
                        # The next subcase starts from a fresh successful run.
                        if failure != 'MOCK_HELP_MALFORMED':
                            subprocess.run(command, env=environment, pass_fds=(lock.fileno(),), check=True)


if __name__ == '__main__':
    unittest.main()
