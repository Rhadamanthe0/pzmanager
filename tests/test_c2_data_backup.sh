#!/usr/bin/env bash
# test_c2_data_backup.sh - Fiabilisation snapshots/data backups (C2).
#
# Couvre (dataBackup.sh uniquement) :
#   (0) câblage statique : staging .tmp + mv -T atomique, latest ln -sfnT +
#       mv -Tf (jamais rm -rf de latest), trap EXIT/INT/TERM, codes rsync
#       stricts (23 toujours échec, 24 toléré seulement en normal),
#       BACKUP_REQUIRED_LOCKED en --required.
#   (1) rsync 23 -> échec + aucun final publié.
#   (2) rsync 24 en normal -> succès ; en --required / --snapshot-only -> échec.
#   (3) disque plein (exit 11) -> échec sans publish.
#   (4) staging vide (rsync 0 sans Saves/db/Server) -> échec sans publish.
#   (5) staging résiduel (.tmp, y compris autre timestamp) -> nettoyé,
#       tmp propre réutilisé, succès.
#   (6) échec bascule latest (mock ln / mv) -> die (non-zéro).
#   (7) backup concurrent : normal -> 0 + BACKUP_SKIPPED_LOCK,
#       --required -> 1 + BACKUP_REQUIRED_LOCKED, aucun final.
#   (8) SIGTERM pendant rsync -> pas de final, pas de .tmp.
#   (9) répertoire réel nommé latest -> refuse sans rm -rf (sentinelle intacte).
#   (10) verrou monde occupé -> retry ~PZ_WORLD_LOCK_RETRIES x
#       PZ_WORLD_LOCK_RETRY_DELAY puis succès sans skip ; essais épuisés ->
#       exit 0 + BACKUP_SKIPPED_LOCK, rien publié.
#   Partout : aucun final incomplet (final absent ou contenant Saves/db/Server),
#   aucun .tmp résiduel.
#
# Preuves réelles : vrai script dataBackup.sh, vrais flock/mv/ln, rsync mocké
# par PATH (succès/échecs pilotés). Isolé : XDG_RUNTIME_DIR + BACKUP_DIR +
# PZ_SOURCE_DIR sous sandbox. source_env lit ${ROOT}/.env (qui écrase
# l'environnement exporté) : le test y pose un stub (sauvegarde + restauration
# du .env préexistant via trap EXIT) pour que l'env sandbox survive via les
# défauts `:=`. Ne touche à aucun backup réel.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/backup/dataBackup.sh"
SANDBOX="${ROOT}/tests/.tmp-c2-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"
HOLDER_PID=""

