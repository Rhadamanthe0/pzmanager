#!/usr/bin/env python3
"""Opt-in: prove opaque SQL restoration accepted a truncated real player, then
prove native admission refuses it before DELETE and accepts the complete blob.
Run only with private copies and mount/network isolation; no live service calls.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import json


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('world','install','ini','java','javac','before-script','results'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--player-id',type=int,required=True);a=p.parse_args()
    root=a.results.absolute();root.mkdir(mode=0o700,parents=True,exist_ok=False)
    source=a.world.resolve(strict=True);frozen={p:digest(p) for p in (source/'players.db',source/'WorldDictionary.bin')}
    repository=Path(__file__).resolve().parents[1]
    profile=root/'profile.ini';profile.write_text('\n'.join(s for s in a.ini.read_text().splitlines() if s.startswith('Mods='))+'\n')
    rows=[]
    for label,script,bad,expected in [('before-truncated',a.before_script,True,True),('after-truncated',repository/'data/scripts/backup/restoreCharacter.sh',True,False),('after-complete',repository/'data/scripts/backup/restoreCharacter.sh',False,True)]:
        case=root/label;case.mkdir();scripts=case/'repo/data/scripts';(scripts/'backup').mkdir(parents=True)
        shutil.copytree(repository/'data/scripts/lib',scripts/'lib');shutil.copy2(script,scripts/'backup/restoreCharacter.sh')
        (scripts/'lib/common.sh').write_text('''source_env() { :; }
require_sqlite() { :; }
die() { echo "$*" >&2; exit 1; }
server_is_active() { return 1; }
acquire_world_lock() { :; }
assert_server_stopped_proven() { :; }
release_world_lock() { :; }
log() { echo "$*"; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
''')
        saved=case/'saved';saved.mkdir();world=case/'live/Saves/Multiplayer/test';world.mkdir(parents=True)
        for folder in (saved,world):
            for name in ('players.db','WorldDictionary.bin'):shutil.copyfile(source/name,folder/name)
        with sqlite3.connect(saved/'players.db') as db:
            user,blob=db.execute('SELECT username,data FROM networkPlayers WHERE id=?',(a.player_id,)).fetchone()
            if bad:db.execute('UPDATE networkPlayers SET data=? WHERE id=?',(blob[:-1],a.player_id))
        with sqlite3.connect(world/'players.db') as db:
            db.execute('UPDATE networkPlayers SET data=? WHERE username=?',(b'current character sentinel',user))
            outside=db.execute('SELECT * FROM networkPlayers WHERE username<>? ORDER BY id',(user,)).fetchall()
        before=digest(world/'players.db');saved_hash=digest(saved/'players.db')
        env={k:v for k,v in os.environ.items() if not k.startswith(('PZ_','BACKUP_','DISCORD_')) and k not in ('BASH_ENV','ENV')}
        env.update(PZ_SOURCE_DIR=str(case/'live'),BACKUP_DIR=str(case),PZ_SERVER_NAME='test',PZ_INSTALL_DIR=str(a.install.absolute()),PZ_INI_PATH=str(profile),PZ_RESTORE_JAVA=str(a.java.absolute()),PZ_RESTORE_JAVAC=str(a.javac.absolute()))
        with (case/'restore.log').open('w') as log:
            result=subprocess.run(['bash',str(scripts/'backup/restoreCharacter.sh'),user,str(saved)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        assert (result.returncode==0)==expected,label
        assert digest(saved/'players.db')==saved_hash
        if not expected:
            assert digest(world/'players.db')==before
            assert 'destination intacte' in (case/'restore.log').read_text()
        with sqlite3.connect(world/'players.db') as db:
            assert db.execute('SELECT * FROM networkPlayers WHERE username<>? ORDER BY id',(user,)).fetchall()==outside
            if expected:assert db.execute('SELECT data FROM networkPlayers WHERE username=? ORDER BY id',(user,)).fetchone()[0]==(blob[:-1] if bad else blob)
        rows.append(dict(scenario=label,accepted=result.returncode==0,source_unchanged=True,unselected_rows_preserved=True))
    assert all(digest(p)==h for p,h in frozen.items())
    (root/'result.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows))

if __name__=='__main__':main()
