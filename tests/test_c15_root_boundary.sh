#!/usr/bin/env bash
# test_c15_root_boundary.sh - Frontiere root/utilisateur (C15).
# Echec sur ancien code (un `source` du .env executerait le touch),
# succes sur nouveau code (parsing declaratif uniquement).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_PARSE="$REPO_ROOT/data/scripts/lib/env_parse.sh"
SETUP_SYS="$REPO_ROOT/data/scripts/install/setupSystem.sh"
CONF_INIT="$REPO_ROOT/data/scripts/install/configurationInitiale.sh"
MARKER="/tmp/pz-root-pwned-c15"
TMP_ENV=""
ALIAS_ROOT=""

cleanup() {
    [[ -z "$ALIAS_ROOT" ]] || rm -rf "$ALIAS_ROOT"
    rm -f "$MARKER"
    [[ -n "$TMP_ENV" && -f "$TMP_ENV" ]] && rm -f "$TMP_ENV"
}
trap cleanup EXIT
rm -f "$MARKER"

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[OK] $*"; }

# (a) .env malicieux
TMP_ENV="$(mktemp)"
cat > "$TMP_ENV" <<'ENVEOF'
PZ_USER=pzmanager
MALICIOUS="$(touch /tmp/pz-root-pwned-c15)"
export PZ_PORT_GAME='16261"; touch /tmp/pz-root-pwned-c15; #'
ENVEOF

# (b) parsing declaratif : aucune execution
[[ -f "$ENV_PARSE" ]] || fail "env_parse.sh introuvable"
# shellcheck disable=SC1090
source "$ENV_PARSE"
declare -F parse_env_declarative >/dev/null || fail "parse_env_declarative absente"
# Env propre pour verifier l'export reel
unset PZ_USER PZ_PORT_GAME MALICIOUS || true
parse_env_declarative "$TMP_ENV" || fail "parse_env_declarative a echoue"
[[ ! -e "$MARKER" ]] || fail "execution shell detectee ($MARKER cree)"
[[ "${PZ_USER:-}" == "pzmanager" ]] || fail "PZ_USER=${PZ_USER:-<vide>} (attendu pzmanager)"
[[ "${PZ_PORT_GAME:-}" == "16261" ]] || fail "PZ_PORT_GAME=${PZ_PORT_GAME:-<vide>} (attendu 16261)"
[[ -z "${MALICIOUS:-}" ]] || fail "MALICIOUS aurait du etre ignore"
pass "parsing declaratif sans execution (PZ_USER=pzmanager, PZ_PORT_GAME=16261)"

# Business profile: declarative path references are resolved without a shell.
cat > "$TMP_ENV" <<'PROFILE'
PZ_MANAGER_DIR=/tmp/profile-manager
PZ_DATA_DIR="${PZ_MANAGER_DIR}/custom-data" # declarative comment
PZ_INSTALL_DIR="${PZ_DATA_DIR}/custom-game"
PZ_SOURCE_DIR="${PZ_MANAGER_DIR}/custom-world"
PZ_SERVICE_NAME='custom-test.service' # literal service
PZ_DB_PATH="${PZ_SOURCE_DIR}/db/servertest.db"
PZ_INI_PATH="${PZ_SOURCE_DIR}/Server/servertest.ini"
PROFILE
( unset INSTALL_MANAGER_ROOT; parse_env_declarative "$TMP_ENV"; [[ "$PZ_DATA_DIR" == /tmp/profile-manager/custom-data && "$PZ_INSTALL_DIR" == /tmp/profile-manager/custom-data/custom-game && "$PZ_SOURCE_DIR" == /tmp/profile-manager/custom-world && "$PZ_SERVICE_NAME" == custom-test.service && "$PZ_DB_PATH" == "$PZ_SOURCE_DIR/db/servertest.db" && "$PZ_INI_PATH" == "$PZ_SOURCE_DIR/Server/servertest.ini" ]] ) || fail 'profil métier perdu'
for setting in 'PZ_SOURCE_DIR="$(touch /tmp/pz-root-pwned-c15)"' 'PZ_SOURCE_DIR=${UNKNOWN}/world' "PZ_SOURCE_DIR='\${PZ_MANAGER_DIR}/literal-world'" 'PZ_SOURCE_DIR=relative' 'PZ_SERVICE_NAME=-bad.service' 'PZ_SERVICE_NAME=foo.socket' 'PZ_SERVER_NAME=${UNKNOWN}' 'PZ_SERVER_NAME=invalid/name'; do
    printf '%s\n' "$setting" > "$TMP_ENV"
    if ( parse_env_declarative "$TMP_ENV" ); then fail "profil invalide accepté : $setting"; fi
    [[ ! -e "$MARKER" ]] || fail 'profil exécuté'
