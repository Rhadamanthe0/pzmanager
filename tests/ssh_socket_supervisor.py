"""Owner of the hosted-only SSH fixture, outside run-isolated's test group.

A protected write-ahead registry survives a killed suite. The workflow also
calls cleanup in a separate always step. Never targets pre-existing units.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import select
import socket
import stat
import subprocess
import sys
import uuid

RUN = Path('/run')
UNITS = RUN/'systemd/system'
SYSTEMCTL = Path('/usr/bin/systemctl')


def protected(path, directory=False):
    path=Path(path)
    for item in (path,*path.parents):
        info=item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:
            raise ValueError('Unprotected fixture path: '+str(item))
    if directory and not path.is_dir():raise ValueError('Not a fixture directory')


def save(path, data, exclusive=False):
    # Root-protected parent and atomic replacement preserve a retryable ledger.
    protected(path.parent,True)
    temporary=path.with_suffix('.new')
    if temporary.exists():
        protected(temporary)
        if not temporary.is_file() or temporary.stat().st_mode&0o077:raise ValueError('Invalid partial ledger')
        temporary.unlink()
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'w') as out:
            json.dump(data,out);out.flush();os.fsync(out.fileno())
        if exclusive:os.link(temporary,path,follow_symlinks=False)
        else:os.replace(temporary,path)
    finally:temporary.unlink(missing_ok=True)


def load(path):
    protected(path)
    if path.stat().st_mode&0o077 or path.stat().st_size>1048576:raise ValueError('Invalid registry protection/size')
    data=json.loads(path.read_text())
    nonce=data['nonce'];base=Path(data['base'])
    if not re.fullmatch(r'pz-ssh-authority-[0-9a-f]{32}',nonce) or base!=RUN/nonce:
        raise ValueError('Invalid fixture nonce/base')
    expected={nonce+'-'+role+suffix for role in ('ssh','other') for suffix in ('.socket','.service')}
    if set(data['units'])!=expected or any(not isinstance(v,str) for v in data['units'].values()):raise ValueError('Invalid owned unit set')
    if not isinstance(data['owned'],list) or not set(data['owned'])<=expected:raise ValueError('Invalid ownership ledger')
    if len(data['ports'])!=2 or any(type(p)is not int or not 1024<=p<=65535 for p in data['ports']) or len(set(data['ports']))!=2:raise ValueError('Invalid fixture ports')
    if base.exists():
        protected(base,True)
        if [base.stat().st_dev,base.stat().st_ino]!=data['base_identity']:raise ValueError('Fixture directory replaced')
    return data


def systemctl(*args,check=True):
    protected(SYSTEMCTL)
    env={k:v for k,v in os.environ.items() if k not in ('DBUS_SYSTEM_BUS_ADDRESS','DBUS_SESSION_BUS_ADDRESS')}
    return subprocess.run([str(SYSTEMCTL),*args],env=env,capture_output=True,text=True,timeout=5,check=check)


def listening_ports():
    result=set()
    for name in ('tcp','tcp6'):
        path=Path('/proc/net')/name
        if not path.exists() and name=='tcp6':continue
        for line in path.read_text().splitlines()[1:]:
            row=line.split()
            if row[3]=='0A':result.add(int(row[1].split(':')[1],16))
    return result


def create_registry(path):
    protected(RUN,True);protected(UNITS,True)
    if path.parent!=RUN or not re.fullmatch(r'pz-ssh-authority-ci-[0-9]+-[0-9]+\.json',path.name):raise ValueError('Invalid hosted registry path')
    if os.path.lexists(path) or os.path.lexists(path.with_suffix('.new')):
        raise ValueError('Registry already exists; clean it explicitly first')
    nonce='pz-ssh-authority-'+uuid.uuid4().hex
    base=RUN/nonce;base.mkdir(mode=0o700)
    created=base.stat()
    try:
        ports=[]
        for _ in range(40):
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            if port>=1024 and port not in {*ports,29998,29999}:ports.append(port)
            if len(ports)==2:break
        if len(ports)!=2:raise RuntimeError('No private ports')
        units={}
        for index,role in enumerate(('ssh','other')):
            name=nonce+'-'+role
            command=f'/usr/sbin/sshd -D -f {base}/sshd_config' if index==0 else '/usr/bin/sleep 120'
            # NonSSH DynamicUser is a real S1a regression witness on the VM.
            user='User=root\n' if index==0 else 'DynamicUser=yes\n'
            units[name+'.socket']=f'[Unit]\nDescription={nonce}\n[Socket]\nListenStream=127.0.0.1:{ports[index]}\nAccept=no\nService={name}.service\n'
            units[name+'.service']=f'[Unit]\nDescription={nonce}\n[Service]\n{user}ExecStart={command}\n'
        data=dict(nonce=nonce,base=str(base),base_identity=[base.stat().st_dev,base.stat().st_ino],ports=ports,units=units,owned=[])
        save(path,data,exclusive=True)
    except BaseException:
        # Before publication only this call's still-empty directory is ours.
        # A valid/partial ledger belongs to the retry path, never discard it.
        if not os.path.lexists(path) and not os.path.lexists(path.with_suffix('.new')):
            try:
                current=base.lstat()
                if stat.S_ISDIR(current.st_mode) and (current.st_dev,current.st_ino)==(created.st_dev,created.st_ino):
                    base.rmdir()
            except OSError:
                pass  # Preserve foreign/nonempty/replaced paths and original error.
        raise
    return data


def process_start(pid):
    # comm may contain spaces and parentheses; numeric fields follow its last ).
    return Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]


def register_test(path):
    data=load(path)
    if os.getpgrp()!=os.getpid():raise ValueError('Native suite must own a separate process group')
    data['test_process']=[os.getpid(),process_start(os.getpid())]
    save(path,data)


def stop_test(data):
    value=data.get('test_process')
    if value is None:return
    if not isinstance(value,list) or len(value)!=2 or type(value[0])is not int or value[0]<=1 or not isinstance(value[1],str) or not value[1].isdecimal():raise ValueError('Invalid test incarnation')
    pid,start=value
    try:fd=os.pidfd_open(pid)
    except ProcessLookupError:return
    try:
        try:
            if process_start(pid)!=start:raise ValueError('Test PID reused')
            if os.getpgid(pid)!=pid or pid==os.getpgrp():raise ValueError('Foreign process group')
            os.killpg(pid,signal.SIGKILL)
            if not select.select([fd],[],[],2)[0]:raise RuntimeError('Fixture process did not exit before cleanup')
        except ProcessLookupError:pass
    finally:os.close(fd)


def publish(path):
    data=load(path);base=Path(data['base'])
    for name,contents in data['units'].items():
        source=base/name
        fd=os.open(source,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as out:out.write(contents)
        # Full bytes become visible atomically, no overwrite and no gap in
        # which an unregistered partial unit could be loaded by systemd.
        os.link(source,UNITS/name,follow_symlinks=False)


def cleanup(path):
    if not path.exists():
        temporary=path.with_suffix('.new')
        if not temporary.exists():return
        # Interrupted atomic publication: valid complete ledger can be resumed;
        # malformed bytes refuse visibly and remain available for diagnosis.
        data=load(temporary)
        os.link(temporary,path,follow_symlinks=False)
        temporary.unlink()
    data=load(path);errors=[]
    stop_test(data)
    # Establish ownership before any bus mutation; preserve ledger on error.
    for name,contents in data['units'].items():
        file=UNITS/name
        if file.exists() or file.is_symlink():
            protected(file)
            if file.read_text()!=contents:raise ValueError('Foreign unit collision: '+name)
            if name not in data['owned']:data['owned'].append(name)
    save(path,data)
    names=data['owned']
    if names:
        loaded=[]
        for name in names:
            result=systemctl('show','--value','-p','LoadState','--',name,check=False)
            if result.returncode or result.stdout.strip() not in ('loaded','not-found'):
                errors.append('Unit load state unproved: '+name)
            elif result.stdout.strip()=='loaded':loaded.append(name)
        if not errors and loaded:
            for verb in ('stop','reset-failed'):
                try:
                    result=systemctl(verb,'--',*loaded,check=False)
                    if result.returncode:errors.append(result.stderr or verb+' failed')
                except (OSError,subprocess.SubprocessError) as error:errors.append(str(error))
        # A failed stop leaves the evidence intact for an explicit retry.
        if errors:raise RuntimeError('; '.join(errors))
        for name in names:
            file=UNITS/name
            if file.exists():
                protected(file)
                if file.read_text()!=data['units'][name]:raise ValueError('Unit changed before unlink')
                file.unlink()
        try:systemctl('daemon-reload')
        except (OSError,subprocess.SubprocessError) as error:errors.append(str(error))
        for name in names:
            try:
                result=systemctl('show','--value','-p','LoadState','--',name,check=False)
                if result.returncode or result.stdout.strip()!='not-found':errors.append('Unit absence unproved: '+name)
            except (OSError,subprocess.SubprocessError) as error:errors.append(str(error))
    if any((UNITS/name).exists() or (UNITS/name).is_symlink() for name in data['units']):errors.append('Unit file survived')
    if set(data['ports'])&listening_ports():errors.append('Private listener survived')
    if errors:raise RuntimeError('; '.join(errors))
    base=Path(data['base'])
    if base.exists():shutil.rmtree(base)
    # Registry is the last resource removed, only after absence is proved.
    path.unlink()


def run(registry,results,scenario):
    create_registry(registry)
    env=dict(os.environ,SSH_AUTHORITY_REGISTRY=str(registry),SSH_AUTHORITY_SCENARIO=scenario)
    runner=Path(__file__).with_name('run-isolated.py')
    process=None
    interrupted=False
    def terminate(signum,frame):
        nonlocal interrupted
        # Do not die with the suite's group. Let the runner finish/kill its
        # child (180+5s maximum), then always clean. Workflow cleanup retries.
        interrupted=True
    previous=signal.signal(signal.SIGTERM,terminate)
    try:
        process=subprocess.Popen([sys.executable,str(runner),'--results',str(results),'--only','test_ssh_socket_activation.py'],env=env,start_new_session=True)
        code=process.wait(timeout=210)
        if scenario=='normal':return 128+signal.SIGTERM if interrupted else code
        rows=json.loads((results/'results.json').read_text())
        expected={'term':-signal.SIGTERM,'kill':-signal.SIGKILL,'command-failure':1}[scenario]
        log=(results/'test_ssh_socket_activation.py.log').read_text()
        if len(rows)!=1 or rows[0]['exit']!=expected or 'CONTROLLED_'+scenario.upper()+'_READY' not in log:raise RuntimeError('Expected controlled interruption was not observed')
        return 0
    finally:
        try:
            if process is not None and process.poll() is None:
                # Stop registered test group before its runner, preventing any
                # concurrent publication during the external cleanup.
                stop_test(load(registry))
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            cleanup(registry)
        finally:signal.signal(signal.SIGTERM,previous)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('run','cleanup'))
    parser.add_argument('--registry',type=Path,required=True)
    parser.add_argument('--results',type=Path)
    parser.add_argument('--scenario',choices=('normal','term','kill','command-failure'),default='normal')
    args=parser.parse_args()
    if os.geteuid()!=0 or os.environ.get('SSH_AUTHORITY_HOSTED_TEST')!='github-hosted' or os.environ.get('GITHUB_ACTIONS')!='true':raise ValueError('Disposable GitHub-hosted opt-in required')
    if args.action=='cleanup':cleanup(args.registry);return 0
    if args.results is None:parser.error('--results required for run')
    return run(args.registry,args.results,args.scenario)


if __name__=='__main__':raise SystemExit(main())
