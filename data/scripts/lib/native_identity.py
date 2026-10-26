#!/usr/bin/env python3
"""Refuse identities changed by the native cachedir/servername arguments."""

# Java String.trim removes only edge code points <= U+0020, not Unicode spaces.
JAVA_TRIM = ''.join(map(chr, range(33)))


def validate_native_identity(source, server):
    if server != server.strip(JAVA_TRIM):
        raise ValueError('PZ_SERVER_NAME changes under native String.trim(); remove edge control characters/spaces')
    if source != source.replace('-cachedir=', '').strip(JAVA_TRIM):
        raise ValueError('PZ_SOURCE_DIR changes under native cachedir parsing; remove -cachedir= and edge control characters/spaces')


if __name__ == '__main__':
    import sys
    try:
        validate_native_identity(*sys.argv[1:])
    except ValueError as error:
        print('ERREUR: ' + str(error), file=sys.stderr)
        sys.exit(1)
