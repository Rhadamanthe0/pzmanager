"""Low-level typed systemd transport only; not native PID1 integration."""
import importlib.util,json,os,pathlib,shutil,tempfile,unittest
ROOT=pathlib.Path(os.environ['PZ_TEST_ROOT'])
@unittest.skipUnless(os.geteuid()==0, 'root-owned metadata fixture required')
class Evidence(unittest.TestCase):
 def test_typed_pid1_other_services(self):
  with tempfile.TemporaryDirectory(dir='/run',prefix='review-ssh-wire-') as tmp:
   tmp=pathlib.Path(tmp)
   spec=importlib.util.spec_from_file_location('authority',ROOT/'data/scripts/lib/ssh_listener_authority.py')
   a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
   anchor=tmp/'sshd';shutil.copy2('/usr/sbin/sshd',anchor)
   other=tmp/'sleep';shutil.copy2('/usr/bin/sleep',other)
   unit=tmp/'fixture.service';unit.write_text('[Service]\n')
   datafile=tmp/'responses.json';log=tmp/'calls'
   wire=tmp/'busctl'
   wire.write_text('#!/usr/bin/python3\nimport json,sys,pathlib\nargs=sys.argv[sys.argv.index("--")+1:]\n'+
     'with pathlib.Path('+repr(str(log))+').open("a") as f:f.write(repr(args)+"\\n")\n'+
     'state=json.loads(pathlib.Path('+repr(str(datafile))+').read_text())\n'+
     'key=json.dumps(args)\nif key not in state:raise SystemExit("UNEXPECTED "+key)\nprint(json.dumps(state[key]))\n')
   wire.chmod(0o755);a.BUSCTL=wire
   def run(user,with_vsock=False,dynamic=False,ssh=False,endpoint=None,bad_type=False):
    owner=':1.1';mgr='/org/freedesktop/systemd1';sp=mgr+'/unit/a_socket';svc=mgr+'/unit/a_service';vp=mgr+'/unit/v_socket'
    service=a.MANAGER
    rows=[['a.socket','fixture','loaded','active','listening','',sp,0,'', '/']]
    if with_vsock:rows.append(['v.socket','fixture','loaded','active','listening','',vp,0,'','/'])
    states={}
    def reply(args,typ,value):states[json.dumps(args)]={'type':typ,'data':value}
    reply(['call',owner,mgr,service+'.Manager','ListUnits',''],'a(ssssssouso)',[rows])
    reply(['call',owner,mgr,service+'.Manager','GetUnit','s','a.service'],'o',[svc])
    for path in [sp,svc]+([vp] if with_vsock else []):
     for prop,typ,value in [('LoadState','s','loaded'),('FragmentPath','s',str(unit)),('DropInPaths','as',[])]:
      reply(['get-property',owner,path,service+'.Unit',prop],typ,value)
    for path,endpoint in [(sp,'127.0.0.1:2222')]+([(vp,endpoint or 'vsock:2:4444')] if with_vsock else []):
     for prop,typ,value in [('ActiveState','s','active'),('Triggers','as',['a.service'])]:
      reply(['get-property',owner,path,service+'.Unit',prop],typ,value)
     reply(['get-property',owner,path,service+'.Socket','Listen'],'a(ss)',[['Stream',endpoint]])
    for prop,typ,value in [('User','s',user),('DynamicUser','b',dynamic),('ExecStart','a(sasbttttuii)',[[str(anchor if ssh else other),[str(anchor if ssh else other),'120'],False,0,0,0,0,0,0,0]])]:
     reply(['get-property',owner,svc,service+'.Service',prop],typ,value)
    if bad_type:
     states[json.dumps(['get-property',owner,sp,service+'.Socket','Listen'])]['type']='s'
    datafile.write_text(json.dumps(states))
    # Constructor authentication is outside this parser/control-flow fixture.
    # query/call/prop/provenance/service/pid1_ports and wire JSON remain real.
    bus=a.SystemBus.__new__(a.SystemBus);bus.owner=owner;bus.cache={}
    with open(anchor,'rb') as fd:bus.anchor=a.identity(fd.fileno())
    return bus.pid1_ports({111:(4,'127.0.0.1',2222,0)}, {111})
   for options,expected in [
    ({'user':'root'},set()),
    ({'user':'65533'},set()),
    ({'user':'root','dynamic':True},set()),
    ({'user':'65533','dynamic':True,'with_vsock':True},set()),
    ({'user':'root','ssh':True},{2222}),
    ({'user':'root','ssh':True,'with_vsock':True},{2222}),
    ({'user':'root','ssh':True,'with_vsock':True,'endpoint':'vsock::4444'},{2222}),
   ]:
    with self.subTest(options=options):
     self.assertEqual(run(**options),expected)
   for user,dynamic in [('65533',False),('root',True)]:
    with self.subTest(user=user,dynamic=dynamic):
     with self.assertRaisesRegex(a.Unproven,'Service SSH administratif non root'):
      run(user,dynamic=dynamic,ssh=True)
   for endpoint in ['vsock:no:4444','vsock:4294967296:1','vsock::4294967296','vsock:::4444','vsock::','not-an-endpoint','127.0.0.1:notaport']:
    with self.subTest(endpoint=endpoint):
     with self.assertRaises((a.Unproven,ValueError)):
      run('root',with_vsock=True,endpoint=endpoint)
   with self.assertRaisesRegex(a.Unproven,'Métadonnées système non typées'):
    run('root',bad_type=True)
   print('Typed JSON transport only: nonSSH UID/DynamicUser and valid VSOCK excluded; SSH/nonroot, malformed endpoint and signature refuse. PID1 authentication NOT exercised.')
if __name__=='__main__':unittest.main()
