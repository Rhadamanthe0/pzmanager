#!/usr/bin/env python3
"""Restore exact B42 tile columns on every floor. Called under the shell world lock.

Cell metadata/populations and global player/vehicle databases stay current.
A complete source chunk is required for every intersecting chunk; absence is
never interpreted as permission to regenerate or erase terrain.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import struct
import zlib
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from terrain_tiles import NativeIndexer, checked_columns, prepare_partial
from zone_zip import zone_map_source
import world_transaction as transactions


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


def file_sha256(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError(f'Fichier non régulier : {path}')
        digest = hashlib.sha256()
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(data)
        return digest.hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def require_hash(path, expected):
    # None is an absence explicitly recorded in the plan, never a missing
    # staged file reinterpreted as an instruction to erase the live terrain.
    if expected is None:
        if os.path.lexists(path):
            raise ValueError(f'Fichier apparu après préparation : {path}')
    elif file_sha256(path) != expected:
        raise ValueError(f'Fichier modifié après préparation : {path}')


def replace_file(source, destination, expected_sha256=None):
    if expected_sha256 is None:
        expected_sha256 = file_sha256(source)
    missing = []
    parent = destination.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Persist new recovery-directory entries before the first live mutation.
    for directory in reversed(missing):
        sync_directory(directory)
        sync_directory(directory.parent)
    fd, name = tempfile.mkstemp(prefix='.zone-', dir=destination.parent)
    os.close(fd)
    try:
        shutil.copy2(source, name)
        require_hash(Path(name), expected_sha256)
        with open(name, 'rb') as stream:
            os.fsync(stream.fileno())
        os.replace(name, destination)  # Never write through a backup hardlink.
        sync_directory(destination.parent)
    finally:
        Path(name).unlink(missing_ok=True)


def sync_recovery_plan(recovery, old, new, paths):
    """Persist recovery images and their directory entries before APPLY."""
    directories = {recovery, recovery.parent, recovery.parent.parent}
    for root in (old, new):
        for rel in paths:
            path = root / rel
            if path.is_file():
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
                parent = path.parent
                while parent != recovery:
                    directories.add(parent)
                    parent = parent.parent
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        sync_directory(directory)


def require_dictionary_compatible(source, current, staging_root):
    """Old IDs must keep their meaning; new current entries are harmless.

    Never roll back the global dictionary or trust its readable Lua sidecar.
    Native loading includes items, entities, objects, sprites, strings and
    versioned script registries. Mod provenance/availability flags may evolve.
    """
    saved_bytes, current_bytes = source.read_bytes(), current.read_bytes()
    if saved_bytes == current_bytes:
        return
    if any(len(data) < 4 or len(data) > 64 * 1024 * 1024 or
           struct.unpack_from('>i', data)[0] != 1 for data in (saved_bytes, current_bytes)):
        raise ValueError('WorldDictionary.bin incompatible : format binaire non supporté.')
    with tempfile.TemporaryDirectory(prefix='.pz-dictionary-', dir=staging_root) as temp:
        root = Path(temp)
        saved, live = root / 'saved.bin', root / 'current.bin'
        shutil.copy2(source, saved); shutil.copy2(current, live)
        native = NativeIndexer(root / 'native', live)
        try:
            before, after = native.dictionaries([saved, live])
            old, new = before['registries'], after['registries']
            if not old or set(old) != set(new):
                raise ValueError('registres absents ou différents')
            for registry, entries in old.items():
                for ident, meaning in entries.items():
                    if ident not in new[registry] or new[registry][ident] != meaning:
                        raise ValueError(f'{registry}, identifiant {ident} : {meaning!r}')
        except (ValueError, KeyError, TypeError) as error:
            raise ValueError(f'WorldDictionary.bin incompatible : {error}') from error
        print('WorldDictionary.bin : identifiants du backup compatibles avec le monde courant.')
        if after['removed_or_obsolete']:
            print('Attention : des entrées du dictionnaire courant sont retirées/obsolètes ; '
                  'les objets de mods désactivés ne sont pas réactivés par la restauration.')


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
    with zone_map_source(backup, save, args.x1, args.y1, args.x2, args.y2,
                         getattr(args, 'staging_root', None)) as source:
        return restore_source(args, backup, save, live, source)


def restore_source(args, backup, save, live, source):
    for root in (live, source):
        plain(root, Path(root.anchor), directory=True)
        plain(root / 'map', root, directory=True)
        if not (root / 'map').is_dir():
            raise ValueError(f'Carte Build 42 absente : {root}')
    if live.resolve() == source.resolve():
        raise ValueError('Source et destination identiques.')
    # Bind compatibility checks to the unchanged source/current dictionaries.
    context_hashes = {}
    # No global dictionary rollback: prove every old ID still has its meaning.
    for name in ('map_ver.bin', 'WorldDictionary.bin'):
        a, b = live / name, source / name
        plain(a, live); plain(b, source)
        # Current B42 saves store version in each terrain header, not map_ver.
        if name == 'map_ver.bin' and not a.exists() and not b.exists():
            continue
        if not a.is_file() or not b.is_file():
            raise ValueError(f'{name} absent ou différent : compatibilité non prouvée.')
        context_hashes[a] = file_sha256(a)
        context_hashes[b] = file_sha256(b)
        if name == 'WorldDictionary.bin':
            require_dictionary_compatible(b, a, getattr(args, 'staging_root', None))
        elif a.read_bytes() != b.read_bytes():
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
          f'({x1},{y1}) → ({x2},{y2}).\n'
          f'Sélection : {x2-x1+1} × {y2-y1+1} cases, soit {(x2-x1+1)*(y2-y1+1)} cases au total.')
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
        with pending.open('rb') as stream:
            os.fsync(stream.fileno())
        os.replace(pending, manifest_path)
        sync_directory(recovery)
    record('preparing')
    # Finish staging AND recovery before the first mutation. Pin copies to
    # their source bytes, including the explicit list of intended absences.
    before_hashes, after_hashes = {}, {}
    for rel in paths:
        if rel.parts[0] == 'map' and not (source / rel).is_file():
            raise ValueError(f'Chunk source disparu pendant la préparation : {rel}')
        after_hashes[rel] = None
        if rel not in invalidate and (source / rel).is_file():
            after_hashes[rel] = file_sha256(source / rel)
            replace_file(source / rel, new / rel, after_hashes[rel])
        before_hashes[rel] = None
        if (live / rel).is_file():
            before_hashes[rel] = file_sha256(live / rel)
            replace_file(live / rel, old / rel, before_hashes[rel])
        else:
            manifest['absent_before'].append(str(rel))
    if partial:
        # Native readers see private copies only. No live map is passed to Java.
        inputs = recovery / 'source'; inputs.mkdir()
        dictionary = inputs / 'WorldDictionary.bin'
        replace_file(live / 'WorldDictionary.bin', dictionary,
                     context_hashes[live / 'WorldDictionary.bin'])
        entries = []
        for rel, selection in partial.items():
            original = inputs / rel
            original.parent.mkdir(parents=True, exist_ok=True)
            replace_file(new / rel, original, after_hashes[rel])
            entries.append(dict(selection, source=original, current=old / rel, output=new / rel))
        prepare_partial(recovery, dictionary, entries)
        for rel in partial:
            after_hashes[rel] = file_sha256(new / rel)
    # Interior/whole chunks need the same complete native validation as
    # spliced edge chunks. A valid CRC cannot establish game readability.
    dictionary = recovery / 'WorldDictionary.bin'
    replace_file(live / 'WorldDictionary.bin', dictionary,
                 context_hashes[live / 'WorldDictionary.bin'])
    native = NativeIndexer(recovery / 'native-final', dictionary)
    terrain = [rel for rel in paths if rel.parts[0] == 'map']
    inputs = [{'file': str(new / rel), 'x': int(rel.parts[1]), 'y': int(rel.stem)}
              for rel in terrain]
    indexes = native.index(inputs)
    if len(indexes) != len(terrain):
        raise ValueError('Validation native du terrain incomplète.')
    for rel, index in zip(terrain, indexes):
        checked_columns((new / rel).read_bytes(), index)
    manifest['files'] = [{'path': str(rel), 'before_sha256': before_hashes[rel],
                          'after_sha256': after_hashes[rel]} for rel in paths]
    record('ready')
    # Recheck the entire plan AFTER native readers return, BEFORE the first
    # live mutation. Keep these hashes for the copy/rename boundary as well.
    for path, expected in context_hashes.items():
        require_hash(path, expected)
    for rel in paths:
        require_hash(old / rel, before_hashes[rel])
        require_hash(live / rel, before_hashes[rel])
        require_hash(new / rel, after_hashes[rel])
    sync_recovery_plan(recovery, old, new, paths)
    world_root = live.parents[2]
    prefix = live.relative_to(world_root)
    token = transactions.begin(world_root, 'zone', recovery, files=[
        {'path': str(prefix/rel), 'before': before_hashes[rel], 'after': after_hashes[rel]} for rel in paths])
    print(f'Copie de récupération : {recovery}', flush=True)
    changed = []
    try:
        record('applying')
        for rel in paths:
            require_hash(live / rel, before_hashes[rel])
            changed.append(rel)
            if after_hashes[rel] is not None:
                replace_file(new / rel, live / rel, after_hashes[rel])
            else:
                require_hash(new / rel, None)
                (live / rel).unlink(missing_ok=True)  # discard only planned iso caches
                if (live / rel).parent.exists():
                    sync_directory((live / rel).parent)
        for rel in paths:
            require_hash(live / rel, after_hashes[rel])
        record('complete')
        transactions.finish(world_root, token, 'complete')
    except BaseException:
        previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            rollback_errors = []
            for rel in reversed(changed):
                try:
                    current = file_sha256(live / rel) if os.path.lexists(live / rel) else None
                    if current == before_hashes[rel]:
                        continue  # An interrupted copy never replaced this file.
                    if current != after_hashes[rel]:
                        raise ValueError(f'Modification externe pendant la restauration : {rel}')
                    if before_hashes[rel] is not None:
                        require_hash(old / rel, before_hashes[rel])
                        replace_file(old / rel, live / rel, before_hashes[rel])
                    else:
                        require_hash(old / rel, None)
                        (live / rel).unlink(missing_ok=True)
                        if (live / rel).parent.exists():
                            sync_directory((live / rel).parent)
                    require_hash(live / rel, before_hashes[rel])
                except (OSError, ValueError) as error:
                    # Preserve conflicts, but still revert other changed files.
                    rollback_errors.append(f'{rel}: {error}')
            if rollback_errors:
                raise ValueError('Récupération manuelle requise ; copies conservées : '
                                 + '; '.join(rollback_errors))
            record('reverted')
            transactions.finish(world_root, token, 'reverted')
        except BaseException:
            record('rollback-failed')
            raise
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        raise
    print('Zone restaurée. Vous pouvez démarrer le serveur.')


class PublicParser(argparse.ArgumentParser):
    def format_usage(self):
        return super().format_usage().replace('usage:', 'Usage :', 1)

    def format_help(self):
        return super().format_help().replace('usage:', 'Usage :', 1)

    def error(self, message):
        if message.startswith('the following arguments are required: '):
            missing = message.split(': ', 1)[1].split(', ')
            if 'backup' in missing:
                message = 'Indiquez une sauvegarde et les quatre coordonnées x1 y1 x2 y2.'
            elif any(name in missing for name in ('x1', 'y1', 'x2', 'y2')):
                message = 'Coordonnées manquantes : indiquez x1 y1 x2 y2 (les deux coins de la zone).'
            else:
                message = 'Configuration interne incomplète : utilisez pzm backup restore-zone.'
        self.print_usage(sys.stderr)
        self.exit(2, f'ERREUR : {message}\n')


def main():
    parser = PublicParser(
        prog='pzm backup restore-zone',
        usage='%(prog)s <sauvegarde> <x1> <y1> <x2> <y2> [--apply] [--save <monde>]',
        description='Restaurer une zone de carte, toutes hauteurs comprises. '
                    'Par défaut : aperçu uniquement, sans modification.',
        allow_abbrev=False, add_help=False)
    parser._positionals.title = 'Arguments'
    parser._optionals.title = 'Options'
    parser.add_argument('-h', '--help', action='help', help='Afficher cette aide.')
    for name in ('live-root', 'backup-root', 'archive-root', 'staging-root', 'recovery-root'):
        parser.add_argument('--' + name, required=name in ('live-root', 'backup-root', 'recovery-root'),
                            help=argparse.SUPPRESS)
    parser.add_argument('backup', metavar='sauvegarde', help='Nom ou chemin de la sauvegarde (dossier ou ZIP).')
    for name in ('x1', 'y1', 'x2', 'y2'):
        parser.add_argument(name, type=int, help='Coordonnée en cases du premier coin.' if name.endswith('1')
                            else 'Coordonnée en cases du second coin.')
    parser.add_argument('--save', metavar='monde', help='Choisir le monde si plusieurs sont présents.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true', help='Appliquer la restauration (serveur arrêté requis).')
    mode.add_argument('--dry-run', action='store_true', help=argparse.SUPPRESS)
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
