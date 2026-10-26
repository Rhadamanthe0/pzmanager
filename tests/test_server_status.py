"""Server status regression through the real CLI under run-isolated.py."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['PZ_TEST_ROOT'])
SYSTEMCTL = r'''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
mode = os.environ['STATUS_MODE']
with open(os.environ['STATUS_CALLS'], 'a') as out:
    out.write(json.dumps(['systemctl'] + args) + '\n')
if mode == 'bus-error':
    print('Failed to connect to bus: counter fixture', file=sys.stderr)
    sys.exit(1)
if args == ['--user', 'is-active', '--quiet', 'fixture.service']:
    sys.exit(0 if mode == 'active' else 3)
if len(args) == 5 and args[:4] == ['--user', 'show', 'fixture.service', '-p']:
    if args[4] == 'ActiveState,SubState,Result':
        state = 'banana' if mode == 'unknown' else mode
        print('ActiveState=' + state + '\nSubState=fixture\nResult=' + os.environ['STATUS_RESULT'])
        sys.exit(0)
if args == ['--user', 'show', 'fixture.service', '-p', 'ActiveEnterTimestamp', '--value']:
    print('Mon 2026-10-26 10:00:00 UTC')
    sys.exit(0)
if args == ['--user', 'show', 'fixture.service', '-p', 'Result', '--value']:
    print(os.environ['STATUS_RESULT'])
    sys.exit(0)
print('Unexpected systemctl arguments: ' + repr(args), file=sys.stderr)
sys.exit(99)
'''
JOURNALCTL = r'''#!/usr/bin/python3
import json, os, sys
with open(os.environ['STATUS_CALLS'], 'a') as out:
    out.write(json.dumps(['journalctl'] + sys.argv[1:]) + '\n')
assert sys.argv[1:] == ['--user', '-u', 'fixture.service', '-n', '30', '--no-pager']
print('private fixture recent log')
'''

class ServerStatus(unittest.TestCase):
    def test_observed_states_and_bus_failure(self):
        observations = []
        with tempfile.TemporaryDirectory(prefix='status-counter-') as temporary:
            base = Path(temporary)
            repo = base / 'repo'
            shutil.copytree(ROOT / 'data/scripts', repo / 'data/scripts')
            shutil.copy2(ROOT / 'pzm', repo / 'pzm')
            pipe = base / 'control.pipe'
            (repo / '.env').write_text(f'PZ_SERVICE_NAME=fixture.service\nPZ_CONTROL_PIPE={pipe}\n')
            bins = base / 'bin'
            bins.mkdir(mode=0o700)
            for name, script in [('systemctl', SYSTEMCTL), ('journalctl', JOURNALCTL)]:
                path = bins / name
                path.write_text(script)
                path.chmod(0o700)
            scenarios = [(mode, False, 'exit-code' if mode == 'failed' else 'success')
                         for mode in ['active', 'inactive', 'activating', 'deactivating',
                                      'failed', 'unknown', 'bus-error']]
            scenarios += [('active', True, 'success'), ('inactive', False, 'exit-code')]
            for index, (mode, pipe_available, last_result) in enumerate(scenarios):
                with self.subTest(mode=mode, pipe_available=pipe_available, result=last_result):
                    pipe.unlink(missing_ok=True)
                    if pipe_available:
                        os.mkfifo(pipe, 0o600)
                    calls = base / f'calls-{index}'
                    env = dict(os.environ, PATH=str(bins) + ':' + os.environ['PATH'],
                               STATUS_MODE=mode, STATUS_CALLS=str(calls), STATUS_RESULT=last_result)
                    result = subprocess.run(['bash', str(repo / 'pzm'), 'server', 'status'],
                                            env=env, capture_output=True, text=True, timeout=8)
                    cli_calls = [json.loads(line) for line in calls.read_text().splitlines()]
                    state = subprocess.run(['bash', '-c', 'source "$1"; PZ_SERVICE_NAME=fixture.service; server_state',
                                            'counter', str(repo / 'data/scripts/lib/server_state.sh')],
                                           env=env, capture_output=True, text=True, timeout=8)
                    row = dict(mode=mode, exit=result.returncode, stdout=result.stdout,
                               stderr=result.stderr, cli_calls=cli_calls,
                               model_state=state.stdout.strip(), model_exit=state.returncode)
                    observations.append(row)
                    self.assertEqual(state.returncode, 0)
                    self.assertEqual(state.stdout.strip(), 'error' if mode == 'bus-error' else mode)
                    self.assertEqual(result.returncode, 1 if mode == 'bus-error' else 0)
                    labels = dict(active='RUNNING', inactive='STOPPED', activating='ACTIVATING',
                                  deactivating='DEACTIVATING', failed='FAILED', unknown='UNKNOWN',
                                  **{'bus-error': 'UNKNOWN'})
                    self.assertIn('Status: ' + labels[mode], result.stdout)
                    if mode != 'inactive':
                        self.assertNotIn('Status: STOPPED', result.stdout)
                    self.assertTrue(all(call[0] == 'journalctl' or call[1:3] in
                                        [['--user', 'is-active'], ['--user', 'show']] for call in cli_calls))
                    if mode == 'active':
                        self.assertIn('Active since: Mon 2026-10-26 10:00:00 UTC', result.stdout)
                        self.assertIn('Control pipe: ' + ('Available' if pipe_available else 'Not available'),
                                      result.stdout)
                    if mode in {'inactive', 'failed'} and last_result != 'success':
                        self.assertIn('Last exit: ' + last_result, result.stdout)
                    else:
                        self.assertNotIn('Last exit:', result.stdout)
                    if mode == 'bus-error':
                        self.assertIn('ERREUR:', result.stderr)
                        self.assertIn('fixture.service', result.stderr)
                        self.assertIn('systemd', result.stderr)
                        self.assertFalse(any(call[0] == 'journalctl' for call in cli_calls))
                        self.assertNotIn('Recent Logs', result.stdout)
                    else:
                        self.assertEqual(result.stderr, '')
                        self.assertIn('private fixture recent log', result.stdout)
            print(json.dumps(observations, ensure_ascii=False, indent=2), flush=True)

if __name__ == '__main__':
    unittest.main()
