#!/usr/bin/env bash
# test_c4_purge.sh - Purge fail-closed transactionnelle (C4).
#
# Couvre (purgeInactivePlayers.sh uniquement) :
#   (0) câblage statique : sql_or_die (aucun `|| echo 0/1`, aucun SELECT masqué),
#       BEGIN IMMEDIATE/COMMIT + sqlite3 -bail, fichier SQL via mktemp, trap
#       EXIT/INT/TERM, snapshot dataBackup.sh --snapshot-only --required,
#       garde orphelin NOT EXISTS intra-transaction.
#   (1) erreur SELECT (table whitelist absente) -> exit != 0, rien supprimé,
#       snapshot même pas tenté.
#   (2a) base verrouillée EXCLUSIVE par un écrivain concurrent -> die (plan
#       illisible), rien supprimé.
#   (2b) base en BEGIN IMMEDIATE concurrent (lectures OK, écriture bloquée) ->
#       die à la transaction, rien supprimé (snapshot --required tenté avant).
#   (3) snapshot impossible (mock dataBackup exit 1) -> exit != 0, rien supprimé.
#   (4) erreur DELETE (trigger ABORT sur un compte) -> ROLLBACK, aucun partiel
#       (le 1er de la liste n'est PAS supprimé).
#   (5) chemin nominal + SteamID partagé : 2 comptes même sid, un seul inactif ->
#       victime retirée, sid CONSERVÉ ; sid orphelin désautorisé ; compte sans
#       steamid retiré ; 'admin' et jamais-connecté épargnés ; comptes exacts.
#   (6) liste vide -> exit 0, snapshot non appelé, base inchangée.
#   (7) SIGTERM avant écriture (sleep injecté PZ_PURGE_TEST_SLEEP) -> exit != 0,
#       rien supprimé, pas de .sql résiduel, verrou libéré (relance OK).
#   (8) témoin ancien code (HEAD, copie isolée) sur le cas (4) -> succès partiel
#       (prouve que le test (4) détecte le défaut corrigé, pas un vacuité).
#   (9) couverture démarreur (C1xC2xC4) : verrou tenu par un processus distinct
#       + unité activating (systemctl mocké) + dataBackup --snapshot-only sans
#       --required rendant BACKUP_SKIPPED_LOCK exit 0 -> filet local
#       <db>.pre-purge-<ts> (présent, non vide, integrity_check=ok, image
#       fidèle d'avant purge), snapshot SANS --required, purge poursuit (état
#       nominal exact).
#   (10) hors couverture (verrou tenu, unité inactive) -> die franc, rien
#       supprimé, aucun filet local ; (10b) erreur snapshot réelle (exit 1)
#       sous couverture -> die aussi (filet réservé au BACKUP_SKIPPED_LOCK).
#   (11) pseudo hostile (pipe + saut de ligne avec tentative d'injection SQL)
#       -> die fail-closed AVANT toute requête, base inchangée.
#
# Preuves réelles : vrai script purgeInactivePlayers.sh, vraies bases SQLite
# (fichiers), vrai flock via lib C1, vraies transactions. Seules parties
# simulées (explicites) : dataBackup.sh via la couture PZ_DATABACKUP_BIN
# (mock qui journalise ses args, exit piloté — le chemin --required est celui
# de production) et le délai pré-écriture PZ_PURGE_TEST_SLEEP (0 en production).
# Isolé : XDG_RUNTIME_DIR sandbox, .env stubé (sauvegardé + restauré via trap),
# WHITELIST_LEDGER sandbox, PZ_DB_PATH sandbox. Sans sqlite3/flock -> SKIP.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/admin/purgeInactivePlayers.sh"
SANDBOX="${ROOT}/tests/.tmp-c4-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"
ENV_STUBBED=false
HOLDER_PID=""

