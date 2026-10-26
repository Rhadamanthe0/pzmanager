#!/usr/bin/env python3
"""Durable maintenance intent outside the renamed world. No automatic recovery."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import uuid
import re

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'internal'))
from configureWritingTextOnly import open_root, atomic_file, ConfigurationError

TERMINAL = {'complete', 'reverted'}


def validate_record(record):
    if not isinstance(record,dict) or not re.fullmatch('[0-9a-f]{32}',record.get('id','')):
        raise ValueError('Invalid transaction identity')
    if not isinstance(record.get('recovery'),str) or not Path(record['recovery']).is_absolute():
        raise ValueError('Invalid transaction recovery')
    def checksum(value):
        return value is None or isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value)
    if sum(k in record for k in ('files','tree','trees'))!=1:raise ValueError('Invalid transaction plan')
    if 'files' in record:
        if not isinstance(record['files'],list):raise ValueError('Invalid transaction files')
        seen=set()
        for entry in record['files']:
            if not isinstance(entry,dict) or not isinstance(entry.get('path'),str):raise ValueError('Invalid transaction entry')
            p=Path(entry['path'])
            if p.is_absolute() or '..' in p.parts or not p.parts or str(p) in seen:
                raise ValueError('Invalid transaction path')
            seen.add(str(p))
            if not all(k in entry and checksum(entry[k]) for k in ('before','after')):
                raise ValueError('Invalid transaction checksum')
    elif 'trees' in record:
        if not isinstance(record['trees'],dict) or not record['trees']:raise ValueError('Invalid directory transaction')
        for name,images in record['trees'].items():
            if name not in {'Saves','db','Server','Lua'}:raise ValueError('Invalid directory transaction path')
            if not isinstance(images,dict) or not all(k in images and checksum(images[k]) for k in ('before','after')):
                raise ValueError('Invalid directory transaction checksum')
    elif not isinstance(record['tree'],dict) or not all(k in record['tree'] and checksum(record['tree'][k]) for k in ('before','after')):
        raise ValueError('Invalid transaction tree')


def location(world):
    world = Path(os.path.abspath(world))
    if world.is_symlink(): raise ValueError('World root symlink refused')
    return world, world.parent / ('.' + world.name + '.pzm-transactions')


def directory(world, create=False):
    world, root = location(world)
    if not create and not root.parent.exists():
        ancestor=root.parent
        while not ancestor.exists():ancestor=ancestor.parent
        fd,_=open_root(ancestor);os.close(fd)
        return world,None
    parent, _ = open_root(root.parent)
    try:
        if create:
            try: os.mkdir(root.name, 0o700, dir_fd=parent)
            except FileExistsError: pass
        try: fd = os.open(root.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        except FileNotFoundError: return world, None
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            os.close(fd); raise ValueError('Untrusted transaction directory')
        if create: os.fsync(parent)
        return world, fd
    finally: os.close(parent)


def records(fd, world):
    if fd is None: return []
    result=[]
    for name in sorted(os.listdir(fd)):
        if not name.endswith('.json'): continue
        f=os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(f,'rb') as stream:
            info=os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or info.st_mode & 0o077 or info.st_size>4*1024*1024:
                raise ValueError('Untrusted transaction record')
            record=json.load(stream)
        validate_record(record)
        if (record.get('schema')!=1 or record.get('world')!=str(world)
                or name!=record.get('id','')+'.json' or record.get('state') not in TERMINAL | {'prepared'}):
            raise ValueError('Invalid transaction record')
        result.append(record)
    return result


def check_legacy(world):
    roots=[]
    if os.environ.get('PZ_HOME'):roots.append(Path(os.environ['PZ_HOME'])/'OLD')
    if os.environ.get('BACKUP_DIR'):roots.append(Path(os.environ['BACKUP_DIR'])/'projectwriting-cleanups')
    for root in roots:
        if not root.exists():continue
        fd,_=open_root(root);os.close(fd)
        for child in root.iterdir():
            if not child.name.startswith(('zone-rollback-','.zone-rollback-','cleanup-')):continue
            if child.is_symlink():raise ValueError('Legacy recovery symlink')
            path=child/'manifest.json'
            if not path.exists():continue
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            with os.fdopen(fd,'rb') as stream:
                info=os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size>4*1024*1024:raise ValueError('Invalid legacy recovery manifest')
                data=json.load(stream)
            old_world=data.get('world','')
            if Path(old_world).is_absolute() and not Path(old_world).is_relative_to(world):continue
            state=data.get('state',data.get('status'))
            if state not in TERMINAL:raise ValueError('Legacy world recovery unfinished: '+str(path))


def check_clean(world,legacy=False):
    if legacy:check_legacy(Path(os.path.abspath(world)))
    world, fd=directory(world)
    try:
        pending=[r for r in records(fd,world) if r['state'] not in TERMINAL]
        if pending: raise ValueError('World transaction unfinished; explicit recovery required: '+', '.join(r['id'] for r in pending))
    finally:
        if fd is not None: os.close(fd)


def digest(path):
    try: fd=os.open(path,os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError: return None
    with os.fdopen(fd,'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise ValueError('Non-regular transaction image')
        return hashlib.file_digest(stream,'sha256').hexdigest()


def tree_digest(root):
    root=Path(root)
    if root.is_symlink(): raise ValueError('Transaction tree root symlink refused')
    if not root.exists(): return None
    fd,_=open_root(root);os.close(fd)
    entries=[]
    def fail(error): raise error
    for base, dirs, files in os.walk(root,followlinks=False,onerror=fail):
        for name in sorted(dirs+files):
            p=Path(base)/name;info=p.lstat()
            if stat.S_ISLNK(info.st_mode): value=['link',os.readlink(p)]
            elif stat.S_ISDIR(info.st_mode): value=['directory']
            elif stat.S_ISREG(info.st_mode): value=['file',digest(p)]
            else: raise ValueError('Unsupported transaction file')
            entries.append([str(p.relative_to(root)),value])
    return hashlib.sha256(json.dumps(sorted(entries),separators=(',',':')).encode()).hexdigest()


def begin(world,kind,recovery,files=None,after_tree=None,trees=None):
    check_clean(world)
    world,fd=directory(world,True)
    try:
        record=dict(schema=1,id=uuid.uuid4().hex,world=str(world),kind=kind,recovery=str(Path(recovery).absolute()),state='prepared')
        if files is not None:
            for entry in files:
                p=Path(entry['path'])
                if p.is_absolute() or '..' in p.parts or not p.parts: raise ValueError('Invalid transaction path')
            record['files']=files
        elif trees is not None:
            if not trees or len(set(trees))!=len(trees) or any(n not in {'Saves','db','Server','Lua'} for n in trees):
                raise ValueError('Invalid directory selection')
            record['trees']={}
            for name in trees:
                before=world/name;after=Path(after_tree)/name
                if not after.is_dir() or after.is_symlink() or before.is_symlink():raise ValueError('Invalid directory image')
                if before.exists():sync_world(before)
                sync_world(after)
                record['trees'][name]={'before':tree_digest(before),'after':tree_digest(after)}
        else:
            # Persist both trees before publishing the intent and moving live.
            if world.exists():sync_world(world)
            sync_world(after_tree)
            record['tree']={'before':tree_digest(world),'after':tree_digest(after_tree)}
        validate_record(record)
        payload=json.dumps(record,sort_keys=True).encode()
        if len(payload)>4*1024*1024:raise ValueError('Transaction plan exceeds record limit')
        atomic_file(fd,record['id']+'.json',payload,0o600)
        return record['id']
    finally: os.close(fd)


def pending_for(world,recovery):
    world,fd=directory(world)
    try:
        found=[r for r in records(fd,world) if r['state']=='prepared']
        if not found:return None
        if len(found)!=1 or found[0]['recovery']!=str(Path(recovery).absolute()):
            raise ValueError('Another world transaction requires explicit recovery')
        return found[0]['id']
    finally:
        if fd is not None:os.close(fd)


def sync_world(world,entries=None):
    directories={Path(world).parent}
    if Path(world).exists():directories.add(Path(world))
    paths=(Path(world)/entry['path'] for entry in entries) if entries is not None else Path(world).rglob('*')
    for p in paths:
        if p.is_symlink():continue
        if p.is_file():
            fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
            try:os.fsync(fd)
            finally:os.close(fd)
        parent=p if p.is_dir() else p.parent
        while not parent.exists():
            if parent.is_symlink(): raise ValueError('Transaction parent symlink')
            parent=parent.parent
        while parent.is_relative_to(world):
            directories.add(parent)
            if parent==Path(world):break
            parent=parent.parent
    for p in sorted(directories,key=lambda p:len(p.parts),reverse=True):
        fd=os.open(p,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(fd)
        finally:os.close(fd)


def finish(world,token,state):
    if state not in TERMINAL:raise ValueError('Invalid terminal transaction state')
    world,fd=directory(world)
    try:
        selected=[r for r in records(fd,world) if r['id']==token]
        if len(selected)!=1:raise ValueError('Unknown world transaction')
        record=selected[0];side='after' if state=='complete' else 'before'
        if 'trees' in record:
            for name,images in record['trees'].items():
                if tree_digest(world/name)!=images[side]:raise ValueError('Directory does not match transaction '+side)
                sync_world(world/name)
        elif 'tree' in record:
            if tree_digest(world)!=record['tree'][side]:raise ValueError('World tree does not match transaction '+side)
        else:
            for entry in record['files']:
                p=world/entry['path'];ancestor=p.parent
                while not ancestor.exists():
                    if ancestor.is_symlink():raise ValueError('Transaction parent symlink')
                    ancestor=ancestor.parent
                parent,_=open_root(ancestor);os.close(parent)
                if digest(p)!=entry[side]:raise ValueError('World bytes do not match transaction '+side)
        if 'trees' not in record:sync_world(world,record.get('files'))
        record['state']=state
        atomic_file(fd,token+'.json',json.dumps(record,sort_keys=True).encode(),0o600)
    finally:
        if fd is not None:os.close(fd)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['init','check','begin','finish','sync'])
    p.add_argument('--world',required=True);p.add_argument('--kind');p.add_argument('--recovery');p.add_argument('--after-tree')
    p.add_argument('--directory',action='append');p.add_argument('--directory-only',action='store_true')
    p.add_argument('--file',action='append');p.add_argument('--delete-file',action='append')
    p.add_argument('--token');p.add_argument('--state',choices=sorted(TERMINAL));a=p.parse_args()
    try:
        if a.action=='init':
            _,fd=directory(a.world,True);os.close(fd)
        elif a.action=='check':check_clean(a.world,legacy=True)
        elif a.action=='sync':
            # Internal backup boundary: recursive contents before publication,
            # directory entries only after rename, without rescanning old backups.
            root=Path(os.path.abspath(a.world));fd,_=open_root(root);os.close(fd)
            entries=None
            if a.file:
                if a.directory_only:raise ValueError('Conflicting sync selection')
                entries=[]
                for name in a.file:
                    path=Path(name)
                    if path.is_absolute() or '..' in path.parts or not path.parts:raise ValueError('Invalid sync file')
                    parent,_=open_root((root/path).parent);os.close(parent)
                    if not (root/path).is_file() or (root/path).is_symlink():raise ValueError('Invalid sync file')
                    entries.append({'path':str(path)})
            sync_world(root,[] if a.directory_only else entries)
        elif a.action=='begin':
            if not all((a.kind,a.recovery)) or bool(a.after_tree)==bool(a.delete_file):raise ValueError('Missing or conflicting transaction plan')
            files=None
            if a.delete_file:
                if a.directory:raise ValueError('Conflicting transaction selection')
                root=Path(os.path.abspath(a.world));files=[]
                for name in a.delete_file:
                    path=Path(name)
                    if path.is_absolute() or '..' in path.parts or not path.parts:raise ValueError('Invalid transaction path')
                    parent,_=open_root((root/path).parent);os.close(parent)
                    before=digest(root/path)
                    if before is None:raise ValueError('Transaction deletion target missing')
                    files.append(dict(path=str(path),before=before,after=None))
            print(begin(a.world,a.kind,a.recovery,files=files,after_tree=a.after_tree,trees=a.directory))
        else:finish(a.world,a.token,a.state)
        return 0
    except (OSError,ValueError,TypeError,KeyError,ConfigurationError) as e:
        print('World transaction refused: '+str(e),file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
