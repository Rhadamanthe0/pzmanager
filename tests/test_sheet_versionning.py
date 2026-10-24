"""Run the Sheets CLI against disposable credentials and a local transport stub."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SheetTransport(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        versionning = self.root / 'versionning'
        versionning.mkdir()
        self.script = versionning / 'sheetVersionning.sh'
        shutil.copy2(ROOT / 'versionning/sheetVersionning.sh', self.script)
        credentials = base64.b64encode(json.dumps({'client_email':'fixture@example.invalid', 'private_key':'fixture-key-not-real'}).encode()).decode()
        (self.root / '.env').write_text('SHEET_VERSIONNING_ID=fixture-sheet\nGOOGLE_SERVICE_ACCOUNT_JSON_B64=' + credentials + '\n')
        commands = self.root / 'bin'
        commands.mkdir()
        self.calls = self.root / 'calls'
        self.command(commands / 'openssl', '''import base64,sys
payload=sys.stdin.buffer.read()
sys.stdout.buffer.write(base64.b64encode(payload) if sys.argv[1]=='base64' else b'fixture-signature')
''')
        self.command(commands / 'curl', '''import json,os,pathlib,sys
args=sys.argv[1:]; url=next(arg for arg in args if arg.startswith('https://')); method=args[args.index('-X')+1] if '-X' in args else 'GET'
operation=('token' if 'oauth2' in url else 'clear' if url.endswith(':clear') else 'put' if method=='PUT' else 'batch' if ':batchUpdate' in url else 'values' if '/values/' in url else 'get')
with pathlib.Path(os.environ['FIXTURE_CALLS']).open('a') as log: log.write(operation+'\\n')
mode=os.environ.get('FIXTURE_MODE','ok'); target=os.environ.get('FIXTURE_TARGET','clear')
if operation==target and mode=='http':
 if any(arg in args for arg in ('--fail','--fail-with-body','-f')): sys.exit(22)
 print(''); sys.exit(0)
if operation==target and mode=='transport': sys.exit(7)
if operation==target and mode=='empty': sys.exit(0)
if operation==target and mode=='malformed': print('not json'); sys.exit(0)
if operation==target and mode=='error': print('{"error":{"message":"fixture failure"}}'); sys.exit(0)
if operation==target and mode=='schema': print('{}'); sys.exit(0)
responses={
 'token':{'access_token':'fixture-token-not-real','token_type':'Bearer','expires_in':3600},
 'clear':{'spreadsheetId':'fixture-sheet','clearedRange':'V1!A1:Z200'},
 'put':{'spreadsheetId':'fixture-sheet','updatedRange':'V1!A1','updatedRows':1,'updatedColumns':1,'updatedCells':1},
 'get':{'sheets':[{'properties':{'sheetId':1,'title':'V1','index':0}}]},
 'values':{'range':'V1!A1:A6','majorDimension':'ROWS','values':[['fixture']]},
 'batch':{'spreadsheetId':'fixture-sheet','replies':[{}]}}
print(json.dumps(responses[operation]))
''')
        self.env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], FIXTURE_CALLS=str(self.calls))
        self.tsv = self.root / 'input.tsv'
        self.tsv.write_text('fixture\n')

    def command(self, path, source):
        path.write_text('#!/usr/bin/python3\n' + source)
        path.chmod(0o700)

    def run_sheet(self, target, mode, *args):
        self.calls.unlink(missing_ok=True)
        return subprocess.run(['bash', str(self.script), *args], env=dict(self.env, FIXTURE_TARGET=target, FIXTURE_MODE=mode),
                              capture_output=True, text=True, timeout=8)

    def test_clear_failure_never_runs_put_or_reports_success(self):
        for mode in ('http','transport','empty','malformed','error','schema'):
            with self.subTest(mode=mode):
                result = self.run_sheet('clear', mode, 'load', 'V1', str(self.tsv))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('put', self.calls.read_text().splitlines())
                self.assertNotIn('peuplé', result.stdout)

    def test_other_api_boundaries_require_http_and_valid_schema(self):
        for target, args in (('token', ('list',)), ('get', ('list',)), ('values', ('show','V1')), ('put', ('setcell','V1','A1','fixture')), ('batch', ('hide-old',))):
            for mode in ('http','transport','empty','malformed','error','schema'):
                with self.subTest(target=target,mode=mode):
                    result = self.run_sheet(target, mode, *args)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('✓', result.stdout)
                    if target == 'token': self.assertEqual(self.calls.read_text().splitlines(), ['token'])

    def test_confirmed_clear_and_put_report_success(self):
        result = self.run_sheet('clear', 'ok', 'load', 'V1', str(self.tsv))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['token','clear','put'])
        self.assertIn('peuplé', result.stdout)

    def test_structured_read_and_batch_succeed(self):
        for args in (('list',),('show','V1'),('setcell','V1','A1','fixture'),('hide-old',)):
            with self.subTest(args=args):
                result = self.run_sheet('none', 'ok', *args)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
