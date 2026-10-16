#!/usr/bin/env python3
"""Read the exact prepared character blobs with the destination game context."""
import argparse
import hashlib
from pathlib import Path
import sqlite3

from terrain_tiles import NativeIndexer, read_native_input


def validate(source_db, source_dictionary, world, username, stage):
    with open(source_db,'rb') as stream:prepared_hash=hashlib.file_digest(stream,'sha256').hexdigest()
    stage=Path(stage);stage.mkdir(mode=0o700)
    world=Path(world)
    originals={p:read_native_input(p) for p in (Path(source_dictionary),world/'WorldDictionary.bin')}
    saved=stage/'saved.bin';current=stage/'current.bin'
    saved.write_bytes(originals[Path(source_dictionary)]);current.write_bytes(originals[world/'WorldDictionary.bin'])
    inputs=[]
    db=sqlite3.connect(Path(source_db).resolve(strict=True).as_uri()+'?mode=ro&immutable=1',uri=True)
    try:
        for index,(version,data) in enumerate(db.execute('SELECT worldversion,data FROM networkPlayers WHERE username=? ORDER BY id',(username,))):
            if version!=249 or not isinstance(data,bytes) or not 0<len(data)<=64*1024*1024:
                raise ValueError('Unsupported character version or blob')
            path=stage/('player-'+str(index)+'.bin');path.write_bytes(data)
            inputs.append(dict(file=str(path),kind='player',version=version))
    finally:db.close()
    if not inputs:raise ValueError('Prepared character absent')
    native=NativeIndexer(stage/'native',current,trace_items=True)
    before,after=native.dictionaries([saved,current])
    old,new=before['registries'],after['registries']
    if not old or set(old)!=set(new):raise ValueError('Incompatible character dictionary registries')
    for name,entries in old.items():
        if any(new[name].get(ident)!=meaning for ident,meaning in entries.items()):
            raise ValueError('Saved character dictionary identifiers changed')
    native.storage(inputs)
    with open(source_db,'rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest()!=prepared_hash:raise ValueError('Prepared database changed during validation')
    for path,data in originals.items():
        if read_native_input(path)!=data:raise ValueError('Character dictionary changed during validation')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('source-db','source-dictionary','world','username','stage'):p.add_argument('--'+name,required=True)
    a=p.parse_args()
    try:validate(a.source_db,a.source_dictionary,a.world,a.username,a.stage)
    except Exception as error:
        # Native logs can contain private saved text. Never print their contents.
        raise SystemExit('Validation native du personnage refusée ; aucune écriture SQL.') from error


if __name__=='__main__':main()
