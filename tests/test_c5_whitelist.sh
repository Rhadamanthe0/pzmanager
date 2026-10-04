#!/usr/bin/env bash
# test_c5_whitelist.sh - rename/remove whitelist cohérents (C5).
#
# Couvre (manageWhitelist.sh : rename-account + remove-account uniquement) :
#   (0) câblage statique : transactions uniques BEGIN IMMEDIATE/COMMIT via
#       sqlite3 -bail + fichier SQL mktemp, verrou monde (acquire_world_lock,
#       ordre WORLD -> SERVERCTL) + arrêt prouvé (assert_server_stopped_proven),
#       prévalidation fail-closed (wl_sql_or_die, sans `|| echo 0`), garde
#       orphelin NOT EXISTS intra-transaction, compensation documentée (2PC
#       impossible en sqlite), aucun WARNING+continue ni DELETE unitaire en boucle.
#   (1) rename vers login existant (whitelist) -> die, rien modifié (2 bases).
#   (2) perso absent (whitelist seule, aucun networkPlayers pour old) -> OK,
#       whitelist seule renommée, players.db inchangé.
#   (3) whitelist absente (old inconnu) -> die, rien modifié.
#   (4) plusieurs persos même user (2 lignes networkPlayers) -> tous renommés.
#   (5) panne milieu (trigger ABORT sur players.db) -> die + COMPENSATION :
#       whitelist restaurée vers old, aucun état partiel.
#   (6) remove-account nominal + atomique : SteamID partagé conservé tant qu'un
#       compte le porte, sid orphelin désautorisé, sid étranger intact ;
#       trigger ABORT sur whitelist -> die, ROLLBACK, aucun partiel.
#
# Preuves réelles : vrai script manageWhitelist.sh, vraies bases SQLite
# (fichiers), vrai flock via lib C1, vraies transactions. Seules parties
# simulées (explicites) : systemctl via mock PATH (état inactive prouvé —
# le chemin d'arrêt prouvé est celui de production) et .env stubé
# (sauvegardé + restauré via trap). Isolé : XDG_RUNTIME_DIR + TMPDIR sandbox,
# PZ_DB_PATH / PZ_SOURCE_DIR sandbox. Sans sqlite3/flock -> SKIP.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/admin/manageWhitelist.sh"
SANDBOX="${ROOT}/tests/.tmp-c5-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"
ENV_STUBBED=false

cleanup() {
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
    echo "[SKIP-local] flock indisponible — test C5 à exécuter sous Linux/WSL." >&2
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
mkdir -p "${SANDBOX}/rt" "${SANDBOX}/tmp" "$BIN"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
export TMPDIR="${SANDBOX}/tmp"
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
    PZ_WORLD_LOCK_DEPTH=0; PZ_WORLD_LOCK_FD=""
    export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
fi
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C5 (restauré en fin de test)\n' > "$REPO_ENV"
ENV_STUBBED=true
export PZ_SERVICE_NAME="zomboid.service"

# --- Mock systemctl (état inactive prouvé) ------------------------------------
cat > "${BIN}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
mode="${MOCK_SYSTEMCTL_MODE:-inactive}"
if [[ " $* " == *" show "* ]]; then
    case "$mode" in
        error) echo "Failed to connect to bus: No medium found" >&2; exit 1 ;;
        active) printf 'ActiveState=active\nSubState=running\nResult=success\n' ;;
        *) printf 'ActiveState=inactive\nSubState=dead\nResult=success\n' ;;
    esac
    exit 0
fi
if [[ " $* " == *" is-active "* ]]; then
    case "$mode" in
        error) echo "Failed to connect to bus: No medium found" >&2; exit 1 ;;
        active) exit 0 ;;
        *) exit 3 ;;
    esac
fi
echo "mock-systemctl: args inattendus: $*" >&2
exit 99
MOCKEOF
chmod +x "${BIN}/systemctl"
export PATH="${BIN}:$PATH"
export MOCK_SYSTEMCTL_MODE=inactive

