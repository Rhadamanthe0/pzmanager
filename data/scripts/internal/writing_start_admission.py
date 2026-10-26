#!/usr/bin/env python3
"""Keep WORLD exclusion across systemd's ExecStartPre process boundary."""
import argparse
import array
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"lib"))
from configureWritingTextOnly import ConfigurationError, open_root, atomic_file
from native_identity import validate_native_identity

MARKER = 'writing-start.json'
SOCKET = 'writing-start.sock'
LAUNCH_KEYS = ('PZ_SOURCE_DIR', 'PZ_SERVER_NAME', 'PZ_INSTALL_DIR', 'PZ_CONTROL_PIPE', 'PZ_MANAGER_DIR')


def validate_launch_profile(profile):
    if (not isinstance(profile, dict) or set(profile) != set(LAUNCH_KEYS) or
            any(not isinstance(value, str) or not value or '\0' in value or
                len(value.encode('utf-8')) > 4096 for value in profile.values())):
        raise ConfigurationError('Malformed start admission configuration')
    validate_native_identity(profile['PZ_SOURCE_DIR'], profile['PZ_SERVER_NAME'])
    return profile


def launch_profile():
    return validate_launch_profile({key: os.environ.get(key) for key in LAUNCH_KEYS})


def process_birth(pid):
    text = Path(f'/proc/{pid}/stat').read_text()
    return int(text.rsplit(')', 1)[1].split()[19])


def parent_pid(pid):
    return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[1])


def ancestor(pid, child):
    for _ in range(128):
        if pid == child: return True
        if child <= 1: return False
        child = parent_pid(child)
    return False


def live(pid, birth):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[0] != 'Z' and int(fields[19]) == birth
    except (OSError, ValueError): return False


def locked_fd(pid, fd, expected):
    info = os.stat(f'/proc/{pid}/fd/{fd}')
    if (info.st_dev, info.st_ino) != expected or not stat.S_ISREG(info.st_mode):
        raise ConfigurationError('WORLD FD identity changed')
    text = Path(f'/proc/{pid}/fdinfo/{fd}').read_text()
    identity = (os.major(info.st_dev), os.minor(info.st_dev), info.st_ino)
    for match in re.finditer(r'FLOCK\s+ADVISORY\s+WRITE\s+-?\d+\s+([0-9a-fA-F]+):([0-9a-fA-F]+):(\d+)', text):
        if (int(match[1], 16), int(match[2], 16), int(match[3])) == identity:
            return
    # flock(1)'s acquiring PID can have exited; OFD ownership is what matters.
    raise ConfigurationError('WORLD FD has no exclusive flock')


def directory(lock_path):
    path = Path(os.path.abspath(lock_path))
    fd, _ = open_root(path.parent)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise ConfigurationError('Admission directory must be private and owned by this UID')
    return path, fd


def runtime_lock_path(name='world.lock'):
    """Resolve a private runtime file (WORLD by default) with namespace-aware FD checks.

    systemd creates RuntimeDirectory for start-pre; pzm creates the same private
    directory before a brokered start. Never replace or unlink its lock inode.
    """
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',name):
        raise ConfigurationError('Invalid private runtime file name')
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}')
    if not runtime.is_absolute():
        raise ConfigurationError('Runtime directory must be absolute')
    if runtime.exists() or runtime.is_symlink():
        fd, _ = open_root(runtime)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ConfigurationError('Runtime directory must be private and owned by this UID')
            try: os.mkdir('pzmanager', mode=0o700, dir_fd=fd)
            except FileExistsError: pass
        finally: os.close(fd)
        path = runtime / 'pzmanager' / name
    else:
        directory_name = 'pzmanager-' + pwd.getpwuid(os.getuid()).pw_name
        fd, _ = open_root(Path('/tmp'))
        try:
            try: os.mkdir(directory_name, mode=0o700, dir_fd=fd)
            except FileExistsError: pass
        finally: os.close(fd)
        path = Path('/tmp') / directory_name / name
    path, fd = directory(path)
    os.close(fd)
    return path


