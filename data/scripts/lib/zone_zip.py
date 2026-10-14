#!/usr/bin/env python3
"""Read only the selected Build 42 map files from a full off-site ZIP.

The ZIP's config/ subtree (which contains secrets) is never extracted. Members
are copied by an internally constructed allowlist, not through ZipFile.extract.
"""
from contextlib import contextmanager
from pathlib import Path
import shutil
import stat
import tempfile
import zipfile


# Bound untrusted archive expansion before writing to the staging filesystem.
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_STAGING_BYTES = 8 * 1024 * 1024 * 1024
FREE_SPACE_RESERVE = 512 * 1024 * 1024


@contextmanager
def zone_map_source(backup, save, x1, y1, x2, y2, staging_root=None):
    """Yield the ordinary source-world directory, from a snapshot or a ZIP."""
    if backup.is_dir():
        yield backup / 'Saves/Multiplayer' / save
        return
    if not backup.is_file() or backup.suffix.lower() != '.zip':
        raise ValueError(f'Source non supportée (dossier snapshot ou ZIP attendu) : {backup}')

    x1, x2 = sorted((x1, x2))
    y1, y2 = sorted((y1, y2))
    if min(x1, y1) < 0 or max(x2, y2) > 2**31 - 1:
        raise ValueError('Coordonnées attendues : entiers entre 0 et 2147483647.')
    cx1, cx2, cy1, cy2 = x1 // 8, x2 // 8, y1 // 8, y2 // 8
    if (cx2 - cx1 + 1) * (cy2 - cy1 + 1) > 65536:
        raise ValueError('Zone trop grande (maximum 65536 chunks).')

    prefix = f'zomboid/Saves/Multiplayer/{save}/'
    terrain = {f'map/{x}/{y}.bin' for x in range(cx1, cx2 + 1)
               for y in range(cy1, cy2 + 1)}
    optional = {f'isoregiondata/datachunk_{x}_{y}.bin'
                for x in range(cx1, cx2 + 1) for y in range(cy1, cy2 + 1)}
    optional.add('map_ver.bin')
    required = terrain | {'WorldDictionary.bin'}
    wanted = {prefix + rel for rel in required | optional}

    # Never default to fullBackups/: Syncthing watches that directory.
    if staging_root is None:
        raise ValueError('Répertoire de staging requis pour un ZIP.')
    staging_root = Path(staging_root)
    if not staging_root.is_dir():
        raise ValueError(f'Répertoire de staging absent : {staging_root}')

    # Keep the staging directory alive during the whole restore, but close
    # the ZIP and scope archive-error translation to the extraction itself.
    with tempfile.TemporaryDirectory(prefix='.pz-restore-zone-', dir=staging_root) as stage:
        source = Path(stage) / 'Saves/Multiplayer' / save
        source.mkdir(parents=True)
        try:
            with zipfile.ZipFile(backup) as archive:
                members = {}
                for info in archive.infolist():
                    if info.filename not in wanted:
                        continue
                    if info.filename in members:
                        raise ValueError(f'Entrée dupliquée dans le ZIP : {info.filename}')
                    # Reject UNIX symlinks, directories, devices and encrypted members.
                    mode = info.external_attr >> 16
                    if (info.is_dir() or (info.create_system == 3 and
                        stat.S_IFMT(mode) not in (0, stat.S_IFREG)) or
                        info.flag_bits & 1):
                        raise ValueError(f'Entrée ZIP non régulière ou chiffrée : {info.filename}')
                    if info.file_size > MAX_MEMBER_BYTES:
                        raise ValueError(f'Entrée ZIP trop volumineuse : {info.filename}')
                    members[info.filename] = info

                missing = required - {name[len(prefix):] for name in members}
                if missing:
                    raise ValueError('Carte Build 42 absente ou incomplète dans le ZIP '
                                     f'({sorted(missing)[0]}) : {backup}')
                size = sum(info.file_size for info in members.values())
                if size > MAX_STAGING_BYTES:
                    raise ValueError('Zone ZIP trop volumineuse pour extraction temporaire (8 Gio maximum).')
                if shutil.disk_usage(staging_root).free - size < FREE_SPACE_RESERVE:
                    raise ValueError('Espace libre insuffisant pour extraire la zone ZIP '
                                     '(réserve de 512 Mio requise).')

                # Copy only files needed for the selected map; never extract config/.
                for name, info in sorted(members.items()):
                    relative = name[len(prefix):]
                    target = source / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(info) as reader, target.open('xb') as writer:
                        shutil.copyfileobj(reader, writer, length=1024 * 1024)
        except (zipfile.BadZipFile, zipfile.LargeZipFile, NotImplementedError,
                RuntimeError, EOFError) as error:
            raise ValueError(f'Archive ZIP illisible ou corrompue : {backup} ({error})') from error
        yield source