cleanup() {
    if [[ -n "${HOLDER_PID:-}" ]]; then kill "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""; fi
    pkill -P $$ sleep 2>/dev/null || true
    if [[ "$ENV_STUBBED" == true ]]; then
        if [[ -f "$ENV_BACKUP" ]]; then
            cp -p "$ENV_BACKUP" "$REPO_ENV"
        else
            rm -f "$REPO_ENV"
        fi
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible — test C4 à exécuter sous Linux/WSL." >&2
    exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[SKIP-local] sqlite3 indisponible (requis par le projet lui-même : require_sqlite)." >&2
    exit 0
fi
if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] script introuvable : $SCRIPT" >&2
    exit 1
fi

# --- Isolation ---------------------------------------------------------------
rm -rf "$SANDBOX"
mkdir -p "${SANDBOX}/rt" "$BIN"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
    PZ_WORLD_LOCK_DEPTH=0; PZ_WORLD_LOCK_FD=""
    export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
fi
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C4 (restauré en fin de test)\n' > "$REPO_ENV"
ENV_STUBBED=true

# --- Mock dataBackup (couture PZ_DATABACKUP_BIN du script) --------------------
# Journalise ses arguments (preuve du --required) dans $MOCK_CALLS_LOG,
# sort avec $MOCK_DATABACKUP_EXIT (0 = snapshot OK).
cat > "${BIN}/dataBackup-mock.sh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "MOCK_DATABACKUP $*" >> "${MOCK_CALLS_LOG:?non défini}"
if [[ "${MOCK_DATABACKUP_SKIPLOCK:-0}" == "1" ]]; then
    echo "BACKUP_SKIPPED_LOCK /fake/world.lock — run ignoré (opération monde en cours)."
    exit 0
fi
exit "${MOCK_DATABACKUP_EXIT:-0}"
MOCKEOF
chmod +x "${BIN}/dataBackup-mock.sh"
export PZ_DATABACKUP_BIN="${BIN}/dataBackup-mock.sh"

# --- Helpers -----------------------------------------------------------------
DB=""
fresh_case() {
    local name="$1"
    DB="${SANDBOX}/db-${name}.db"
    rm -f "$DB"
    export PZ_DB_PATH="$DB"
    export WHITELIST_LEDGER="${SANDBOX}/ledger-${name}.csv"
    rm -f "$WHITELIST_LEDGER" "${SANDBOX}/calls-${name}.log"
    export MOCK_CALLS_LOG="${SANDBOX}/calls-${name}.log"
    unset MOCK_DATABACKUP_EXIT PZ_PURGE_TEST_SLEEP MOCK_DATABACKUP_SKIPLOCK || true
    export MOCK_DATABACKUP_EXIT=0
    RECENT="$(date '+%F %T')"
}
OLD='2020-01-01 00:00:00'
RECENT=""
# Fixture : admin épargné (nom) ; alice victime orpheline ; bob victime partageant
# sid-shared avec carol (gardée, récente) ; dave victime sans steamid ; newbie
# jamais connecté et hors registre (épargné) ; sid-foreign sans whitelist.
mk_fixture() {
    sqlite3 "$DB" "CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT, steamid TEXT, lastConnection TEXT);"
    sqlite3 "$DB" "CREATE TABLE allowedsteamid(steamid TEXT PRIMARY KEY);"
    sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection) VALUES
        (1,'admin','sid-admin','$OLD'),
        (2,'alice','sid-alice','$OLD'),
        (3,'bob','sid-shared','$OLD'),
        (4,'carol','sid-shared','$RECENT'),
        (5,'dave','','$OLD'),
        (6,'newbie',NULL,NULL);"
    sqlite3 "$DB" "INSERT INTO allowedsteamid(steamid) VALUES ('sid-alice'),('sid-shared'),('sid-foreign');"
}
db_state() {
    sqlite3 "$DB" "SELECT 'W:' || id || '|' || username || '|' || COALESCE(steamid,'<null>') || '|' || COALESCE(lastConnection,'<null>') FROM whitelist ORDER BY id;"
    sqlite3 "$DB" "SELECT 'A:' || steamid FROM allowedsteamid ORDER BY steamid;"
}
run_purge() { bash "$SCRIPT" --force --days 30 >"${SANDBOX}/out.log" 2>&1; }
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }
calls() { cat "$MOCK_CALLS_LOG" 2>/dev/null || true; }
start_holder() {
    ( printf 'BEGIN %s;\n' "$1"; sleep 25 ) | sqlite3 "$DB" >/dev/null 2>&1 &
    HOLDER_PID=$!
    sleep 1
    kill -0 "$HOLDER_PID" 2>/dev/null || { ko "holder $1 : détenteur mort"; return 1; }
}
stop_holder() {
    if [[ -n "${HOLDER_PID:-}" ]]; then kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""; fi
}

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'sql_or_die' "$SCRIPT" \
    && ok "helper sql_or_die présent" \
    || ko "sql_or_die absent"
