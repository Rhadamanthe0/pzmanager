#!/usr/bin/env python3
"""Close the native INI through a pinned directory, never through a link."""
import os
from pathlib import Path
import stat
import subprocess
import sys

from configureWritingTextOnly import ConfigurationError, atomic_file, open_root, trusted_owner, validate_directory

# java.lang.String.trim(), used by the native INI key parser.
TRIM = bytes(range(33))


def closed_content(data):
    result=[];found=False
    for line in data.splitlines(keepends=True):
        body=line.rstrip(b'\r\n');ending=line[len(body):]
        key,separator,_=body.partition(b'=')
        if separator and key.strip(TRIM)==b'Open':
            result.append(b'Open=false'+ending);found=True
        else:result.append(line)
    if not found:
        newline=b'\r\n' if b'\r\n' in data else b'\r' if b'\r' in data and b'\n' not in data else b'\n'
        if data and not data.endswith((b'\r',b'\n')):result.append(newline)
        result.append(b'Open=false'+newline)
    return b''.join(result)


def ini_parent(path):
    missing=[];parent=path.parent
    while True:
        try:
            fd,private=open_root(parent);break
        except FileNotFoundError:
            missing.append(parent.name);parent=parent.parent
    try:
        for name in reversed(missing):
            try:os.mkdir(name,0o700,dir_fd=fd)
            except FileExistsError:pass
            child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=child
            validate_directory(fd,name,private)
            info=os.fstat(fd)
            private=private or info.st_uid==os.getuid() and not info.st_mode & 0o077
        return fd,private
    except Exception:
        os.close(fd);raise


def identity(info):
    return info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_nlink


def close_ini(path):
    path=Path(os.path.abspath(path))
    parent,private=ini_parent(path)
    try:
        try:fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        except FileNotFoundError:before=None;data=b'';mode=0o600
        else:
            with os.fdopen(fd,'rb') as stream:
                before=os.fstat(stream.fileno())
                # Refuse hardlinks before reading: even replacing a leaf would
                # change the external inode's link count and ctime.
                if (not stat.S_ISREG(before.st_mode) or before.st_nlink!=1
                        or not trusted_owner(before.st_uid) or before.st_mode & 0o002
                        or before.st_mode & 0o020 and not private):
                    raise ConfigurationError('INI must be a trusted regular file with one link')
                data=stream.read();mode=stat.S_IMODE(before.st_mode)
                if identity(before)!=identity(os.fstat(stream.fileno())):
                    raise ConfigurationError('INI changed while reading')
        closed=closed_content(data)
        try:current=os.stat(path.name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError:current=None
        if ((before is None)!=(current is None)
                or before is not None and identity(before)!=identity(current)):
            raise ConfigurationError('INI changed before publication')
        if before is not None and closed==data:return False
        atomic_file(parent,path.name,closed,mode)
        return True
    finally:os.close(parent)


def main():
    try:
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
        from account_safety import verify_worker
        verify_worker()
        if close_ini(os.environ['PZ_INI_PATH']):print('Open=false publié ('+os.environ['PZ_INI_PATH']+').')
        return 0
    except (OSError,ValueError,subprocess.SubprocessError) as error:
        print('Open=false refusé : '+str(error)+' ; serveur non démarré.',file=sys.stderr)
        return 1


if __name__=='__main__':sys.exit(main())
