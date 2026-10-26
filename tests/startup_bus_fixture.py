"""Private busctl boundary; every admission/FD and metadata check stays real."""
from pathlib import Path


def write_busctl(directory, launcher, unit='probe.service'):
    path=Path(directory)/'busctl'
    path.write_text('''#!/usr/bin/env python3
import json,os,shlex,sys
from pathlib import Path
args=sys.argv[1:]
prefix=['--user','--json=short','--timeout=5','--']
service='org.freedesktop.systemd1'
objectpath='/org/freedesktop/systemd1/unit/fixture_2eservice'
calls=os.environ.get('STARTUP_TEST_BUS_CALLS')
if calls:
 with open(calls,'a') as stream:stream.write(json.dumps(args)+'\\n')
if args==prefix+['call',service,'/org/freedesktop/systemd1',service+'.Manager','GetUnit','s',UNIT]:
 if os.environ.get('STARTUP_TEST_BUS_ERROR')=='manager':sys.exit(7)
 print(os.environ.get('STARTUP_TEST_OBJECT',json.dumps({'type':'o','data':[objectpath]})))
elif args in [prefix+['get-property',service,objectpath,service+'.Service',name] for name in ('ExecStart','ExecStartPre')]:
 if os.environ.get('STARTUP_TEST_BUS_ERROR')=='property':sys.exit(7)
 row=[LAUNCHER,[LAUNCHER],False,0,0,0,0,0,0,0]
 rows=None
 if os.environ.get('STARTUP_TEST_UNIT_FILE'):
  unitfile=Path(os.environ['STARTUP_TEST_UNIT_FILE']);rows=[]
  for file in [unitfile,*sorted(Path(str(unitfile)+'.d').glob('*.conf'))]:
   for line in file.read_text().splitlines():
    if not line.startswith(args[-1]+'='):continue
    command=line.split('=',1)[1]
    if not command:rows=[];continue
    ignore=command.startswith('-');command=command.lstrip('-').replace('%h',os.environ['HOME'])
    argv=shlex.split(command);rows.append([argv[0],argv,ignore,0,0,0,0,0,0,0])
 if args[-1]=='ExecStart':
  print(os.environ.get('STARTUP_TEST_EXECSTART',json.dumps({'type':'a(sasbttttuii)','data':[row] if rows is None else rows})))
 else:
  prepare=str(Path(LAUNCHER).with_name('prepareWorldStart.sh'))
  if rows is None:rows=[[LAUNCHER,[LAUNCHER,'--check'],False,0,0,0,0,0,0,0],[prepare,[prepare],False,0,0,0,0,0,0,0]]
  print(os.environ.get('STARTUP_TEST_PRE',json.dumps({'type':'a(sasbttttuii)','data':rows})))
else:
 print('Unexpected private bus metadata request',file=sys.stderr);sys.exit(89)
'''.replace("args=sys.argv[1:]",'LAUNCHER='+repr(str(launcher))+'\nUNIT='+repr(unit)+'\nargs=sys.argv[1:]'))
    path.chmod(0o700)
    return path
