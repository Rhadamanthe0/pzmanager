#!/usr/bin/env python3
"""Typed account mutations and recovery points for admitted offline workers."""
import argparse
from contextlib import closing, contextmanager, ExitStack
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'internal'))
from writing_start_admission import validate_worker_admission
from world_transaction import check_clean
from configureWritingTextOnly import ConfigurationError, open_root, trusted_owner


def validate_database(path,missing_ok=False,normalize=False):
    """Validate physical SQLite files, including journals, before SQLite opens them.

    Safe ancestors prevent replacement by another UID; WORLD serializes our
    writers. SQLite canonicalizes filenames, so a /proc/fd URI is not a pin.
    Callers pass normalize=True only while they hold WORLD with the server
    proven stopped (admitted restart worker, offline account/restore commands):
    Project Zomboid rewrites its own SQLite files as 0777 on every JVM start
    (incident 2026-10-27), so those paths would otherwise refuse the world the
    game just created.
    """
    path=Path(os.path.abspath(path))
    if not path.name:raise ConfigurationError('SQLite path must name a regular file')
    try:parent,private=open_root(path.parent)
    except FileNotFoundError:
        if not missing_ok:raise
        ancestor=path.parent
        while True:
            try:parent,_=open_root(ancestor);break
            except FileNotFoundError:ancestor=ancestor.parent
        os.close(parent)
        return False
    try:
        present=False
        for suffix in ('','-journal','-wal','-shm'):
            try:fd=os.open(path.name+suffix,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
            except FileNotFoundError:
                if not suffix and not missing_ok:raise
                continue
            try:
                info=os.fstat(fd)
                if (normalize and stat.S_ISREG(info.st_mode) and info.st_nlink==1
                        and trusted_owner(info.st_uid) and info.st_mode & 0o022):
                    # 27/10/2026 : the game rewrites its SQLite files as 0777 on
                    # every JVM start. Tighten the pinned descriptor only, never
                    # the path; links and foreign owners never reach this point.
                    # Split multi-UID is refused, so group write is not needed.
                    os.fchmod(fd,stat.S_IMODE(info.st_mode) & ~0o022)
                    info=os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink!=1
                        or not trusted_owner(info.st_uid) or info.st_mode & 0o002
                        or info.st_mode & 0o020 and not private):
                    raise ConfigurationError('SQLite files must be trusted regular files with one link: '+str(path)+suffix)
                if not suffix:present=True
            finally:os.close(fd)
        return present
    finally:os.close(parent)


def connect(path):
    validate_database(path)
    return sqlite3.connect(Path(path).absolute().as_uri()+'?mode=rw',uri=True,timeout=0)


def _file_identity(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_uid,info.st_gid,
            info.st_nlink,info.st_size,info.st_mtime_ns,info.st_ctime_ns)


def _ancestor_identity(path):
    result=[]
    for parent in reversed((path.parent,*path.parent.parents)):
        info=parent.lstat()
        if not stat.S_ISDIR(info.st_mode):raise ConfigurationError('Linked SQLite ancestor refused')
        result.append((info.st_dev,info.st_ino,info.st_mode,info.st_uid,info.st_gid))
    return result


def _check_preview_sources(sources):
    for path,parent,files,before,ancestors in sources:
        checked,_=open_root(path.parent)
        try:
            if _ancestor_identity(path)!=ancestors or _file_identity(os.fstat(checked))[:5]!=_file_identity(os.fstat(parent))[:5]:
                raise ValueError('SQLite ancestor changed during preview')
        finally:os.close(checked)
        for suffix in ('','-journal','-wal','-shm'):
            try:current=_file_identity(os.stat(path.name+suffix,dir_fd=parent,follow_symlinks=False))
            except FileNotFoundError:current=None
            if current!=before[suffix] or suffix in files and _file_identity(os.fstat(files[suffix]))!=before[suffix]:
                raise ValueError('SQLite source changed during preview: '+str(path)+suffix)