def read_marker(directory_fd):
    fd = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConfigurationError('Untrusted start admission marker')
        contents = stream.read(65537)
        if len(contents) > 65536:
            raise ConfigurationError('Oversized start admission marker')
        data = json.loads(contents)
    if not isinstance(data, dict): raise ConfigurationError('Malformed start admission marker')
    required = ('pid', 'birth', 'fd', 'dev', 'ino', 'broker', 'broker_birth')
    if any(type(data.get(key)) is not int or data[key] < 0 for key in required):
        raise ConfigurationError('Malformed start admission marker')
    if not re.fullmatch(r'[0-9a-f]{32}', data.get('token', '')) or not isinstance(data.get('unit'), str):
        raise ConfigurationError('Malformed start admission token/unit')
    if type(data.get('quiet_ready', False)) is not bool:
        raise ConfigurationError('Malformed start admission quiet flag')
    # Old markers can still be removed once their owner and broker are dead.
    # Actual handoff requires the profile after FD authentication below.
    if 'launch' in data:
        validate_launch_profile(data['launch'])
    return data


def unit_state(unit):
    output = subprocess.check_output(['systemctl', '--user', 'show',
        '--property=ActiveState,SubState,MainPID,ControlPID', '--', unit], text=True)
    result = {}
    for line in output.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in result: raise ConfigurationError('Ambiguous service state')
        result[key] = value
    if set(result) != {'ActiveState', 'SubState', 'MainPID', 'ControlPID'}:
        raise ConfigurationError('Incomplete service state')
    result['MainPID'] = int(result['MainPID']); result['ControlPID'] = int(result['ControlPID'])
    return result


def startup_state(state, pid):
    return state['ActiveState'] == 'activating' and state['SubState'] == 'start-pre' \
        and state['MainPID'] == 0 and state['ControlPID'] > 0 and ancestor(state['ControlPID'], pid)


def validate_native_launcher(unit):
    """Require the effective typed ExecStart, including any installed drop-ins.

    Reading .env cannot update an old inline ExecStart. Refuse that unit before
    any startup worker writes a world that the game would not actually load.
    """
    prefix=['busctl','--user','--json=short','--timeout=5','--']
    service='org.freedesktop.systemd1'
    def query(arguments):
        raw=subprocess.check_output(prefix+arguments,text=True,stderr=subprocess.DEVNULL,timeout=6)
        if len(raw)>65536:raise ValueError('Oversized unit metadata')
        return json.loads(raw)
    try:
        obj=query(['call',service,'/org/freedesktop/systemd1',service+'.Manager','GetUnit','s',unit])
        if (not isinstance(obj,dict) or obj.get('type')!='o' or not isinstance(obj.get('data'),list)
                or len(obj['data'])!=1 or not isinstance(obj['data'][0],str)
                or not re.fullmatch(r'(?:/[A-Za-z0-9_]+)+',obj['data'][0])):
            raise ValueError('Invalid service object')
        def commands(property_name):
            value=query(['get-property',service,obj['data'][0],service+'.Service',property_name])
            if (not isinstance(value,dict) or value.get('type')!='a(sasbttttuii)'
                    or not isinstance(value.get('data'),list)):
                raise ValueError('Invalid command metadata')
            for row in value['data']:
                if (not isinstance(row,list) or len(row)!=10 or not isinstance(row[0],str)
                        or not row[0].startswith('/') or not isinstance(row[1],list)
                        or not row[1] or any(not isinstance(arg,str) for arg in row[1])
                        or type(row[2]) is not bool or any(type(v) is not int for v in row[3:])
                        or any(v<0 or v>=2**64 for v in row[3:7]) or not 0<=row[7]<2**32
                        or any(not -2**31<=v<2**31 for v in row[8:])):
                    raise ValueError('Invalid command row')
            return value['data']
        expected=os.path.abspath(str(Path(__file__).with_name('startServer.sh')))
        main=commands('ExecStart')
        if len(main)!=1 or main[0][:3]!=[expected,[expected],False]:
            raise ValueError('ExecStart is not the unified launcher')
        pre=commands('ExecStartPre')
        prepare=os.path.abspath(str(Path(__file__).with_name('prepareWorldStart.sh')))
        if (not pre or pre[0][:3]!=[expected,[expected,'--check'],False]
                or sum(row[:3]==[prepare,[prepare],False] for row in pre)!=1):
            raise ValueError('Native preflight is not first or preparation is absent')
    except (OSError,ValueError,TypeError,subprocess.SubprocessError):
        # ExecStart can contain credentials: never include its payload/errors.
        raise ConfigurationError('Lanceur effectif non vérifié : actualiser zomboid.service et ses drop-ins pour utiliser startServer.sh sans argument.') from None


