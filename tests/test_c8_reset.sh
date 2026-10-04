#!/usr/bin/env bash
# test_c8_reset.sh - Reset via staging + PID exact + rollback (C8).
#
# Couvre (data/scripts/admin/resetServer.sh uniquement) :
#   (0) câblage statique : staging mktemp -d sous PZ_HOME (Zomboid.new.*),
#       traps EXIT + INT/TERM (nettoient générateur + staging), PID exact
#       ($! puis kill PID / kill -- groupe), vérification cmdline cachedir
#       staging exact avant kill, aucun pkill/pgrep large au nom,
#       validation staging (DB + admin + Server/.ini), rollback_live,
#       bascule mv -T (ou copie), OLD jamais supprimé, ordre main
#       (staging -> génération -> validation/swap).
#   (1) génération échouée (mock start-server exit 1) -> die, live restauré
#       depuis OLD (rollback auto, OLD conservé), staging nettoyé.
#   (2) timeout (mock jamais crée DB) -> die, pas de bascule (live intact,
#       aucune trace staging dans live).
#   (3) SIGTERM pendant génération -> générateur tué (PID exact), staging
#       nettoyé, live ou OLD récupérable.
#   (4) homonyme (ProjectZomboid64-like, autre cachedir) non tué par
#       kill_generator_exact ; vrai générateur (cachedir staging exact) tué.
#
# Preuves réelles : vraies fonctions EXTRAITES du script (awk, aucun duplicata
# de logique), vrais mv/cp/rm/kill, mock start-server.sh via PZ_INSTALL_DIR,
# mocks pgrep/pkill/sqlite3 via PATH (enregistreurs : tout appel large au nom
# est détecté). Isolé : PZ_HOME + PZ_SOURCE_DIR sous sandbox (aucun monde
# réel, aucun .env touché : common.sh sourcée sans source_env). Limite : le
# main complet n'est pas rejoué (pz.sh stop/start réels exclus) — l'ordre est
# prouvé statiquement (0) et chaque étape fonctionnellement (1)-(4).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/admin/resetServer.sh"
LIB_DIR="${ROOT}/data/scripts/lib"
SANDBOX="${ROOT}/tests/.tmp-c8-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    local rc=$?
    # Strays best-effort (générateurs/homonymes éventuels).
    pkill -P $$ sleep 2>/dev/null || true
    rm -rf "$SANDBOX"
    exit "$rc"
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------
if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] script introuvable : $SCRIPT" >&2
    exit 1
fi
if [[ ! -d /proc ]]; then
    echo "[SKIP-local] /proc absent — test C8 à exécuter sous Linux/WSL." >&2
    exit 0
fi

# --- Vraie lib (die/log/generate_password) sans source_env -------------------
# shellcheck disable=SC1090
source "${LIB_DIR}/common.sh"

# --- Extraction des vraies fonctions depuis la cible (aucune copie) ----------
extract_func() { awk "/^$1\(\) \{/,/^\}/" "$SCRIPT"; }
EVAL_FILE="${SANDBOX:-/tmp}/extracted.sh"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX" "$BIN"
{
    extract_func step
    extract_func generator_cmdline_matches
    extract_func kill_generator_exact
    extract_func cleanup_reset_staging
    extract_func backup_current
    extract_func generate_world
    extract_func validate_staging_world
    extract_func rollback_live
    extract_func swap_staging_to_live
} > "$EVAL_FILE"
for fn in step generator_cmdline_matches kill_generator_exact \
          cleanup_reset_staging backup_current generate_world \
          validate_staging_world rollback_live swap_staging_to_live; do
    grep -q "^${fn}() {" "$EVAL_FILE" || { echo "[FAIL] extraction de ${fn} impossible" >&2; exit 1; }
done
# shellcheck disable=SC1090
source "$EVAL_FILE"