# --- Helpers -----------------------------------------------------------------
DB=""
SRC=""
PLAYERS=""
fresh_case() {
    local name="$1"
    DB="${SANDBOX}/db-${name}.db"
    SRC="${SANDBOX}/src-${name}"
    PLAYERS="${SRC}/Saves/Multiplayer/w/players.db"
    rm -f "$DB"
    rm -rf "$SRC"
    mkdir -p "${SRC}/Saves/Multiplayer/w"
    export PZ_DB_PATH="$DB"
    export PZ_SOURCE_DIR="$SRC"
    rm -f "${SANDBOX}/out.log"
}
mk_world() {
    # mk_world <id:username:steamid>...
    sqlite3 "$DB" "CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT, steamid TEXT, lastConnection TEXT, password TEXT);"
    sqlite3 "$DB" "CREATE TABLE allowedsteamid(steamid TEXT PRIMARY KEY);"
    local spec id uname sid
    for spec in "$@"; do
        IFS=':' read -r id uname sid <<< "$spec"
        sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid) VALUES (${id},'${uname}','${sid}');"
    done
}
allow_sid() {
    local sid
    for sid in "$@"; do
        sqlite3 "$DB" "INSERT OR IGNORE INTO allowedsteamid(steamid) VALUES ('${sid}');"
    done
}
mk_players() {
    # mk_players <username:name>...
    sqlite3 "$PLAYERS" "CREATE TABLE networkPlayers(id INTEGER PRIMARY KEY, username TEXT, name TEXT);"
    local spec uname pname i=1
    for spec in "$@"; do
        IFS=':' read -r uname pname <<< "$spec"
        sqlite3 "$PLAYERS" "INSERT INTO networkPlayers(id,username,name) VALUES (${i},'${uname}','${pname}');"
        i=$(( i + 1 ))
    done
}
mk_players_empty() {
    sqlite3 "$PLAYERS" "CREATE TABLE networkPlayers(id INTEGER PRIMARY KEY, username TEXT, name TEXT);"
}
world_state() {
    sqlite3 "$DB" "SELECT 'W:' || id || '|' || username || '|' || COALESCE(steamid,'<null>') FROM whitelist ORDER BY id;"
    sqlite3 "$DB" "SELECT 'A:' || steamid FROM allowedsteamid ORDER BY steamid;"
}
players_state() {
    if [[ -f "$PLAYERS" ]]; then
        sqlite3 "$PLAYERS" "SELECT 'P:' || id || '|' || username || '|' || name FROM networkPlayers ORDER BY id;"
    else
        echo "(no-players-db)"
    fi
}
run_rename() { bash "$SCRIPT" rename-account "$1" "$2" >"${SANDBOX}/out.log" 2>&1; }
run_remove() { bash "$SCRIPT" remove-account "$@" >"${SANDBOX}/out.log" 2>&1; }
run_reset() { bash "$SCRIPT" resetpassword "$1" >"${SANDBOX}/out.log" 2>&1; }
run_purge_delete() { printf 'oui\n' | bash "$SCRIPT" purge "$@" >"${SANDBOX}/out.log" 2>&1; }
# Schéma complet (resetpassword lit/affiche WHITELIST_COLUMNS + password ;
# purge filtre sur lastConnection) : le mk_world minimal ci-dessus ne suffit pas.
mk_full_world() {
    sqlite3 "$DB" "CREATE TABLE whitelist(id INTEGER PRIMARY KEY, username TEXT, steamid TEXT, lastConnection TEXT, password TEXT, role TEXT, displayName TEXT);"
    sqlite3 "$DB" "CREATE TABLE allowedsteamid(steamid TEXT PRIMARY KEY);"
}
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }
no_tmp_left() {
    if ls "${SANDBOX}/tmp"/pz-whitelist-* "${SANDBOX}/tmp"/pz-players-* 2>/dev/null | grep -q .; then
        ko "$1 : fichier(s) SQL résiduel(s) sous TMPDIR sandbox"
        ls "${SANDBOX}/tmp" | sed 's/^/  [tmp] /'
    else
        ok "$1 : aucun .sql résiduel"
    fi
}

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'wl_sql_or_die' "$SCRIPT" \
    && ok "lectures fail-closed via wl_sql_or_die" \
    || ko "wl_sql_or_die absent"
grep -q 'BEGIN IMMEDIATE' "$SCRIPT" && grep -q 'COMMIT' "$SCRIPT" \
    && ok "transaction unique BEGIN IMMEDIATE ... COMMIT" \
    || ko "transaction unique absente"
grep -q 'sqlite3 -bail' "$SCRIPT" \
    && ok "sqlite3 -bail (stop au 1er échec, pas de COMMIT partiel)" \
    || ko "sqlite3 -bail absent"
grep -q 'mktemp' "$SCRIPT" \
    && ok "fichier SQL via mktemp" \
    || ko "mktemp absent"
grep -q 'acquire_world_lock' "$SCRIPT" \
    && ok "verrou monde acquis (acquire_world_lock, ordre WORLD -> SERVERCTL)" \
    || ko "acquire_world_lock absent"
grep -q 'acquire_serverctl_lock_or_die' "$SCRIPT" \
    && ok "verrou serverctl conservé" \
    || ko "acquire_serverctl_lock_or_die absent"
