#!/usr/bin/env bash
# test_c3_restore_character.sh - Restauration personnage transactionnelle (C3).
#
# Couvre (data/scripts/backup/restoreCharacter.sh uniquement) :
#   (0) câblage statique : transaction explicite (BEGIN IMMEDIATE/COMMIT +
#       ROLLBACK, .bail on / -bail), fichier SQL tmp (mktemp + trap rm),
#       find_players_db_strict (pas de choix arbitraire), garde source==dest
#       (realpath/inode), vérif schéma via PRAGMA table_info, verrou monde
#       (acquire_world_lock) + arrêt prouvé (assert_server_stopped_proven),
#       compat find_players_db conservée dans lib/common.sh.
#   (1) succès normal : perso live remplacé par celui du backup, autres
#       persos intacts.
#   (2) insertion cassée après DELETE (colonne NOT NULL supplémentaire en
#       live) -> ROLLBACK, exit != 0, live inchangé (checksum + count +
#       contenu).
#   (3) perso absent du backup -> die, live inchangé.
#   (4) source == dest (même players.db) -> die, live inchangé.
#   (5) deux mondes dans le backup : (a) sans PZ_SERVER_NAME correspondant ->
#       die en listant les mondes, live inchangé ; (b) PZ_SERVER_NAME
#       correspondant -> succès depuis le bon monde.
#   (6) schéma incompatible (table networkPlayers absente du backup) -> die,
#       live inchangé.
#
# Preuves réelles : vrai script restoreCharacter.sh, vraies bases SQLite
# (créées/vérifiées via le moteur SQLite), vrai flock, mock systemctl par
# PATH (état serveur piloté). Isolé : XDG_RUNTIME_DIR + PZ_SOURCE_DIR +
# BACKUP_DIR sous sandbox, stub .env (restauré via trap EXIT). Ne touche à
# aucune base réelle.
#
# Repli sqlite3 : si le binaire sqlite3 est absent (ex. WSL sans le paquet),
# un shim test-local `sqlite3` adossé au moteur SQLite réel (stdlib python3,
# même version de bibliothèque) est posé dans PATH. Il exécute le VRAI texte
# SQL du script (BEGIN/ATTACH/DELETE/INSERT/COMMIT, .bail on, PRAGMA, COUNT)
# avec la vraie sémantique transactionnelle (ROLLBACK sur erreur) ; seul le
# frontal CLI (formatage -header/-column) est approximé. Limite explicite :
# un résultat obtenu via le shim prouve le SQL et la transaction, pas le
# binaire sqlite3 officiel (qui reste requis en production via require_sqlite).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/backup/restoreCharacter.sh"
SANDBOX="${ROOT}/tests/.tmp-c3-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"
USE_SHIM=0

cleanup() {
    # `local rc=$?` + `exit` : sans cela, le statut du dernier `rm` du trap
    # EXIT écraserait le statut réel du test (un ÉCHEC sortirait en 0).
    local rc=$?
    if [[ -f "$ENV_BACKUP" ]]; then
        cp -p "$ENV_BACKUP" "$REPO_ENV"
    else
        rm -f "$REPO_ENV"
    fi
    rm -rf "$SANDBOX"
    exit "$rc"
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible — test C3 à exécuter sous Linux/WSL." >&2
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1 && ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[SKIP-local] ni python3 ni sqlite3 disponibles — moteur SQLite requis." >&2
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
# Stub .env (cf. test C2) : source_env le lit puis applique les défauts `:=`,
# donc l'env sandbox exporté ci-dessous survit.
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C3 (restauré en fin de test)\n' > "$REPO_ENV"

# --- Mock systemctl (état serveur piloté) -------------------------------------
cat > "${BIN}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
mode="${MOCK_SYSTEMCTL_MODE:-inactive}"
if [[ " $* " == *" show "* ]]; then
    case "$mode" in
        error) echo "Failed to connect to bus: No medium found" >&2; exit 1 ;;
        active) printf 'ActiveState=active\nSubState=running\nResult=success\n' ;;
        inactive) printf 'ActiveState=inactive\nSubState=dead\nResult=success\n' ;;
        activating) printf 'ActiveState=activating\nSubState=start-pre\nResult=success\n' ;;
        deactivating) printf 'ActiveState=deactivating\nSubState=stop-sigterm\nResult=success\n' ;;
        failed) printf 'ActiveState=failed\nSubState=failed\nResult=exit-code\n' ;;
        *) printf 'ActiveState=unknown\nSubState=unknown\nResult=success\n' ;;
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