# --- Mocks -------------------------------------------------------------------
# sqlite3 : COUNT admin piloté par MOCK_ADMIN_PRESENT (1 si DB existe) ; le
# reste sort 0. Tout appel est journalisé.
cat > "${BIN}/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "sqlite3 $*" >> "${MOCK_SQLITE_LOG:-/dev/null}"
db="${1:-}"; sql="${2:-}"
if [[ "$sql" == *"username = 'admin'"* ]]; then
    if [[ "${MOCK_ADMIN_PRESENT:-1}" == "1" && -f "$db" ]]; then echo 1; else echo 0; fi
    exit 0
fi
if [[ "$sql" == *"COUNT("* ]]; then echo 2; exit 0; fi
exit 0
MOCKEOF
chmod +x "${BIN}/sqlite3"
# pgrep/pkill : enregistreurs. Le code C8 ne doit JAMAIS les appeler avec un
# pattern large (tout appel est une faute).
cat > "${BIN}/pgrep" <<'MOCKEOF'
#!/usr/bin/env bash
echo "pgrep $*" >> "${MOCK_PGREP_LOG:-/dev/null}"
exit 1
MOCKEOF
chmod +x "${BIN}/pgrep"
cat > "${BIN}/pkill" <<'MOCKEOF'
#!/usr/bin/env bash
echo "pkill $*" >> "${MOCK_PKILL_LOG:-/dev/null}"
exit 0
MOCKEOF
chmod +x "${BIN}/pkill"
export PATH="${BIN}:$PATH"
export MOCK_SQLITE_LOG="${SANDBOX}/sqlite.log"
export MOCK_PGREP_LOG="${SANDBOX}/pgrep.log"
export MOCK_PKILL_LOG="${SANDBOX}/pkill.log"
: > "$MOCK_SQLITE_LOG"; : > "$MOCK_PGREP_LOG"; : > "$MOCK_PKILL_LOG"

# --- Helpers -----------------------------------------------------------------
# make_live <racine> <marqueur> : monde plausible marqué.
make_live() {
    local root="$1" mark="$2"
    mkdir -p "$root/Saves/Multiplayer/world1" "$root/Server" "$root/db"
    echo "${mark}-players" > "$root/Saves/Multiplayer/world1/players.db"
    echo "${mark}-map" > "$root/Saves/Multiplayer/world1/map.bin"
    echo "${mark}-ini" > "$root/Server/servertest.ini"
    echo "${mark}-sandbox" > "$root/Server/servertest_SandboxVars.lua"
    echo "${mark}-spawnpoints" > "$root/Server/servertest_spawnpoints.lua"
    echo "${mark}-spawnregions" > "$root/Server/servertest_spawnregions.lua"
    echo "${mark}-db" > "$root/db/servertest.db"
}
LIVE=""; HOME_DIR=""; INSTALL_DIR=""; OLD_DIR=""
# fresh_case <nom> : LIVE (marqueur LIVE) + env sandbox, mocks réinitialisés.
fresh_case() {
    local name="$1"
    LIVE="${SANDBOX}/live-${name}"
    HOME_DIR="${SANDBOX}/home-${name}"
    INSTALL_DIR="${SANDBOX}/install-${name}"
    rm -rf "$LIVE" "$HOME_DIR" "$INSTALL_DIR"
    mkdir -p "$HOME_DIR" "$INSTALL_DIR"
    make_live "$LIVE" "LIVE"
    export PZ_SOURCE_DIR="$LIVE" PZ_HOME="$HOME_DIR" PZ_INSTALL_DIR="$INSTALL_DIR"
    export PZ_SERVER_NAME="servertest" PZ_USER="$(id -un)"
    export PZ_DB_PATH="${LIVE}/db/servertest.db"
    OLD_DIR="${HOME_DIR}/OLD/Zomboid_OLD_${name}"
    export OLD_DIR
    STAGING_DIR=""; GENERATOR_PID=""; STAGING_CACHEDIR=""
    export STAGING_DIR GENERATOR_PID STAGING_CACHEDIR
    STEP=0; OPT_KEEP_CONFIG=false; OPT_KEEP_WHITELIST=false
    export STEP OPT_KEEP_CONFIG OPT_KEEP_WHITELIST
    export PZ_RESET_MAX_WAIT=10 PZ_RESET_ADMIN_WAIT=4
    export PZ_RESET_POLL_INTERVAL=1 PZ_RESET_EARLY_GRACE=2
    export MOCK_GEN_MODE=success MOCK_GEN_DELAY=1 MOCK_ADMIN_PRESENT=1
    : > "$MOCK_SQLITE_LOG"; : > "$MOCK_PGREP_LOG"; : > "$MOCK_PKILL_LOG"
    # Mock start-server.sh via PZ_INSTALL_DIR (lu par generate_world).
    cat > "${INSTALL_DIR}/start-server.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cachedir=""
for a in "$@"; do case "$a" in -cachedir=*) cachedir="${a#-cachedir=}";; esac; done
echo "start-server cachedir=${cachedir} mode=${MOCK_GEN_MODE:-success}" >> "${MOCK_START_LOG:-/dev/null}"
case "${MOCK_GEN_MODE:-success}" in
    fail) exit 1 ;;
    hang) sleep 60; exit 0 ;;
    success)
        mkdir -p "${cachedir}/db" "${cachedir}/Server" "${cachedir}/Saves/Multiplayer/world1" 2>/dev/null || true
        sleep "${MOCK_GEN_DELAY:-1}"
        echo "STAGING-db" > "${cachedir}/db/servertest.db" 2>/dev/null || true
        echo "STAGING-ini" > "${cachedir}/Server/servertest.ini" 2>/dev/null || true
        echo "STAGING-players" > "${cachedir}/Saves/Multiplayer/world1/players.db" 2>/dev/null || true
        sleep 60
        exit 0
        ;;
