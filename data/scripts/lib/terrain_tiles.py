"""Splice original B42 tile-column records; use PZ only to index/validate copies."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import zlib

MAX_TERRAIN_BYTES = 64 * 1024 * 1024


def read_native_input(path):
    """Bound reads and reject links/special files before a native validation."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_TERRAIN_BYTES:
            raise ValueError('Entrée native non régulière ou trop volumineuse.')
        data = stream.read(MAX_TERRAIN_BYTES + 1)
    if len(data) > MAX_TERRAIN_BYTES:
        raise ValueError('Entrée native trop volumineuse.')
    return data


def native_script_context(install):
    """Pass only mod IDs and installed search roots, never server credentials."""
    mods = []
    ini = os.environ.get('PZ_INI_PATH')
    if ini:
        for line in Path(ini).read_text().splitlines():
            key, separator, value = line.partition('=')
            if separator and key.strip() == 'Mods':
                mods = [mod.strip().lstrip('\\') for mod in value.split(';') if mod.strip()]
    roots = []
    workshop = Path(install) / 'steamapps/workshop/content/108600'
    if workshop.is_dir():
        roots.extend(p / 'mods' for p in sorted(workshop.iterdir()) if (p / 'mods').is_dir())
    source = os.environ.get('PZ_SOURCE_DIR')
    if source and (Path(source) / 'mods').is_dir():
        roots.append(Path(source) / 'mods')
    return {'mods': mods, 'mod_roots': [str(p.resolve(strict=True)) for p in roots]}


def mod_script_catalogs(install):
    """Find static catalogs of enabled mods, without executing any mod code.

    Include common and versioned definitions. Consumers must refuse conflicting
    classes across versions rather than guess which serialized type to edit.
    """
    context = native_script_context(install)
    enabled = set(context['mods'])
    catalogs = []
    for root in context['mod_roots']:
        for mod in sorted(Path(root).iterdir()):
            if not mod.is_dir():
                continue
            identifiers = set()
            for info in [mod / 'mod.info', *sorted(mod.glob('*/mod.info'))]:
                if info.is_file():
                    for line in info.read_text(encoding='utf-8-sig').splitlines():
                        key, separator, value = line.partition('=')
                        if separator and key.strip() == 'id':
                            identifiers.add(value.strip().lstrip('\\'))
            if identifiers & enabled:
                catalogs.extend(p for p in [mod / 'media/scripts', *sorted(mod.glob('*/media/scripts'))]
                                if p.is_dir())
    return catalogs


def checked_columns(data, index):
    """Reject stale or inconsistent native indexes before any binary surgery."""
    if len(data) < 17 or len(data) > MAX_TERRAIN_BYTES or data[0] != 0:
        raise ValueError('En-tête de terrain incompatible.')
    version, length, crc = struct.unpack_from('>iiq', data, 1)
    if version != 249 or length != len(data) or crc != zlib.crc32(data[17:]):
        raise ValueError('Terrain invalide : version, longueur ou checksum.')
    if index['sha256'] != hashlib.sha256(data).hexdigest():
        raise ValueError('Terrain modifié après indexation.')
    lo, hi, offset = index['min_level'], index['max_level'], index['level_offset']
    if not (-32 <= lo <= hi <= 31 and 17 <= offset <= len(data) - 12):
        raise ValueError('Étages de terrain invalides.')
    if struct.unpack_from('>ii', data, offset) != (hi, lo):
        raise ValueError('Index des étages incohérent.')
    columns = index['columns']
    if len(columns) != 64:
        raise ValueError('Index de terrain incomplet.')
    allowed = ((1 << (hi - lo + 1)) - 1) << (lo + 32)
    previous = None
    for start, end, flag in columns:
        flag = int(flag)
        if not (offset + 12 <= start <= end - 8 < len(data) and end <= len(data)):
            raise ValueError('Limites de colonne invalides.')
        if previous is not None and previous != start:
            raise ValueError('Colonnes non contiguës.')
        if flag != struct.unpack_from('>Q', data, start)[0] or flag & ~allowed:
            raise ValueError('Masque des étages incohérent.')
        previous = end
    return [data[start:end] for start, end, _ in columns]


def merge_columns(source, current, source_index, current_index, selected):
    """Replace whole vertical columns, preserving all other raw tile bytes."""
    wanted = set(selected)
    if not wanted or any(type(i) is not int or i < 0 or i >= 64 for i in wanted):
        raise ValueError('Sélection de tuiles invalide.')
    old = checked_columns(current, current_index)
    saved = checked_columns(source, source_index)
    prefix_end = current_index['columns'][0][0]
    suffix_start = current_index['columns'][-1][1]
    result = bytearray(current[:prefix_end])
    for i in range(64):
        result.extend(saved[i] if i in wanted else old[i])
    result.extend(current[suffix_start:])
    # A restored column can introduce a basement or upper floor, or remove it.
    # The union is valid even when some levels contain no remaining squares.
    struct.pack_into('>ii', result, current_index['level_offset'],
                     max(source_index['max_level'], current_index['max_level']),
                     min(source_index['min_level'], current_index['min_level']))
    if len(result) > MAX_TERRAIN_BYTES:
        raise ValueError('Terrain restauré trop volumineux (64 Mio maximum).')
    struct.pack_into('>iq', result, 5, len(result), zlib.crc32(result[17:]))
    return bytes(result)


