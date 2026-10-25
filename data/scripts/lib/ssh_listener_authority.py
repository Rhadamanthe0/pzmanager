"""Administrative OpenSSH listeners: kernel provenance, never a process name.

Read only. A coherent absence permits the protected -T fallback; uncertainty
refuses before the caller can mutate UFW. Linux proc/pidfd and systemd >=249.
"""
from contextlib import ExitStack
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import socket
import stat
import subprocess
import sys

PROC = Path('/proc')
SSHD = Path('/usr/sbin/sshd')
BUSCTL = Path('/usr/bin/busctl')
SYSTEM_BUS = Path('/run/dbus/system_bus_socket')
SYSTEMD = Path('/usr/lib/systemd/systemd')
MANAGER = 'org.freedesktop.systemd1'


class Unproven(ValueError):
    pass


def identity(fd):
    value = os.fstat(fd)
    return value.st_dev, value.st_ino


def protected(path):
    path = Path(path).resolve(strict=True)
    for part in (path, *path.parents):
        value = part.stat()
        if value.st_uid != 0 or value.st_mode & 0o022:
            raise Unproven('Provenance administrative non protégée')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    if not stat.S_ISREG(os.fstat(fd).st_mode) or identity(fd) != (path.stat().st_dev, path.stat().st_ino):
        os.close(fd)
        raise Unproven('Référence administrative remplacée')
    return fd


def uids(directory):
    values = [line.split()[1:] for line in (directory/'status').read_text().splitlines() if line.startswith('Uid:')]
    if len(values) != 1 or len(values[0]) != 4 or any(not value.isdecimal() for value in values[0]):
        raise Unproven('Identité kernel indéterminée')
    return tuple(map(int, values[0]))


def listeners():
    result = {}
    for family, filename in ((4, 'tcp'), (6, 'tcp6')):
        file = PROC/'net'/filename
        if family == 6 and not file.exists():
            continue
        for line in file.read_text().splitlines()[1:]:
            row = line.split()
            if len(row) < 10:
                raise Unproven('Table TCP kernel incomplète')
            if row[3] != '0A':
                continue
            address, port = row[1].split(':')
            raw = bytes.fromhex(address)
            raw = b''.join(raw[i:i+4][::-1] for i in range(0, len(raw), 4))
            local = str(ipaddress.ip_address(raw))
            inode, uid, port = int(row[9]), int(row[7]), int(port, 16)
            if not inode or not 1 <= port <= 65535 or inode in result:
                raise Unproven('Listener kernel ambigu')
            result[inode] = (family, local, port, uid)
    return result


def fd_sockets(directory, table):
    found = {}
    for fd in (directory/'fd').iterdir():
        try:
            link = os.readlink(fd)
        except FileNotFoundError:
            # Unrelated transient FDs (including proc scandir itself) need
            # not be sockets. Selected listener FDs are revalidated below.
            continue
        match = re.fullmatch(r'socket:\[([0-9]+)\]', link)
        if match and int(match[1]) in table:
            found[fd.name] = int(match[1])
    return found


def alive(pidfd):
    if select.select([pidfd], [], [], 0)[0]:
        raise Unproven('Processus disparu pendant la collecte')


def current_image(directory, stack):
    text = os.readlink(directory/'exe')
    if text.endswith(' (deleted)'):
        raise Unproven('Image vivante supprimée ; ancien SSH non exclu')
    actual = stack.enter_context(os.fdopen(os.open(directory/'exe', os.O_RDONLY | os.O_CLOEXEC), 'rb'))
    reference = stack.enter_context(os.fdopen(protected(text), 'rb'))
    if identity(actual.fileno()) != identity(reference.fileno()):
        raise Unproven('Image vivante différente de sa référence courante')
    return actual.fileno(), text