if grep -q '|| echo "1"' "$SCRIPT" || grep -q '|| echo "0"' "$SCRIPT"; then
    ko "masquage || echo 0/1 encore présent"
else
    ok "aucun || echo 0/1 (erreurs non masquées)"
fi
# (hors commentaires qui citent l'historique du défaut ; les `|| true` de
# nettoyage best-effort ne décident de rien et sont exclus : seul un sqlite3
# masqué est un SELECT masqué)
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qE 'sqlite3[^|]*2>/dev/null'; then
    ko "appel sqlite3 masqué (2>/dev/null)"
else
    ok "aucun appel sqlite3 masqué"
fi
grep -q 'BEGIN IMMEDIATE' "$SCRIPT" && grep -q 'COMMIT' "$SCRIPT" \
    && ok "transaction unique BEGIN IMMEDIATE ... COMMIT" \
    || ko "transaction unique absente"
grep -q 'sqlite3 -bail' "$SCRIPT" \
    && ok "sqlite3 -bail (stop au 1er échec, pas de COMMIT partiel)" \
    || ko "sqlite3 -bail absent"
grep -q 'mktemp' "$SCRIPT" \
    && ok "fichier SQL via mktemp" \
    || ko "mktemp absent"
grep -q "trap 'purge_cleanup; exit" "$SCRIPT" && grep -q 'trap purge_cleanup EXIT' "$SCRIPT" \
    && ok "trap EXIT/INT/TERM (cleanup + release lock)" \
    || ko "trap interruption absent"
grep -q -- '--snapshot-only --required' "$SCRIPT" \
    && ok "snapshot dataBackup.sh --snapshot-only --required (C2)" \
    || ko "--snapshot-only --required absent"
grep -q 'NOT EXISTS' "$SCRIPT" \
    && ok "garde orphelin NOT EXISTS intra-transaction (SteamID partagé)" \
    || ko "garde NOT EXISTS absente"
if grep -q 'WARNING: échec suppression' "$SCRIPT" || grep -q 'WARNING: snapshot' "$SCRIPT"; then
    ko "WARNING+continue encore présent (non fail-closed)"
else
    ok "aucun WARNING+continue (fail-closed)"
fi
if grep -q 'DELETE FROM whitelist WHERE id = ' "$SCRIPT"; then
    ko "ancienne boucle de DELETE unitaires encore présente"
else
    ok "plus de DELETE unitaire en boucle"
fi

# --- (1) erreur SELECT (table absente) ------------------------------------------
echo "== (1) SELECT en erreur =="
fresh_case sel
sqlite3 "$DB" "CREATE TABLE other(x); INSERT INTO other VALUES (1);"
before="$(sha256sum "$DB" | cut -d' ' -f1)"
if run_purge; then
    ko "table absente : exit 0 (attendu échec)"; show_out
else
    ok "table absente : échec (exit $?)"
fi
after="$(sha256sum "$DB" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && ok "table absente : base inchangée" || ko "table absente : base modifiée"
[[ -f "$MOCK_CALLS_LOG" ]] && { ko "table absente : snapshot tenté à tort"; } || ok "table absente : snapshot jamais tenté"
grep -q 'fail-closed' "${SANDBOX}/out.log" && ok "table absente : message fail-closed" || { ko "table absente : pas de mention fail-closed"; show_out; }

