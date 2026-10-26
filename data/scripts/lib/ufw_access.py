"""Prove exact inbound access from UFW's C-locale declarative output.

Unknown syntax or a relevant restriction refuses the complete plan before UFW
writes. No rule text is executed; inactive rules come from `ufw show added`.
"""
import re
import ipaddress
from pathlib import Path
import shlex
import sys


def configured_families(defaults, state):
    # UFW itself accepts bare or double-quoted yes/no at column zero. Refuse
    # extensions (inline comments, shell syntax) that its backend may read
    # differently, rather than claiming a family it will not configure.
    values = set()
    # The backend reads both files; an override must not silently disagree.
    for path in (defaults, state):
        for line in path.read_text().splitlines():
            if not re.match(r'^\s*IPV6\b', line, re.IGNORECASE):
                continue
            match = re.fullmatch(r'IPV6=(yes|no|"yes"|"no")[ \t]*', line)
            if not match:
                raise ValueError('Configuration UFW IPV6 inconnue')
            values.add(match[1].strip('"'))
    if len(values) != 1:
        raise ValueError('Configuration UFW IPV6 absente ou contradictoire')
    if values == {'yes'}:
        if not Path("/proc/sys/net/ipv6").is_dir():
            raise ValueError('UFW IPv6 activé mais capacité noyau non prouvée')
        return {4, 6}
    return {4}


def endpoint(value):
    if value.lower() in ('any', 'anywhere'):
        return None, None
    if value in ('any/tcp', 'any/udp'):
        return None, value.split('/')[1]
    match = re.fullmatch(r'([0-9,:]+)(?:/(tcp|udp))?', value)
    if not match:
        raise ValueError('Destination UFW non interprétable : ' + value)
    spans = []
    for part in match[1].split(','):
        bounds = [int(n) for n in part.split(':')]
        if len(bounds) not in (1, 2) or not all(1 <= n <= 65535 for n in bounds) or bounds[0] > bounds[-1]:
            raise ValueError('Port UFW invalide : ' + value)
        spans.append((bounds[0], bounds[-1]))
    return spans, match[2]


def numbered(text):
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line in ('Status: active', 'To                         Action      From') or re.fullmatch(r'[-\s]+', line):
            continue
        if re.fullmatch(r'To\s+Action\s+From', line):
            continue
        match = re.fullmatch(r'\[\s*\d+\]\s*(.*?)\s+(ALLOW|LIMIT|DENY|REJECT)\s+(IN|OUT|FWD)\s+(.+)', line.split('#', 1)[0].strip())
        if not match:
            raise ValueError('État UFW non reconnu : ' + line)
        target, action, direction, source = match.groups()
        family = 6 if '(v6)' in target else 4
        target = target.replace(' (v6)', '')
        source = re.sub(r' \(log(?:-all)?\)$', '', source).replace(' (v6)', '')
        interface = ' on ' in target
        target = target.split(' on ', 1)[0]
        rows.append((target, action, direction, source != 'Anywhere' or interface, family))
    return rows


