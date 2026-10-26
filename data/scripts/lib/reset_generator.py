#!/usr/bin/env python3
"""Keep a stable session leader until the complete reset generator group stops."""
import argparse
import errno
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time


def process(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return {
        'state': fields[0],
        'pgid': int(fields[2]),
        'sid': int(fields[3]),
        'birth': int(fields[19]),
    }


def members(identity):
    result = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            info = process(int(path.name))
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ESRCH):
                continue
            raise
        if info['sid'] == identity['sid'] and info['state'] not in {'Z', 'X'}:
            if info['pgid'] != identity['pgid']:
                raise ValueError('Generator descendant escaped the dedicated process group')
            result.append(int(path.name))
    return result


def identity(args):
    fd = os.open(args.metadata, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 4096):
            raise ValueError('Untrusted generator identity file')
        data = json.load(stream)
    if not isinstance(data, dict):
        raise ValueError('Malformed generator identity')
    expected = {
        'pid': args.pid,
        'pgid': args.pid,
        'sid': args.pid,
        'birth': data.get('birth'),
        'cachedir': args.cachedir,
    }
    if data != expected or type(data.get('birth')) is not int:
        raise ValueError('Generator session identity differs')
    current = process(args.pid)
    if current['state'] in {'Z', 'X'} or any(
            current[key] != data[key] for key in ('pgid', 'sid', 'birth')):
        raise ValueError('Generator leader identity cannot be proven')
    argv = Path(f'/proc/{args.pid}/cmdline').read_bytes().split(b'\0')
    if os.fsencode('-cachedir=' + args.cachedir) not in argv or os.getsid(0) == data['sid']:
        raise ValueError('Generator cachedir/session identity cannot be proven')
    return data


def launch(args):
    # Bash disables monitor mode before spawning this process: no implicit fork
    # or setsid(1) PID ambiguity. This exact $! becomes the stable group leader.
    os.setsid()
    pid = os.getpid()
    info = process(pid)
    if info['pgid'] != pid or info['sid'] != pid:
        raise ValueError('Dedicated generator session unavailable')
    # Keep the anchor alive after TERM or after the vendor wrapper exits. Its
    # live birth identity prevents accidentally signalling a recycled group.
    signal.signal(signal.SIGTERM, lambda *_: None)
    data = dict(pid=pid, pgid=pid, sid=pid, birth=info['birth'], cachedir=args.cachedir)
    fd = os.open(args.metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        # Preserve the WORLD/SERVERCTL descriptors inherited from Bash.
        child = subprocess.Popen(args.command, close_fds=False)
        child.wait()
    except OSError:
        pass
    while True:
        time.sleep(1)


def stop(args):
    data = identity(args)
    # Signal the group, not just the wrapper PID. The anchor intentionally
    # survives TERM until stubborn descendants have received KILL as well.
    os.killpg(data['pgid'], signal.SIGTERM)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if members(data) == [data['pid']]:
            break
        time.sleep(.02)
    identity(args)
    os.killpg(data['pgid'], signal.SIGKILL)
    # This observer stays outside the session it kills. Zombies cannot write;
    # the caller reaps its own leader with wait after this check succeeds.
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not members(data):
            return 0
        time.sleep(.02)
    raise ValueError('Generator writers have not stopped; staging must be preserved')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['launch', 'ready', 'running', 'stop'])
    parser.add_argument('--metadata', required=True)
    parser.add_argument('-cachedir', dest='cachedir', required=True)
    parser.add_argument('--pid', type=int)
    argv = sys.argv[1:]
    command = []
    if '--' in argv:
        boundary = argv.index('--')
        argv, command = argv[:boundary], argv[boundary + 1:]
    args = parser.parse_args(argv)
    args.command = command
    try:
        if args.action == 'launch':
            if not args.command:
                raise ValueError('Missing generator command')
            return launch(args)
        if not args.pid:
            raise ValueError('Generator leader PID required')
        if args.action == 'ready':
            identity(args)
            return 0
        if args.action == 'running':
            return 0 if len(members(identity(args))) > 1 else 1
        return stop(args)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print('Reset generator refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