# --- (2a) verrou EXCLUSIVE concurrent --------------------------------------------
echo "== (2a) base verrouillée EXCLUSIVE =="
fresh_case excl
mk_fixture
before="$(db_state)"
start_holder EXCLUSIVE
if run_purge; then rc=0; else rc=$?; fi
stop_holder
(( rc != 0 )) && ok "EXCLUSIVE : die (exit $rc)" || { ko "EXCLUSIVE : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "EXCLUSIVE : comptes restants exacts (0 suppression)" || { ko "EXCLUSIVE : base modifiée"; show_out; }
[[ -f "$MOCK_CALLS_LOG" ]] && { ko "EXCLUSIVE : snapshot tenté malgré SELECT impossible"; } || ok "EXCLUSIVE : mort avant snapshot (aucun DELETE possible)"

# --- (2b) BEGIN IMMEDIATE concurrent (écriture bloquée) ----------------------------
echo "== (2b) écriture bloquée (RESERVED) =="
fresh_case resv
mk_fixture
before="$(db_state)"
start_holder IMMEDIATE
if run_purge; then rc=0; else rc=$?; fi
stop_holder
(( rc != 0 )) && ok "RESERVED : die à la transaction (exit $rc)" || { ko "RESERVED : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "RESERVED : comptes restants exacts (0 suppression)" || { ko "RESERVED : base modifiée"; show_out; }
if grep -q -- '--required' "$MOCK_CALLS_LOG" 2>/dev/null; then
    ok "RESERVED : snapshot --required tenté AVANT l'échec d'écriture"
else
    ko "RESERVED : snapshot --required non tenté"; show_out
fi

# --- (3) snapshot impossible -------------------------------------------------------
echo "== (3) snapshot impossible =="
fresh_case snap
mk_fixture
export MOCK_DATABACKUP_EXIT=1
before="$(db_state)"
if run_purge; then rc=0; else rc=$?; fi
(( rc != 0 )) && ok "snapshot KO : die (exit $rc)" || { ko "snapshot KO : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "snapshot KO : comptes restants exacts (0 suppression)" || { ko "snapshot KO : base modifiée"; show_out; }
if grep -q -- '--snapshot-only --required' "$MOCK_CALLS_LOG" 2>/dev/null; then
    ok "snapshot KO : tentative --snapshot-only --required journalisée"
else
    ko "snapshot KO : appel --required non journalisé"; show_out
fi

# --- (4) erreur DELETE -> ROLLBACK --------------------------------------------------
echo "== (4) DELETE en erreur (trigger) =="
fresh_case trig
mk_fixture
sqlite3 "$DB" "CREATE TRIGGER purge_guard BEFORE DELETE ON whitelist WHEN OLD.username='bob' BEGIN SELECT RAISE(ABORT,'C4-test-boom'); END;"
before="$(db_state)"
if run_purge; then rc=0; else rc=$?; fi
(( rc != 0 )) && ok "trigger : die (exit $rc)" || { ko "trigger : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "trigger : ROLLBACK, aucun partiel (alice intacte)" || { ko "trigger : état partiel !"; show_out; }
grep -q 'ROLLBACK' "${SANDBOX}/out.log" && ok "trigger : ROLLBACK annoncé" || { ko "trigger : ROLLBACK non annoncé"; show_out; }

# --- (5) nominal + SteamID partagé ----------------------------------------------------
echo "== (5) nominal + sid partagé =="
fresh_case happy
mk_fixture
if run_purge; then
    ok "nominal : exit 0"
else
    ko "nominal : échec à tort"; show_out
fi
expected="W:1|admin|sid-admin|$OLD
W:4|carol|sid-shared|$RECENT
W:6|newbie|<null>|<null>
A:sid-foreign
A:sid-shared"
[[ "$(db_state)" == "$expected" ]] && ok "nominal : comptes restants exacts (alice/bob/dave retirés, sid-shared conservé, sid-alice désautorisé)" || { ko "nominal : état inattendu :"; db_state | sed 's/^/  [db] /'; }
grep -q 'Purge terminée : 3 compte(s) retiré(s), 1 SteamID désautorisé(s)' "${SANDBOX}/out.log" \
    && ok "nominal : compteurs exacts 3/1 (changes())" \
    || { ko "nominal : compteurs inexacts"; show_out; }
grep -q -- '--snapshot-only --required' "$MOCK_CALLS_LOG" 2>/dev/null \
    && ok "nominal : snapshot --required effectué" \
    || { ko "nominal : snapshot --required absent"; show_out; }
if ls /tmp/pz-purge-*.sql >/dev/null 2>&1; then
    leftovers="$(ls /tmp/pz-purge-*.sql 2>/dev/null | wc -l | tr -d ' ')"
    ko "nominal : ${leftovers} fichier(s) SQL résiduel(s) sous /tmp"
else
    ok "nominal : aucun .sql résiduel sous /tmp"
fi

# --- (6) liste vide -------------------------------------------------------------------
echo "== (6) liste vide =="
fresh_case empty
sqlite3 "$DB" "CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT, steamid TEXT, lastConnection TEXT);"
sqlite3 "$DB" "CREATE TABLE allowedsteamid(steamid TEXT PRIMARY KEY);"
sqlite3 "$DB" "INSERT INTO whitelist VALUES (1,'admin','sid-admin','$OLD'),(4,'carol','sid-shared','$RECENT');"
before="$(db_state)"
if run_purge; then
    ok "vide : exit 0"
else
    ko "vide : échec à tort"; show_out
fi
grep -q 'Aucun compte inactif' "${SANDBOX}/out.log" && ok "vide : message attendu" || { ko "vide : message absent"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "vide : base inchangée" || ko "vide : base modifiée"
[[ -f "$MOCK_CALLS_LOG" ]] && { ko "vide : snapshot appelé pour rien"; } || ok "vide : aucun snapshot (exit avant)"

# --- (7) SIGTERM avant écriture ----------------------------------------------------------
echo "== (7) interruption SIGTERM =="
fresh_case term
mk_fixture
export PZ_PURGE_TEST_SLEEP=15
before="$(db_state)"
bash "$SCRIPT" --force --days 30 >"${SANDBOX}/out.log" 2>&1 &
TPID=$!
for _i in $(seq 1 200); do [[ -f "$MOCK_CALLS_LOG" ]] && break; sleep 0.1; done
if ! [[ -f "$MOCK_CALLS_LOG" ]]; then
    ko "SIGTERM : la purge n'a pas atteint le snapshot (pré-requis du test)"
    kill "$TPID" 2>/dev/null || true
else
    sleep 1
    kill -TERM "$TPID" 2>/dev/null || true
    if wait "$TPID" 2>/dev/null; then rc=0; else rc=$?; fi
    (( rc != 0 )) && ok "SIGTERM : exit $rc (jamais un succès)" || ko "SIGTERM : exit 0 malgré interruption"
    [[ "$(db_state)" == "$before" ]] && ok "SIGTERM : rien supprimé (pas de partiel)" || { ko "SIGTERM : base modifiée"; show_out; }
fi
wait 2>/dev/null || true
unset PZ_PURGE_TEST_SLEEP
if ls /tmp/pz-purge-*.sql >/dev/null 2>&1; then
    ko "SIGTERM : .sql résiduel sous /tmp"
else
    ok "SIGTERM : aucun .sql résiduel"
fi
# Verrou libéré par le trap : une relance aboutit.
if run_purge; then
    ok "SIGTERM : verrou libéré (relance OK)"
else
    ko "SIGTERM : relance impossible (verrou ?)"
fi
# expected figé en (5) utilisait le RECENT du cas happy ; fresh_case term a
# recalculé RECENT à la seconde -> reconstruire (flake si la seconde a changé).
expected="W:1|admin|sid-admin|$OLD
W:4|carol|sid-shared|$RECENT
W:6|newbie|<null>|<null>
A:sid-foreign
A:sid-shared"
[[ "$(db_state)" == "$expected" ]] && ok "SIGTERM : relance = état nominal exact" || { ko "SIGTERM : état après relance inattendu"; show_out; }

# --- (9) couverture démarreur (C1xC2xC4) -------------------------------------------
# Reproduit l'ExecStartPre réel : un processus DISTINCT (le « démarreur ») tient
# le verrou monde (fd non hérité : pas de participation), l'unité est en
# « activating » (systemctl mocké via PATH), et dataBackup --snapshot-only
# (sans --required, impossible sous couverture) rend BACKUP_SKIPPED_LOCK exit 0.
# Attendu : filet local <db>.pre-purge-<ts> (présent, non vide, intègre, image
# fidèle d'avant purge), snapshot tenté SANS --required, puis la purge poursuit
# (exit 0, état nominal exact).
echo "== (9) couverture démarreur (C1xC2xC4) =="
cat > "${BIN}/systemctl" <<'SYSEOF'
#!/usr/bin/env bash
# Mock systemctl minimal : seuls `show` (lu par server_state) et `is-active`
# (lu par server_is_active) sont simulés, pilotés par MOCK_ACTIVE_STATE.
if [[ "${1:-}" == "--user" ]]; then shift; fi
case "${1:-}" in
    show) printf 'ActiveState=%s\nSubState=active\nResult=success\n' "${MOCK_ACTIVE_STATE:-inactive}"; exit 0 ;;
    is-active) [[ "${MOCK_ACTIVE_STATE:-inactive}" == "active" ]] && exit 0 || exit 3 ;;
esac
exit 0
SYSEOF
chmod +x "${BIN}/systemctl"
PATH_SAVED="$PATH"
export PATH="${BIN}:$PATH"
hold_world_lock() {
    WORLD_LOCKF="${XDG_RUNTIME_DIR}/pzmanager/world.lock"
    mkdir -p "$(dirname "$WORLD_LOCKF")"
    flock "$WORLD_LOCKF" sleep 60 &
    WORLD_HOLDER_PID=$!
    for _i in $(seq 1 50); do
        if flock -n "$WORLD_LOCKF" true 2>/dev/null; then sleep 0.1; else break; fi
    done
    kill -0 "$WORLD_HOLDER_PID" 2>/dev/null || { ko "holder monde : détenteur mort"; return 1; }
    if flock -n "$WORLD_LOCKF" true 2>/dev/null; then ko "holder monde : verrou non tenu"; return 1; fi
}
release_world_lock_holder() {
    if [[ -n "${WORLD_HOLDER_PID:-}" ]]; then kill "$WORLD_HOLDER_PID" 2>/dev/null || true; wait "$WORLD_HOLDER_PID" 2>/dev/null || true; WORLD_HOLDER_PID=""; fi
}
fb_state() {
    sqlite3 "$1" "SELECT 'W:' || id || '|' || username || '|' || COALESCE(steamid,'<null>') || '|' || COALESCE(lastConnection,'<null>') FROM whitelist ORDER BY id;"
    sqlite3 "$1" "SELECT 'A:' || steamid FROM allowedsteamid ORDER BY steamid;"
}
fresh_case cover
export MOCK_ACTIVE_STATE=activating MOCK_DATABACKUP_SKIPLOCK=1
mk_fixture
before="$(db_state)"
hold_world_lock
if run_purge; then rc=0; else rc=$?; fi
release_world_lock_holder
(( rc == 0 )) && ok "couverture : exit 0 (filet local, la purge poursuit)" || { ko "couverture : échec à tort (rc=$rc)"; show_out; }
if grep -q -- '--snapshot-only' "$MOCK_CALLS_LOG" 2>/dev/null && ! grep -q -- '--required' "$MOCK_CALLS_LOG" 2>/dev/null; then
    ok "couverture : snapshot tenté SANS --required (chemin ExecStartPre)"
else
    ko "couverture : appel snapshot inattendu"; show_out
fi
fb_matches=( "${DB}".pre-purge-* )
if (( ${#fb_matches[@]} == 1 )) && [[ -s "${fb_matches[0]}" ]] \
    && [[ "$(sqlite3 "${fb_matches[0]}" 'PRAGMA integrity_check;')" == "ok" ]]; then
    ok "couverture : filet local ${fb_matches[0]##*/} présent, non vide, intègre"
else
    ko "couverture : filet local absent ou invalide"; show_out
fi
if [[ -e "${fb_matches[0]}" ]] && [[ "$(fb_state "${fb_matches[0]}")" == "$before" ]]; then
    ok "couverture : filet local = image fidèle d'avant purge (restauration possible)"
else
    ko "couverture : filet local infidèle"; show_out
fi
expected="W:1|admin|sid-admin|$OLD
W:4|carol|sid-shared|$RECENT
W:6|newbie|<null>|<null>
A:sid-foreign
A:sid-shared"
[[ "$(db_state)" == "$expected" ]] && ok "couverture : base purgée (état nominal exact)" || { ko "couverture : état inattendu :"; db_state | sed 's/^/  [db] /'; }

# --- (10) hors couverture : verrou tenu, unité inactive -> die franc ------------
echo "== (10) hors couverture (verrou tenu, unité inactive) =="
fresh_case nocover
export MOCK_ACTIVE_STATE=inactive
mk_fixture
before="$(db_state)"
hold_world_lock
if run_purge; then rc=0; else rc=$?; fi
release_world_lock_holder
(( rc != 0 )) && ok "hors couverture : die (exit $rc)" || { ko "hors couverture : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "hors couverture : rien supprimé" || { ko "hors couverture : base modifiée"; show_out; }
if ls "${DB}".pre-purge-* >/dev/null 2>&1; then
    ko "hors couverture : filet local créé à tort"
else
    ok "hors couverture : aucun filet local (refus franc)"
fi

# --- (10b) erreur snapshot réelle sous couverture : pas de filet, die -----------
# Le filet local est réservé au seul BACKUP_SKIPPED_LOCK exit 0 : une vraie
# erreur dataBackup (exit 1) sous couverture reste fail-closed.
echo "== (10b) erreur snapshot réelle sous couverture =="
fresh_case snaperr
export MOCK_ACTIVE_STATE=activating MOCK_DATABACKUP_EXIT=1
mk_fixture
before="$(db_state)"
hold_world_lock
if run_purge; then rc=0; else rc=$?; fi
release_world_lock_holder
(( rc != 0 )) && ok "snapshot KO sous couverture : die (exit $rc)" || { ko "snapshot KO sous couverture : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "snapshot KO sous couverture : rien supprimé" || { ko "snapshot KO sous couverture : base modifiée"; show_out; }
if ls "${DB}".pre-purge-* >/dev/null 2>&1; then
    ko "snapshot KO sous couverture : filet local créé à tort (réservé au BACKUP_SKIPPED_LOCK)"
else
    ok "snapshot KO sous couverture : aucun filet local (fail-closed)"
fi
export PATH="$PATH_SAVED"
unset MOCK_ACTIVE_STATE

# --- (8) témoin ancien code (copie isolée HEAD) ---------------------------------------------
# Miroite data/scripts/{admin,lib,backup} : PZ_MANAGER_ROOT est dérivé à 3
# niveaux au-dessus de lib/common.sh — toute autre profondeur casse source_env.
echo "== (8) témoin ancien code =="
mkdir -p "${SANDBOX}/oldtree/data/scripts/admin"
if ! git -C "$ROOT" show "HEAD:data/scripts/admin/purgeInactivePlayers.sh" > "${SANDBOX}/oldtree/data/scripts/admin/purge-old.sh" 2>/dev/null; then
    echo "[SKIP-local] HEAD inaccessible pour le témoin" >&2
else
    ln -sfn "${ROOT}/data/scripts/lib" "${SANDBOX}/oldtree/data/scripts/lib"
    ln -sfn "${ROOT}/data/scripts/backup" "${SANDBOX}/oldtree/data/scripts/backup"
    ln -sfn "${ROOT}/data/scripts/admin/creationDateInit.sh" "${SANDBOX}/oldtree/data/scripts/admin/creationDateInit.sh"
    printf '# stub témoin C4\n' > "${SANDBOX}/oldtree/.env"
    fresh_case oldcode
    mk_fixture
    sqlite3 "$DB" "CREATE TRIGGER purge_guard BEFORE DELETE ON whitelist WHEN OLD.username='bob' BEGIN SELECT RAISE(ABORT,'C4-test-boom'); END;"
    # dataBackup réel sur source vide : échec rapide (WARNING+continue, l'ancien défaut).
    mkdir -p "${SANDBOX}/oldsrc"
    export PZ_SOURCE_DIR="${SANDBOX}/oldsrc" BACKUP_DIR="${SANDBOX}/oldbkp" BACKUP_LATEST_LINK="${SANDBOX}/oldbkp/latest"
    if bash "${SANDBOX}/oldtree/data/scripts/admin/purge-old.sh" --force --days 30 >"${SANDBOX}/out.log" 2>&1; then rco=0; else rco=$?
    fi
    unset PZ_SOURCE_DIR BACKUP_DIR BACKUP_LATEST_LINK
    if ! grep -q 'compte(s) inactif(s) détecté(s)' "${SANDBOX}/out.log"; then
        echo "[SKIP-local] ancien code non exécutable ici (friction d'environnement, sans valeur de preuve)" >&2
        show_out
    else
        alice_gone="$(sqlite3 "$DB" "SELECT COUNT(*) FROM whitelist WHERE username='alice';")"
        bob_here="$(sqlite3 "$DB" "SELECT COUNT(*) FROM whitelist WHERE username='bob';")"
        if (( rco == 0 )) && [[ "$alice_gone" == "0" && "$bob_here" == "1" ]]; then
            ok "témoin : ancien code = succès partiel (alice supprimée, bob gardé) -> le test (4) détecte bien le défaut"
        else
            ko "témoin : comportement ancien inattendu (rc=$rco alice_gone=$alice_gone bob_here=$bob_here)"; show_out
        fi
    fi
fi

# --- (11) pseudo hostile : pipe + saut de ligne avec injection -------------------
# Constat Codex Security (10/2026) : un saut de ligne dans un pseudo forgeait des
# lignes (VICTIM_IDS="5,0); DELETE FROM whitelist;--"), exécutées dès le plan.
# Le garde précoce (id entiers + lignes bien cadrées + cardinalité) annule la
# purge AVANT toute requête : base inchangée, snapshot même pas tenté.
echo "== (11) pseudo hostile =="
fresh_case hostile
mk_fixture
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection) VALUES (7,'MabEira | Hannibal','sid-hostile','$OLD');"
sqlite3 "$DB" "INSERT INTO allowedsteamid(steamid) VALUES ('sid-hostile');"
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection) VALUES (8,'evil' || char(10) || '0); DELETE FROM whitelist;--','sid-evil','$OLD');"
sqlite3 "$DB" "INSERT INTO allowedsteamid(steamid) VALUES ('sid-evil');"
before="$(db_state)"
if run_purge; then rc=0; else rc=$?; fi
(( rc != 0 )) && ok "pseudo hostile : die fail-closed (exit $rc)" || { ko "pseudo hostile : exit 0 à tort"; show_out; }
[[ "$(db_state)" == "$before" ]] && ok "pseudo hostile : base inchangée" || { ko "pseudo hostile : base MODIFIÉE"; show_out; }
grep -q 'fail-closed' "${SANDBOX}/out.log" \
    && ok "pseudo hostile : refus journalisé" \
    || { ko "pseudo hostile : refus non journalisé"; show_out; }

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C4 PURGE: OK (${PASS} contrôles)"
else
    echo "C4 PURGE: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