class SystemBus:
    def __init__(self, anchor):
        self.anchor = anchor
        self.cache = {}
        metadata=SYSTEM_BUS.stat()
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != 0:
            raise Unproven('Canal système non administratif')
        for parent in (*SYSTEM_BUS.parents,*SYSTEM_BUS.resolve(strict=True).parents):
            value=parent.stat()
            if value.st_uid!=0 or value.st_mode & 0o022:
                raise Unproven('Canal système remplaçable')
        self.owner = self.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetNameOwner', 's', MANAGER, signature='s')[0]
        if not isinstance(self.owner, str) or not re.fullmatch(r':[0-9]+\.[0-9]+', self.owner):
            raise Unproven('Propriétaire du gestionnaire système invalide')
        for method, expected in (('GetConnectionUnixProcessID', 1), ('GetConnectionUnixUser', 0)):
            value=self.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', method, 's', self.owner, signature='u')
            if type(value[0]) is not int or value != [expected]:
                raise Unproven('Gestionnaire système non authentifié')
        with ExitStack() as stack:
            fd, _ = current_image(PROC/'1', stack)
            reference = stack.enter_context(os.fdopen(protected(SYSTEMD), 'rb'))
            if uids(PROC/'1') != (0, 0, 0, 0) or identity(fd) != identity(reference.fileno()):
                raise Unproven('PID1 ne correspond pas au gestionnaire protégé')

    def query(self, args, signature):
        with os.fdopen(protected(BUSCTL), 'rb'):
            env = {k:v for k,v in os.environ.items() if k not in ('DBUS_SYSTEM_BUS_ADDRESS', 'DBUS_SESSION_BUS_ADDRESS')}
            raw = subprocess.check_output([str(BUSCTL), '--system', '--json=short', '--timeout=5', '--auto-start=no', '--', *args], env=env, text=True, stderr=subprocess.DEVNULL, timeout=6)
        if len(raw) > 1048576:
            raise Unproven('Métadonnées système excessives')
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {'type', 'data'} or value['type'] != signature:
            raise Unproven('Métadonnées système non typées')
        return value['data']

    def call(self, service, path, interface, method, *args, signature):
        value = self.query(['call', service, path, interface, method, *args], signature)
        if not isinstance(value, list) or len(value) != 1:
            raise Unproven('Cardinalité de réponse système invalide')
        return value

    def prop(self, path, interface, name, signature):
        key = (path, interface, name, signature)
        value = self.query(['get-property', self.owner, path, MANAGER+'.'+interface, name], signature)
        if key in self.cache and self.cache[key] != value:
            raise Unproven('Unité système modifiée pendant la collecte')
        self.cache[key] = value
        return value

    def unit(self, name):
        value = self.call(self.owner, '/org/freedesktop/systemd1', MANAGER+'.Manager', 'GetUnit', 's', name, signature='o')[0]
        if not isinstance(value, str) or not re.fullmatch(r'(?:/[A-Za-z0-9_]+)+', value):
            raise Unproven('Objet unité système invalide')
        return value

    def provenance(self, path):
        if self.prop(path, 'Unit', 'LoadState', 's') != 'loaded':
            raise Unproven('Unité système non chargée')
        fragment = self.prop(path, 'Unit', 'FragmentPath', 's')
        dropins = self.prop(path, 'Unit', 'DropInPaths', 'as')
        if not isinstance(fragment, str) or not fragment.startswith('/') or not isinstance(dropins, list) or any(not isinstance(p,str) or not p.startswith('/') for p in dropins):
            raise Unproven('Provenance unité système inconnue')
        for file in [fragment, *dropins]:
            os.close(protected(file))

    def service(self, path):
        self.provenance(path)
        user = self.prop(path, 'Service', 'User', 's')
        dynamic = self.prop(path, 'Service', 'DynamicUser', 'b')
        if not isinstance(user, str) or type(dynamic) is not bool:
            raise Unproven('Identité de service non typée')
        commands = self.prop(path, 'Service', 'ExecStart', 'a(sasbttttuii)')
        if not isinstance(commands, list) or len(commands) != 1:
            raise Unproven('Programme du service indéterminé')
        row = commands[0]
        if not isinstance(row,list) or len(row)!=10 or not isinstance(row[0],str) or not row[0].startswith('/') or not isinstance(row[1],list) or not row[1] or any(not isinstance(a,str) for a in row[1]) or type(row[2]) is not bool or any(type(n) is not int for n in row[3:]):
            raise Unproven('Commande du service non typée')
        with os.fdopen(protected(row[0]), 'rb') as image:
            is_ssh = identity(image.fileno()) == self.anchor
        if is_ssh and (user not in ('', 'root', '0') or dynamic):
            raise Unproven('Service SSH administratif non root')
        return is_ssh

    def units(self):
        rows = self.call(self.owner, '/org/freedesktop/systemd1', MANAGER+'.Manager', 'ListUnits', '', signature='a(ssssssouso)')[0]
        if not isinstance(rows,list) or len(rows)>16384:
            raise Unproven('Liste unités invalide')
        for row in rows:
            if not isinstance(row,list) or len(row)!=10 or any(not isinstance(row[i],str) for i in (0,1,2,3,4,5,6,8,9)) or type(row[7]) is not int or not re.fullmatch(r'(?:/[A-Za-z0-9_]+)+',row[6]):
                raise Unproven('Ligne unité non typée')
        return rows

    def ssh_attribution(self, pid):
        # Attribution is corroboration, not a requirement for manual/wrapper
        # programs. A service's live administrative PIDs can veto exclusion.
        for row in self.units():
            if row[0].endswith('.service') and row[3] in ('active','activating','deactivating'):
                for key in ('MainPID','ControlPID'):
                    value=self.prop(row[6],'Service',key,'u')
                    if type(value) is not int or not 0<=value<2**32:
                        raise Unproven('PID de service invalide')
                    if value==pid and self.service(row[6]):
                        return True
        return False

    def pid1_ports(self, table, inodes):
        rows = self.units()
        matches = {inode:[] for inode in inodes}
        for row in rows:
            if not isinstance(row,list) or len(row)!=10 or any(not isinstance(row[i],str) for i in (0,1,2,3,4,5,6,8,9)) or type(row[7]) is not int:
                raise Unproven('Ligne unité non typée')
            if not row[0].endswith('.socket') or row[3] != 'active':
                continue
            path = row[6]
            self.provenance(path)
            if self.prop(path,'Unit','ActiveState','s') != 'active':
                raise Unproven('Socket unité instable')
            listen = self.prop(path,'Socket','Listen','a(ss)')
            triggers = self.prop(path,'Unit','Triggers','as')
            if not isinstance(listen,list) or not isinstance(triggers,list) or any(not isinstance(t,str) for t in triggers):
                raise Unproven('Relations socket non typées')
            selected = []
            for entry in listen:
                if not isinstance(entry,list) or len(entry)!=2 or any(not isinstance(v,str) for v in entry):
                    raise Unproven('Endpoint socket invalide')
                kind, address = entry
                if kind != 'Stream' or non_tcp_stream(address):
                    continue
                endpoint = parse_endpoint(address)
                for inode in inodes:
                    if table[inode][:3] == endpoint:
                        selected.append(inode)
            if not selected:
                continue
            services = [t for t in triggers if t.endswith('.service')]
            if len(services)!=1 or len(triggers)!=1:
                raise Unproven('Service activé ambigu')
            is_ssh = self.service(self.unit(services[0]))
            for inode in selected:
                matches[inode].append(is_ssh)
        if any(len(value)!=1 for value in matches.values()):
            raise Unproven('Attribution PID1/socket absente ou multiple')
        return {table[inode][2] for inode,value in matches.items() if value == [True]}

    def revalidate(self):
        for path, interface, name, signature in list(self.cache):
            self.prop(path, interface, name, signature)
        if self.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetNameOwner', 's', MANAGER, signature='s') != [self.owner]:
            raise Unproven('Gestionnaire système remplacé')