esac
MOCKEOF
    chmod +x "${INSTALL_DIR}/start-server.sh"
    export MOCK_START_LOG="${SANDBOX}/start-${name}.log"
    : > "$MOCK_START_LOG"
}
live_marker() { cat "$LIVE/Saves/Multiplayer/world1/players.db" 2>/dev/null || echo "(absent)"; }
live_db() { cat "$LIVE/db/servertest.db" 2>/dev/null || echo "(absent)"; }
old_marker() { cat "${OLD_DIR}/Saves/Multiplayer/world1/players.db" 2>/dev/null || echo "(absent)"; }
staging_left() { find "$HOME_DIR" -maxdepth 1 -name 'Zomboid.new.*' 2>/dev/null | wc -l | tr -d ' '; }
no_large_kill() {
    if grep -q "ProjectZomboid" "$MOCK_PGREP_LOG" 2>/dev/null \
        || grep -q "ProjectZomboid" "$MOCK_PKILL_LOG" 2>/dev/null; then
        return 1
    fi
    return 0
}

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'mktemp -d "${PZ_HOME}/Zomboid.new.' "$SCRIPT" \
    && ok "staging mktemp -d sous PZ_HOME (Zomboid.new.*)" \
    || ko "staging mktemp sous PZ_HOME absent"
grep -q 'trap cleanup_reset_staging EXIT' "$SCRIPT" \
    && ok "trap EXIT (nettoie générateur + staging)" \
    || ko "trap EXIT absent"
grep -q "trap 'cleanup_reset_staging; exit 143' INT TERM" "$SCRIPT" \
    && ok "trap INT/TERM (interruption nettoyée)" \
    || ko "trap INT/TERM absent"
grep -q 'GENERATOR_PID=$!' "$SCRIPT" \
    && ok "PID exact capturé (\$!)" \
    || ko "capture \$! absente"
grep -q 'kill -TERM "$pid"' "$SCRIPT" && grep -q 'kill -- "-${pid}"' "$SCRIPT" \
    && ok "kill PID puis groupe (PID exact)" \
    || ko "kill PID/groupe absent"
