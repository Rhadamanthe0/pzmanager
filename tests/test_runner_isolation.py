"""Exercise the runner's child environment before permitting any lock acquisition."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import json
import os
from pathlib import Path
import stat
import subprocess

base = Path(os.environ['TMPDIR']).resolve()
home = Path(os.environ['HOME']).resolve()
assert home != Path(os.environ['FIXTURE_CALLER_HOME']), 'HOME inherited from caller'
assert 'XDG_RUNTIME_DIR' in os.environ, 'private runtime missing'
runtime = Path(os.environ['XDG_RUNTIME_DIR']).resolve()
assert runtime != Path(os.environ['FIXTURE_CALLER_RUNTIME']), 'runtime inherited from caller'
assert home != runtime
for directory in (home, runtime):
    assert directory.is_relative_to(base), f'outside disposable tree: {directory}'
    assert directory.is_dir() and not directory.is_symlink()
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700
for key in ('SSH_CLIENT', 'SSH_CONNECTION', 'SSH2_CLIENT', 'BASH_ENV', 'ENV'):
    assert key not in os.environ, f'caller startup environment inherited: {key}'

# All isolation assertions precede shell startup and any lock acquisition.
common = Path(__file__).resolve().parents[1] / 'data/scripts/lib/common.sh'
script = r"""
set -euo pipefail
source "$1"
world_path="$(world_lock_path)"
server_path="$(serverctl_lock_path)"
[[ "$world_path" == "$XDG_RUNTIME_DIR/pzmanager/world.lock" ]]
[[ "$server_path" == "$XDG_RUNTIME_DIR/pzmanager/serverctl.lock" ]]
acquire_world_lock
acquire_serverctl_lock_or_die
[[ "$world_path" -ef "/proc/self/fd/$PZ_WORLD_LOCK_FD" ]]
[[ "$server_path" -ef "/proc/self/fd/$SERVERCTL_LOCK_FD" ]]
bash -c '
    set -euo pipefail
    source "$1"
    acquire_world_lock
    acquire_serverctl_lock_or_die
    [[ "$PZ_WORLD_LOCK_DEPTH" == 2 ]]
    [[ "$SERVERCTL_LOCK_FILE" == "$XDG_RUNTIME_DIR/pzmanager/serverctl.lock" ]]
' inherited "$1"
"""
result = subprocess.run(['bash', '-c', script, 'probe', str(common)],
                        capture_output=True, text=True, timeout=10)
assert result.returncode == 0, result.stdout + result.stderr
for name in ('world.lock', 'serverctl.lock'):
    assert (runtime / 'pzmanager' / name).is_file()
Path(os.environ['FIXTURE_PROOF']).write_text(json.dumps({
    'home': str(home), 'runtime': str(runtime), 'base': str(base),
    'private_locks_and_inherited_fds': True,
}))
'''


class RunnerIsolation(unittest.TestCase):
    def test_children_have_private_home_runtime_and_no_ssh_startup(self):
        with tempfile.TemporaryDirectory(prefix='pz-runner-probe-') as temporary:
            base = Path(temporary)
            repository = base / 'mini-repository'
            tests = repository / 'tests'
            tests.mkdir(parents=True)
            shutil.copy2(ROOT / 'tests/run-isolated.py', tests / 'run-isolated.py')
            shutil.copytree(ROOT / 'data/scripts/lib', repository / 'data/scripts/lib')
            (tests / 'test_probe.py').write_text(textwrap.dedent(PROBE))
            subprocess.run(['git', 'init', '-q', str(repository)], check=True,
                           capture_output=True, text=True)
            home, runtime = base / 'caller-home', base / 'caller-runtime'
            home.mkdir(mode=0o700)
            runtime.mkdir(mode=0o700)
            (home / 'sentinel').write_text('preserve caller home\n')
            (runtime / 'sentinel').write_text('preserve caller runtime\n')
            startup = home / '.bashrc'
            startup.write_text('printf unsafe > ' + shlex.quote(str(home / 'sentinel')) + '\n')
            before = {path: path.read_bytes() for folder in (home, runtime)
                      for path in folder.iterdir()}
            proof = base / 'proof.json'
            results = base / 'results'
            env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                       SSH_CLIENT='fixture', SSH_CONNECTION='fixture', SSH2_CLIENT='fixture',
                       BASH_ENV=str(startup), ENV=str(startup),
                       FIXTURE_CALLER_HOME=str(home), FIXTURE_CALLER_RUNTIME=str(runtime),
                       FIXTURE_PROOF=str(proof))
            result = subprocess.run([sys.executable, str(tests / 'run-isolated.py'),
                                     '--results', str(results), '--only', 'test_probe.py'],
                                    env=env, capture_output=True, text=True, timeout=30)
            after = {path: path.read_bytes() for folder in (home, runtime)
                     for path in folder.iterdir()}
            self.assertEqual(before, after, 'caller home/runtime were modified')
            log = (results / 'test_probe.py.log').read_text()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + log)
            evidence = json.loads(proof.read_text())
            self.assertTrue(evidence['private_locks_and_inherited_fds'])
            for key in ('home', 'runtime'):
                self.assertFalse(Path(evidence[key]).exists(), 'disposable tree was not removed')


if __name__ == '__main__':
    unittest.main()