grep -q 'assert_server_stopped_proven' "$SCRIPT" \
    && ok "arrêt prouvé (assert_server_stopped_proven, garde)" \
    || ko "assert_server_stopped_proven absent"
grep -qi 'compens' "$SCRIPT" && grep -q '2PC' "$SCRIPT" \
    && ok "compensation documentée (2PC impossible en sqlite)" \
    || ko "compensation / mention 2PC absente"
grep -q 'NOT EXISTS' "$SCRIPT" \
    && ok "garde orphelin NOT EXISTS intra-transaction (remove)" \
    || ko "garde NOT EXISTS absente"
if grep -q 'WARNING: échec' "$SCRIPT"; then
    ko "WARNING+continue encore présent (non fail-closed)"
else
    ok "aucun WARNING+continue (fail-closed)"
fi
if grep -q 'DELETE FROM whitelist WHERE id = ' "$SCRIPT"; then
    ko "ancienne boucle de DELETE unitaires encore présente"
else
    ok "plus de DELETE unitaire en boucle (transaction IN unique)"
fi
if grep -q 'UPDATE whitelist SET' "$SCRIPT" && grep -q 'UPDATE networkPlayers SET' "$SCRIPT"; then
    ok "rename couvre whitelist + networkPlayers"
else
    ko "UPDATE rename incomplets"
fi

# --- (1) rename vers existant -> die sans modif ---------------------------------
echo "== (1) rename vers existant =="
fresh_case clash
mk_world "1:alice:sid-alice" "2:bob:sid-bob"
allow_sid sid-alice sid-bob
mk_players "alice:char-alice" "bob:char-bob"
before_w="$(world_state)"; before_p="$(players_state)"
if run_rename alice bob; then
    ko "collision : exit 0 (attendu échec)"; show_out
else
    ok "collision : échec (exit $?)"
fi
[[ "$(world_state)" == "$before_w" ]] && ok "collision : whitelist inchangée" || { ko "collision : whitelist modifiée"; show_out; }
[[ "$(players_state)" == "$before_p" ]] && ok "collision : players.db inchangé" || { ko "collision : players.db modifié"; show_out; }
grep -qi 'collision' "${SANDBOX}/out.log" && ok "collision : message explicite" || { ko "collision : pas de mention collision"; show_out; }
no_tmp_left "collision"

# --- (1b) rename vers perso existant (players seul) -> die sans modif ------------
echo "== (1b) rename vers perso existant =="
fresh_case clashp
mk_world "1:alice:sid-alice"
allow_sid sid-alice
mk_players "alice:char-alice" "bob:char-bob"
before_w="$(world_state)"; before_p="$(players_state)"
if run_rename alice bob; then
    ko "collision players : exit 0 (attendu échec)"; show_out
else
    ok "collision players : échec (exit $?)"
fi
[[ "$(world_state)" == "$before_w" ]] && ok "collision players : whitelist inchangée" || { ko "collision players : whitelist modifiée"; show_out; }
[[ "$(players_state)" == "$before_p" ]] && ok "collision players : players.db inchangé" || { ko "collision players : players.db modifié"; show_out; }
no_tmp_left "collision-players"

# --- (2) perso absent (whitelist seule) -> OK whitelist seule ----------------------
echo "== (2) whitelist seule =="
fresh_case solo
mk_world "1:alice:sid-alice"
allow_sid sid-alice
mk_players "bob:char-bob"
if run_rename alice alice2; then
    ok "whitelist seule : exit 0"
else
    ko "whitelist seule : échec à tort"; show_out
fi
[[ "$(sqlite3 "$DB" "SELECT username FROM whitelist WHERE id=1;")" == "alice2" ]] \
    && ok "whitelist seule : compte renommé" \
    || { ko "whitelist seule : whitelist inattendue"; world_state | sed 's/^/  [db] /'; }
[[ "$(players_state)" == "P:1|bob|char-bob" ]] \
    && ok "whitelist seule : players.db inchangé" \
    || { ko "whitelist seule : players.db modifié"; players_state | sed 's/^/  [db] /'; }
no_tmp_left "whitelist-seule"

# --- (3) whitelist absente (old inconnu) -> die -------------------------------------
echo "== (3) old inconnu =="
fresh_case missing
mk_world "1:bob:sid-bob"
allow_sid sid-bob
mk_players "bob:char-bob"
before_w="$(world_state)"; before_p="$(players_state)"
if run_rename alice alice2; then
    ko "old inconnu : exit 0 (attendu échec)"; show_out
else
    ok "old inconnu : échec (exit $?)"