def validate_start_identity(data, lock_info, unit):
    if data['unit'] != unit or not live(data['pid'], data['birth']):
        raise ConfigurationError('Start admission owner is no longer the prepared start')
    expected = (lock_info.st_dev, lock_info.st_ino)
    if (data['dev'], data['ino']) != expected: raise ConfigurationError('Start admission WORLD inode differs')
    if not live(data['broker'], data['broker_birth']): raise ConfigurationError('Start admission broker exited')


def validate_marker(data, lock_info, unit):
    # Cross-process descriptors are inspected by the broker in the CLI context.
    # A confined start-pre may read process identity but cannot open those FDs.
    validate_start_identity(data, lock_info, unit)
    expected = (lock_info.st_dev, lock_info.st_ino)
    locked_fd(data['pid'], data['fd'], expected)
    locked_fd(data['broker'], data['fd'], expected)


def clear(lock_path, token):
    path, directory_fd = directory(lock_path)
    try:
        try: data = read_marker(directory_fd)
        except FileNotFoundError: return
        if data['token'] != token: raise ConfigurationError('Refusing to clear another start admission')
        if live(data['broker'], data['broker_birth']):
            os.kill(data['broker'], signal.SIGTERM)
            for _ in range(100):
                if not live(data['broker'], data['broker_birth']): break
                time.sleep(0.01)
            else: raise ConfigurationError('Admission broker did not release its descriptor')
        for name in (MARKER, SOCKET):
            try: os.unlink(name, dir_fd=directory_fd)
            except FileNotFoundError: pass
    finally: os.close(directory_fd)


