"""Native PID1/system bus test: disposable GitHub-hosted VM only.

The ordinary suite intentionally skips this test. The reviewed hosted-only
workflow opts in separately; unavailable native resources fail explicitly.
Only nonce units under /run and loopback sockets are changed. UFW is doubled.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import subprocess
import signal
import unittest

ROOT=Path(os.environ['PZ_TEST_ROOT'])
AUTHORIZED=os.environ.get('SSH_AUTHORITY_HOSTED_TEST')=='github-hosted' and os.environ.get('GITHUB_ACTIONS')=='true'


@unittest.skipUnless(AUTHORIZED, 'NON VÉRIFIÉ: hosted-only native PID1 test not opted in')
class SocketActivation(unittest.TestCase):
    def test_native_pid1_authority_and_exclusion(self):
        # All guards and resource checks precede the first privileged write.
        self.assertEqual(os.geteuid(),0,'native test requires root on the disposable hosted VM')
        self.assertEqual(Path('/proc/1/comm').read_text().strip(),'systemd','NON VÉRIFIÉ: no native systemd PID1')
        for tool in ('busctl','systemctl','ssh-keygen','sleep'):
            self.assertIsNotNone(shutil.which(tool),'NON VÉRIFIÉ: missing preinstalled '+tool)
        self.assertTrue(Path('/usr/sbin/sshd').is_file(),'NON VÉRIFIÉ: OpenSSH server unavailable')
        self.assertTrue(Path('/run/dbus/system_bus_socket').is_socket(),'NON VÉRIFIÉ: no native system bus')
        spec=importlib.util.spec_from_file_location('authority',ROOT/'data/scripts/lib/ssh_listener_authority.py')
        authority=importlib.util.module_from_spec(spec);spec.loader.exec_module(authority)
        anchor=authority.protected(authority.SSHD)
        try:baseline_ports=authority.active_ports(authority.identity(anchor))
        finally:os.close(anchor)
        os.close(authority.protected('/usr/bin/sleep'))
        os.close(authority.protected('/usr/bin/systemctl'))
        directory=Path('/run/systemd/system')
        for parent in (directory,*directory.parents):
            info=parent.stat();self.assertEqual(info.st_uid,0);self.assertEqual(info.st_mode&0o022,0)
        # The outer supervisor owns cleanup and publishes this ledger before
        # any unit exists; SIGKILL of this process cannot kill that owner.
        spec=importlib.util.spec_from_file_location('supervisor',ROOT/'tests/ssh_socket_supervisor.py')
        supervisor=importlib.util.module_from_spec(spec);spec.loader.exec_module(supervisor)
        registry=Path(os.environ['SSH_AUTHORITY_REGISTRY'])
        data=supervisor.load(registry)
        supervisor.register_test(registry)
        base=Path(data['base']);nonce=data['nonce']
        names=[nonce+'-ssh',nonce+'-other'];ports=data['ports']
        self.assertFalse(set(ports)&baseline_ports,'reserved fixture port is already administrative')
        def systemctl(*args,check=True):
            env={k:v for k,v in os.environ.items() if k not in ('DBUS_SYSTEM_BUS_ADDRESS','DBUS_SESSION_BUS_ADDRESS')}
            return subprocess.run(['/usr/bin/systemctl',*args],env=env,capture_output=True,text=True,timeout=15,check=check)
        key=base/'hostkey'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True,timeout=10)
        config=base/'sshd_config';config.write_text(f'HostKey {key}\nListenAddress 127.0.0.1:29999\nUsePAM no\n')
        supervisor.publish(registry)
        systemctl('daemon-reload')
        systemctl('start','--',*(name+'.socket' for name in names))
        scenario=os.environ.get('SSH_AUTHORITY_SCENARIO','normal')
        if scenario in ('term','kill'):
            print('CONTROLLED_'+scenario.upper()+'_READY',flush=True)
            os.kill(os.getpid(),signal.SIGTERM if scenario=='term' else signal.SIGKILL)
        if scenario=='command-failure':
            # Deliberately fail a read of our own unit, after live sockets.
            print('CONTROLLED_COMMAND-FAILURE_READY',flush=True)
            systemctl('--definitely-invalid-fixture-option','show','--',names[0]+'.socket')
            raise RuntimeError('controlled command failure after fixture creation')
        for name in names:
            self.assertEqual(systemctl('show','--value','-p','ActiveState','--',name+'.service').stdout.strip(),'inactive','test must not start the activated service')
        # No connection is made: PID1 must still own the actual TCP FDs.
        result=subprocess.run(['python3',str(ROOT/'data/scripts/lib/ssh_listener_authority.py'),'--config',str(config)],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        selected=set(map(int,result.stdout.split()))
        self.assertIn(ports[0],selected)
        self.assertNotIn(ports[1],selected)
        config.write_text(f'HostKey {key}\nListenAddress 127.0.0.1:29998\nUsePAM no\n')
        again=subprocess.run(['python3',str(ROOT/'data/scripts/lib/ssh_listener_authority.py'),'--config',str(config)],capture_output=True,text=True,timeout=30)
        self.assertEqual(again.returncode,0,again.stderr)
        self.assertEqual(again.stdout,result.stdout)
        for name in names:
            self.assertEqual(systemctl('show','--value','-p','ActiveState','--',name+'.service').stdout.strip(),'inactive')
        # Exercise the real mutation planner, with only UFW transport and
        # its physical policy files replaced inside the disposable copy.
        project=base/'project'
        shutil.copytree(ROOT/'data/scripts',project/'data/scripts')
        shutil.copytree(ROOT/'data/setupTemplates',project/'data/setupTemplates')
        state=base/'state';state.mkdir()
        (state/'ufw.active').write_text('yes');(state/'ufw.rules').write_text('')
        defaults=state/'defaults';defaults.write_text('IPV6=no\n')
        ufwconf=state/'ufw.conf';ufwconf.write_text('ENABLED=yes\n')
        reader=project/'data/scripts/lib/ufw_access.py'
        reader.write_text(reader.read_text().replace('Path("/etc/default/ufw")','Path('+repr(str(defaults))+')').replace('Path("/etc/ufw/ufw.conf")','Path('+repr(str(ufwconf))+')'))
        binary=base/'bin';binary.mkdir()
        canned=(ROOT/'tests/test_c12_ufw.sh').read_text().split('cat > "$BIN/ufw" <<\'MOCKEOF\'\n',1)[1].split('\nMOCKEOF',1)[0]
        (binary/'ufw').write_text(canned);(binary/'ufw').chmod(0o755)
        env=dict(os.environ,PATH=str(binary)+':'+os.environ['PATH'],MOCK_DIR=str(state),PZ_SSHD_CONFIG=str(config))
        planned=subprocess.run(['bash','-c','source "$1" fixture; configure_firewall','_',str(project/'data/scripts/install/setupSystem.sh')],env=env,capture_output=True,text=True,timeout=40)
        self.assertEqual(planned.returncode,0,planned.stderr+planned.stdout)
        self.assertIn(str(ports[0])+'/tcp ALLOW IN Anywhere',(state/'ufw.rules').read_text())
        self.assertNotIn(str(ports[1])+'/tcp',(state/'ufw.rules').read_text())


if __name__=='__main__':unittest.main()