@contextmanager
def preview_databases(paths):
    """Read private DB+WAL copies while retaining Linux SQLite byte locks."""
    sources=[];identities=set()
    with ExitStack() as cleanup:
        # Finish ALL opening validations before taking ANY POSIX lock. Closing
        # another FD of a source inode would release this process's byte locks.
        for argument in paths:
            path=Path(os.path.abspath(argument))
            parent,private=open_root(path.parent);cleanup.callback(os.close,parent)
            files={};before={}
            for suffix in ('','-journal','-wal','-shm'):
                try:fd=os.open(path.name+suffix,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
                except FileNotFoundError:
                    if not suffix:raise
                    before[suffix]=None;continue
                cleanup.callback(os.close,fd);files[suffix]=fd;info=os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink!=1
                        or not trusted_owner(info.st_uid) or info.st_mode & 0o002
                        or info.st_mode & 0o020 and not private):
                    raise ConfigurationError('SQLite files must be trusted regular files with one link: '+str(path)+suffix)
                identity=(info.st_dev,info.st_ino)
                if identity in identities:raise ValueError('Aliased SQLite preview sources refused')
                identities.add(identity);before[suffix]=_file_identity(info)
            sources.append((path,parent,files,before,_ancestor_identity(path)))
        for path,parent,files,before,ancestors in sources:
            for suffix in ('','-shm'):
                if suffix in files:
                    try:fcntl.lockf(files[suffix],fcntl.LOCK_SH|fcntl.LOCK_NB,0,0,os.SEEK_SET)
                    except BlockingIOError as error:raise sqlite3.OperationalError('database is locked: '+str(path)) from error
            if '-journal' in files:
                header=os.pread(files['-journal'],8,0)
                if any(header):raise ValueError('SQLite recovery required before preview: '+str(path))
        _check_preview_sources(sources)
        # Ignore TMPDIR: an operator may have pointed it inside the world.
        # Choose a physical system temporary directory outside every source.
        world=Path(os.environ.get('PZ_SOURCE_DIR',str(Path(paths[0]).absolute().parent))).resolve()
        temporary_parent=next((candidate for candidate in (Path('/tmp'),Path('/var/tmp'))
            if not candidate.resolve().is_relative_to(world)
            and not any(candidate.resolve().is_relative_to(path.parent.resolve()) for path in map(Path,paths))),None)
        if temporary_parent is None:raise ValueError('No temporary directory outside SQLite source world')
        temporary=Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix='pzm-account-preview-',dir=temporary_parent)))
        if temporary.resolve().is_relative_to(world):raise ValueError('Preview temporary directory is inside world')
        databases=[]
        for index,(path,parent,files,before,ancestors) in enumerate(sources):
            copy=temporary/(str(index)+'.db')
            for suffix in ('','-wal'):
                if suffix not in files:continue
                fd=os.open(str(copy)+suffix,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
                try:
                    offset=0
                    while True:
                        data=os.pread(files[suffix],65536,offset)
                        if not data:break
                        offset+=len(data);view=memoryview(data)
                        while view:
                            written=os.write(fd,view)
                            if written<=0:raise OSError('Incomplete SQLite preview copy')
                            view=view[written:]
                finally:os.close(fd)
            _check_preview_sources(sources)
            db=cleanup.enter_context(closing(sqlite3.connect(copy,timeout=0)))
            if db.execute('PRAGMA quick_check').fetchall()!=[('ok',)]:raise ValueError('SQLite preview integrity failed')
            databases.append(db)
        try:yield databases
        finally:_check_preview_sources(sources)


def rename_plan(db_path,players,old,new):
    if old=='admin':raise ValueError('The admin account is protected')
    with preview_databases([db_path]+([players] if players else [])) as databases:
        db=databases[0]
        exists=db.execute('SELECT COUNT(*) FROM whitelist WHERE username=?',(old,)).fetchone()[0]
        if not exists:raise ValueError('Source account missing')
        if db.execute('SELECT 1 FROM whitelist WHERE username=?',(new,)).fetchone():raise ValueError('Account collision')
        characters=0
        if players:
            characters=databases[1].execute('SELECT COUNT(*) FROM networkPlayers WHERE username=?',(old,)).fetchone()[0]
            if databases[1].execute('SELECT 1 FROM networkPlayers WHERE username=?',(new,)).fetchone():raise ValueError('Character collision')
    print(str(exists)+' '+str(characters))


def read_sql(db_path,sql,options):
    """Keep sqlite3 CLI formatting, publishing only a revalidated private read."""
    result=None
    try:
        with preview_databases([db_path]) as databases:
            private=databases[0].execute('PRAGMA database_list').fetchone()[2]
            result=subprocess.run(['sqlite3',*options,private,sql],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    finally:
        # Keep the native diagnostic even when final source validation fails.
        if result is not None:sys.stderr.buffer.write(result.stderr)
    sys.stdout.buffer.write(result.stdout)
    return result.returncode if result.returncode>=0 else 128-result.returncode


def ledger_rows(db_path,now):
    """Read typed SQLite fields before emitting rows for the historical CSV."""
    with preview_databases([db_path]) as databases:
        rows=databases[0].execute("SELECT username, COALESCE(steamid,''), COALESCE(lastConnection,'') FROM whitelist").fetchall()
    records=[]
    for username,sid,lastconn in rows:
        if not all(isinstance(value,str) for value in (username,sid,lastconn)):
            raise ValueError('Invalid account text fields for ledger')
        if not username:continue
        # No quoting exists in this CSV. NUL would also be lost in Bash;
        # a leading # would turn the username into a comment on the next read.
        if username.startswith('#') or any(char in value for value in (username,sid,lastconn) for char in ';\r\n\0'):
            print('AVERTISSEMENT: compte non représentable ignoré au registre: '+json.dumps(username,ensure_ascii=False),file=sys.stderr)
            continue
        # An unknown age uses the current time, conservatively delaying purge.
        records.append(username+';'+sid+';'+(lastconn or now))
    for record in records:print(record)


def select_players(world,server,normalize=False):
    saves=Path(world)/'Saves/Multiplayer'
    try:parent,_=open_root(saves)
    except FileNotFoundError:return None
    try:
        candidates=[]
        for name in os.listdir(parent):
            entry=saves/name
            info=os.stat(name,dir_fd=parent,follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):raise ConfigurationError('Linked character directory refused: '+str(entry))
            if not stat.S_ISDIR(info.st_mode):continue
            candidate=entry/'players.db'
            if validate_database(candidate,missing_ok=True,normalize=normalize):candidates.append(candidate)
    finally:os.close(parent)
    matching=[path for path in candidates if path.parent.name==server]
    if matching:return matching[0]
    if len(candidates)>1:
        raise ValueError('Multiple character databases without a match for configured server '+server)
    return candidates[0] if candidates else None


def verify_worker():
    validate_worker_admission()
    check_clean(os.environ['PZ_SOURCE_DIR'],legacy=True)
    if os.environ.get('PZ_DB_PATH'):validate_database(os.environ['PZ_DB_PATH'],missing_ok=True,normalize=True)


def valid_id(value):
    if type(value) is not int or value < 0:
        raise ValueError('Invalid account identifier; operation refused before mutation')
    return value


def _remove_plan(db,targets):
    accounts={};sids=set()
    # All reads and typed validation finish before displaying a plan or SQL.
    for target in targets:
        steamid=len(target)==17 and target.startswith('7656119') and target.isascii() and target.isdigit()
        field='steamid' if steamid else 'username'
        rows=db.execute('SELECT id,username,steamid FROM whitelist WHERE '+field+'=?',(target,)).fetchall()
        for identity,username,sid in rows:
            valid_id(identity)
            if not isinstance(username,str) or sid is not None and not isinstance(sid,str):
                raise ValueError('Invalid account text fields')
            if username!='admin':accounts[identity]=(username,sid)
        if steamid and not rows and db.execute('SELECT 1 FROM allowedsteamid WHERE steamid=?',(target,)).fetchone():sids.add(target)
    return accounts,sids


def _print_remove_plan(accounts,sids):
    print('=== remove-account : plan ===')
    for identity,(username,sid) in accounts.items():
        print('  - compte '+json.dumps(username,ensure_ascii=False)+' (id '+str(identity)+') -> serait supprimé')
        if sid:sids.add(sid)
    for sid in sorted(sids):print('  - SteamID '+json.dumps(sid)+' : retrait seulement si orphelin')


def remove(db_path,targets,dry_run=False):
    if dry_run:
        with preview_databases([db_path]) as databases:
            accounts,sids=_remove_plan(databases[0],targets)
        _print_remove_plan(accounts,sids)
        print("[dry-run] Rien n'a été modifié.");return
    with closing(connect(db_path)) as db:
        accounts,sids=_remove_plan(db,targets)
        _print_remove_plan(accounts,sids)
        db.execute('BEGIN IMMEDIATE')
        # Recheck every selected identity under the write lock; admin can never
        # be removed even if a writer changed a row after the read-only plan.
        for identity,(username,sid) in accounts.items():
            current=db.execute('SELECT username,steamid FROM whitelist WHERE id=?',(identity,)).fetchall()
            if current!=[(username,sid)]:raise ValueError('Account changed since plan; mutation refused')
        for identity in accounts:db.execute("DELETE FROM whitelist WHERE id=? AND username<>'admin'",(identity,))
        for sid in sids:
            db.execute('DELETE FROM allowedsteamid WHERE steamid=? AND NOT EXISTS (SELECT 1 FROM whitelist WHERE whitelist.steamid=allowedsteamid.steamid)',(sid,))
        db.commit()
        print('✓ Suppression effectuée. Personnages (networkPlayers) conservés.')


def rename(db_path,players,old,new):
    if old=='admin':raise ValueError('The admin account is protected')
    if players:validate_database(players)
    with closing(connect(db_path)) as db:
        schemas=['main']
        if players:
            # URI rw prevents accidentally creating a missing character DB.
            db.execute('ATTACH DATABASE ? AS players',(Path(players).absolute().as_uri()+'?mode=rw',))
            schemas.append('players')
        # Cross-file crash atomicity requires rollback journals and durable
        # synchronization on BOTH files. Do not convert a game's journal mode.
        for schema in schemas:
            mode=db.execute('PRAGMA '+schema+'.journal_mode').fetchone()[0].lower()
            sync=db.execute('PRAGMA '+schema+'.synchronous').fetchone()[0]
            if mode not in {'delete','truncate','persist'} or sync<2:
                raise ValueError('Atomic rename requires durable rollback journals: '+schema+' '+mode)
        db.execute('BEGIN IMMEDIATE')
        if not db.execute('SELECT 1 FROM whitelist WHERE username=?',(old,)).fetchone():raise ValueError('Source account missing')
        if db.execute('SELECT 1 FROM whitelist WHERE username=?',(new,)).fetchone():raise ValueError('Account collision')
        if players and db.execute('SELECT 1 FROM players.networkPlayers WHERE username=?',(new,)).fetchone():raise ValueError('Character collision')
        db.execute('UPDATE main.whitelist SET username=? WHERE username=?',(new,old))
        if players:db.execute('UPDATE players.networkPlayers SET username=? WHERE username=?',(new,old))
        db.commit()


def backup(db_path):
    verify_worker()
    validate_database(db_path)
    path=Path(db_path).absolute();parent,_=open_root(path.parent)
    temporary=path.name+'.pre-purge-'+str(time.time_ns())+'-'+uuid.uuid4().hex+'.tmp'
    final=temporary[:-4]
    try:
        fd=os.open(temporary,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=parent);os.close(fd)
        with closing(connect(path)) as source,closing(sqlite3.connect(path.parent/temporary)) as destination:
            source.backup(destination)
            if destination.execute('PRAGMA integrity_check').fetchall()!=[('ok',)]:raise ValueError('Pre-purge backup integrity failed')
        fd=os.open(temporary,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent)
        try:os.fsync(fd)
        finally:os.close(fd)
        os.rename(temporary,final,src_dir_fd=parent,dst_dir_fd=parent);os.fsync(parent)
        print(path.parent/final)
    finally:
        try:os.unlink(temporary,dir_fd=parent)
        except FileNotFoundError:pass
        os.close(parent)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    sub.add_parser('verify-worker')
    p=sub.add_parser('validate-db');p.add_argument('--db',required=True);p.add_argument('--missing-ok',action='store_true');p.add_argument('--normalize',action='store_true')
    p=sub.add_parser('select-players');p.add_argument('--world',required=True);p.add_argument('--server',required=True);p.add_argument('--normalize',action='store_true')
    p=sub.add_parser('read-sql');p.add_argument('--db',required=True);p.add_argument('--sql',required=True);p.add_argument('options',nargs=argparse.REMAINDER)
    p=sub.add_parser('ledger-rows');p.add_argument('--db',required=True);p.add_argument('--now',required=True)
    p=sub.add_parser('backup');p.add_argument('--db',required=True)
    p=sub.add_parser('remove');p.add_argument('--db',required=True);p.add_argument('--dry-run',action='store_true');p.add_argument('targets',nargs='+')
    p=sub.add_parser('rename-plan');p.add_argument('--db',required=True);p.add_argument('--players');p.add_argument('old');p.add_argument('new')
    p=sub.add_parser('rename');p.add_argument('--db',required=True);p.add_argument('--players');p.add_argument('old');p.add_argument('new')
    a=parser.parse_args()
    try:
        if a.action=='select-players':
            selected=select_players(a.world,a.server,a.normalize)
            if selected is not None:print(selected)
        elif a.action=='verify-worker':verify_worker()
        elif a.action=='validate-db':validate_database(a.db,a.missing_ok,a.normalize)
        elif a.action=='read-sql':return read_sql(a.db,a.sql,a.options[1:] if a.options[:1]==['--'] else a.options)
        elif a.action=='ledger-rows':ledger_rows(a.db,a.now)
        elif a.action=='backup':backup(a.db)
        elif a.action=='remove':remove(a.db,a.targets,a.dry_run)
        elif a.action=='rename-plan':rename_plan(a.db,a.players,a.old,a.new)
        elif a.action=='rename':rename(a.db,a.players,a.old,a.new)
        return 0
    except (OSError,ValueError,sqlite3.Error,ConfigurationError) as error:
        print('Account operation refused: '+str(error),file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