def prepare(lock_path, pid, fd, unit, quiet_ready=False):
    if type(quiet_ready) is not bool:
        raise ConfigurationError('Malformed start admission quiet flag')
    path, directory_fd = directory(lock_path)
    try:
        lock_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            info = os.fstat(lock_fd)
            if not ancestor(pid, os.getpid()): raise ConfigurationError('Start owner must be an ancestor')
            locked_fd(pid, fd, (info.st_dev, info.st_ino))
            validate_native_launcher(unit)
            launch_profile()
            # Never overwrite a live or malformed admission. Dead owner and
            # broker together make removal of only our stale metadata safe.
            try: old = read_marker(directory_fd)
            except FileNotFoundError: old = None
            if old:
                if live(old['pid'], old['birth']) or live(old['broker'], old['broker_birth']):
                    raise ConfigurationError('A start admission is still alive')
                clear(lock_path, old['token'])
            try: os.stat(SOCKET, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError: pass
            else: raise ConfigurationError('An unclaimed admission socket already exists')
            token = uuid.uuid4().hex
            child = subprocess.Popen([sys.executable, __file__, 'broker', '--lock-path', str(path),
                '--pid', str(pid), '--birth', str(process_birth(pid)), '--fd', str(fd),
                '--unit', unit, '--token', token] + (['--quiet-ready'] if quiet_ready else []), pass_fds=(fd,),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                try:
                    data = read_marker(directory_fd)
                    if data['token'] == token and data['broker'] == child.pid: return token
                except FileNotFoundError: pass
                if child.poll() is not None: raise ConfigurationError('Admission broker failed to initialize')
                time.sleep(0.05)
            child.terminate(); child.wait()
            raise ConfigurationError('Admission broker initialization timed out')
        finally: os.close(lock_fd)
    finally: os.close(directory_fd)


def broker(args):
    path, directory_fd = directory(args.lock_path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    try:
        info = os.fstat(args.fd)
        locked_fd(os.getpid(), args.fd, (info.st_dev, info.st_ino))
        payload = {'pid': args.pid, 'birth': args.birth, 'fd': args.fd, 'dev': info.st_dev,
            'ino': info.st_ino, 'broker': os.getpid(), 'broker_birth': process_birth(os.getpid()),
            'unit': args.unit, 'token': args.token, 'quiet_ready': args.quiet_ready,
            'launch': launch_profile()}
        validate_marker(payload, info, args.unit)
        contents = json.dumps(payload, ensure_ascii=False).encode()
        if len(contents) > 65536:
            raise ConfigurationError('Oversized start admission marker')
        listener.bind(str(path.parent / SOCKET)); os.chmod(path.parent / SOCKET, 0o600)
        listener.listen(1); listener.settimeout(0.25)
        atomic_file(directory_fd, MARKER, contents, 0o600)
        while live(args.pid, args.birth):
            try: client, _ = listener.accept()
            except socket.timeout: continue
            with client:
                client.settimeout(2)
                peer = array.array('i'); peer.frombytes(client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if peer[1] != os.getuid(): continue
                request = client.recv(64)
                if request != args.token.encode() or not startup_state(unit_state(args.unit), peer[0]): continue
                validate_marker(payload, info, args.unit)
                rights = array.array('i', [args.fd])
                client.sendmsg([b'WORLD'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)])
                return
    finally:
        listener.close(); os.close(directory_fd)
        # Close the inherited FD; never flock(LOCK_UN), which would unlock pzm.
        os.close(args.fd)


def run(args):
    validate_native_identity(os.environ.get('PZ_SOURCE_DIR', ''), os.environ.get('PZ_SERVER_NAME', ''))
    if os.environ.get('PZ_SOURCE_DIR'):
        from world_transaction import check_clean
        check_clean(os.environ['PZ_SOURCE_DIR'],legacy=True)
    path, directory_fd = directory(args.lock_path)
    held_fd = None
    data = None
    try:
        state = unit_state(args.unit)
        startup = startup_state(state, os.getpid())
        offline = state['ActiveState'] == 'inactive' and state['MainPID'] == 0 and state['ControlPID'] == 0
        if not startup and not offline: raise ConfigurationError('Server is not stopped or this unit start-pre')
        held_fd = os.open(path.name, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        info = os.fstat(held_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ConfigurationError('Untrusted WORLD lock file')
        # Older CLI creates this same inode as 0664 under umask 002. Tighten the
        # already verified descriptor, never replace the path or unlock it.
        os.fchmod(held_fd, 0o600)
        info = os.fstat(held_fd)
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise ConfigurationError('WORLD lock permissions could not be secured')
        try: fcntl.flock(held_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not startup: raise ConfigurationError('A world operation is already running')
            data = read_marker(directory_fd); validate_start_identity(data, info, args.unit)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            try:
                socket_info = os.stat(SOCKET, dir_fd=directory_fd, follow_symlinks=False)
                if not stat.S_ISSOCK(socket_info.st_mode) or socket_info.st_uid != os.getuid() or socket_info.st_mode & 0o077:
                    raise ConfigurationError('Untrusted start admission socket')
                client.settimeout(5); client.connect(str(path.parent / SOCKET))
                peer = array.array('i'); peer.frombytes(client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if peer[1] != os.getuid() or peer[0] != data['broker'] or not live(peer[0], data['broker_birth']):
                    raise ConfigurationError('Start admission socket is not the authenticated broker')
                client.sendall(data['token'].encode())
                message, ancillary, flags, _ = client.recvmsg(16, socket.CMSG_SPACE(array.array('i').itemsize))
                fds = array.array('i')
                for level, kind, value in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS: fds.frombytes(value)
                if message != b'WORLD' or len(fds) != 1 or flags & socket.MSG_CTRUNC:
                    for fd in fds: os.close(fd)
                    raise ConfigurationError('WORLD descriptor handoff failed')
                os.close(held_fd); held_fd = fds[0]
                locked_fd(os.getpid(), held_fd, (info.st_dev, info.st_ino))
            finally: client.close()
        # State can change while acquiring the lock; prove it again before work.
        fresh = unit_state(args.unit)
        if not (startup_state(fresh, os.getpid()) if startup else
                fresh['ActiveState'] == 'inactive' and fresh['MainPID'] == 0 and fresh['ControlPID'] == 0):
            raise ConfigurationError('Server state changed before offline cleanup')
        if os.environ.get('PZ_SOURCE_DIR'):
            check_clean(os.environ['PZ_SOURCE_DIR'],legacy=True)
        if startup:
            validate_native_launcher(args.unit)
        if startup and data is not None:
            # Compare only: a client must never retarget the service environment.
            # This follows authenticated SCM_RIGHTS and the fresh start-pre proof.
            if validate_launch_profile(data.get('launch')) != launch_profile():
                raise ConfigurationError('CLI/service native configuration differs; put shared launch settings in .env')
        if startup and data is not None and data.get('quiet_ready', False):
            invocation = os.environ.get('INVOCATION_ID', '')
            current = subprocess.check_output(['systemctl', '--user', 'show', args.unit,
                '-p', 'InvocationID', '--value'], text=True).strip()
            if not re.fullmatch(r'[0-9a-fA-F]{32}', invocation) or current != invocation:
                raise ConfigurationError('Silent readiness requires the current service invocation')
            # Only authenticated handoff can bind silence to this start. A failed
            # or killed caller cannot silence a later, unrelated invocation.
            atomic_file(directory_fd, 'notify-ready-' + invocation + '.silent', b'', 0o600)
        environment = dict(os.environ, PZ_WORLD_LOCK_FD=str(held_fd), PZ_WORLD_LOCK_DEPTH='1',
            PZ_WORLD_LOCK_FILE=str(path), PZ_SERVICE_NAME=args.unit)
        return subprocess.call(args.command, pass_fds=(held_fd,), env=environment)
    finally:
        if held_fd is not None: os.close(held_fd)
        os.close(directory_fd)


def validate_worker_admission(unit=None):
    """Re-prove stop/start-pre and the actual inherited WORLD FD before mutation."""
    validate_native_identity(os.environ.get('PZ_SOURCE_DIR', ''), os.environ.get('PZ_SERVER_NAME', ''))
    raw_fd = os.environ.get('PZ_WORLD_LOCK_FD', '')
    lock_path = os.environ.get('PZ_WORLD_LOCK_FILE', '')
    unit = unit or os.environ.get('PZ_SERVICE_NAME', '')
    if not raw_fd.isdigit() or not lock_path or not unit or os.environ.get('PZ_WORLD_LOCK_DEPTH') != '1':
        raise ConfigurationError('Offline worker requires startup admission and an inherited WORLD FD')
    path, directory_fd = directory(lock_path)
    try:
        lock_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            info = os.fstat(lock_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
                raise ConfigurationError('Untrusted WORLD lock file')
            locked_fd(os.getpid(), int(raw_fd), (info.st_dev, info.st_ino))
        finally: os.close(lock_fd)
        state = unit_state(unit)
        offline = state['ActiveState'] == 'inactive' and state['MainPID'] == 0 and state['ControlPID'] == 0
        if not offline and not startup_state(state, os.getpid()):
            raise ConfigurationError('Offline worker is not stopped or the authorized start-pre')
        if not offline:
            validate_native_launcher(unit)
        return int(raw_fd)
    finally: os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('path').add_argument('--name',default='world.lock')
    for action in ('prepare', 'broker', 'clear', 'run'):
        p = sub.add_parser(action); p.add_argument('--lock-path', required=True)
        if action in ('prepare', 'broker'):
            p.add_argument('--pid', type=int, required=True); p.add_argument('--fd', type=int, required=True)
            p.add_argument('--quiet-ready', action='store_true')
        if action in ('prepare', 'broker', 'run'): p.add_argument('--unit', required=True)
        if action == 'broker': p.add_argument('--birth', type=int, required=True)
        if action in ('broker', 'clear'): p.add_argument('--token', required=True)
        if action == 'run': p.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.action == 'path': print(runtime_lock_path(args.name)); return 0
        if args.action == 'prepare': print(prepare(args.lock_path, args.pid, args.fd, args.unit, args.quiet_ready)); return 0
        if args.action == 'clear': clear(args.lock_path, args.token); return 0
        if args.action == 'broker': broker(args); return 0
        if args.command and args.command[0] == '--': args.command.pop(0)
        if not args.command: raise ConfigurationError('Missing offline command')
        return run(args)
    except (ConfigurationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('Writing restart cleanup refused: ' + str(error), file=sys.stderr); return 1

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
    from shared_memory_budget import check_process
    check_process()
    sys.exit(main())
