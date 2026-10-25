#!/usr/bin/env bash
# Métadonnées APT et mutations sont des doubles ; aucune installation ni Java.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?copie Linux jetable requise}"
fixture="$(mktemp -d)"; trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
export APT_FIXTURE_LOG="$fixture/calls"
cat > "$fixture/bin/apt-cache" <<'CACHE'
#!/bin/bash
printf 'cache locale=%s %s\n' "${LC_ALL:-}" "$*" >> "$APT_FIXTURE_LOG"
if [[ "$2" == openjdk-* && "$2" != openjdk-17-jre-headless ]]; then
    echo 'Candidate: (none)'
elif [[ "$2" == steamcmd && "${STEAM_CANDIDATE:-none}" == none ]]; then
    echo 'Candidate: (none)'
elif [[ "$2" == steamcmd && "${LC_ALL:-}" != C ]]; then
    printf 'Candidat : 1.0\n'
else
    printf 'Candidate: 1.0\n'
fi
CACHE
cat > "$fixture/bin/apt-get" <<'APT'
#!/bin/bash
printf 'apt %s\n' "$*" >> "$APT_FIXTURE_LOG"
[[ "$1" != install ]] || exit 73
APT
for command in dpkg debconf-set-selections; do
    cat > "$fixture/bin/$command" <<'BOUNDARY'
#!/bin/bash
printf 'boundary %s %s\n' "${0##*/}" "$*" >> "$APT_FIXTURE_LOG"
BOUNDARY
    chmod +x "$fixture/bin/$command"
done
chmod +x "$fixture/bin/apt-cache" "$fixture/bin/apt-get"
export PATH="$fixture/bin:$PATH" LANGUAGE=fr LC_ALL=fr_FR.UTF-8
for candidate in none present; do
    : > "$APT_FIXTURE_LOG"
    set +e
    STEAM_CANDIDATE="$candidate" bash -eu -c 'source "$1"; install_zomboid_dependencies' \
        "$ROOT/data/scripts/install/setupSystem.sh" "$ROOT/data/scripts/install/configurationInitiale.sh" > "$fixture/out" 2>&1
    status=$?
    set -e
    if [[ "$candidate" == none ]]; then
        [[ "$status" != 0 ]]
        grep -q 'steamcmd indisponible.*non-free.*multiverse' "$fixture/out" || {
            echo 'FAIL steamcmd absent sans diagnostic des dépôts avant apt-install.' >&2; cat "$APT_FIXTURE_LOG"; exit 1;
        }
        ! grep -q '^apt install' "$APT_FIXTURE_LOG"
    else
        [[ "$status" == 73 ]] || { echo 'FAIL faux refus steamcmd présent sous locale française.' >&2; cat "$fixture/out"; exit 1; }
        grep -q '^apt install.*steamcmd openjdk-17-jre-headless$' "$APT_FIXTURE_LOG"
        grep -q 'cache locale=C policy steamcmd' "$APT_FIXTURE_LOG"
    fi
    [[ "$LC_ALL" == fr_FR.UTF-8 && "$LANGUAGE" == fr ]]
done
echo 'OK steamcmd absent : diagnostic dépôts avant install ; candidat présent et locale française : apt-install doublé atteint, locale parent conservée.'