class NativeIndexer:
    """Compile once; native readers run only against private recovery copies."""
    def __init__(self, root, dictionary, *, java=None, javac=None):
        self.root = Path(root).absolute()
        self.root.mkdir()
        self.dictionary = Path(dictionary).absolute()
        install = Path(os.environ.get('PZ_INSTALL_DIR', ''))
        self.script_context = native_script_context(install)
        self.jar = (install / 'java/projectzomboid.jar').resolve(strict=True)
        self.java = Path(java or os.environ.get('PZ_RESTORE_JAVA', str(install / 'jre64/bin/java'))).resolve(strict=True)
        compiler = javac or os.environ.get('PZ_RESTORE_JAVAC')
        if compiler is None:
            sibling = self.java.with_name('javac')
            compiler = str(sibling) if os.access(sibling, os.X_OK) else shutil.which('javac')
        if not compiler or not os.path.isfile(compiler) or not os.access(compiler, os.X_OK):
            raise ValueError('Restauration par tuile : JDK compatible requis ; renseignez PZ_RESTORE_JAVAC.')
        self.javac = str(Path(compiler).resolve(strict=True))
        fd = os.environ.get('PZ_WORLD_LOCK_FD')
        self.pass_fds = () if not fd else (int(fd),)
        for inherited in self.pass_fds:
            os.fstat(inherited)
        version = self.run([str(self.java), '-version'], 'version')
        match = re.search(rb'version\s+"([0-9]+)', version)
        if not match or int(match[1]) < 17:
            raise ValueError('Version de la JVM de restauration indéterminée.')
        for name in ('media', 'stdlib.lua'):
            target = (install / name).resolve(strict=True)
            (self.root / name).symlink_to(target)
        classes = self.root / 'classes'
        classes.mkdir()
        self.classpath = str(self.jar) + os.pathsep + str(classes)
        self.run([self.javac, '--release', match[1].decode(), '-cp', str(self.jar), '-d', str(classes),
                  str(Path(__file__).with_name('IndexTerrainColumns.java'))], 'compile')
        self.sequence = 0

    def run(self, command, label):
        # subprocess.run kills/reaps its child on timeout or an interrupted
        # parent. The inherited world-lock FD also covers the native reader.
        try:
            result = subprocess.run(command, cwd=self.root, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    pass_fds=self.pass_fds, timeout=300)
        except subprocess.TimeoutExpired as error:
            raise ValueError('Lecture native du terrain trop longue ; monde inchangé.') from error
        (self.root / (label + '.log')).write_bytes(result.stdout)
        if result.returncode:
            raise ValueError(f'Validation native du terrain refusée ({label}, code {result.returncode}). '
                             f'Diagnostic privé : {self.root / (label + ".log")}')
        return result.stdout

    def index(self, files):
        # A successful subprocess and the right result count do not bind the
        # returned indexes to the exact bytes the caller is about to install.
        before = [hashlib.sha256(read_native_input(entry['file'])).hexdigest()
                  for entry in files]
        self.sequence += 1
        label = 'index-' + str(self.sequence)
        request = self.root / (label + '.json')
        response = self.root / (label + '-result.json')
        request.write_text(json.dumps(dict(self.script_context, dictionary=str(self.dictionary), chunks=files)))
        self.run([str(self.java), '-Xmx512m', '-cp', self.classpath, 'IndexTerrainColumns',
                  str(request), str(response)], label)
        try:
            indexes = json.loads(response.read_text())['chunks']
            if not isinstance(indexes, list) or len(indexes) != len(files):
                raise ValueError('Validation native du terrain incomplète.')
            for entry, expected, index in zip(files, before, indexes):
                data = read_native_input(entry['file'])
                if hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError('Terrain modifié pendant la validation native.')
                checked_columns(data, index)
        except (KeyError, TypeError, IndexError, OverflowError, struct.error) as error:
            raise ValueError('Résultat natif du terrain invalide.') from error
        return indexes

    def dictionaries(self, paths):
        request = self.root / 'dictionaries.json'
        response = self.root / 'dictionaries-result.json'
        request.write_text(json.dumps({'dictionaries': [str(Path(p).absolute()) for p in paths]}))
        self.run([str(self.java), '-Xmx512m', '-cp', self.classpath, 'IndexTerrainColumns',
                  str(request), str(response)], 'dictionaries')
        return json.loads(response.read_text())['dictionaries']


def prepare_partial(root, dictionary, entries):
    """Produce every partial chunk and revalidate before the first live write."""
    native = NativeIndexer(Path(root) / 'native', dictionary)
    inputs = []
    for entry in entries:
        for side in ('source', 'current'):
            inputs.append({'file': str(entry[side]), 'x': entry['x'], 'y': entry['y']})
    indexes = native.index(inputs)
    for n, entry in enumerate(entries):
        source = Path(entry['source']).read_bytes()
        current = Path(entry['current']).read_bytes()
        a, b = indexes[n * 2:n * 2 + 2]
        result = merge_columns(source, current, a, b, entry['selected'])
        Path(entry['output']).write_bytes(result)
    outputs = [{'file': str(e['output']), 'x': e['x'], 'y': e['y']} for e in entries]
    for n, (entry, index) in enumerate(zip(entries, native.index(outputs))):
        saved = checked_columns(Path(entry['source']).read_bytes(), indexes[2*n])
        before = checked_columns(Path(entry['current']).read_bytes(), indexes[2*n+1])
        wanted = set(entry['selected'])
        columns = [saved[i] if i in wanted else before[i] for i in range(64)]
        if checked_columns(Path(entry['output']).read_bytes(), index) != columns:
            raise ValueError('La relecture du terrain ne préserve pas exactement les tuiles prévues.')