def added(text):
    lines = text.splitlines()
    if not lines or lines[0] != "Added user rules (see 'ufw status' for running firewall):":
        raise ValueError('Règles UFW persistées non reconnues')
    rows = []
    for line in lines[1:]:
        if not line.strip() or line.strip() == '(None)':
            continue
        tokens = shlex.split(line)
        if len(tokens) < 3 or tokens[0] != 'ufw' or tokens[1] not in ('allow', 'limit', 'deny', 'reject'):
            raise ValueError('Règle UFW persistée non reconnue : ' + line)
        action, tokens = tokens[1].upper(), tokens[2:]
        if 'comment' in tokens:
            index = tokens.index('comment')
            if len(tokens[index:]) != 2:
                raise ValueError('Commentaire UFW invalide')
            tokens = tokens[:index]
        direction = 'IN'
        if tokens and tokens[0] in ('in', 'out'):
            direction, tokens = tokens[0].upper(), tokens[1:]
        if tokens and tokens[0] in ('log', 'log-all'):
            tokens = tokens[1:]
        restricted = False
        explicit_families = set()
        if len(tokens) == 1:
            target = tokens[0]
        else:
            target, proto = 'any', None
            while tokens:
                key, tokens = tokens[0], tokens[1:]
                if not tokens:
                    raise ValueError('Règle UFW incomplète')
                value, tokens = tokens[0], tokens[1:]
                if key == 'on':
                    restricted = True
                elif key == 'proto' and value in ('tcp', 'udp'):
                    proto = value
                elif key in ('from', 'to'):
                    restricted |= value != 'any'
                    if value != 'any':
                        explicit_families.add(ipaddress.ip_network(value, strict=False).version)
                    if tokens and tokens[0] == 'port':
                        if len(tokens) < 2:
                            raise ValueError('Port UFW absent')
                        if key == 'to':
                            target = tokens[1]
                        else:
                            restricted = True
                        tokens = tokens[2:]
                else:
                    raise ValueError('Règle UFW ambiguë : ' + line)
            if proto:
                target += '/' + proto
        if len(explicit_families) > 1:
            raise ValueError('Familles UFW persistées contradictoires')
        rows.append((target, action, direction, restricted, next(iter(explicit_families), 0)))
    return rows


def missing(status, persisted, requested, families):
    if families not in ({4}, {4, 6}):
        raise ValueError('Familles UFW non prouvées')
    first = status.splitlines()[0] if status.splitlines() else ''
    if first not in ('Status: active', 'Status: inactive'):
        raise ValueError('Statut UFW inconnu')
    rows = numbered(status) if first == 'Status: active' else added(persisted)
    if any(family and family not in families for *_, family in rows):
        raise ValueError('ACL UFW incompatible avec la configuration IPV6')
    needed = []
    for wanted in requested:
        port_text, proto = wanted.split('/')
        port = int(port_text)
        if not 1 <= port <= 65535 or proto not in ('tcp', 'udp'):
            raise ValueError('Accès demandé invalide : ' + wanted)
        covered = set()
        for target, action, direction, restricted, family in rows:
            if direction != 'IN':
                continue
            # A global ALLOW application profile is harmless but cannot prove
            # an exact numeric endpoint; restrictive/unknown profiles refuse.
            if action == 'ALLOW' and not restricted and re.fullmatch(r'[A-Za-z][A-Za-z0-9 _-]*', target) and target.lower() not in ('any', 'anywhere'):
                continue
            spans, rule_proto = endpoint(target)
            if rule_proto not in (None, proto) or (spans is not None and not any(a <= port <= b for a, b in spans)):
                continue
            if action in ('DENY', 'REJECT') or restricted or (action == 'LIMIT' and (spans != [(port, port)] or rule_proto != proto)):
                raise ValueError('ACL entrante restrictive pour ' + wanted + ' : arbitrage requis, aucune règle modifiée')
            if spans == [(port, port)] and rule_proto == proto:
                covered.add(family)
        if 0 in covered:
            # Unqualified persisted commands apply to the configured backend
            # families, independently of which ACLs happen to exist today.
            covered.remove(0)
            covered.update(families)
        if covered and covered != families:
            raise ValueError('Autorisation UFW partielle IPv4/IPv6 : ' + wanted)
        if not covered:
            needed.append(wanted)
    return needed


if __name__ == '__main__':
    try:
        status, persisted = sys.stdin.read().split('\n--PERSISTED--\n', 1)
        families = configured_families(Path("/etc/default/ufw"), Path("/etc/ufw/ufw.conf"))
        print('\n'.join(missing(status, persisted, sys.argv[1:], families)))
    except (ValueError, IndexError, OSError) as error:
        print('[ERROR] ' + str(error), file=sys.stderr)
        sys.exit(2)