fi
[[ "$(world_state)" == "$before_w" ]] && ok "old inconnu : whitelist inchangée" || { ko "old inconnu : whitelist modifiée"; show_out; }
[[ "$(players_state)" == "$before_p" ]] && ok "old inconnu : players.db inchangé" || { ko "old inconnu : players.db modifié"; show_out; }
no_tmp_left "old-inconnu"

# --- (4) plusieurs persos même user (2 lignes) -> tous renommés -----------------------
echo "== (4) deux persos =="
fresh_case two
mk_world "1:alice:sid-alice"
allow_sid sid-alice
mk_players "alice:char-1" "alice:char-2"
if run_rename alice alice2; then
    ok "deux persos : exit 0"
else
    ko "deux persos : échec à tort"; show_out
fi
[[ "$(sqlite3 "$DB" "SELECT username FROM whitelist WHERE id=1;")" == "alice2" ]] \
    && ok "deux persos : whitelist renommée" \
    || { ko "deux persos : whitelist inattendue"; world_state | sed 's/^/  [db] /'; }
expected_p="P:1|alice2|char-1
P:2|alice2|char-2"
[[ "$(players_state)" == "$expected_p" ]] \
    && ok "deux persos : les 2 lignes networkPlayers renommées" \
    || { ko "deux persos : players inattendu"; players_state | sed 's/^/  [db] /'; }
no_tmp_left "deux-persos"

# --- (5) panne milieu (trigger players) -> compensation -------------------------------
echo "== (5) panne milieu =="
fresh_case midfail
mk_world "1:alice:sid-alice"
allow_sid sid-alice
mk_players "alice:char-alice"
sqlite3 "$PLAYERS" "CREATE TRIGGER c5_guard BEFORE UPDATE ON networkPlayers WHEN OLD.username='alice' BEGIN SELECT RAISE(ABORT,'C5-test-boom'); END;"
before_w="$(world_state)"; before_p="$(players_state)"
if run_rename alice alice2; then
    ko "panne milieu : exit 0 (attendu échec)"; show_out
else
    ok "panne milieu : échec (exit $?)"
fi
[[ "$(world_state)" == "$before_w" ]] \
    && ok "panne milieu : whitelist restaurée (compensation, aucun partiel)" \
    || { ko "panne milieu : whitelist partielle !"; world_state | sed 's/^/  [db] /'; show_out; }
[[ "$(players_state)" == "$before_p" ]] \
    && ok "panne milieu : players.db inchangé" \
    || { ko "panne milieu : players.db modifié"; show_out; }
if grep -qi 'compensation\|restaurée' "${SANDBOX}/out.log"; then
    ok "panne milieu : compensation annoncée"
else
    ko "panne milieu : compensation non annoncée"; show_out
fi
no_tmp_left "panne-milieu"

# --- (6) remove-account nominal + atomique ----------------------------------------------
echo "== (6) remove-account =="
fresh_case remove
mk_world "1:alice:sid-alice" "2:bob:sid-shared" "3:carol:sid-shared"
allow_sid sid-alice sid-shared sid-foreign
if run_remove alice; then
    ok "remove alice : exit 0"
else
    ko "remove alice : échec à tort"; show_out
fi
expected="W:2|bob|sid-shared
W:3|carol|sid-shared
A:sid-foreign
A:sid-shared"
[[ "$(world_state)" == "$expected" ]] \
    && ok "remove alice : sid orphelin désautorisé, sid partagé + sid étranger conservés" \
    || { ko "remove alice : état inattendu"; world_state | sed 's/^/  [db] /'; show_out; }
if run_remove bob; then
    ok "remove bob (partagé) : exit 0"
else
    ko "remove bob : échec à tort"; show_out
fi
expected="W:3|carol|sid-shared
A:sid-foreign
A:sid-shared"
[[ "$(world_state)" == "$expected" ]] \
    && ok "remove bob : sid partagé CONSERVÉ (carol le porte)" \
    || { ko "remove bob : état inattendu"; world_state | sed 's/^/  [db] /'; show_out; }
no_tmp_left "remove-nominal"

echo "== (6b) remove atomique (trigger) =="
fresh_case removeatomic
mk_world "1:alice:sid-alice" "2:bob:sid-bob"
allow_sid sid-alice sid-bob
sqlite3 "$DB" "CREATE TRIGGER c5_rm_guard BEFORE DELETE ON whitelist WHEN OLD.username='bob' BEGIN SELECT RAISE(ABORT,'C5-test-boom'); END;"
before="$(world_state)"
if run_remove alice bob; then
    ko "remove trigger : exit 0 (attendu échec)"; show_out
