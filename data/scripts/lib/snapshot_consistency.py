#!/usr/bin/env python3
"""Distinguish completed copies from an offline, checked recovery point."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

NAME='.pzm-snapshot.json'


def probe(unit):
    try:
        p=subprocess.run(['systemctl','--user','show',unit,'-p','LoadState,ActiveState,SubState,MainPID,ControlPID,InvocationID'],capture_output=True,text=True,timeout=10)
    except (OSError,subprocess.SubprocessError):
        # Unknown state cannot certify an offline point. A normal hourly copy
        # remains useful as best-effort and keeps its existing save behavior.
        return dict(unit=unit,observed_ns=time.time_ns(),ok=False)
    data=dict(line.split('=',1) for line in p.stdout.splitlines() if '=' in line)
    return dict(unit=unit,observed_ns=time.time_ns(),ok=p.returncode==0,
                **{k:data.get(k,'') for k in ('LoadState','ActiveState','SubState','MainPID','ControlPID','InvocationID')})


def stopped(data):
    return (data.get('ok') is True and data.get('LoadState')=='loaded' and data.get('ActiveState')=='inactive'
            and data.get('MainPID')=='0' and data.get('ControlPID')=='0')


def sqlite_check(root):
    for p in Path(root).rglob('*'):
        if p.is_symlink(): raise ValueError('Linked snapshot data cannot be certified')
        if p.name.endswith(('-wal','-journal')) and p.is_file() and p.stat().st_size:
            raise ValueError('SQLite journal present in snapshot')
        if p.suffix=='.db' and p.is_file():
            db=sqlite3.connect(p.resolve().as_uri()+'?mode=ro&immutable=1',uri=True)
            try:
                if db.execute('PRAGMA quick_check').fetchall()!=[('ok',)]:raise ValueError('SQLite snapshot integrity failed')
            finally:db.close()


def write(root,before,after,required=False):
    coherent=(stopped(before) and stopped(after) and before['unit']==after['unit']
              and before.get('InvocationID')==after.get('InvocationID'))
    if coherent:
        try:sqlite_check(root)
        except (OSError,ValueError,sqlite3.Error):coherent=False
    if required and not coherent:raise ValueError('Stopped, consistent snapshot not proven; nothing published')
    data=dict(schema=1,consistency='stopped' if coherent else 'best-effort',before=before,after=after)
    p=Path(root)/NAME
    fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as stream:json.dump(data,stream,sort_keys=True);stream.flush();os.fsync(stream.fileno())
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
    return data['consistency']


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['probe','write']);p.add_argument('--unit');p.add_argument('--root');p.add_argument('--before');p.add_argument('--required',action='store_true');a=p.parse_args()
    try:
        if a.action=='probe':print(json.dumps(probe(a.unit)))
        else:
            before=json.loads(a.before)
            print(write(a.root,before,probe(a.unit),a.required))
        return 0
    except (OSError,ValueError,sqlite3.Error,subprocess.SubprocessError) as e:
        print('Snapshot refused: '+str(e),file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
