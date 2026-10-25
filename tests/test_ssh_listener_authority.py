"""Real proc/UID/socket/OpenSSH evidence, only inside a private Linux rootfs."""
import ctypes
import json
import os
from pathlib import Path
import shutil
import socket
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(os.environ['PZ_TEST_ROOT'])


@unittest.skipUnless(os.geteuid()==0 and Path('/').stat().st_dev==Path('/run').stat().st_dev and '0          0' not in Path('/proc/self/uid_map').read_text(), 'mapped-root private rootfs required')
class Authority(unittest.TestCase):
    def setUp(self):
        # Explicit independent guard before any daemon or UID fixture.
        row=Path('/proc/self/uid_map').read_text().splitlines()[0].split()
        if row[:2]==['0','0'] or subprocess.check_output(['stat','-f','-c','%T','/'],text=True).strip()!='tmpfs':
            self.skipTest('private tmpfs rootfs with mapped UID required')
        self.base=Path(tempfile.mkdtemp(prefix='ssh-authority-',dir='/root'))
        self.addCleanup(shutil.rmtree,self.base)
        self.children=[]
        self.descendants={}
        self.addCleanup(self.stop)
        self.anchor=self.base/'sshd'
        shutil.copy2('/usr/sbin/sshd',self.anchor)
        self.anchor.chmod(0o755)
        self.python=self.base/'python'
        shutil.copy2(sys.executable,self.python)
        self.python.chmod(0o755)
        self.key=self.base/'hostkey'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(self.key)],check=True)
        self.config=self.base/'sshd_config'
        self.module=self.base/'authority.py'
        text=(ROOT/'data/scripts/lib/ssh_listener_authority.py').read_text().replace("Path('/usr/sbin/sshd')",'Path('+repr(str(self.anchor))+')')
        self.module.write_text(text)
        self.config.write_text(f'HostKey {self.key}\nPort 24422\nListenAddress 127.0.0.1\nUsePAM no\nPidFile {self.base}/sshd.pid\n')
        Path('/run/sshd').mkdir(exist_ok=True)
        self.transport=self.base/'bin';self.transport.mkdir()
        self.state=self.base/'state';self.state.mkdir()
        self.calls=self.state/'ufw.log';self.calls.touch()
        (self.state/'ufw.active').write_text('yes')
        (self.state/'ufw.rules').write_text('')
        self.defaults=self.base/'defaults';self.defaults.write_text('IPV6=no\n')
        self.ufwconf=self.base/'ufw.conf';self.ufwconf.write_text('ENABLED=yes\n')
        source=(ROOT/'tests/test_c12_ufw.sh').read_text()
        boundary=source.split('cat > "$BIN/ufw" <<\'MOCKEOF\'\n',1)[1].split('\nMOCKEOF',1)[0]
        (self.transport/'ufw').write_text(boundary)
        (self.transport/'ufw').chmod(0o755)
        # Source the real setup helper with the actual authority reader copied
        # adjacent to it, so configure_firewall remains the mutation boundary.
        self.repo=self.base/'project'
        shutil.copytree(ROOT/'data/scripts',self.repo/'data/scripts')
        shutil.copytree(ROOT/'data/setupTemplates',self.repo/'data/setupTemplates')
        (self.repo/'data/scripts/lib/ssh_listener_authority.py').write_text(text)
        budget=self.repo/'data/scripts/lib/ufw_access.py'
        budget.write_text(budget.read_text().replace('Path("/etc/default/ufw")','Path('+repr(str(self.defaults))+')').replace('Path("/etc/ufw/ufw.conf")','Path('+repr(str(self.ufwconf))+')'))
        self.env=dict(os.environ,PATH=str(self.transport)+':'+os.environ['PATH'],MOCK_DIR=str(self.state),PZ_SSHD_CONFIG=str(self.config))

    def stop(self):
        for fd in self.descendants.values():
            try:signal.pidfd_send_signal(fd,signal.SIGTERM)
            except ProcessLookupError:pass
            finally:os.close(fd)
        for child in self.children:
            child.terminate()
        for child in self.children:
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:child.kill();child.wait()
            for stream in (child.stdout,child.stderr):
                if stream:stream.close()

    def configure(self):
        result=subprocess.run(['bash','-c','source "$1" pzfixture; configure_firewall','_',str(self.repo/'data/scripts/install/setupSystem.sh')],env=self.env,text=True,capture_output=True,timeout=20)
        return result

    def probe(self):
        return subprocess.run([sys.executable,str(self.module),'--config',str(self.config)],text=True,capture_output=True,timeout=20)

    def child_socket(self, uid=0, name='http-fixture', wrapper=False):
        script=self.base/'listener.py'
        script.write_text('''import ctypes,json,os,socket,sys,time,signal
if sys.argv[1]!='0':
 os.setgroups([]);os.setgid(int(sys.argv[1]));os.setuid(int(sys.argv[1]))
ctypes.CDLL(None).prctl(15,sys.argv[2].encode(),0,0,0)
signal.signal(signal.SIGUSR1,lambda *_:ctypes.CDLL(None).prctl(15,b'sshd',0,0,0))
signal.signal(signal.SIGUSR2,lambda *_:ctypes.CDLL(None).unshare(0x40000000))
s=socket.socket();s.bind(('127.0.0.1',0));s.listen()
print(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1]}),flush=True)
time.sleep(90)
''')
        # Nonroot can traverse only this fixture, never change trusted images.
        self.base.chmod(0o755);script.chmod(0o644)
        command=[str(self.python),str(script),str(uid),name]
        if wrapper:
            shell=self.base/'wrapper';shutil.copy2('/bin/bash',shell);shell.chmod(0o755)
            launcher=self.base/'launch';launcher.write_text('#!'+str(shell)+'\n"$@" &\nwait\n');launcher.chmod(0o755)
            command=[str(launcher),*command]
        child=subprocess.Popen(command,stdout=subprocess.PIPE,text=True)
        self.children.append(child)
        data=json.loads(child.stdout.readline())
        self.descendants[data['pid']]=os.pidfd_open(data['pid'])
        return data

    def ssh(self):
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        self.config.write_text(f'HostKey {self.key}\nPort {port}\nListenAddress 127.0.0.1\nUsePAM no\nPidFile {self.base}/sshd.pid\n')
        child=subprocess.Popen([str(self.anchor),'-D','-e','-f',str(self.config)],stderr=subprocess.PIPE,text=True)
        self.children.append(child)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            result=self.probe()
            if result.returncode==0 and str(port) in result.stdout.split():return port
            if child.poll() is not None:self.fail(child.stderr.read())
            time.sleep(.05)
        self.fail(result.stderr)

    def test_00_minimal_real_nonroot_and_active_root(self):
        fake=self.child_socket(65533,'plain-fixture')
        status=Path('/proc')/str(fake['pid'])/'status'
        fields=dict(line.split(':',1) for line in status.read_text().splitlines() if ':' in line)
        self.assertEqual(fields['Uid'].split(),['65533']*4)
        self.assertEqual(int(fields['CapEff'].strip(),16),0)
        result=self.probe();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.split(),['22','24422'])
        self.assertNotIn(str(fake['port']),result.stdout.split())
        configured=self.configure();self.assertEqual(configured.returncode,0,configured.stderr+configured.stdout)
        before=(self.state/'ufw.rules').read_text()
        os.kill(fake['pid'],signal.SIGUSR1)
        deadline=time.monotonic()+2
        while (Path('/proc')/str(fake['pid'])/'comm').read_text().strip()!='sshd' and time.monotonic()<deadline:time.sleep(.02)
        renamed=self.probe();self.assertEqual(renamed.returncode,0,renamed.stderr)
        self.assertEqual(renamed.stdout,result.stdout)
        configured=self.configure();self.assertEqual(configured.returncode,0,configured.stderr+configured.stdout)
        self.assertEqual((self.state/'ufw.rules').read_text(),before)
        self.assertNotIn(str(fake['port'])+'/tcp',(self.state/'ufw.rules').read_text())
        port=self.ssh()
        self.config.write_text('invalid after daemon start\n')
        result=self.probe();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.split(),list(map(str,sorted({22,port}))))
        configured=self.configure();self.assertEqual(configured.returncode,0,configured.stderr+configured.stdout)
        self.assertIn(str(port)+'/tcp ALLOW IN Anywhere',(self.state/'ufw.rules').read_text())

    def test_10_manual_wrapper_and_child_are_excluded(self):
        port=self.ssh()
        for wrapper in (False,True):
            other=self.child_socket(0,'http-fixture',wrapper)
            result=self.probe();self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(set(result.stdout.split()),{str(port),'22'})
            self.assertNotIn(str(other['port']),result.stdout.split())

    def test_15_kernel_namespace_incoherence_refuses(self):
        child=self.child_socket()
        before=(Path('/proc')/str(child['pid'])/'ns/net').stat().st_ino
        os.kill(child['pid'],signal.SIGUSR2)
        deadline=time.monotonic()+2
        while (Path('/proc')/str(child['pid'])/'ns/net').stat().st_ino==before and time.monotonic()<deadline:time.sleep(.02)
        self.assertNotEqual((Path('/proc')/str(child['pid'])/'ns/net').stat().st_ino,before)
        result=self.configure()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls.read_text(),'')

    def test_16_unprotected_anchor_refuses(self):
        self.anchor.chmod(0o777)
        result=self.configure()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls.read_text(),'')

    def test_20_replaced_anchor_refuses_before_ufw(self):
        self.ssh()
        replacement=self.base/'replacement';shutil.copy2('/usr/sbin/sshd',replacement);replacement.chmod(0o755)
        replacement.replace(self.anchor)
        result=self.probe();self.assertNotEqual(result.returncode,0)
        command=['bash','-c','source "$1" pzfixture; configure_firewall','_',str(self.repo/'data/scripts/install/setupSystem.sh')]
        result=subprocess.run(command,env=self.env,text=True,capture_output=True,timeout=20)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls.read_text(),'')


if __name__=='__main__':unittest.main()