done
# Real .env template expressions for the newly supported business paths.
ALIAS_ROOT="$(mktemp -d)"
mkdir "$ALIAS_ROOT/pzmanager"
( unset INSTALL_MANAGER_ROOT PZ_HOME PZ_MANAGER_DIR PZ_DATA_DIR PZ_INSTALL_DIR PZ_SOURCE_DIR PZ_DB_PATH PZ_INI_PATH;
  parse_env_declarative "$REPO_ROOT/data/setupTemplates/.env.example";
  [[ "$PZ_HOME" == /home/pzuser && "$PZ_MANAGER_DIR" == /home/pzuser/pzmanager && "$PZ_DATA_DIR" == /home/pzuser/pzmanager/data && "$PZ_INSTALL_DIR" == /home/pzuser/pzmanager/data/pzserver && "$PZ_SOURCE_DIR" == /home/pzuser/pzmanager/Zomboid && "$PZ_SERVICE_NAME" == zomboid.service ]] ) || fail 'expressions du template canonique perdues'
for setting in 'PZ_MANAGER_DIR=${UNKNOWN}' 'PZ_MANAGER_DIR=/tmp/other-manager' 'PZ_MANAGER_DIR=${PZ_MANAGER_DIR}' 'PZ_MANAGER_DIR='; do
    printf '%s\n' "$setting" > "$TMP_ENV"
    if ( INSTALL_MANAGER_ROOT="$ALIAS_ROOT/pzmanager"; parse_env_declarative "$TMP_ENV" ); then fail "alias manager divergent accepté : $setting"; fi
done
pass 'alias manager canonique résolu ; contradiction et alias non résolu refusés'
for assignment in 'PZ_SOURCE_DIR=/tmp/custom#world' 'PZ_SOURCE_DIR=/tmp/custom#world # comment' 'PZ_SOURCE_DIR="/tmp/custom#world" # comment'; do
    printf '%s\n' "$assignment" > "$TMP_ENV"
    ( parse_env_declarative "$TMP_ENV"; [[ "$PZ_SOURCE_DIR" == '/tmp/custom#world' ]] ) || fail 'caractère # littéral tronqué'
done
for assignment in 'PZ_SOURCE_DIR="/tmp/custom"#suffix' 'PZ_SOURCE_DIR=/tmp/custom world' 'PZ_SOURCE_DIR=/tmp/custom\#world'; do
    printf '%s\n' "$assignment" > "$TMP_ENV"
    if ( parse_env_declarative "$TMP_ENV" ); then fail "syntaxe ambiguë acceptée : $assignment"; fi
done
for assignment in 'PZ_SOURCE_DIR="/tmp/world\\cache"' 'PZ_SOURCE_DIR=/tmp/world|true' 'PZ_SOURCE_DIR=/tmp/world&true' 'PZ_SOURCE_DIR=/tmp/world>/tmp/other' 'PZ_SOURCE_DIR=/tmp/world</tmp/other' 'PZ_SOURCE_DIR=/tmp/world:~'; do
    printf '%s\n' "$assignment" > "$TMP_ENV"
    if ( parse_env_declarative "$TMP_ENV" ); then fail "syntaxe shell complexe acceptée : $assignment"; fi
done
pass 'chemins avec # littéral et commentaires séparés ; syntaxe ambiguë refusée'
pass 'profil métier résolu ; template, commentaires, injection et profils indéterminés contrôlés'

# parse_env_declarative ne doit jamais executer : pas de source/eval dans le helper
if grep -qE '(^|[^A-Za-z0-9_])(source|eval)([^A-Za-z0-9_]|$)' "$ENV_PARSE"; then
    fail "env_parse.sh contient source/eval"
fi
pass "env_parse.sh sans source/eval"

# (c) plus aucun chargement par execution du .env en contexte root
for f in "$SETUP_SYS" "$CONF_INIT"; do
    [[ -f "$f" ]] || fail "$f introuvable"
    # Lignes de code (hors commentaires #...) qui sourceraient le .env directement
    if grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:];])(source|\.)[[:space:]]+.*env_file'; then
        fail "$f charge encore env_file par execution shell"
    fi
    if grep -vE '^[[:space:]]*#' "$f" | grep -qE '^[[:space:]]*source_env([[:space:];]|$)'; then
        fail "$f appelle encore source_env en code (contexte root)"
    fi
done
pass "aucun source .env / source_env en contexte root"

# (d) permissions des helpers installes (si presents)
LIBEXEC="/usr/local/libexec/pzmanager"
if [[ -d "$LIBEXEC" ]]; then
    for h in "$LIBEXEC"/setupSystem.sh "$LIBEXEC"/configurationInitiale.sh "$LIBEXEC"/env_parse.sh; do
        [[ -e "$h" ]] || continue
        perms="$(stat -c %a "$h" 2>/dev/null || echo 000)"
        other="${perms: -1}"
        if (( other & 2 )); then
            fail "$h writable par autres (perms $perms)"
        fi
    done
    pass "helpers $LIBEXEC non-writable par autres"
else
    pass "helpers $LIBEXEC absents (install dev : controle saute)"
fi

rm -f "$MARKER"
echo "C15 ROOT BOUNDARY: OK"
