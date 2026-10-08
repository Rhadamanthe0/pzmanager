#!/usr/bin/env bash
# test_sec_openfalse.sh - Admission verrouillée Open=false (068cd7b).
#
# Constat Codex Security (10/2026) : aucun code n'écrivait jamais Open= ;
# une installation existante restait Open=true, une fraîche dépendait du
# défaut du jeu — serveur ouvert malgré la doc whitelist.
# enforceClosedServer.sh (ExecStartPre BLOQUANT de zomboid.service) garantit
# Open=false sur tous les chemins de démarrage, sans toucher à la whitelist
# (le flux « whitelist dès la première connexion » est inchangé).
#
# Preuves réelles : vrai script, vrai .ini sandbox. Isolé : PZ_SOURCE_DIR
# sandbox, .env stubé (sauvegardé + restauré via trap). Sans flock/sqlite :
# exécutable partout.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/internal/enforceClosedServer.sh"
SERVICE="${ROOT}/data/setupTemplates/zomboid.service"
SANDBOX="${ROOT}/tests/.tmp-openfalse-$$"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"

cleanup() {
    if [[ -f "$ENV_BACKUP" ]]; then
        cp -p "$ENV_BACKUP" "$REPO_ENV"
    else
        rm -f "$REPO_ENV"
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/world"

export PZ_MANAGER_ROOT="$ROOT"
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test openfalse (restauré en fin de test)\n' > "$REPO_ENV"
export PZ_SOURCE_DIR="${SANDBOX}/world" PZ_SERVER_NAME="servertest"
INI="${PZ_SOURCE_DIR}/Server/servertest.ini"

run_enforce() { bash "$SCRIPT" >"${SANDBOX}/out.log" 2>&1; }

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
if grep -q '^ExecStartPre=%h/pzmanager/data/scripts/internal/enforceClosedServer.sh' "$SERVICE" \
    && ! grep -q '^-[^-]*enforceClosedServer' "$SERVICE"; then
    ok "ExecStartPre BLOQUANT (sans tiret) dans zomboid.service"
else
    ko "ExecStartPre enforce absent ou non-bloquant"
fi
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q 'allowedsteamid\|whitelist'; then
    ko "le script touche à la whitelist (hors commentaires)"
else
    ok "le script ne touche jamais à la whitelist"
fi

# --- (1) ini absent -> pré-ensemencé -------------------------------------------
echo "== (1) ini absent =="
if run_enforce; then
    grep -q '^Open=false$' "$INI" \
        && ok "ini absent : Open=false pré-ensemencé" \
        || ko "ini absent : Open=false manquant"
else
    ko "ini absent : exit non-zéro à tort"
fi

# --- (2) Open=true -> réparé ----------------------------------------------------
echo "== (2) Open=true =="
printf 'ServerName=servertest\nOpen=true\nMaxPlayers=32\n' > "$INI"
if run_enforce; then
    grep -q '^Open=false$' "$INI" && grep -q '^MaxPlayers=32$' "$INI" \
        && ok "Open=true réparé, autres clés intactes" \
        || ko "Open=true : contenu inattendu"
else
    ko "Open=true : exit non-zéro à tort"
fi

# --- (3) Open=false -> inchangé --------------------------------------------------
echo "== (3) Open=false =="
avant="$(sha256sum "$INI" | cut -d' ' -f1)"
if run_enforce; then
    [[ "$(sha256sum "$INI" | cut -d' ' -f1)" == "$avant" ]] \
        && ok "Open=false : fichier inchangé" \
        || ko "Open=false : fichier réécrit à tort"
else
    ko "Open=false : exit non-zéro à tort"
fi

# --- (4) clé absente -> ajoutée ---------------------------------------------------
echo "== (4) sans clé Open =="
printf 'ServerName=servertest\nMaxPlayers=32\n' > "$INI"
if run_enforce; then
    grep -q '^Open=false$' "$INI" && grep -q '^MaxPlayers=32$' "$INI" \
        && ok "clé absente : Open=false ajouté, reste intact" \
        || ko "clé absente : contenu inattendu"
else
    ko "clé absente : exit non-zéro à tort"
fi

# --- (5) ini non inscriptible -> die ----------------------------------------------
echo "== (5) non inscriptible =="
rm -rf "${SANDBOX}/world"
touch "${SANDBOX}/world"
if run_enforce; then
    ko "ini bloqué : exit 0 à tort (serveur démarrerait ouvert)"
else
    ok "ini bloqué : die fail-closed (exit $?)"
fi
rm -f "${SANDBOX}/world"

echo ""
if (( FAIL == 0 )); then
    echo "SEC OPENFALSE: OK (${PASS} contrôles)"
else
    echo "SEC OPENFALSE: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
