#!/usr/bin/env python3
"""Opt-in real, nonempty reanimated input; private copies in a Linux namespace.

Uses the installed game reader and strict item trace. Checks the complete valid
file and refuses truncation, trailing bytes and a false character count. Never
starts a server or modifies the supplied input/dictionary/profile.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'data/scripts/lib'))
from terrain_tiles import NativeIndexer, read_native_input


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('install', 'world', 'ini', 'java', 'javac', 'results'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    source = args.world.resolve(strict=True)
    root = args.results.absolute()
    if root == source or source in root.parents:
        raise ValueError('Results must be outside source world')
    frozen = {p: read_native_input(p) for p in (source/'WorldDictionary.bin', source/'reanimated.bin')}
    original = frozen[source/'reanimated.bin']
    version, count = struct.unpack_from('>ii', original)
    if version != 249 or count <= 0:
        raise ValueError('A genuine nonempty version-249 input is required')
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    dictionary = root/'WorldDictionary.bin'; dictionary.write_bytes(frozen[source/'WorldDictionary.bin'])
    profile = root/'profile.ini'
    profile.write_text('\n'.join(s for s in args.ini.read_text().splitlines() if s.startswith('Mods='))+'\n')
    os.environ.update(PZ_INSTALL_DIR=str(args.install.absolute()), PZ_INI_PATH=str(profile),
                      PZ_RESTORE_JAVA=str(args.java.absolute()), PZ_RESTORE_JAVAC=str(args.javac.absolute()))
    native = NativeIndexer(root/'native', dictionary, trace_items=True)
    valid = root/'valid.bin'; valid.write_bytes(original)
    result = native.storage([dict(file=str(valid), kind='reanimated', version=version)])[0]
    if result['sha256'] != hashlib.sha256(original).hexdigest() or not result['items']:
        raise AssertionError('The real saved items were not loaded')
    cases = {'truncated': original[:-1], 'trailing': original+b'\0',
             'false-count': struct.pack('>ii', version, count-1)+original[8:]}
    for name, data in cases.items():
        path = root/(name+'.bin'); path.write_bytes(data)
        try:
            native.storage([dict(file=str(path), kind='reanimated', version=version)])
        except ValueError:
            log = (root/'native'/('storage-'+str(native.sequence)+'.log')).read_text(errors='replace')
            if not any(s in log for s in ('BufferUnderflowException', 'Unparsed storage bytes', 'StrictFailure')):
                raise AssertionError('Unrelated failure cannot prove malformed input refusal')
        else:
            raise AssertionError(name+' unexpectedly accepted')
    for path, raw in frozen.items():
        if read_native_input(path) != raw:
            raise AssertionError('Source changed')
    summary = dict(characters=count, item_reads=len(result['items']), invalid_refused=list(cases), source_unchanged=True)
    (root/'result.json').write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))


if __name__ == '__main__': main()