cleanup() {
    if [[ -n "${HOLDER_PID:-}" ]]; then kill "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""; fi
    # Orphelin éventuel du test SIGTERM (sleep du mock rsync) : best-effort.
    pkill -P $$ sleep 2>/dev/null || true
    # Restaure le .env préexistant (ou retire le stub posé par le test).
    if [[ -f "$ENV_BACKUP" ]]; then
        cp -p "$ENV_BACKUP" "$REPO_ENV"
    else
        rm -f "$REPO_ENV"
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible — test C2 à exécuter sous Linux/WSL." >&2
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
# Stub .env (sauvegarde d'abord) : sans lui, source_env crée/copie l'exemple
# (pollution) ou lit la prod (écrase l'env sandbox exporté ci-dessous).
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C2 (restauré en fin de test)\n' > "$REPO_ENV"

# --- Mocks -------------------------------------------------------------------
# rsync mocké : publie un staging plausible AVANT tout sleep (pour que le trap
# du parent ait quelque chose à nettoyer), dort si MOCK_RSYNC_SLEEP, sort avec
# MOCK_RSYNC_EXIT. MOCK_RSYNC_EMPTY=1 -> staging sans Saves/db/Server.
cat > "${BIN}/rsync" <<'MOCKEOF'
#!/usr/bin/env bash
dest="${@: -1}"
mkdir -p "$dest" 2>/dev/null || true
if [[ "${MOCK_RSYNC_EMPTY:-0}" == "1" ]]; then
    : > "$dest/nothing.bin" 2>/dev/null || true
else
    mkdir -p "$dest/Saves" 2>/dev/null || true
    echo dummy > "$dest/Saves/dummy.bin" 2>/dev/null || true
fi
if [[ -n "${MOCK_RSYNC_SLEEP:-}" ]]; then sleep "$MOCK_RSYNC_SLEEP"; fi
exit "${MOCK_RSYNC_EXIT:-0}"
MOCKEOF
chmod +x "${BIN}/rsync"
# ln / mv : échec forcé seulement sur les chemins latest (bascule), le publish
# staging (backup_*.tmp -> backup_*) passe toujours.
cat > "${BIN}/ln" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${MOCK_LN_FAIL:-0}" == "1" ]] && [[ " $* " == *"latest"* ]]; then
    echo "mock ln: forced failure on latest" >&2; exit 1
fi
exec /bin/ln "$@"
MOCKEOF
chmod +x "${BIN}/ln"
cat > "${BIN}/mv" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${MOCK_MV_FAIL:-0}" == "1" ]] && [[ " $* " == *"latest"* ]]; then
    echo "mock mv: forced failure on latest" >&2; exit 1
fi
exec /bin/mv "$@"
MOCKEOF
chmod +x "${BIN}/mv"
export PATH="${BIN}:$PATH"

# --- Helpers -----------------------------------------------------------------
# fresh_case <nom> : (re)crée SRC + BKP vierges, exporte l'env sandbox dans CE
# shell (appel direct, JAMAIS en substitution $() qui perdrait les exports),
# pose BKP (global). Réinitialise aussi les MOCK_* (pas de fuite entre cas).
BKP=""
fresh_case() {
    local name="$1"
    local src="${SANDBOX}/src-${name}"
    BKP="${SANDBOX}/bkp-${name}"
    rm -rf "$src" "$BKP"
    mkdir -p "$src/Saves" "$src/db" "$src/Server" "$BKP"
    echo "world" > "$src/Saves/player.bin"
    echo "db" > "$src/db/servertest.db"
    echo "ini" > "$src/Server/servertest.ini"
    export PZ_SOURCE_DIR="$src" BACKUP_DIR="$BKP" BACKUP_LATEST_LINK="$BKP/latest"
    export PZ_CONTROL_PIPE="${SANDBOX}/nopipe-${name}"
    export BACKUP_WARN_DELAY=0 RSYNC_RETRY_DELAY=0 BACKUP_PRUNE_DRY_RUN=1
    unset MOCK_RSYNC_EXIT MOCK_RSYNC_SLEEP MOCK_RSYNC_EMPTY MOCK_LN_FAIL MOCK_MV_FAIL
}
final_count() { find "$1" -maxdepth 1 -type d -name 'backup_*' 2>/dev/null | wc -l | tr -d ' '; }
tmp_left() { find "$1" -maxdepth 1 -name '*.tmp*' 2>/dev/null | wc -l | tr -d ' '; }
# Aucun final incomplet : chaque backup_* contient Saves ou db ou Server.
assert_no_partial() {
    local bkp="$1" ctx="$2" d
    for d in "$bkp"/backup_*; do
        [[ -d "$d" ]] || continue
        if [[ ! -d "$d/Saves" && ! -d "$d/db" && ! -d "$d/Server" ]]; then
            ko "${ctx} : final incomplet publié ($d sans Saves/db/Server)"
            return 1
        fi
    done
    return 0
}
run_backup() { bash "$SCRIPT" "$@" >"${SANDBOX}/out.log" 2>&1; }
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q '\.tmp' "$SCRIPT" && grep -q 'mv -T' "$SCRIPT" \
    && ok "staging .tmp + publish mv -T atomique" \
    || ko "staging .tmp / mv -T absents"
grep -q 'ln -sfnT' "$SCRIPT" && grep -q 'mv -Tf' "$SCRIPT" \
    && ok "latest atomique (ln -sfnT + mv -Tf)" \
    || ko "latest atomique absente"
if grep -q 'rm -rf "${BACKUP_LATEST_LINK}"' "$SCRIPT"; then
    ko "rm -rf direct de latest encore présent"
else
    ok "jamais de rm -rf direct de latest"
fi
grep -q 'répertoire réel' "$SCRIPT" \
    && ok "refus si latest est un répertoire réel" \
    || ko "garde répertoire-réel latest absente"
grep -q 'trap.*EXIT' "$SCRIPT" && grep -q 'trap.*INT.*TERM' "$SCRIPT" \
    && ok "trap EXIT/INT/TERM (nettoie .tmp)" \
    || ko "trap interruption absent"
grep -q 'BACKUP_REQUIRED_LOCKED' "$SCRIPT" \
    && ok "message BACKUP_REQUIRED_LOCKED présent" \
    || ko "BACKUP_REQUIRED_LOCKED absent"
grep -q 'BACKUP_SKIPPED_LOCK' "$SCRIPT" \
    && ok "message BACKUP_SKIPPED_LOCK conservé (non-régression C1)" \
    || ko "BACKUP_SKIPPED_LOCK absent (régression C1)"
grep -q -- '--required' "$SCRIPT" \
    && ok "--required accepté (non-régression C1)" \
    || ko "--required absent (régression C1)"
if grep -q 'pzmanager-backup-.*\.lock' "$SCRIPT"; then
    ko "verrou backup /tmp prévisible encore présent"
else
    ok "verrou backup : plus de chemin /tmp prévisible"
fi
grep -q 'private_state_path "backup.lock"' "$SCRIPT" \
    && ok "verrou backup : passe par private_state_path" \
    || ko "verrou backup : n'utilise pas private_state_path"

# --- (1) rsync 23 -> échec, rien publié ----------------------------------------
echo "== (1) rsync 23 =="
fresh_case c23
export MOCK_RSYNC_EXIT=23
if run_backup; then
    ko "rsync 23 : exit 0 (attendu échec)"; show_out
else
    ok "rsync 23 : échec (exit $?)"
fi
(( $(final_count "$BKP") == 0 )) && ok "rsync 23 : aucun final publié" || { ko "rsync 23 : final publié à tort"; show_out; }
(( $(tmp_left "$BKP") == 0 )) && ok "rsync 23 : pas de .tmp résiduel" || ko "rsync 23 : .tmp résiduel"
assert_no_partial "$BKP" "rsync 23" && ok "rsync 23 : aucun incomplet" || true

# --- (2) rsync 24 : normal OK, required/snapshot-only KO -------------------------
echo "== (2) rsync 24 =="
fresh_case c24ok
export MOCK_RSYNC_EXIT=24
if run_backup; then
    ok "rsync 24 normal : succès"
else
    ko "rsync 24 normal : échec à tort"; show_out
fi
(( $(final_count "$BKP") == 1 )) && ok "rsync 24 normal : un final publié" || { ko "rsync 24 normal : final=$(final_count "$BKP") (attendu 1)"; show_out; }
[[ -L "${BKP}/latest" ]] && ok "rsync 24 normal : latest pointe" || { ko "rsync 24 normal : latest absent"; show_out; }
(( $(tmp_left "$BKP") == 0 )) && ok "rsync 24 normal : pas de .tmp" || ko "rsync 24 normal : .tmp résiduel"
assert_no_partial "$BKP" "rsync 24 normal" && ok "rsync 24 normal : final complet" || true
sleep 1.1

fresh_case c24req
export MOCK_RSYNC_EXIT=24
if run_backup --required; then
    ko "rsync 24 --required : succès à tort (safety)"; show_out
else
    ok "rsync 24 --required : échec exigé"
fi
(( $(final_count "$BKP") == 0 )) && ok "rsync 24 --required : rien publié" || ko "rsync 24 --required : final publié à tort"
(( $(tmp_left "$BKP") == 0 )) && ok "rsync 24 --required : pas de .tmp" || ko "rsync 24 --required : .tmp résiduel"

fresh_case c24snap
export MOCK_RSYNC_EXIT=24
if run_backup --snapshot-only; then
    ko "rsync 24 --snapshot-only : succès à tort (safety)"; show_out
else
    ok "rsync 24 --snapshot-only : échec exigé"
fi
(( $(final_count "$BKP") == 0 )) && ok "rsync 24 --snapshot-only : rien publié" || ko "rsync 24 --snapshot-only : final publié à tort"

# --- (3) disque plein (11) -------------------------------------------------------
echo "== (3) disque plein =="
fresh_case cfull
export MOCK_RSYNC_EXIT=11
if run_backup; then
    ko "exit 11 : succès à tort"; show_out
else
    ok "exit 11 : échec"
fi
(( $(final_count "$BKP") == 0 )) && ok "exit 11 : rien publié" || ko "exit 11 : final publié à tort"
(( $(tmp_left "$BKP") == 0 )) && ok "exit 11 : pas de .tmp" || ko "exit 11 : .tmp résiduel"
assert_no_partial "$BKP" "exit 11" && ok "exit 11 : aucun incomplet" || true

# --- (4) staging vide -------------------------------------------------------------
echo "== (4) staging vide =="
fresh_case cempty
export MOCK_RSYNC_EXIT=0 MOCK_RSYNC_EMPTY=1
if run_backup; then
    ko "staging vide : succès à tort"; show_out
else
    ok "staging vide : échec (validation)"
fi
(( $(final_count "$BKP") == 0 )) && ok "staging vide : rien publié" || ko "staging vide : final publié à tort"
(( $(tmp_left "$BKP") == 0 )) && ok "staging vide : pas de .tmp" || ko "staging vide : .tmp résiduel"

# --- (5) .tmp résiduel -> tmp propre -----------------------------------------------
echo "== (5) tmp résiduel =="
fresh_case cstale
mkdir -p "$BKP/backup_2099-01-01_00h00m00s.tmp"
echo stale > "$BKP/backup_2099-01-01_00h00m00s.tmp/stale"
export MOCK_RSYNC_EXIT=0
if run_backup; then
    ok "tmp résiduel : succès avec tmp propre"
else
    ko "tmp résiduel : échec à tort"; show_out
fi
(( $(final_count "$BKP") == 1 )) && ok "tmp résiduel : un final publié" || { ko "tmp résiduel : final=$(final_count "$BKP")"; show_out; }
(( $(tmp_left "$BKP") == 0 )) && ok "tmp résiduel : pas de .tmp restant" || ko "tmp résiduel : .tmp restant"
if grep -rq "stale" "$BKP"/backup_* 2>/dev/null; then
    ko "tmp résiduel : contenu périmé fusionné dans le final"
else
    ok "tmp résiduel : final sans trace du stale"
fi
sleep 1.1

# --- (6) échec bascule latest ---------------------------------------------------------
echo "== (6) latest ln/mv =="
fresh_case cln
export MOCK_RSYNC_EXIT=0 MOCK_LN_FAIL=1
if run_backup; then
    ko "mock ln fail : succès à tort"; show_out
else
    ok "mock ln fail : die (non-zéro)"
fi
(( $(tmp_left "$BKP") == 0 )) && ok "mock ln fail : pas de .tmp latest" || ko "mock ln fail : .tmp latest restant"

fresh_case cmv
export MOCK_RSYNC_EXIT=0 MOCK_MV_FAIL=1
if run_backup; then
    ko "mock mv fail : succès à tort"; show_out
else
    ok "mock mv fail : die (non-zéro)"
fi
(( $(tmp_left "$BKP") == 0 )) && ok "mock mv fail : pas de .tmp latest" || ko "mock mv fail : .tmp latest restant"

# --- (7) concurrence --------------------------------------------------------------------
echo "== (7) concurrence =="
fresh_case clock
export MOCK_RSYNC_EXIT=0
# Verrou tenu au même endroit que le script : répertoire privé (cf. fix
# c8c38a9). La fonction réelle est sourcée, pas le chemin dupliqué.
# shellcheck disable=SC1091
source "${ROOT}/data/scripts/lib/common.sh"
LOCKFILE="$(private_state_path "backup.lock")"
# Holder SANS fork : le subshell est REMPLACÉ par sleep (même pid, fd hérité) —
# le kill libère donc réellement le verrou (sinon l'enfant sleep orphelin
# garderait le fd et le verrou jusqu'à la fin de son sleep).
( exec {HFD}>"$LOCKFILE" && flock -n "$HFD" && exec sleep 15 ) &
HOLDER_PID=$!
sleep 1
if ! kill -0 "$HOLDER_PID" 2>/dev/null; then
    ko "holder concurrence : verrou non tenu (holder mort)"
    HOLDER_PID=""
fi
if run_backup; then
    rc=0
else
    rc=$?
fi
out="$(cat "${SANDBOX}/out.log")"
if (( rc == 0 )) && grep -q 'BACKUP_SKIPPED_LOCK' <<<"$out"; then
    ok "concurrent normal : 0 + BACKUP_SKIPPED_LOCK"
else
    ko "concurrent normal : rc=$rc (attendu 0 + BACKUP_SKIPPED_LOCK)"; show_out
fi
(( $(final_count "$BKP") == 0 )) && ok "concurrent normal : rien publié" || ko "concurrent normal : final publié à tort"
if run_backup --required; then
    rcr=0
else
    rcr=$?
fi
out="$(cat "${SANDBOX}/out.log")"
if (( rcr == 1 )) && grep -q 'BACKUP_REQUIRED_LOCKED' <<<"$out"; then
    ok "concurrent --required : 1 + BACKUP_REQUIRED_LOCKED"
else
    ko "concurrent --required : rc=$rcr (attendu 1 + BACKUP_REQUIRED_LOCKED)"; show_out
fi
(( $(final_count "$BKP") == 0 )) && ok "concurrent --required : rien publié" || ko "concurrent --required : final publié à tort"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""

# --- (8) SIGTERM pendant rsync --------------------------------------------------------------
echo "== (8) SIGTERM =="
fresh_case cterm
export MOCK_RSYNC_EXIT=0 MOCK_RSYNC_SLEEP=8
bash "$SCRIPT" >"${SANDBOX}/out.log" 2>&1 &
TPID=$!
sleep 2
kill -TERM "$TPID" 2>/dev/null || true
if wait "$TPID" 2>/dev/null; then
    ko "SIGTERM : exit 0 (attendu non-zéro)"; show_out
else
    ok "SIGTERM : interrompu (non-zéro)"
fi
(( $(final_count "$BKP") == 0 )) && ok "SIGTERM : pas de final" || ko "SIGTERM : final publié à tort"
(( $(tmp_left "$BKP") == 0 )) && ok "SIGTERM : pas de .tmp" || ko "SIGTERM : .tmp résiduel"
assert_no_partial "$BKP" "SIGTERM" && ok "SIGTERM : aucun incomplet" || true
unset MOCK_RSYNC_SLEEP

# --- (9) latest = répertoire réel --------------------------------------------------------------
echo "== (9) latest réel =="
fresh_case creal
export MOCK_RSYNC_EXIT=0
mkdir -p "${BKP}/latest"
echo sentinel > "${BKP}/latest/sentinel.txt"
if run_backup; then
    ko "latest réel : succès à tort"; show_out
else
    ok "latest réel : refus (non-zéro)"
fi
if [[ -d "${BKP}/latest" && ! -L "${BKP}/latest" && -f "${BKP}/latest/sentinel.txt" ]]; then
    ok "latest réel : répertoire + sentinelle intacts (pas de rm -rf)"
else
    ko "latest réel : répertoire altéré ou supprimé"
fi

# --- (10) attente verrou monde (retry, cf. fix a49ebd2) ----------------------------------
echo "== (10) attente verrou monde =="
fresh_case cwait
export MOCK_RSYNC_EXIT=0 PZ_WORLD_LOCK_RETRIES=30 PZ_WORLD_LOCK_RETRY_DELAY=1
# shellcheck disable=SC1091
source "${ROOT}/data/scripts/lib/world_lock.sh"
WL="$(world_lock_path)"
mkdir -p "$(dirname "$WL")"
( exec {WHFD}>"$WL" && flock -n "$WHFD" && exec sleep 4 ) &
HOLDER_PID=$!
sleep 1
if run_backup; then rc=0; else rc=$?; fi
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
out="$(cat "${SANDBOX}/out.log")"
if (( rc == 0 )) && grep -q 'BACKUP_WAITING_LOCK OK' <<<"$out" && ! grep -q 'BACKUP_SKIPPED_LOCK' <<<"$out"; then
    ok "attente monde : backup passe après libération (pas de skip)"
else
    ko "attente monde : rc=$rc (attendu 0 sans skip)"; show_out
fi
(( $(final_count "$BKP") == 1 )) && ok "attente monde : un final publié" || { ko "attente monde : final=$(final_count "$BKP") (attendu 1)"; show_out; }
# Essais épuisés -> skip propre (exit 0 + BACKUP_SKIPPED_LOCK).
fresh_case cwaitko
export MOCK_RSYNC_EXIT=0 PZ_WORLD_LOCK_RETRIES=2 PZ_WORLD_LOCK_RETRY_DELAY=1
( exec {WHFD}>"$WL" && flock -n "$WHFD" && exec sleep 15 ) &
HOLDER_PID=$!
sleep 1
if run_backup; then rc=0; else rc=$?; fi
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
out="$(cat "${SANDBOX}/out.log")"
if (( rc == 0 )) && grep -q 'BACKUP_SKIPPED_LOCK' <<<"$out"; then
    ok "attente épuisée : 0 + BACKUP_SKIPPED_LOCK"
else
    ko "attente épuisée : rc=$rc (attendu 0 + skip)"; show_out
fi
(( $(final_count "$BKP") == 0 )) && ok "attente épuisée : rien publié" || ko "attente épuisée : final publié à tort"
unset PZ_WORLD_LOCK_RETRIES PZ_WORLD_LOCK_RETRY_DELAY

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C2 DATA BACKUP: OK (${PASS} contrôles)"
else
    echo "C2 DATA BACKUP: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