def non_tcp_stream(text):
    # systemd 249 socket_address_print: Unix or AF_VSOCK Stream. Unknown
    # forms still reach the strict IP parser, never a catch-all exclusion.
    if text.startswith(('/', '@')):
        if len(text) == 1 or '\x00' in text:
            raise Unproven('Endpoint Unix invalide')
        return True
    # Empty CID is the official VMADDR_CID_ANY representation.
    match = re.fullmatch(r'vsock:([0-9]*):([0-9]+)', text)
    if match:
        if any(int(value) >= 2**32 for value in match.groups() if value):
            raise Unproven('Endpoint VSOCK invalide')
        return True
    return False

def parse_endpoint(text):
    match = re.fullmatch(r'\[([^]]+)\]:([0-9]+)|([^:]+):([0-9]+)', text)
    if not match:
        raise Unproven('Endpoint administratif non normalisé')
    address = ipaddress.ip_address(match[1] or match[3])
    port = int(match[2] or match[4])
    if not 1 <= port <= 65535:
        raise Unproven('Port administratif invalide')
    return address.version, str(address), port


def active_ports(anchor):
    table = listeners()
    ports, proved, records = set(), set(), []
    bus = SystemBus(anchor) if SYSTEM_BUS.exists() else None
    with ExitStack() as stack:
        for directory in sorted(PROC.iterdir()):
            if not directory.name.isdecimal():
                continue
            try:
                ids = uids(directory)
            except FileNotFoundError:
                continue
            if all(uid != 0 for uid in ids):
                continue
            try:
                pidfd = os.pidfd_open(int(directory.name))
            except ProcessLookupError:
                continue
            stack.callback(os.close, pidfd)
            procfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            stack.callback(os.close, procfd)
            pinned = Path('/proc/self/fd')/str(procfd)
            fds = fd_sockets(pinned, table)
            if not fds:
                continue
            alive(pidfd)
            if ids != (0,0,0,0) or uids(pinned) != ids or any(table[i][3] != 0 for i in fds.values()):
                raise Unproven('Identité administrative du listener contradictoire')
            own_ns=(PROC/'self/ns/net').stat()
            peer_ns=(pinned/'ns/net').stat()
            if (peer_ns.st_dev,peer_ns.st_ino)!=(own_ns.st_dev,own_ns.st_ino):
                raise Unproven('Namespace du listener incohérent')
            image, image_path = current_image(pinned, stack)
            if int(directory.name) == 1:
                if bus is None:
                    raise Unproven('Socket PID1 sans autorité système')
                ports.update(bus.pid1_ports(table, set(fds.values())))
            elif identity(image) == anchor:
                ports.update(table[inode][2] for inode in fds.values())
            else:
                # R is established independently above; a mismatch with SSH
                # alone never excludes an old/deleted executable.
                if Path(image_path).name.startswith('sshd') or (bus and bus.ssh_attribution(int(directory.name))):
                    raise Unproven('Ancienne image SSH ou attribution contradictoire')
            proved.update(fds.values())
            records.append((pidfd, pinned, ids, fds, image, identity(image), (peer_ns.st_dev,peer_ns.st_ino)))
        fresh = listeners()
        roots = {i:v for i,v in table.items() if v[3] == 0}
        if roots != {i:v for i,v in fresh.items() if v[3] == 0} or set(roots) - proved:
            raise Unproven('Collecte administrative incomplète ou instable')
        for pidfd, directory, ids, fds, image, reference, namespace in records:
            alive(pidfd)
            current_ns=(directory/'ns/net').stat()
            if uids(directory)!=ids or fd_sockets(directory, fresh)!=fds or identity(image)!=reference or (current_ns.st_dev,current_ns.st_ino)!=namespace:
                raise Unproven('Relation processus/socket modifiée')
            check, _ = current_image(directory, stack)
            if identity(check)!=reference:
                raise Unproven('Image remplacée pendant la collecte')
        if bus:
            bus.revalidate()
    return ports


