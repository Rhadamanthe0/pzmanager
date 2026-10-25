"""Run the Sheets CLI against disposable credentials and a local transport stub."""
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import time
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
        self.secrets = self.root / 'temp secrets with spaces'
        self.secrets.mkdir(mode=0o700)
        self.command(commands / 'openssl', '''import base64,os,pathlib,sys,time
payload=sys.stdin.buffer.read()
if sys.argv[1]=='dgst':
 root=pathlib.Path(os.environ['FIXTURE_ROOT']);key=pathlib.Path(sys.argv[sys.argv.index('-sign')+1])
 (root/'sign-path').write_text(str(key));(root/'sign-ready').touch()
 if os.environ.get('FIXTURE_SIGN_MODE')=='fail':sys.exit(37)
 if os.environ.get('FIXTURE_SIGN_MODE')=='blocked':
  while not (root/'sign-release').exists():time.sleep(.02)
sys.stdout.buffer.write(base64.b64encode(payload) if sys.argv[1]=='base64' else b'fixture-signature')
''')
        self.command(commands / 'curl', '''import base64,copy,hashlib,json,os,pathlib,sys,time
args=sys.argv[1:]; url=next(arg for arg in args if arg.startswith('https://')); method=args[args.index('-X')+1] if '-X' in args else 'GET'
operation=('token' if 'oauth2' in url else 'clear' if url.endswith(':clear') else 'put' if method=='PUT' else 'batch' if ':batchUpdate' in url else 'values' if '/values/' in url else 'get')
with pathlib.Path(os.environ['FIXTURE_CALLS']).open('a') as log: log.write(operation+'\\n')
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
credential_path=None;valid=False
if operation=='token':
 argument=next(args[i+1] for i,arg in enumerate(args) if arg=='--data-urlencode' and args[i+1].startswith('assertion'))
 if argument.startswith('assertion@'):
  credential_path=pathlib.Path(argument[len('assertion@'):]);jwt=credential_path.read_text();(root/'jwt-path').write_text(str(credential_path))
 else:jwt=argument.partition('=')[2]
 header,claim,signature=jwt.split('.')
 claims=json.loads(base64.urlsafe_b64decode(claim+'='*(-len(claim)%4)))
 valid=(claims['iss']=='fixture@example.invalid' and claims['aud']=='https://oauth2.googleapis.com/token' and
        base64.urlsafe_b64decode(signature+'='*(-len(signature)%4))==b'fixture-signature')
else:
 headers=[]
 for i,arg in enumerate(args):
  if arg!='-H':continue
  value=args[i+1]
  if value.startswith('@'):
   credential_path=pathlib.Path(value[1:]);headers.extend(credential_path.read_text().splitlines())
  else:headers.append(value)
 valid='Authorization: Bearer fixture-token-not-real' in headers
record={'operation':operation,'credential_valid':valid,'file':str(credential_path) if credential_path else None}
if credential_path:
 record.update(mode=credential_path.stat().st_mode & 0o777,directory_mode=credential_path.parent.stat().st_mode & 0o777)
if operation!='token':record['jwt_removed']=not (root/'jwt-path').exists() or not pathlib.Path((root/'jwt-path').read_text()).exists()
with (root/'transport.jsonl').open('a') as stream:stream.write(json.dumps(record)+'\\n')
if not valid:raise SystemExit(22)
if os.environ.get('FIXTURE_CURL_BLOCK')==operation:
 (root/'transport-ready').touch()
 while not (root/'transport-release').exists():time.sleep(.02)
mode=os.environ.get('FIXTURE_MODE','ok'); target=os.environ.get('FIXTURE_TARGET','clear')
data_flag=next((flag for flag in ('-d','--data-binary') if flag in args),None)
payload=args[args.index(data_flag)+1] if data_flag else '{}'
body=json.loads(sys.stdin.read() if payload=='@-' else payload)
if operation==target and mode=='http':
 if any(arg in args for arg in ('--fail','--fail-with-body','-f')): sys.exit(22)
 print(''); sys.exit(0)
if operation==target and mode=='transport': sys.exit(7)
if operation==target and mode=='empty': sys.exit(0)
if operation==target and mode=='malformed': print('not json'); sys.exit(0)
if operation==target and mode=='error': print('{"error":{"message":"fixture failure"}}'); sys.exit(0)
if operation==target and mode=='schema': print('{}'); sys.exit(0)
sheets_path=os.environ.get('FIXTURE_SHEETS')
if operation=='batch':
 (root/'batch.json').write_text(json.dumps(body))
 if sheets_path:
  sheets_path=pathlib.Path(sheets_path);candidate=json.loads(sheets_path.read_text())
  for request in body['requests']:
   update=request['updateSheetProperties'];properties=update['properties']
   assert update['fields']=='hidden' and set(properties)=={'sheetId','hidden'}
   matches=[sheet['properties'] for sheet in candidate['sheets'] if sheet['properties']['sheetId']==properties['sheetId']]
   assert len(matches)==1 and type(properties['hidden']) is bool
   matches[0]['hidden']=properties['hidden']
  if not any(not sheet['properties'].get('hidden',False) for sheet in candidate['sheets']):sys.exit(22)
  sheets_path.write_text(json.dumps(candidate))
state_path=os.environ.get('FIXTURE_STATE')
if state_path and operation in ('clear','put','batch'):
 state_path=pathlib.Path(state_path);state=json.loads(state_path.read_text());candidate=copy.deepcopy(state)
 if os.environ.get('FIXTURE_ATOMIC_FAILURE') and operation in ('put','batch'):sys.exit(7)
 def clear_values(grid,end_row,end_column):
  for key,cell in grid['cells'].items():
   row,column=map(int,key.split(','))
   if row<end_row and column<end_column:cell.pop('value',None)
 def write_values(grid,rows,start_row=0,start_column=0):
  for r,row in enumerate(rows,start_row):
   for c,value in enumerate(row,start_column):
    if r>=grid['rows'] or c>=grid['columns'] or not isinstance(value,str):raise ValueError('fixture grid bounds or value invalid')
    grid['cells'].setdefault(str(r)+','+str(c),{})['value']=value
 try:
  if operation=='clear':clear_values(candidate,200,26)
  elif operation=='put':write_values(candidate,body['values'])
  else:
   pathlib.Path(os.environ['FIXTURE_ROOT']+'/batch.json').write_text(json.dumps(body))
   for request in body['requests']:
    update=request['updateCells']
    if update['fields']!='userEnteredValue':raise ValueError('must preserve formatting')
    if 'range' in update:
     area=update['range']
     if area!={'sheetId':1,'startRowIndex':0,'endRowIndex':min(200,state['rows']),'startColumnIndex':0,'endColumnIndex':min(26,state['columns'])} or update.get('rows')!=[]:raise ValueError('unexpected clear')
     clear_values(candidate,area['endRowIndex'],area['endColumnIndex'])
    else:
     start=update['start']
     if start!={'sheetId':1,'rowIndex':0,'columnIndex':0}:raise ValueError('unexpected anchor')
     write_values(candidate,[[cell['userEnteredValue']['stringValue'] for cell in row['values']] for row in update['rows']])
 except (KeyError,ValueError):print('{"error":{"message":"fixture invalid data"}}');sys.exit(0)
 state_path.write_text(json.dumps(candidate))
grid=json.loads(pathlib.Path(state_path).read_text()) if state_path else {'rows':300,'columns':30}
properties={'sheetId':1,'title':'V1','index':0}
if not os.environ.get('FIXTURE_OMIT_DIMENSIONS'):properties['gridProperties']={'rowCount':grid.get('rows'),'columnCount':grid.get('columns')}
responses={
 'token':{'access_token':'fixture-token-not-real','token_type':'Bearer','expires_in':3600},
 'clear':{'spreadsheetId':'fixture-sheet','clearedRange':'V1!A1:Z200'},
 'put':{'spreadsheetId':'fixture-sheet','updatedRange':'V1!A1','updatedRows':1,'updatedColumns':1,'updatedCells':1},
 'get':{'sheets':[{'properties':properties}]},
 'values':{'range':'V1!A1:A6','majorDimension':'ROWS','values':[['fixture']]},
 'batch':{'spreadsheetId':'fixture-sheet','replies':[{} for _ in (body['requests'] if operation=='batch' else [])]}}
if sheets_path and operation=='get':responses['get']=json.loads(pathlib.Path(sheets_path).read_text())
print(json.dumps(responses[operation]))
''')
        self.env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], FIXTURE_CALLS=str(self.calls),FIXTURE_ROOT=str(self.root),TMPDIR=str(self.secrets))
        self.command(commands / 'jq', 'os.execv("/usr/bin/jq",["/usr/bin/jq",*sys.argv[1:]])\n')
        self.tsv = self.root / 'input.tsv'
        self.tsv.write_text('fixture\n')

    def command(self, path, source):
        path.write_text('#!/usr/bin/python3\n' +
                        'import json,os,pathlib,sys\n' +
                        'with (pathlib.Path(os.environ["FIXTURE_ROOT"])/"argv.jsonl").open("a") as stream: stream.write(json.dumps({"command":pathlib.Path(sys.argv[0]).name,"arguments":sys.argv[1:]})+"\\n")\n' + source)
        path.chmod(0o700)

    def run_sheet(self, target, mode, *args):
        self.calls.unlink(missing_ok=True)
        return subprocess.run(['bash', str(self.script), *args], env=dict(self.env, FIXTURE_TARGET=target, FIXTURE_MODE=mode),
                              capture_output=True, text=True, timeout=8)

    def test_all_commands_deliver_credentials_privately_without_argv_or_log_exposure(self):
        for args in (('list',),('new','2'),('hide-old',),('show','V1'),('setcell','V1','A1','fixture'),('load','V1',str(self.tsv))):
            with self.subTest(args=args):
                for name in ('argv.jsonl','transport.jsonl','jwt-path'):(self.root/name).unlink(missing_ok=True)
                result=self.run_sheet('none','ok',*args)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                argv=(self.root/'argv.jsonl').read_text()
                for forbidden in ('fixture-token-not-real','fixture-key-not-real','Authorization: Bearer','assertion='):
                    self.assertNotIn(forbidden,argv)
                    self.assertNotIn(forbidden,result.stdout+result.stderr)
                self.assertNotRegex(argv,r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
                transports=[json.loads(line) for line in (self.root/'transport.jsonl').read_text().splitlines()]
                self.assertEqual(transports[0]['operation'],'token')
                for entry in transports:
                    self.assertTrue(entry['credential_valid'])
                    self.assertEqual(entry.get('mode'),0o600)
                    self.assertEqual(entry.get('directory_mode'),0o700)
                    self.assertTrue(Path(entry['file']).is_relative_to(self.secrets))
                    if entry['operation']!='token':self.assertTrue(entry['jwt_removed'])
                self.assertEqual(list(self.secrets.iterdir()),[])

    def test_signals_during_oauth_transport_clean_all_private_credentials(self):
        for operation,signum,status in (('token',signal.SIGTERM,143),('get',signal.SIGINT,130)):
            with self.subTest(operation=operation):
                (self.root/'transport-ready').unlink(missing_ok=True)
                env=dict(self.env,FIXTURE_CURL_BLOCK=operation)
                proc=subprocess.Popen(['bash',str(self.script),'list'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
                try:
                    deadline=time.monotonic()+5
                    while not (self.root/'transport-ready').exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.01)
                    self.assertTrue((self.root/'transport-ready').exists())
                    os.killpg(proc.pid,signum);output,error=proc.communicate(timeout=5)
                    self.assertEqual(proc.returncode,status,output+error)
                    self.assertEqual(list(self.secrets.iterdir()),[])
                    self.assertNotIn('fixture-token-not-real',output+error)
                finally:
                    if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL)
                    proc.communicate()

    def stateful(self):
        state={'rows':300,'columns':30,'cells':{'0,0':{'value':'old','format':'bold'},
               '150,20':{'value':'stale','format':'italic'},'250,29':{'value':'outside','format':'green'}}}
        path=self.root/'api-state.json';path.write_text(json.dumps(state));self.env['FIXTURE_STATE']=str(path)
        return path,state

    def test_transport_failure_preserves_old_matrix(self):
        path,before=self.stateful();self.env['FIXTURE_ATOMIC_FAILURE']='1'
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(path.read_text()),before)

    def test_invalid_matrix_preserves_old_values_atomically(self):
        path,before=self.stateful();self.tsv.write_text('value\n'*301)
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(path.read_text()),before)

    def test_matrix_replaces_union_preserving_format_and_outside_cells(self):
        path,before=self.stateful()
        matrix=[[f'{r}:{c}' for c in range(28)] for r in range(205)]
        matrix[0][:3]=['=not-a-formula','001','']
        self.tsv.write_text('\n'.join('\t'.join(row) for row in matrix)+'\n')
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertEqual(result.returncode,0,result.stderr)
        after=json.loads(path.read_text())
        self.assertEqual(after['cells']['250,29'],before['cells']['250,29'])
        self.assertEqual(after['cells']['0,0']['format'],'bold')
        for r,row in enumerate(matrix):
            for c,value in enumerate(row):self.assertEqual(after['cells'][f'{r},{c}']['value'],value)
        self.assertEqual(self.calls.read_text().splitlines(),['token','get','batch'])
        batch=json.loads((self.root/'batch.json').read_text());self.assertEqual(len(batch['requests']),2)

    def test_short_matrix_clears_stale_values_preserving_format(self):
        path,before=self.stateful()
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertEqual(result.returncode,0,result.stderr)
        after=json.loads(path.read_text())
        self.assertEqual(after['cells']['0,0'],{'value':'fixture','format':'bold'})
        self.assertEqual(after['cells']['150,20'],{'format':'italic'})
        self.assertEqual(after['cells']['250,29'],before['cells']['250,29'])

    def test_unknown_sheet_refuses_before_batch(self):
        path,before=self.stateful()
        result=self.run_sheet('none','ok','load','unknown',str(self.tsv))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(path.read_text()),before)
        self.assertEqual(self.calls.read_text().splitlines(),['token','get'])

    def test_small_grid_clips_clear_without_truncating_matrix(self):
        path,state=self.stateful();state.update(rows=3,columns=4)
        state['cells']={'0,0':{'value':'old','format':'bold'},'2,3':{'value':'stale','format':'italic'}}
        path.write_text(json.dumps(state));self.tsv.write_text('new\t001\n=literal\t\n')
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertEqual(result.returncode,0,result.stderr)
        after=json.loads(path.read_text())
        self.assertEqual(after['cells']['0,0'],{'value':'new','format':'bold'})
        self.assertEqual(after['cells']['0,1']['value'],'001')
        self.assertEqual(after['cells']['1,0']['value'],'=literal')
        self.assertEqual(after['cells']['1,1']['value'],'')
        self.assertEqual(after['cells']['2,3'],{'format':'italic'})
        clear=json.loads((self.root/'batch.json').read_text())['requests'][0]['updateCells']['range']
        self.assertEqual((clear['endRowIndex'],clear['endColumnIndex']),(3,4))
        self.assertEqual(self.calls.read_text().splitlines(),['token','get','batch'])

    def test_load_rejects_invalid_dimensions_before_batch(self):
        path,base=self.stateful()
        for field in ('rows','columns'):
            for invalid in (None,0,-1,1.5,'4',True):
                with self.subTest(field=field,invalid=invalid):
                    state=dict(base);state[field]=invalid;path.write_text(json.dumps(state))
                    result=self.run_sheet('none','ok','load','V1',str(self.tsv))
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(self.calls.read_text().splitlines(),['token','get'])
                    self.assertEqual(json.loads(path.read_text()),state)

    def test_metadata_commands_do_not_require_grid_dimensions(self):
        self.env['FIXTURE_OMIT_DIMENSIONS']='1'
        for args in (('list',),('new','2'),('hide-old',)):
            with self.subTest(args=args):
                result=self.run_sheet('none','ok',*args)
                self.assertEqual(result.returncode,0,result.stderr)
        result=self.run_sheet('none','ok','load','V1',str(self.tsv))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls.read_text().splitlines(),['token','get'])

    def test_auth_http_failure_cleans_all_secrets(self):
        result=self.run_sheet('token','http','list')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(list(self.secrets.iterdir()),[])

    def test_signing_failure_cleans_parent_owned_secrets_with_inherit_errexit(self):
        env=dict(self.env,FIXTURE_SIGN_MODE='fail')
        result=subprocess.run(['bash','-O','inherit_errexit',str(self.script),'list'],env=env,capture_output=True,text=True,timeout=8)
        self.assertEqual(result.returncode,37,result.stdout+result.stderr)
        self.assertEqual(list(self.secrets.iterdir()),[])
        self.assertNotIn('fixture-key-not-real',result.stdout+result.stderr)

    def test_term_during_signing_cleans_json_and_pem(self):
        env=dict(self.env,FIXTURE_SIGN_MODE='blocked')
        proc=subprocess.Popen(['bash',str(self.script),'list'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while not (self.root/'sign-ready').exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.root/'sign-ready').exists())
            key=Path((self.root/'sign-path').read_text())
            self.assertEqual(key.stat().st_mode & 0o777,0o600)
            self.assertEqual(key.parent.stat().st_mode & 0o777,0o700)
            self.assertEqual({path.name for path in key.parent.iterdir()},{'account.json','private.pem'})
            for path in key.parent.iterdir():self.assertEqual(path.stat().st_mode & 0o777,0o600)
            os.killpg(proc.pid,signal.SIGTERM);output,error=proc.communicate(timeout=5)
            self.assertNotEqual(proc.returncode,0)
            self.assertEqual(list(self.secrets.iterdir()),[])
            self.assertNotIn('fixture-key-not-real',output+error)
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate()

    def test_mktemp_failure_writes_no_secret(self):
        self.command(self.root/'bin/mktemp','raise SystemExit(23)')
        result=self.run_sheet('none','ok','list')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(list(self.secrets.iterdir()),[])
        self.assertFalse((self.root/'sign-ready').exists())

    def test_matrix_batch_failure_never_runs_put_or_reports_success(self):
        for mode in ('http','transport','empty','malformed','error','schema'):
            with self.subTest(mode=mode):
                result = self.run_sheet('batch', mode, 'load', 'V1', str(self.tsv))
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

    def test_confirmed_matrix_batch_reports_success(self):
        result = self.run_sheet('batch', 'ok', 'load', 'V1', str(self.tsv))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['token','get','batch'])
        self.assertIn('peuplé', result.stdout)

    def hide_old_metadata(self, titles):
        metadata={'sheets':[{'properties':{'sheetId':index+1,'title':title,'index':index,'hidden':False}}
                            for index,title in enumerate(titles)]}
        path=self.root/'sheets.json';path.write_text(json.dumps(metadata));self.env['FIXTURE_SHEETS']=str(path)
        return path,metadata

    def test_hide_old_rejects_absent_or_nonversion_selection_without_writing(self):
        for titles,keep in ((['V1','Accueil'],'V999'),(['V1'],'V999'),
                            (['V1','Accueil'],'Accueil'),(['Accueil'],'V999')):
            with self.subTest(titles=titles,keep=keep):
                path,before=self.hide_old_metadata(titles)
                (self.root/'batch.json').unlink(missing_ok=True)
                result=self.run_sheet('none','ok','hide-old',keep)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Onglet de version introuvable',result.stderr)
                self.assertNotIn('reste visible',result.stdout)
                self.assertEqual(self.calls.read_text().splitlines(),['token','get'])
                self.assertFalse((self.root/'batch.json').exists())
                self.assertEqual(json.loads(path.read_text()),before)
                self.assertEqual(list(self.secrets.iterdir()),[])

    def test_hide_old_explicit_and_default_keep_selected_version(self):
        for selection,keep in ((['V1'],'V1'),([], 'V10')):
            with self.subTest(selection=selection):
                path,before=self.hide_old_metadata(['V1','V10','V2','Accueil'])
                before['sheets'][1]['properties']['hidden']=True
                path.write_text(json.dumps(before))
                result=self.run_sheet('none','ok','hide-old',*selection)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(f'Seul {keep} reste visible',result.stdout)
                self.assertEqual(self.calls.read_text().splitlines(),['token','get','batch'])
                after=json.loads(path.read_text())
                self.assertEqual(after['sheets'][-1],before['sheets'][-1])
                for sheet in after['sheets'][:-1]:
                    self.assertEqual(sheet['properties']['hidden'],sheet['properties']['title']!=keep)
                self.assertEqual(len(json.loads((self.root/'batch.json').read_text())['requests']),3)
                self.assertEqual(list(self.secrets.iterdir()),[])

    def test_hide_old_default_without_versions_does_not_write(self):
        path,before=self.hide_old_metadata(['Accueil'])
        result=self.run_sheet('none','ok','hide-old')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Aucun onglet de version trouvé',result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(),['token','get'])
        self.assertFalse((self.root/'batch.json').exists())
        self.assertEqual(json.loads(path.read_text()),before)
        self.assertEqual(list(self.secrets.iterdir()),[])

    def test_structured_read_and_batch_succeed(self):
        for args in (('list',),('show','V1'),('setcell','V1','A1','fixture'),('hide-old',)):
            with self.subTest(args=args):
                result = self.run_sheet('none', 'ok', *args)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
