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

cleanup() {
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
    if grep -vE '^[[:space:]]*#' "$f" | grep -q 'source_env'; then
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
