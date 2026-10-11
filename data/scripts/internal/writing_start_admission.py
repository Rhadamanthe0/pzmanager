#!/usr/bin/env python3
"""Keep WORLD exclusion across systemd's ExecStartPre process boundary."""
import argparse
import array
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

from configureWritingTextOnly import ConfigurationError, open_root, atomic_file

MARKER = 'writing-start.json'
SOCKET = 'writing-start.sock'


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


def read_marker(directory_fd):
    fd = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConfigurationError('Untrusted start admission marker')
        data = json.loads(stream.read(4097))
    if not isinstance(data, dict): raise ConfigurationError('Malformed start admission marker')
    required = ('pid', 'birth', 'fd', 'dev', 'ino', 'broker', 'broker_birth')
    if any(type(data.get(key)) is not int or data[key] < 0 for key in required):
        raise ConfigurationError('Malformed start admission marker')
    if not re.fullmatch(r'[0-9a-f]{32}', data.get('token', '')) or not isinstance(data.get('unit'), str):
        raise ConfigurationError('Malformed start admission token/unit')
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


def validate_marker(data, lock_info, unit):
    if data['unit'] != unit or not live(data['pid'], data['birth']):
        raise ConfigurationError('Start admission owner is no longer the prepared start')
    expected = (lock_info.st_dev, lock_info.st_ino)
    if (data['dev'], data['ino']) != expected: raise ConfigurationError('Start admission WORLD inode differs')
    locked_fd(data['pid'], data['fd'], expected)
    if not live(data['broker'], data['broker_birth']): raise ConfigurationError('Start admission broker exited')
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


def prepare(lock_path, pid, fd, unit):
    path, directory_fd = directory(lock_path)
    try:
        lock_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            info = os.fstat(lock_fd)
            if not ancestor(pid, os.getpid()): raise ConfigurationError('Start owner must be an ancestor')
            locked_fd(pid, fd, (info.st_dev, info.st_ino))
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
                '--unit', unit, '--token', token], pass_fds=(fd,),
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
        listener.bind(str(path.parent / SOCKET)); os.chmod(path.parent / SOCKET, 0o600)
        listener.listen(1); listener.settimeout(0.25)
        payload = {'pid': args.pid, 'birth': args.birth, 'fd': args.fd, 'dev': info.st_dev,
            'ino': info.st_ino, 'broker': os.getpid(), 'broker_birth': process_birth(os.getpid()),
            'unit': args.unit, 'token': args.token}
        atomic_file(directory_fd, MARKER, json.dumps(payload).encode(), 0o600)
        while live(args.pid, args.birth):
            try: client, _ = listener.accept()
            except socket.timeout: continue
            with client:
                client.settimeout(2)
                peer = array.array('i'); peer.frombytes(client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if peer[1] != os.getuid(): continue
                request = client.recv(64)
                if request != args.token.encode() or not startup_state(unit_state(args.unit), peer[0]): continue
                rights = array.array('i', [args.fd])
                client.sendmsg([b'WORLD'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)])
                return
    finally:
        listener.close(); os.close(directory_fd)
        # Close the inherited FD; never flock(LOCK_UN), which would unlock pzm.
        os.close(args.fd)


def run(args):
    path, directory_fd = directory(args.lock_path)
    held_fd = None
    try:
        state = unit_state(args.unit)
        startup = startup_state(state, os.getpid())
        offline = state['ActiveState'] == 'inactive' and state['MainPID'] == 0 and state['ControlPID'] == 0
        if not startup and not offline: raise ConfigurationError('Server is not stopped or this unit start-pre')
        held_fd = os.open(path.name, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        info = os.fstat(held_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ConfigurationError('Untrusted WORLD lock file')
        try: fcntl.flock(held_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not startup: raise ConfigurationError('A world operation is already running')
            data = read_marker(directory_fd); validate_marker(data, info, args.unit)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            try:
                socket_info = os.stat(SOCKET, dir_fd=directory_fd, follow_symlinks=False)
                if not stat.S_ISSOCK(socket_info.st_mode) or socket_info.st_uid != os.getuid() or socket_info.st_mode & 0o077:
                    raise ConfigurationError('Untrusted start admission socket')
                client.settimeout(5); client.connect(str(path.parent / SOCKET)); client.sendall(data['token'].encode())
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
        environment = dict(os.environ, PZ_WORLD_LOCK_FD=str(held_fd), PZ_WORLD_LOCK_DEPTH='1',
            PZ_WORLD_LOCK_FILE=str(path), PZ_SERVICE_NAME=args.unit)
        return subprocess.call(args.command, pass_fds=(held_fd,), env=environment)
    finally:
        if held_fd is not None: os.close(held_fd)
        os.close(directory_fd)


def validate_worker_admission(unit=None):
    """Re-prove stop/start-pre and the actual inherited WORLD FD before mutation."""
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
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise ConfigurationError('Untrusted WORLD lock file')
            locked_fd(os.getpid(), int(raw_fd), (info.st_dev, info.st_ino))
        finally: os.close(lock_fd)
        state = unit_state(unit)
        offline = state['ActiveState'] == 'inactive' and state['MainPID'] == 0 and state['ControlPID'] == 0
        if not offline and not startup_state(state, os.getpid()):
            raise ConfigurationError('Offline worker is not stopped or the authorized start-pre')
        return int(raw_fd)
    finally: os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('prepare', 'broker', 'clear', 'run'):
        p = sub.add_parser(action); p.add_argument('--lock-path', required=True)
        if action in ('prepare', 'broker'):
            p.add_argument('--pid', type=int, required=True); p.add_argument('--fd', type=int, required=True)
        if action in ('prepare', 'broker', 'run'): p.add_argument('--unit', required=True)
        if action == 'broker': p.add_argument('--birth', type=int, required=True)
        if action in ('broker', 'clear'): p.add_argument('--token', required=True)
        if action == 'run': p.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.action == 'prepare': print(prepare(args.lock_path, args.pid, args.fd, args.unit)); return 0
        if args.action == 'clear': clear(args.lock_path, args.token); return 0
        if args.action == 'broker': broker(args); return 0
        if args.command and args.command[0] == '--': args.command.pop(0)
        if not args.command: raise ConfigurationError('Missing offline command')
        return run(args)
    except (ConfigurationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('Writing restart cleanup refused: ' + str(error), file=sys.stderr); return 1

if __name__ == '__main__': sys.exit(main())