grep -q 'generator_cmdline_matches' "$SCRIPT" && grep -q -- '-cachedir=${cachedir}' "$SCRIPT" \
    && ok "vérification cmdline cachedir staging exact avant kill" \
    || ko "vérification cmdline absente"
if grep -qE '(^|[^_a-zA-Z])(pgrep|pkill)[[:space:]]+(-[0-9]|-[a-z]*f)' "$SCRIPT"; then
    ko "kill large au nom encore présent (pgrep/pkill)"
else
    ok "aucun kill large au nom (pgrep/pkill)"
fi
grep -q 'validate_staging_world' "$SCRIPT" \
    && ok "validation staging présente" \
    || ko "validate_staging_world absent"
grep -q "SELECT COUNT(\*) FROM whitelist WHERE username = 'admin'" "$SCRIPT" \
    && ok "validation admin présente" \
    || ko "validation admin absente"
grep -q 'Server/${PZ_SERVER_NAME}.ini' "$SCRIPT" \
    && ok "validation .ini/Server présente" \
    || ko "validation .ini absente"
grep -q 'rollback_live' "$SCRIPT" \
    && ok "rollback auto présent" \
    || ko "rollback_live absent"
grep -q 'mv -T "${STAGING_DIR}" "${PZ_SOURCE_DIR}"' "$SCRIPT" \
    && ok "bascule staging→live (mv -T)" \
    || ko "bascule mv -T absente"
if grep -q 'rm -rf.*OLD' "$SCRIPT"; then
    ko "OLD supprimé quelque part (doit être conservé)"
else
    ok "OLD jamais supprimé (conservé jusqu'à finalize OK)"
fi
main_body="$(sed -n '/^main()/,/^}/p' "$SCRIPT")"
line_of() { grep -n "$1" <<<"$main_body" | head -1 | cut -d: -f1; }
l_stage="$(line_of 'mktemp -d "${PZ_HOME}/Zomboid.new')"; l_gen="$(line_of 'generate_world')"
l_swap="$(line_of 'swap_staging_to_live')"
if [[ -n "$l_stage" && -n "$l_gen" && -n "$l_swap" ]] \
    && (( l_stage < l_gen && l_gen < l_swap )); then
    ok "ordre main : staging créé puis généré puis basculé (validé)"
else
    ko "ordre main incorrect (staging=$l_stage gen=$l_gen swap=$l_swap)"
fi

# --- (1) génération échouée ------------------------------------------------------
echo "== (1) génération échouée =="
fresh_case fail
export MOCK_GEN_MODE=fail
backup_current
STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")"
STAGING_CACHEDIR="${STAGING_DIR}"
if ( generate_world ) 2>"${SANDBOX}/gen-fail.log"; then
    ko "génération fail : succès à tort"; cat "${SANDBOX}/gen-fail.log" | sed 's/^/  [out] /'
else
    ok "génération fail : die (exit $?)"
fi
kill_generator_exact 2>/dev/null || true
cleanup_reset_staging 2>/dev/null || true
rollback_live >/dev/null 2>&1 || true
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "génération fail : live intact (marqueur LIVE)" \
    || ko "génération fail : live altéré (marqueur: $(live_marker))"
[[ "$(live_db)" == "LIVE-db" ]] \
    && ok "génération fail : DB live d'origine (pas de bascule)" \
    || ko "génération fail : DB live altérée ($(live_db))"
if [[ -d "$OLD_DIR" ]] && [[ "$(old_marker)" == "LIVE-players" ]]; then
    ok "génération fail : OLD conservé (sans perte)"
else
    ko "génération fail : OLD manquant ou altéré"
fi
(( $(staging_left) == 0 )) && ok "génération fail : staging nettoyé" || ko "génération fail : staging résiduel"
no_large_kill && ok "génération fail : aucun kill large au nom" || ko "génération fail : pgrep/pkill large appelé"