# --- Repli sqlite3 via moteur réel (shim test-local) --------------------------
# Forçable via PZ_TEST_FORCE_SHIM=1 (prouve le repli même si le CLI existe).
if [[ "${PZ_TEST_FORCE_SHIM:-0}" == "1" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
    USE_SHIM=1
    cat > "${BIN}/sqlite3" <<'PYEOF'
#!/usr/bin/env python3
"""Shim sqlite3 (test C3 uniquement) : exécute le vrai SQL via le moteur
SQLite réel (stdlib). Supporte -bail, .bail on/off, ATTACH/BEGIN/COMMIT,
SELECT/PRAGMA (sortie|-séparée), SQL en argument ou via stdin."""
import sys
import sqlite3


def split_sql(text):
    stmts, cur, in_str = [], [], False
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if in_str:
            cur.append(ch)
            if ch == "'":
                if i + 1 < n and text[i + 1] == "'":
                    cur.append("'")
                    i += 2
                    continue
                in_str = False
        else:
            if ch == "'":
                in_str = True
                cur.append(ch)
            elif ch == ';':
                cur.append(ch)
                s = ''.join(cur).strip()
                if s.strip(';').strip():
                    stmts.append(s)
                cur = []
            else:
                cur.append(ch)
        i += 1
    tail = ''.join(cur).strip()
    if tail.strip(';').strip():
        stmts.append(tail)
    return stmts


def fmt(v):
    if v is None:
        return ''
    if isinstance(v, bytes):
        return v.decode('utf-8', 'replace')
    return str(v)


args = sys.argv[1:]
bail, pos = False, []
for a in args:
    if a in ('-bail', '--bail'):
        bail = True
    elif a.startswith('-'):
        continue  # -header, -column, ... : formatage ignoré
    else:
        pos.append(a)
if not pos:
    print('usage: sqlite3 DB [SQL]', file=sys.stderr)
    sys.exit(1)
db = pos[0]
sql_text = ' '.join(pos[1:]) if len(pos) > 1 else ''
if not sql_text:
    sql_text = sys.stdin.read()

con = sqlite3.connect(db)
con.isolation_level = None  # BEGIN/COMMIT explicites du script
cur = con.cursor()
rc = 0
# Commandes dot (.bail on) : traitées ligne par ligne AVANT le découpage en
# ordres, car `.bail on` (sans point-virgule) fusionnerait sinon avec l'ordre
# SQL suivant et l'avalerait (ATTACH perdu -> no such table: bk...).
body_lines = []
for line in sql_text.splitlines():
    t = line.strip()
    if t.startswith('.'):
        parts = t.split()
        if parts[0] == '.bail' and len(parts) > 1:
            bail = (parts[1].lower() == 'on')
        continue
    body_lines.append(line)
for stmt in split_sql('\n'.join(body_lines)):
    s = stmt.strip()
    if not s:
        continue
    try:
        head = s.lstrip(';').strip()[:6].upper()
        if head in ('SELECT', 'PRAGMA', 'EXPLAI', 'WITH'):
            cur.execute(s)
            for row in cur.fetchall():
                print('|'.join(fmt(v) for v in row))
        else:
            cur.execute(s)
    except sqlite3.Error as ex:
        print('Error: %s' % ex, file=sys.stderr)
        if bail:
            con.close()
            sys.exit(1)
        rc = 1
con.close()
sys.exit(rc)
PYEOF
    chmod +x "${BIN}/sqlite3"
fi
export PATH="${BIN}:$PATH"
export PZ_SERVICE_NAME="zomboid.service"
export MOCK_SYSTEMCTL_MODE="inactive"

# --- Helpers SQLite (moteur réel) ----------------------------------------------
make_players() {
    # make_players <db> <variante> : normal | extra_notnull | no_table | missing_data
    python3 - "$1" "${2:-normal}" <<'PYEOF'
import sqlite3, sys
db, variant = sys.argv[1], sys.argv[2]
import os
os.makedirs(os.path.dirname(db), exist_ok=True)
con = sqlite3.connect(db)
c = con.cursor()
if variant == 'no_table':
    c.execute('CREATE TABLE other (id INTEGER PRIMARY KEY)')
elif variant == 'missing_data':
    c.execute('''CREATE TABLE networkPlayers (
        id INTEGER PRIMARY KEY AUTOINCREMENT, world TEXT, username TEXT,
        playerIndex INTEGER, name TEXT, steamid TEXT, x REAL, y REAL, z REAL,
        worldversion INTEGER, isDead INTEGER)''')
elif variant == 'extra_notnull':
    c.execute('''CREATE TABLE networkPlayers (
        id INTEGER PRIMARY KEY AUTOINCREMENT, world TEXT, username TEXT,
        playerIndex INTEGER, name TEXT, steamid TEXT, x REAL, y REAL, z REAL,
        worldversion INTEGER, data BLOB, isDead INTEGER,
        extra TEXT NOT NULL)''')
else:
    c.execute('''CREATE TABLE networkPlayers (
        id INTEGER PRIMARY KEY AUTOINCREMENT, world TEXT, username TEXT,
        playerIndex INTEGER, name TEXT, steamid TEXT, x REAL, y REAL, z REAL,
        worldversion INTEGER, data BLOB, isDead INTEGER)''')
con.commit()
con.close()
PYEOF
}
add_player() {
    # add_player <db> <username> <datalabel> [variante]
    python3 - "$1" "$2" "$3" "${4:-normal}" <<'PYEOF'
import sqlite3, sys
db, user, data, variant = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
con = sqlite3.connect(db)
c = con.cursor()
if variant == 'extra_notnull':
    c.execute("""INSERT INTO networkPlayers
        (world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead,extra)
        VALUES ('servertest',?,'0',?,'76561197960287930','1.0','2.0','3.0','1',?,'0','tag')""",
        (user, 'name_' + user, data))
else:
    c.execute("""INSERT INTO networkPlayers
        (world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead)
        VALUES ('servertest',?,'0',?,'76561197960287930','1.0','2.0','3.0','1',?,'0')""",
        (user, 'name_' + user, data))
con.commit()
con.close()
PYEOF
}
player_data() {
    # player_data <db> <username> -> contenu data (vide si absent)
    python3 - "$1" "$2" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
try:
    row = con.execute('SELECT data FROM networkPlayers WHERE username=?',
                      (sys.argv[2],)).fetchone()
except sqlite3.Error:
    row = None
if row is None or row[0] is None:
    print('')
else:
    v = row[0]
    print(v.decode() if isinstance(v, bytes) else v)
PYEOF
}
row_count() {
    python3 - "$1" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
try:
    print(con.execute('SELECT COUNT(*) FROM networkPlayers').fetchone()[0])
except sqlite3.Error:
    print('ERR')
PYEOF
}
world_db() {
    # world_db <racine> <monde> <variante> -> chemin players.db créé
    local db="$1/Saves/Multiplayer/$2/players.db"
    make_players "$db" "$3"
    printf '%s\n' "$db"
}
sha() { sha256sum "$1" | awk '{ print $1 }'; }
run_restore() {
    # run_restore <pseudo> <backup> -> code retour (sortie dans out.log)
    bash "$SCRIPT" "$@" >"${SANDBOX}/out.log" 2>&1
}
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }
fresh_case() {
    # fresh_case <nom> : SRC + BKP vierges, env sandbox exporté
    local name="$1"
    SRC="${SANDBOX}/src-${name}"
    BKP="${SANDBOX}/bkp-${name}"
    rm -rf "$SRC" "$BKP"
    mkdir -p "$SRC" "$BKP"
    export PZ_SOURCE_DIR="$SRC" BACKUP_DIR="$BKP" BACKUP_LATEST_LINK="$BKP/latest"
    export PZ_SERVER_NAME="servertest"
    unset MOCK_SYSTEMCTL_MODE
    export MOCK_SYSTEMCTL_MODE="inactive"
}

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'BEGIN IMMEDIATE' "$SCRIPT" && grep -q 'COMMIT' "$SCRIPT" \
    && ok "transaction explicite BEGIN IMMEDIATE ... COMMIT" \
    || ko "transaction explicite absente"
grep -q 'ROLLBACK' "$SCRIPT" \
    && ok "ROLLBACK sur erreur" \
    || ko "ROLLBACK absent"
grep -q '\.bail on' "$SCRIPT" && grep -q -- '-bail' "$SCRIPT" \
    && ok ".bail on + sqlite3 -bail" \
    || ko ".bail on / -bail absents"
grep -q 'mktemp' "$SCRIPT" && grep -q "trap.*rm -f.*SQL_TMP" "$SCRIPT" \
    && ok "fichier SQL tmp via mktemp + trap rm" \
    || ko "mktemp/trap SQL_TMP absents"
grep -q 'find_players_db_strict' "$SCRIPT" \
    && ok "find_players_db_strict utilisée" \
    || ko "find_players_db_strict absente"
if grep -E '\| head -1' "$SCRIPT" >/dev/null 2>&1; then
    ko "choix arbitraire (pipe head -1) encore présent dans restoreCharacter.sh"
else
    ok "aucun choix arbitraire par pipe head -1"
fi
grep -q 'find_players_db()' "${ROOT}/data/scripts/lib/common.sh" \
    && ok "compat : find_players_db conservée dans common.sh" \
    || ko "compat : find_players_db perdue dans common.sh"
grep -q 'PRAGMA table_info' "$SCRIPT" \
    && ok "vérif schéma via PRAGMA table_info" \
    || ko "PRAGMA table_info absent"
grep -q 'realpath\|readlink.*-f\|stat.*%d:%i' "$SCRIPT" \
    && ok "garde source==dest (realpath/inode)" \
    || ko "garde source==dest absente"
grep -q 'acquire_world_lock' "$SCRIPT" \
    && ok "verrou monde acquis (C1)" \
    || ko "acquire_world_lock absent"
grep -q 'assert_server_stopped_proven' "$SCRIPT" \
    && ok "assert_server_stopped_proven avant transaction (fail-closed)" \
    || ko "assert_server_stopped_proven absent"
if (( USE_SHIM == 1 )); then
    echo "[INFO] sqlite3 CLI absent : shim test-local sur moteur réel (voir limites en tête)." >&2
else
    ok "sqlite3 CLI réel disponible"
fi

# --- (1) succès normal ----------------------------------------------------------
echo "== (1) succès normal =="
fresh_case ok1
LIVE_DB="$(world_db "$SRC" servertest normal)"
BK_DIR="$BKP/backup_ok1"; mkdir -p "$BK_DIR"
BK_DB="$(world_db "$BK_DIR" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD
add_player "$LIVE_DB" Bob BOB_LIVE
add_player "$BK_DB" Alice BK_ALICE_NEW
add_player "$BK_DB" Bob BOB_BK
if run_restore Alice "$BK_DIR"; then
    ok "succès normal : exit 0"
else
    ko "succès normal : exit non nul"; show_out
fi
[[ "$(player_data "$LIVE_DB" Alice)" == "BK_ALICE_NEW" ]] \
    && ok "perso live remplacé par celui du backup" \
    || { ko "perso live non remplacé (data=$(player_data "$LIVE_DB" Alice))"; show_out; }
[[ "$(player_data "$LIVE_DB" Bob)" == "BOB_LIVE" ]] \
    && ok "autres persos live intacts" \
    || ko "Bob live altéré à tort"

# --- (2) insertion cassée après DELETE -> ROLLBACK -------------------------------
echo "== (2) ROLLBACK =="
fresh_case rb
LIVE_DB="$(world_db "$SRC" servertest extra_notnull)"
BK_DIR="$BKP/backup_rb"; mkdir -p "$BK_DIR"
BK_DB="$(world_db "$BK_DIR" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD extra_notnull
add_player "$BK_DB" Alice BK_ALICE_NEW
BEFORE_SHA="$(sha "$LIVE_DB")"
BEFORE_COUNT="$(row_count "$LIVE_DB")"
if run_restore Alice "$BK_DIR"; then
    ko "insertion cassée : succès à tort (ROLLBACK attendu)"; show_out
else
    ok "insertion cassée : échec (exit non nul)"
fi
[[ "$(sha "$LIVE_DB")" == "$BEFORE_SHA" ]] \
    && ok "ROLLBACK : base live inchangée (checksum)" \
    || { ko "ROLLBACK manqué : live modifiée malgré l'échec"; show_out; }
[[ "$(row_count "$LIVE_DB")" == "$BEFORE_COUNT" ]] \
    && ok "ROLLBACK : count inchangé (${BEFORE_COUNT})" \
    || ko "ROLLBACK : count altéré"
[[ "$(player_data "$LIVE_DB" Alice)" == "LIVE_ALICE_OLD" ]] \
    && ok "ROLLBACK : DELETE annulé (Alice d'origine toujours là)" \
    || { ko "ROLLBACK : ligne Alice perdue (DELETE non annulé)"; show_out; }

# --- (3) perso absent ------------------------------------------------------------
echo "== (3) perso absent =="
fresh_case nochar
LIVE_DB="$(world_db "$SRC" servertest normal)"
BK_DIR="$BKP/backup_nochar"; mkdir -p "$BK_DIR"
BK_DB="$(world_db "$BK_DIR" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD
add_player "$BK_DB" Bob BOB_BK
BEFORE_SHA="$(sha "$LIVE_DB")"
if run_restore Alice "$BK_DIR"; then
    ko "perso absent : succès à tort"; show_out
else
    ok "perso absent : die (exit non nul)"
fi
grep -q 'Aucun personnage' "${SANDBOX}/out.log" \
    && ok "message 'Aucun personnage' explicite" \
    || { ko "message 'Aucun personnage' absent"; show_out; }
[[ "$(sha "$LIVE_DB")" == "$BEFORE_SHA" ]] \
    && ok "perso absent : live inchangé" \
    || ko "perso absent : live modifiée à tort"

# --- (4) source == dest ------------------------------------------------------------
echo "== (4) source==dest =="
fresh_case samedb
LIVE_DB="$(world_db "$SRC" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD
BEFORE_SHA="$(sha "$LIVE_DB")"
if run_restore Alice "$LIVE_DB"; then
    ko "source==dest : succès à tort"; show_out
else
    ok "source==dest : die (exit non nul)"
fi
grep -qi 'identiques' "${SANDBOX}/out.log" \
    && ok "message source/destination identiques" \
    || { ko "message source==dest absent"; show_out; }
[[ "$(sha "$LIVE_DB")" == "$BEFORE_SHA" ]] \
    && ok "source==dest : live inchangé" \
    || ko "source==dest : live modifiée à tort"

# --- (5) deux mondes ---------------------------------------------------------------
echo "== (5) deux mondes =="
fresh_case twoworlds
LIVE_DB="$(world_db "$SRC" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD
BK_DIR="$BKP/backup_two"; mkdir -p "$BK_DIR"
DB_A="$(world_db "$BK_DIR" worldA normal)"
DB_B="$(world_db "$BK_DIR" worldB normal)"
add_player "$DB_A" Alice BK_ALICE_A
add_player "$DB_B" Alice BK_ALICE_B
BEFORE_SHA="$(sha "$LIVE_DB")"
# (5a) sans PZ_SERVER_NAME correspondant -> die en listant les mondes
export PZ_SERVER_NAME="servertest"
if run_restore Alice "$BK_DIR"; then
    ko "deux mondes : succès à tort (choix arbitraire ?)"; show_out
else
    ok "deux mondes : die sans choisir (exit non nul)"
fi
if grep -q 'worldA' "${SANDBOX}/out.log" && grep -q 'worldB' "${SANDBOX}/out.log"; then
    ok "deux mondes : les deux mondes listés dans le message"
else
    ko "deux mondes : message ne liste pas les mondes"; show_out
fi
[[ "$(sha "$LIVE_DB")" == "$BEFORE_SHA" ]] \
    && ok "deux mondes : live inchangé" \
    || ko "deux mondes : live modifiée à tort"
# (5b) PZ_SERVER_NAME correspondant -> succès depuis le bon monde
export PZ_SERVER_NAME="worldB"
if run_restore Alice "$BK_DIR"; then
    ok "PZ_SERVER_NAME=worldB : succès depuis le monde désigné"
else
    ko "PZ_SERVER_NAME=worldB : échec à tort"; show_out
fi
[[ "$(player_data "$LIVE_DB" Alice)" == "BK_ALICE_B" ]] \
    && ok "restauré depuis worldB (pas worldA)" \
    || { ko "mauvais monde restauré (data=$(player_data "$LIVE_DB" Alice))"; show_out; }

# --- (6) schéma incompatible ----------------------------------------------------------
echo "== (6) schéma incompatible =="
fresh_case badschema
LIVE_DB="$(world_db "$SRC" servertest normal)"
add_player "$LIVE_DB" Alice LIVE_ALICE_OLD
BK_DIR="$BKP/backup_badschema"; mkdir -p "$BK_DIR"
BK_DB="$(world_db "$BK_DIR" servertest no_table)"
BEFORE_SHA="$(sha "$LIVE_DB")"
BEFORE_COUNT="$(row_count "$LIVE_DB")"
if run_restore Alice "$BK_DIR"; then
    ko "schéma incompatible : succès à tort"; show_out
else
    ok "schéma incompatible : die (exit non nul)"
fi
grep -qi 'Schéma incompatible' "${SANDBOX}/out.log" \
    && ok "message 'Schéma incompatible' explicite" \
    || { ko "message schéma absent"; show_out; }
[[ "$(sha "$LIVE_DB")" == "$BEFORE_SHA" ]] \
    && ok "schéma incompatible : live inchangé (checksum)" \
    || ko "schéma incompatible : live modifiée à tort"
[[ "$(row_count "$LIVE_DB")" == "$BEFORE_COUNT" ]] \
    && ok "schéma incompatible : live inchangé (count)" \
    || ko "schéma incompatible : count altéré"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C3 RESTORE CHARACTER: OK (${PASS} contrôles)"
else
    echo "C3 RESTORE CHARACTER: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
