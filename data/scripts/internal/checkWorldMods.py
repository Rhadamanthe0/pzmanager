#!/usr/bin/env python3
"""Check a proposed mod list against the saved world's client script registry."""
import argparse
import json
from pathlib import Path
import sys

from configureWritingTextOnly import StaticTableParser, Token, lex, string_key
from cleanWritingDrawings import read_file


def tables(text):
    source = lex(text)
    tokens = []
    # PZ's readable dump uses `0 = ...` for indexed sections. Normalize that
    # display syntax into static bracket keys, without executing any Lua.
    for i, token in enumerate(source):
        if token.kind == 'number' and i + 1 < len(source) and source[i + 1].kind == '=':
            tokens.extend([Token('[', '[', token.start, token.start), token,
                           Token(']', ']', token.end, token.end)])
        else:
            tokens.append(token)
    parser = StaticTableParser(tokens)
    result = {}
    while parser.peek() is not None:
        name = parser.take('identifier').value
        parser.take('=')
        value = parser.table()
        if name in result:
            raise ValueError('Duplicate world dictionary section: ' + name)
        result[name] = value
        if parser.peek() is not None and parser.peek().kind == ';':
            parser.take(';')
        # B42's exporter emits one extra closing brace after `strings`.
        if name == 'strings' and parser.peek() is not None and parser.peek().kind == '}':
            parser.take('}')
    return result


def field(record, key, kinds):
    if record.kind != 'table':
        raise ValueError('Unsupported dictionary record')
    value = record.entries.get(key)
    if value is None or value.kind not in kinds:
        raise ValueError('World dictionary field ' + key + ' is missing or has an unsupported type')
    return value


def identity(text, record, key):
    value = field(record, key, ('string',))
    result = string_key(text[value.start:value.end])
    if not result.strip():
        raise ValueError('World dictionary field ' + key + ' must be a nonempty string')
    return result


def flag(record, key):
    # Un état inconnu n'est pas un état « non chargé » : refuser avant mutation.
    return field(record, key, ('true', 'false')).kind == 'true'


def check(dictionary, ini):
    # ConfigFile.read du jeu retire les espaces en début/fin de ligne
    # avant d'interpréter la clé : ne pas ignorer une seconde ligne indentée.
    lines = [line.strip() for line in read_file(Path(ini)).decode('utf-8').splitlines()]
    lists = [line.split('=', 1)[1] for line in lines if line.startswith('Mods=')]
    if len(lists) != 1:
        raise ValueError('Expected exactly one Mods= line')
    enabled = {mod.strip().lstrip('\\') for mod in lists[0].split(';')}
    path = Path(dictionary)
    if not path.exists():
        if path.is_symlink() or (path.parent/'players.db').exists() or any(path.parent.glob('*.bin')) or (path.parent/'map').exists():
            raise ValueError('Saved world lacks a readable dictionary; cannot assess removal')
        return {'required_missing': {}, 'historical_missing': {}}
    text = read_file(path).decode('utf-8')
    sections = tables(text)
    if not {'items', 'entities', 'scripts'} <= sections.keys():
        raise ValueError('Unsupported world dictionary; cannot assess removal')
    owners = {}
    historical = {}
    available = set()
    for section in ('items', 'entities'):
        for record in sections[section].entries.values():
            name = identity(text, record, 'fulltype')
            mod = identity(text, record, 'modID')
            modded = flag(record, 'isModded')
            if mod == 'pz-vanilla' or mod in enabled:
                available.add(name)
                continue
            if not modded:
                continue
            historical.setdefault(mod, set()).add(name)
            owners.setdefault(name, set()).add(mod)
    required = {}
    for register in sections['scripts'].entries.values():
        if register.kind != 'table':
            raise ValueError('Unsupported client script register')
        for record in register.entries.values():
            name = identity(text, record, 'name')
            if not flag(record, 'isLoaded'):
                continue
            if name in available:
                continue
            if name not in owners:
                raise ValueError('Loaded client script has no assessable dictionary owner: ' + name)
            for mod in owners[name]:
                required.setdefault(mod, set()).add(name)
    return {key: {mod: sorted(names) for mod, names in sorted(values.items())}
            for key, values in [('required_missing', required), ('historical_missing', historical)]}


def require_compatible(dictionary, ini):
    report = check(dictionary, ini)
    if report['required_missing']:
        details = '; '.join(mod + ': ' + ', '.join(names[:3])
                            for mod, names in report['required_missing'].items())
        raise ValueError('Mod removal refused: saved client scripts require ' + details
                         + '. Restore these mods or migrate the world before removal.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dictionary', required=True)
    parser.add_argument('--ini', required=True, help='Current or proposed server INI')
    args = parser.parse_args()
    try:
        report = check(args.dictionary, args.ini)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1 if report['required_missing'] else 0
    except (OSError, ValueError, UnicodeError) as error:
        print('World mod check refused: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