# --- (2) timeout -----------------------------------------------------------------
echo "== (2) timeout =="
fresh_case hang
export MOCK_GEN_MODE=hang
backup_current
STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")"
STAGING_CACHEDIR="${STAGING_DIR}"
if ( generate_world ) 2>"${SANDBOX}/gen-hang.log"; then
    ko "timeout : succès à tort"; cat "${SANDBOX}/gen-hang.log" | sed 's/^/  [out] /'
else
    ok "timeout : die (exit $?)"
fi
grep -q "Timeout" "${SANDBOX}/gen-hang.log" \
    && ok "timeout : cause imputée au timeout" \
    || { ko "timeout : cause non identifiée"; sed 's/^/  [out] /' "${SANDBOX}/gen-hang.log"; }
kill_generator_exact 2>/dev/null || true
cleanup_reset_staging 2>/dev/null || true
rollback_live >/dev/null 2>&1 || true
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "timeout : live intact (pas de bascule)" \
    || ko "timeout : live altéré (marqueur: $(live_marker))"
if grep -rq "STAGING-db" "$LIVE" 2>/dev/null; then
    ko "timeout : trace staging dans live (bascule à tort)"
else
    ok "timeout : aucune trace staging dans live"
fi
(( $(staging_left) == 0 )) && ok "timeout : staging nettoyé" || ko "timeout : staging résiduel"
no_large_kill && ok "timeout : aucun kill large au nom" || ko "timeout : pgrep/pkill large appelé"

# --- (3) SIGTERM ------------------------------------------------------------------
echo "== (3) SIGTERM =="
fresh_case term
export MOCK_GEN_MODE=success MOCK_GEN_DELAY=1
STAGING_TERM="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")"
(
    STAGING_DIR="$STAGING_TERM"; STAGING_CACHEDIR="$STAGING_TERM"
    GENERATOR_PID=""
    trap cleanup_reset_staging EXIT
    trap 'cleanup_reset_staging; exit 143' INT TERM
    "${PZ_INSTALL_DIR}/start-server.sh" -cachedir="$STAGING_TERM" \
        -servername "$PZ_SERVER_NAME" -adminpassword x <<< "x" >/dev/null 2>&1 &
    GENERATOR_PID=$!
    echo "$GENERATOR_PID" > "${SANDBOX}/term-gen.pid"
    sleep 30
) &
TPID=$!
sleep 3
GENPID="$(cat "${SANDBOX}/term-gen.pid" 2>/dev/null || echo "")"
if [[ -z "$GENPID" ]] || ! kill -0 "$GENPID" 2>/dev/null; then
    ko "SIGTERM : générateur non démarré (précondition)"
else
    ok "SIGTERM : générateur démarré (PID exact $GENPID)"
fi
kill -TERM "$TPID" 2>/dev/null || true
if wait "$TPID" 2>/dev/null; then
    ko "SIGTERM : exit 0 (attendu non-zéro)"
else
    ok "SIGTERM : interrompu (non-zéro)"
fi
sleep 1
if [[ -n "$GENPID" ]] && kill -0 "$GENPID" 2>/dev/null; then
    ko "SIGTERM : générateur toujours vivant (PID exact non tué)"
    kill -KILL "$GENPID" 2>/dev/null || true
else
    ok "SIGTERM : générateur tué (PID exact)"
fi
[[ -d "$STAGING_TERM" ]] && ko "SIGTERM : staging résiduel" || ok "SIGTERM : staging nettoyé"
live_n="$(find "$LIVE" -type f 2>/dev/null | wc -l | tr -d ' ')"
old_n="0"; [[ -d "$HOME_DIR/OLD" ]] && old_n="$(find "$HOME_DIR/OLD" -type f 2>/dev/null | wc -l | tr -d ' ')"
if (( live_n > 0 )) || (( old_n > 0 )); then
    ok "SIGTERM : live ou OLD récupérable (live=${live_n} fichiers, OLD=${old_n} fichiers)"
