#!/usr/bin/env python3
"""Restore B42 8x8 terrain chunks. Called under the shell world lock.

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
import tempfile


def plain(path, root, directory=False):
    """Reject links (including parent links) and special files before copying."""
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError(f"Lien symbolique refusé : {item}")
        if item == root:
            break
    if path.exists() and not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f"Type de fichier incompatible : {path}")


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
    if not backup.is_dir():
        backup = Path(args.backup_root) / args.backup
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
    source = backup / 'Saves/Multiplayer' / save
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
    for x in range(cx1, cx2 + 1):
        for y in range(cy1, cy2 + 1):
            terrain = Path(f'map/{x}/{y}.bin')
            iso = Path(f'isoregiondata/datachunk_{x}_{y}.bin')
            for rel in (terrain, iso):
                plain(source / rel, source); plain(live / rel, live)
                paths.append(rel)
            if not (source / terrain).is_file() or (source / terrain).stat().st_size == 0:
                raise ValueError(f'Chunk absent ou vide dans le backup : {terrain}. Rien modifié.')
    print(f'Monde : {save}\nBackup : {backup}\nZone effective inclusive : '
          f'({cx1*8},{cy1*8}) → ({cx2*8+7},{cy2*8+7}), {count} chunks de 8×8.')
    print('Tous les étages et objets/conteneurs de ces chunks reviennent au backup.\n'
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
                'paths': [str(p) for p in paths], 'absent_before': [], 'status': 'preparing'}
    manifest_path = recovery / 'manifest.json'
    def record(status):
        manifest['status'] = status
        pending = recovery / '.manifest.pending'
        pending.write_text(json.dumps(manifest, indent=2) + '\n')
        os.replace(pending, manifest_path)
    record('preparing')
    # Finish staging AND recovery before the first mutation.
    for rel in paths:
        if (source / rel).is_file():
            (new / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / rel, new / rel)
        if (live / rel).is_file():
            (old / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(live / rel, old / rel)
        else:
            manifest['absent_before'].append(str(rel))
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
        for rel in reversed(changed):
            if (old / rel).is_file():
                replace_file(old / rel, live / rel)
            else:
                (live / rel).unlink(missing_ok=True)
        record('reverted')
        raise
    print('Zone restaurée. Vous pouvez démarrer le serveur.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-root', required=True)
    parser.add_argument('--backup-root', required=True)
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
        raise KeyboardInterrupt(f"Signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        restore(args)
    except (OSError, ValueError) as error:
        parser.exit(1, f'ERREUR : {error}\n')


if __name__ == '__main__':
    main()