else
    ok "remove trigger : échec (exit $?)"
fi
[[ "$(world_state)" == "$before" ]] \
    && ok "remove trigger : ROLLBACK, aucun partiel (alice intacte)" \
    || { ko "remove trigger : état partiel !"; world_state | sed 's/^/  [db] /'; show_out; }
if grep -qi 'ROLLBACK' "${SANDBOX}/out.log"; then
    ok "remove trigger : ROLLBACK annoncé"
else
    ko "remove trigger : ROLLBACK non annoncé"; show_out
fi
no_tmp_left "remove-trigger"

# --- (7) resetpassword exclu si start concurrent (verrou monde tenu) ---------------
echo "== (7) resetpassword concurrent =="
fresh_case resetlock
mk_full_world
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,password) VALUES (1,'alice','sid-alice','hash123');"
allow_sid sid-alice
export MOCK_SYSTEMCTL_MODE=inactive
WLOCK="${SANDBOX}/rt/pzmanager/world.lock"
mkdir -p "$(dirname "$WLOCK")"
exec {C5_HOLD_FD}>"$WLOCK" || { ko "resetpassword concurrent : ouverture verrou impossible"; }
if flock -n "$C5_HOLD_FD"; then
    if run_reset alice; then
        ko "resetpassword sous verrou : exit 0 (attendu exclu)"; show_out
    else
        ok "resetpassword sous verrou : exclu (exit $?)"
    fi
    if grep -qi 'déjà en cours' "${SANDBOX}/out.log"; then
        ok "resetpassword sous verrou : message d'exclusion"
    else
        ko "resetpassword sous verrou : message d'exclusion absent"; show_out
    fi
    [[ "$(sqlite3 "$DB" "SELECT password FROM whitelist WHERE username='alice';")" == "hash123" ]] \
        && ok "resetpassword sous verrou : mot de passe intact" \
        || { ko "resetpassword sous verrou : mot de passe modifié !"; show_out; }
    flock -u "$C5_HOLD_FD" || true
else
    ko "resetpassword concurrent : prise du verrou témoin impossible"
fi
exec {C5_HOLD_FD}>&- || true
C5_HOLD_FD=""
if run_reset alice; then
    ok "resetpassword verrou libre : exit 0"
else
    ko "resetpassword verrou libre : échec à tort"; show_out
fi
[[ -z "$(sqlite3 "$DB" "SELECT password FROM whitelist WHERE username='alice';")" ]] \
    && ok "resetpassword verrou libre : mot de passe vidé" \
    || { ko "resetpassword verrou libre : mot de passe non vidé"; show_out; }

# --- (8) purge --delete : bus systemd en erreur -> refus fail-closed ------------
echo "== (8) purge bus erreur =="
fresh_case purgeerr
mk_full_world
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection,password) VALUES (1,'victim','sid-old','2000-01-01 00:00:00','h');"
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection,password) VALUES (2,'recent','sid-new',datetime('now'),'h');"
sqlite3 "$DB" "INSERT INTO whitelist(id,username,steamid,lastConnection,password) VALUES (3,'admin','sid-adm','2000-01-01 00:00:00','h');"
allow_sid sid-old sid-new sid-adm
export MOCK_SYSTEMCTL_MODE=error
if run_purge_delete 30j --delete; then
    ko "purge bus erreur : exit 0 (attendu refus)"; show_out
else
    ok "purge bus erreur : refusé (exit $?)"
fi
[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM whitelist WHERE username='victim';")" == "1" ]] \
    && ok "purge bus erreur : victim conservée (aucun DELETE)" \
    || { ko "purge bus erreur : victim supprimée à chaud !"; show_out; }
if grep -qi 'indéterminé\|fail-closed\|refus' "${SANDBOX}/out.log"; then
    ok "purge bus erreur : refus fail-closed annoncé"
else
    ko "purge bus erreur : refus non annoncé"; show_out
fi
export MOCK_SYSTEMCTL_MODE=inactive
if run_purge_delete 30j --delete; then
    ok "purge bus sain : exit 0"
else
    ko "purge bus sain : échec à tort"; show_out
fi
[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM whitelist WHERE username='victim';")" == "0" ]] \
    && ok "purge bus sain : victim supprimée" \
    || { ko "purge bus sain : victim toujours là"; show_out; }
[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM whitelist WHERE username='recent';")" == "1" ]] \
    && ok "purge bus sain : recent conservé" \
    || { ko "purge bus sain : recent touché !"; show_out; }

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C5 WHITELIST: OK (${PASS} contrôles)"
else
    echo "C5 WHITELIST: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
