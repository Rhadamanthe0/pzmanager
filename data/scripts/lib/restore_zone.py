#!/usr/bin/env python3
"""Restore exact B42 tile columns on every floor. Called under the shell world lock.

Cell metadata/populations and global player/vehicle databases stay current.
A complete source chunk is required for every intersecting chunk; absence is
never interpreted as permission to regenerate or erase terrain.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import zlib
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from terrain_tiles import prepare_partial
from zone_zip import zone_map_source


def plain(path, root, directory=False):
    """Reject links (including parent links) and special files before copying."""
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError(f"Lien symbolique refusé : {item}")
        if item == root:
            break
    if path.exists() and not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f"Type de fichier incompatible : {path}")


def terrain_version(path, validate=True):
    data = path.read_bytes()
    if len(data) < 17 or data[0] != 0:
        raise ValueError(f'En-tête de chunk Build 42 invalide : {path}')
    version, length, checksum = struct.unpack_from('>iiq', data, 1)
    if version != 249:
        raise ValueError(f'Version de chunk non supportée ({version}) : {path}')
    if validate and (length != len(data) or checksum != zlib.crc32(data[17:])):
        raise ValueError(f'Longueur ou checksum de chunk invalide : {path}')
    return version


def replace_file(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.zone-', dir=destination.parent)
    os.close(fd)
    try:
        shutil.copy2(source, name)
        os.replace(name, destination)  # Never write through a backup hardlink.
    finally:
        Path(name).unlink(missing_ok=True)


def restore(args):
    live_root = Path(args.live_root).absolute()
    backup = Path(args.backup)
    if not backup.exists():
        candidate = Path(args.backup_root) / args.backup
        backup = candidate
        if not candidate.exists() and getattr(args, 'archive_root', None):
            backup = Path(args.archive_root) / args.backup
    backup = backup.resolve(strict=True)  # supports the regular `latest` alias
    mp = live_root / 'Saves/Multiplayer'
    plain(mp, live_root, directory=True)
    saves = [p.name for p in mp.iterdir() if p.is_dir() and not p.is_symlink()]
    save = args.save
    if save is None:
        if len(saves) != 1:
            raise ValueError('Précisez --save <monde> : monde absent ou ambigu.')
        save = saves[0]
    if not save or '..' in save or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in save):
        raise ValueError('Nom de monde invalide.')
    live = mp / save
    with zone_map_source(backup, save, args.x1, args.y1, args.x2, args.y2) as source:
        return restore_source(args, backup, save, live, source)


def restore_source(args, backup, save, live, source):
    for root in (live, source):
        plain(root, Path(root.anchor), directory=True)
        plain(root / 'map', root, directory=True)
        if not (root / 'map').is_dir():
            raise ValueError(f'Carte Build 42 absente : {root}')
    if live.resolve() == source.resolve():
        raise ValueError('Source et destination identiques.')
    # No global dictionary rollback: refuse mismatches instead of silently
    # interpreting restored object IDs with a different global dictionary.
    for name in ('map_ver.bin', 'WorldDictionary.bin'):
        a, b = live / name, source / name
        plain(a, live); plain(b, source)
        # Current B42 saves store version in each terrain header, not map_ver.
        if name == 'map_ver.bin' and not a.exists() and not b.exists():
            continue
        if not a.is_file() or not b.is_file() or a.read_bytes() != b.read_bytes():
            raise ValueError(f'{name} absent ou différent : compatibilité non prouvée.')
    x1, x2 = sorted((args.x1, args.x2))
    y1, y2 = sorted((args.y1, args.y2))
    if min(x1, y1) < 0 or max(x2, y2) > 2**31 - 1:
        raise ValueError('Coordonnées attendues : entiers entre 0 et 2147483647.')
    cx1, cx2, cy1, cy2 = x1 // 8, x2 // 8, y1 // 8, y2 // 8
    count = (cx2 - cx1 + 1) * (cy2 - cy1 + 1)
    if count > 65536:
        raise ValueError('Zone trop grande (maximum 65536 chunks).')
    paths = []
    partial = {}
    invalidate = set()
    for x in range(cx1, cx2 + 1):
        for y in range(cy1, cy2 + 1):
            terrain = Path(f'map/{x}/{y}.bin')
            iso = Path(f'isoregiondata/datachunk_{x}_{y}.bin')
            for rel in (terrain, iso):
                plain(source / rel, source); plain(live / rel, live)
                paths.append(rel)
            if not (source / terrain).is_file() or (source / terrain).stat().st_size == 0:
                raise ValueError(f'Chunk absent ou vide dans le backup : {terrain}. Rien modifié.')
            selected = [lx * 8 + ly for lx in range(8) for ly in range(8)
                        if x1 <= x * 8 + lx <= x2 and y1 <= y * 8 + ly <= y2]
            if len(selected) < 64:
                if not (live / terrain).is_file():
                    raise ValueError(f'Chunk courant absent : {terrain}. Impossible de préserver les tuiles voisines.')
                terrain_version(live / terrain)  # Partial restoration needs an intact neighbour record.
                partial[terrain] = {'x': x, 'y': y, 'selected': selected}
                invalidate.add(iso)  # Rebuild regions from the merged map, never from the old whole chunk.
            source_version = terrain_version(source / terrain)
            # A damaged live checksum is recoverable; its version must still
            # match. A missing chunk is explicitly allowed in the destination.
            if (live / terrain).is_file() and terrain_version(live / terrain, validate=False) != source_version:
                raise ValueError(f'Versions de chunks incompatibles : {terrain}')
    print(f'Monde : {save}\nBackup : {backup}\nZone effective inclusive : '
          f'({x1},{y1}) → ({x2},{y2}). Tuiles : {(x2-x1+1)*(y2-y1+1)} ; chunks : {count}.')
    print('Toutes les hauteurs de ces tuiles, sous-sols compris, reviennent au backup.\n'
          'Les tuiles voisines sont conservées.\n'
          'Métadonnées de cellule, populations, personnages et véhicules restent courants.')
    if not args.apply:
        print('Aperçu : rien modifié. Serveur arrêté + --apply pour appliquer.')
        return
    recovery_root = Path(args.recovery_root).absolute()
    plain(recovery_root, Path(recovery_root.anchor), directory=True)
    recovery_root.mkdir(parents=True, exist_ok=True)
    recovery = Path(tempfile.mkdtemp(prefix='zone-rollback-', dir=recovery_root))
    old = recovery / 'before' / 'Saves/Multiplayer' / save
    new = recovery / 'staged'
    old.mkdir(parents=True); new.mkdir()
    manifest = {'world': save, 'source': str(backup), 'bounds': [x1, y1, x2, y2],
                'paths': [str(p) for p in paths], 'absent_before': [], 'status': 'preparing',
                'selection': 'exact-tile-columns-all-floors',
                'partial_chunks': [str(p) for p in partial]}
    manifest_path = recovery / 'manifest.json'
    def record(status):
        manifest['status'] = status
        pending = recovery / '.manifest.pending'
        pending.write_text(json.dumps(manifest, indent=2) + '\n')
        os.replace(pending, manifest_path)
    record('preparing')
    # Finish staging AND recovery before the first mutation.
    for rel in paths:
        if rel not in invalidate and (source / rel).is_file():
            (new / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / rel, new / rel)
        if (live / rel).is_file():
            (old / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(live / rel, old / rel)
        else:
            manifest['absent_before'].append(str(rel))
    if partial:
        # Native readers see private copies only. No live map is passed to Java.
        inputs = recovery / 'source'; inputs.mkdir()
        dictionary = inputs / 'WorldDictionary.bin'
        shutil.copy2(source / 'WorldDictionary.bin', dictionary)
        entries = []
        for rel, selection in partial.items():
            original = inputs / rel
            original.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(new / rel, original)
            entries.append(dict(selection, source=original, current=old / rel, output=new / rel))
        prepare_partial(recovery, dictionary, entries)
    record('ready')
    print(f'Copie de récupération : {recovery}', flush=True)
    changed = []
    try:
        record('applying')
        for rel in paths:
            changed.append(rel)
            if (new / rel).is_file():
                replace_file(new / rel, live / rel)
            else:
                (live / rel).unlink(missing_ok=True)  # discard stale selected iso cache
        record('complete')
    except BaseException:
        previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            for rel in reversed(changed):
                if (old / rel).is_file():
                    replace_file(old / rel, live / rel)
                else:
                    (live / rel).unlink(missing_ok=True)
            record('reverted')
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        raise
    print('Zone restaurée. Vous pouvez démarrer le serveur.')


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--live-root', required=True)
    parser.add_argument('--backup-root', required=True)
    parser.add_argument('--archive-root')
    parser.add_argument('--recovery-root', required=True)
    parser.add_argument('backup')
    for name in ('x1', 'y1', 'x2', 'y2'):
        parser.add_argument(name, type=int)
    parser.add_argument('--save')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    def interrupted(signum, frame):
        # The process group and the shell may both deliver TERM. Further
        # interruptions must not abort restoration of already changed files.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt(f"Signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        restore(args)
    except (OSError, ValueError) as error:
        parser.exit(1, f'ERREUR : {error}\n')


if __name__ == '__main__':
    main()