def configured_ports(anchor_fd, config):
    with os.fdopen(protected(config),'rb') as configuration:
        configfd=configuration.fileno()
        result = subprocess.run([f'/proc/self/fd/{anchor_fd}', '-T', '-f', f'/proc/{os.getpid()}/fd/{configfd}'], pass_fds=(anchor_fd,configfd), capture_output=True, text=True, timeout=10, check=True)
    ports, endpoints = set(), set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0].lower() in ('port','listenaddress'):
            if len(fields)<2:
                raise Unproven('Configuration SSH effective incomplète')
            if fields[0].lower() == 'listenaddress':
                endpoints.add(parse_endpoint(fields[1])[2])
            elif re.fullmatch(r'[0-9]+',fields[1]) and 1<=int(fields[1])<=65535:
                ports.add(int(fields[1]))
            else:
                raise Unproven('Port SSH effectif invalide')
    if not endpoints and not ports:
        raise Unproven('Aucune écoute SSH effective')
    return endpoints or ports


def main(config):
    if SSHD.exists():
        with os.fdopen(protected(SSHD),'rb') as executable:
            anchor=identity(executable.fileno())
            ports = active_ports(anchor)
            if not ports:
                if not config.is_file():
                    raise Unproven('Configuration SSH administrative absente')
                ports = configured_ports(executable.fileno(), config)
            with os.fdopen(protected(SSHD),'rb') as current:
                if identity(current.fileno())!=anchor:
                    raise Unproven('Ancre SSH remplacée')
    else:
        active_ports(None)
        if config.exists() or config.is_symlink():
            raise Unproven('Binaire SSH administratif absent')
        ports = set()
    print('\n'.join(map(str, sorted(ports | {22}))))


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--config',type=Path,required=True)
    args=parser.parse_args()
    try:
        main(args.config)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('[ERROR] Autorité SSH non prouvée : '+str(error),file=sys.stderr)
        sys.exit(1)
