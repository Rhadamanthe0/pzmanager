#!/usr/bin/env python3
"""Opt-in native regression: copied active/restored mod profiles, never a server.

Run only with private installation/world copies inside an isolated Linux mount
and network namespace. No package install, source edits or guard bypass.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'data/scripts/lib'))
from terrain_tiles import NativeIndexer,read_native_input


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('install','world','active-ini','restored-ini','java','javac','results'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--x',type=int,required=True);p.add_argument('--y',type=int,required=True)
    p.add_argument('--registry-id',type=int,required=True)
    a=p.parse_args();root=a.results.absolute()
    if root==a.world.absolute() or a.world.absolute() in root.parents:
        raise ValueError('Results must be outside the source world')
    root.mkdir(mode=0o700,parents=True,exist_ok=False)
    dictionary=a.world/'WorldDictionary.bin';chunk=a.world/'map'/str(a.x)/(str(a.y)+'.bin')
    frozen={p:read_native_input(p) for p in (dictionary,chunk)}
    private_dictionary=root/'WorldDictionary.bin';private_dictionary.write_bytes(frozen[dictionary])
    private_chunk=root/'terrain.bin';private_chunk.write_bytes(frozen[chunk])
    os.environ.update(PZ_INSTALL_DIR=str(a.install.absolute()),PZ_RESTORE_JAVA=str(a.java.absolute()),
                      PZ_RESTORE_JAVAC=str(a.javac.absolute()))
    entry=dict(file=str(private_chunk),x=a.x,y=a.y)
    for name,ini in [('active',a.active_ini),('restored',a.restored_ini)]:
        safe_ini=root/(name+'.ini')
        safe_ini.write_text('\n'.join(x for x in ini.read_text().splitlines() if x.startswith('Mods='))+'\n')
        os.environ['PZ_INI_PATH']=str(safe_ini)
        native=NativeIndexer(root/name,private_dictionary,trace_items=True)
        if name=='active':
            try:native.index([entry])
            except ValueError:
                # A compiler, dependency, bus or unrelated parsing failure is
                # never evidence of the intended missing-item refusal.
                log=(root/name/'index-1.log').read_text(errors='replace')
                if 'Native loader ignored or truncated item rid='+str(a.registry_id)+' ' not in log:
                    raise AssertionError('Expected native registry refusal was not reached')
            else:raise AssertionError('Inactive saved item unexpectedly admitted')
        else:
            result=native.index([entry])[0]
            records=[r for r in result['items'] if r['registry_id']==a.registry_id]
            if not records:raise AssertionError('Restored item was not actually loaded')
            summary=dict(active_refused=True,restored_accepted=True,registry_id=a.registry_id,
                         restored_types=sorted({r['itemType'] for r in records}),item_reads=len(result['items']),
                         sha256=result['sha256'])
    for path,original in frozen.items():
        if read_native_input(path)!=original:raise AssertionError('Source changed during validation')
    (root/'result.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))


if __name__=='__main__':main()
