#!/usr/bin/env python3
"""Optional proprietary-game integration, ALWAYS on private copies of snapshots.

Example (run from a disposable checkout):
  PZ_INSTALL_DIR=/path/to/game python3 tests/verify_tile_restore_native.py \
    --backup-world /snapshot-old/Saves/Multiplayer/world \
    --current-world /snapshot-new/Saves/Multiplayer/world \
    --chunk-x 514 --chunk-y 793 --results /private/validation

A lost column is simulated only in the private current copy when needed. This
uses real record bytes and PZ readers; it never starts a game or edits a snapshot.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'data/scripts/lib'))
import restore_zone as zone
import terrain_tiles as tiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup-world', type=Path, required=True)
    parser.add_argument('--current-world', type=Path, required=True)
    parser.add_argument('--chunk-x', type=int, required=True)
    parser.add_argument('--chunk-y', type=int, required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True, mode=0o700)
    base = Path(tempfile.mkdtemp(prefix='native-tiles-', dir=args.results))
    cx, cy = args.chunk_x, args.chunk_y
    rel = Path(f'map/{cx}/{cy}.bin')
    worlds = {}
    for side, original in [('backup', args.backup_world), ('live', args.current_world)]:
        world = base / side / 'Saves/Multiplayer/world'
        world.mkdir(parents=True)
        for name in (Path('WorldDictionary.bin'), rel):
            destination = world / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original / name, destination)
        worlds[side] = world
    dictionary = worlds['live'] / 'WorldDictionary.bin'
    if dictionary.read_bytes() != (worlds['backup'] / 'WorldDictionary.bin').read_bytes():
        raise ValueError('Snapshots have different world dictionaries')
    native = tiles.NativeIndexer(base / 'audit', dictionary)
    files = [{'file': str(worlds[side] / rel), 'x': cx, 'y': cy} for side in ('backup', 'live')]
    indexes = native.index(files)
    source, current = [Path(entry['file']).read_bytes() for entry in files]
    a, b = [tiles.checked_columns(data, index) for data, index in zip((source, current), indexes)]
    available = [i for i in range(64) if len(a[i]) > 8]
    if not available:
        raise ValueError('Select a populated source chunk')
    # Prefer a multi-floor column so the real test covers vertical restoration.
    selected = max(available, key=lambda i: int(indexes[0]['columns'][i][2]).bit_count())
    simulated_loss = a[selected] == b[selected]
    if simulated_loss:
        columns = list(b)
        columns[selected] = b'\0' * 8
        index = indexes[1]
        body = (current[17:index['columns'][0][0]] + b''.join(columns)
                + current[index['columns'][-1][1]:])
        current = b'\0' + struct.pack('>iiq', 249, len(body) + 17, zlib.crc32(body)) + body
        Path(files[1]['file']).write_bytes(current)
        indexes[1] = native.index([files[1]])[0]
        b = tiles.checked_columns(current, indexes[1])
    x, y = cx * 8 + selected // 8, cy * 8 + selected % 8
    zone.restore(argparse.Namespace(live_root=str(base / 'live'), backup_root=str(base),
        recovery_root=str(base / 'OLD'), backup='backup', save=None, apply=True,
        x1=x, y1=y, x2=x, y2=y))
    result = Path(files[1]['file']).read_bytes()
    index = native.index([files[1]])[0]
    restored = tiles.checked_columns(result, index)
    assert restored[selected] == a[selected] and restored[selected] != b[selected]
    assert all(restored[i] == b[i] for i in range(64) if i != selected)
    assert result[index['columns'][-1][1]:] == current[indexes[1]['columns'][-1][1]:]
    assert dictionary.read_bytes() == (worlds['backup'] / 'WorldDictionary.bin').read_bytes()
    report = dict(result='PASS', selection=[x, y, x, y],
                  restored_floors=[z - 32 for z in range(64)
                                   if int(indexes[0]['columns'][selected][2]) & (1 << z)],
                  simulated_loss_in_private_copy=simulated_loss,
                  other_63_columns_byte_identical=True, chunk_suffix_unchanged=True,
                  native_reader_accepted_source_current_and_result=True,
                  production_world_modified=False, private_copy=str(base),
                  game_jar_sha256=hashlib.sha256(native.jar.read_bytes()).hexdigest())
    (base / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
