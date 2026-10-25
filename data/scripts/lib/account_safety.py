#!/usr/bin/env python3
"""Typed account mutations and recovery points for admitted offline workers."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'internal'))
from writing_start_admission import validate_worker_admission
from world_transaction import check_clean
from configureWritingTextOnly import ConfigurationError, open_root, trusted_owner


def validate_database(path,missing_ok=False):
    """Validate physical SQLite files, including journals, before SQLite opens them.

    Safe ancestors prevent replacement by another UID; WORLD serializes our
    writers. SQLite canonicalizes filenames, so a /proc/fd URI is not a pin.
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


def ledger_rows(db_path,now):
    """Read typed SQLite fields before emitting rows for the historical CSV."""
    validate_database(db_path)
    with closing(sqlite3.connect(Path(db_path).absolute().as_uri()+'?mode=ro',uri=True,timeout=0)) as db:
        rows=db.execute("SELECT username, COALESCE(steamid,''), COALESCE(lastConnection,'') FROM whitelist").fetchall()
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
        print(username+';'+sid+';'+(lastconn or now))


def select_players(world,server):
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
            if validate_database(candidate,missing_ok=True):candidates.append(candidate)
    finally:os.close(parent)
    matching=[path for path in candidates if path.parent.name==server]
    if matching:return matching[0]
    if len(candidates)>1:
        raise ValueError('Multiple character databases without a match for configured server '+server)
    return candidates[0] if candidates else None


def verify_worker():
    validate_worker_admission()
    check_clean(os.environ['PZ_SOURCE_DIR'],legacy=True)
    if os.environ.get('PZ_DB_PATH'):validate_database(os.environ['PZ_DB_PATH'],missing_ok=True)


def valid_id(value):
    if type(value) is not int or value < 0:
        raise ValueError('Invalid account identifier; operation refused before mutation')
    return value


def remove(db_path,targets,dry_run=False):
    with closing(connect(db_path)) as db:
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
        print('=== remove-account : plan ===')
        for identity,(username,sid) in accounts.items():
            print('  - compte '+json.dumps(username,ensure_ascii=False)+' (id '+str(identity)+') -> serait supprimé')
            if sid:sids.add(sid)
        for sid in sorted(sids):print('  - SteamID '+json.dumps(sid)+' : retrait seulement si orphelin')
        if dry_run:
            print("[dry-run] Rien n'a été modifié.");return
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
    p=sub.add_parser('validate-db');p.add_argument('--db',required=True);p.add_argument('--missing-ok',action='store_true')
    p=sub.add_parser('select-players');p.add_argument('--world',required=True);p.add_argument('--server',required=True)
    p=sub.add_parser('ledger-rows');p.add_argument('--db',required=True);p.add_argument('--now',required=True)
    p=sub.add_parser('backup');p.add_argument('--db',required=True)
    p=sub.add_parser('remove');p.add_argument('--db',required=True);p.add_argument('--dry-run',action='store_true');p.add_argument('targets',nargs='+')
    p=sub.add_parser('rename');p.add_argument('--db',required=True);p.add_argument('--players');p.add_argument('old');p.add_argument('new')
    a=parser.parse_args()
    try:
        if a.action=='select-players':
            selected=select_players(a.world,a.server)
            if selected is not None:print(selected)
        elif a.action=='verify-worker':verify_worker()
        elif a.action=='validate-db':validate_database(a.db,a.missing_ok)
        elif a.action=='ledger-rows':ledger_rows(a.db,a.now)
        elif a.action=='backup':backup(a.db)
        elif a.action=='remove':remove(a.db,a.targets,a.dry_run)
        elif a.action=='rename':rename(a.db,a.players,a.old,a.new)
        return 0
    except (OSError,ValueError,sqlite3.Error,ConfigurationError) as error:
        print('Account operation refused: '+str(error),file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