else
    ko "SIGTERM : live ET OLD vides/absents"
fi

# --- (4) homonyme ------------------------------------------------------------------
echo "== (4) homonyme =="
fresh_case homo
export MOCK_GEN_MODE=success MOCK_GEN_DELAY=1
STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")"
STAGING_CACHEDIR="${STAGING_DIR}"
bash -c 'exec -a ProjectZomboid64 sleep 60' &
HOMOPID=$!
sleep 0.3
if ! kill -0 "$HOMOPID" 2>/dev/null; then
    ko "homonyme : précondition (processus non démarré)"
else
    "${PZ_INSTALL_DIR}/start-server.sh" -cachedir="$STAGING_DIR" \
        -servername "$PZ_SERVER_NAME" -adminpassword x <<< "x" >/dev/null 2>&1 &
    GENERATOR_PID=$!
    sleep 2
    if ! kill -0 "$GENERATOR_PID" 2>/dev/null; then
        ko "homonyme : générateur non démarré (précondition)"
        kill -KILL "$HOMOPID" 2>/dev/null || true
    else
        kill_generator_exact 2>/dev/null || true
        sleep 0.5
        if kill -0 "$HOMOPID" 2>/dev/null; then
            ok "homonyme : processus au nom ressemblant (autre cachedir) toujours vivant"
        else
            ko "homonyme : processus au nom ressemblant TUÉ à tort"
        fi
        if kill -0 "$GENERATOR_PID" 2>/dev/null; then
            ko "homonyme : vrai générateur non tué"
            kill -KILL "$GENERATOR_PID" 2>/dev/null || true
        else
            ok "homonyme : vrai générateur tué (PID exact, cachedir staging exact)"
        fi
        kill -KILL "$HOMOPID" 2>/dev/null || true
        wait "$HOMOPID" 2>/dev/null || true
    fi
fi
cleanup_reset_staging 2>/dev/null || true
no_large_kill && ok "homonyme : aucun kill large au nom" || ko "homonyme : pgrep/pkill large appelé"

# --- (5) succès nominal ------------------------------------------------------------
echo "== (5) succès =="
fresh_case ok
export MOCK_GEN_MODE=success MOCK_GEN_DELAY=1 MOCK_ADMIN_PRESENT=1
backup_current
STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")"
STAGING_CACHEDIR="${STAGING_DIR}"
if ( generate_world ) 2>"${SANDBOX}/gen-ok.log"; then
    ok "succès : génération exit 0"
else
    ko "succès : génération échec à tort"; sed 's/^/  [out] /' "${SANDBOX}/gen-ok.log"
fi
kill_generator_exact 2>/dev/null || true
if validate_staging_world "$STAGING_DIR"; then
    ok "succès : staging validé (DB + admin + .ini/Server)"
else
    ko "succès : staging invalide à tort"
fi
swap_staging_to_live
[[ "$(live_marker)" == "STAGING-players" && "$(live_db)" == "STAGING-db" ]] \
    && ok "succès : live basculé depuis staging" \
    || { ko "succès : live non basculé (marker=$(live_marker) db=$(live_db))"; sed 's/^/  [out] /' "${SANDBOX}/gen-ok.log"; }
if [[ -d "$OLD_DIR" ]] && [[ "$(old_marker)" == "LIVE-players" ]]; then
    ok "succès : OLD conservé (live d'origine)"
else
    ko "succès : OLD absent ou altéré"
fi
(( $(staging_left) == 0 )) && ok "succès : staging nettoyé (basculé)" || ko "succès : staging résiduel"
no_large_kill && ok "succès : aucun kill large au nom" || ko "succès : pgrep/pkill large appelé"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C8 RESET STAGING: OK (${PASS} contrôles)"
else
    echo "C8 RESET STAGING: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
