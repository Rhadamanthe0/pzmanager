#!/usr/bin/env bash
# test_c1_world_lock.sh - Protocole unique verrou monde + état serveur (C1).
#
# Couvre :
#   (0) câblage statique : chaque opération du protocole acquiert le verrou
#       monde (start/stop/restart, backup, restore, wipe, purge, reset,
#       maintenance) ; backup --required + BACKUP_SKIPPED_LOCK ; fail-closed.
#   (1) start pendant maintenance exclu (exclusion mutuelle réelle).
#   (2) deux wipes concurrents exclus (flock exclusif).
#   (3) restore pendant backup exclu (et inversement).
#   (4) erreur bus systemd -> require_server_stopped refuse (fail-closed),
#       via mock systemctl dans PATH (aucun systemd réel requis).
#   (5) PrivateTmp : chemin sous XDG_RUNTIME_DIR (partagé, hors /tmp privé),
#       repli /tmp seulement si le runtime est absent.
#   (6) kill -9 du détenteur -> verrou libéré par le noyau (pas de fantôme).
#   (7) sous-script réentrant : pas de deadlock (compteur + fd hérité).
#
# Preuves réelles : processus bash séparés, vrai flock(1), mock systemctl par
# PATH. Isolé : XDG_RUNTIME_DIR redirigé vers un sandbox (aucun impact sur
# l'installation). Sans flock sur l'hôte -> SKIP propre (vérifié en WSL/Linux).
set -euo pipefail
# Réserver aussi le repli : les sous-shells ne doivent jamais employer le compte réel.
TEST_FALLBACK_DIR="$(mktemp -d /tmp/pzmanager-pz-c1.XXXXXX)"
readonly TEST_FALLBACK_DIR
TEST_FALLBACK_INODE="$(stat -c '%d:%i' "$TEST_FALLBACK_DIR")"
readonly TEST_FALLBACK_INODE
WORLD_TEST_USER="${TEST_FALLBACK_DIR#/tmp/pzmanager-}"
export WORLD_TEST_USER
id() {
    if [[ "$*" == "-un" ]]; then printf '%s\n' "$WORLD_TEST_USER"
    else command id "$@"; fi
}
export -f id
remove_test_fallback() {
    if [[ -d "$TEST_FALLBACK_DIR" && ! -L "$TEST_FALLBACK_DIR" && -O "$TEST_FALLBACK_DIR" ]] \
       && [[ "$(stat -c '%d:%i' "$TEST_FALLBACK_DIR")" == "$TEST_FALLBACK_INODE" ]]; then
        rm -rf -- "$TEST_FALLBACK_DIR"
    else
        echo "[FAIL] cleanup du repli refusé : identité inattendue" >&2
        return 1
    fi
}

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB_DIR="${ROOT}/data/scripts/lib"
SANDBOX="$(mktemp -d "${ROOT}/tests/.tmp-c1.XXXXXX")"
readonly SANDBOX
SANDBOX_INODE="$(stat -c '%d:%i' "$SANDBOX")"
readonly SANDBOX_INODE
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    # Uniquement les jobs encore enregistrés comme vivants par ce shell.
    local job
    for job in $(jobs -pr); do
        kill "$job" 2>/dev/null || true
        wait "$job" 2>/dev/null || true
    done
    release_world_lock 2>/dev/null || true
    remove_test_fallback
    if [[ -d "$SANDBOX" && ! -L "$SANDBOX" && -O "$SANDBOX" ]] \
       && [[ "$(stat -c '%d:%i' "$SANDBOX")" == "$SANDBOX_INODE" ]]; then
        rm -rf -- "$SANDBOX"
    else
        echo "[FAIL] cleanup sandbox refusé : identité inattendue" >&2
        return 1
    fi
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible sur cet hôte — test C1 à exécuter sous Linux/WSL." >&2
    exit 0
fi

# --- Libs réelles -------------------------------------------------------------
# shellcheck disable=SC1090
source "${LIB_DIR}/world_lock.sh"
# shellcheck disable=SC1090
source "${LIB_DIR}/server_state.sh"
# shellcheck disable=SC1090
source "${LIB_DIR}/common.sh"

# --- Isolation ----------------------------------------------------------------
mkdir -p "${SANDBOX}/rt" "$BIN"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
# État verrou assaini pour ce shell de test (ou participation si né sous verrou).
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : 1>&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
    PZ_WORLD_LOCK_DEPTH=0; PZ_WORLD_LOCK_FD=""
    export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
fi
export PZ_SERVICE_NAME="zomboid.service"

# --- Mock systemctl (cas 4) ----------------------------------------------------
# MOCK_SYSTEMCTL_MODE : error|active|inactive|activating|deactivating|failed|weird
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
        weird) printf 'ActiveState=banana\nSubState=weird\nResult=success\n' ;;
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

# --- (0) Câblage statique -------------------------------------------------------
echo "== (0) câblage =="
for f in core/pz.sh backup/dataBackup.sh backup/restoreZomboidData.sh admin/wipeMapTile.sh \
         admin/resetServer.sh admin/performFullMaintenance.sh; do
    if grep -q 'acquire_world_lock' "${ROOT}/data/scripts/${f}"; then
        ok "${f} acquiert le verrou monde"
    else
        ko "${f} n'acquiert PAS le verrou monde"
    fi
done
# La purge acquiert WORLD par le courtier et valide le FD dans le worker.
# Son parcours réel et la contention sont exercés par test_accounts_safety.py.
purge="${ROOT}/data/scripts/admin/purgeInactivePlayers.sh"
verified_before_write="$(awk '/sqlite3 -bail/ { print n+0; exit }
    /^[[:space:]]*python3 .*verify-worker.*\|\| exit 1/ { n++ }' "$purge")"
if grep -qF 'readonly ADMISSION_HELPER="${SCRIPT_DIR}/../internal/writing_start_admission.py"' "$purge" &&
   grep -qF 'readonly ACCOUNT_HELPER="${SCRIPT_DIR}/../lib/account_safety.py"' "$purge" &&
   grep -qF 'if [[ "$DRY_RUN" != true && "$ADMITTED_WORKER" != true ]]; then' "$purge" &&
   grep -qF 'exec python3 "$ADMISSION_HELPER" run --lock-path "$_purge_lock" --unit "$PZ_SERVICE_NAME" --' "$purge" &&
   grep -qF 'bash "$0" --admitted-worker "${ORIGINAL_ARGS[@]}"' "$purge" &&
   grep -qF 'if [[ "$ADMITTED_WORKER" == true ]]; then' "$purge" &&
   grep -qF 'python3 "$ACCOUNT_HELPER" verify-worker || exit 1' "$purge" &&
   [[ "$verified_before_write" =~ ^[0-9]+$ ]] && (( verified_before_write >= 2 )); then
    ok "purgeInactivePlayers.sh : courtier WORLD et validation worker avant écriture"
else
    ko "purgeInactivePlayers.sh : courtier WORLD ou validation worker absent avant écriture"
fi
grep -q 'BACKUP_SKIPPED_LOCK' "${ROOT}/data/scripts/backup/dataBackup.sh" \
    && ok "dataBackup.sh émet BACKUP_SKIPPED_LOCK" \
    || ko "dataBackup.sh : BACKUP_SKIPPED_LOCK absent"
grep -q -- '--required' "${ROOT}/data/scripts/backup/dataBackup.sh" \
    && ok "dataBackup.sh accepte --required" \
    || ko "dataBackup.sh : --required absent"
for f in admin/wipeMapTile.sh backup/restoreZomboidData.sh; do
    if grep -q 'assert_server_stopped_proven' "${ROOT}/data/scripts/${f}"; then
        ok "${f} exige l'arrêt prouvé (assert)"
    else
        ko "${f} : assert_server_stopped_proven absent"
    fi
done
grep -q 'server_is_active_strict' "${ROOT}/data/scripts/lib/common.sh" \
    && ok "common.sh fournit server_is_active_strict" \
    || ko "common.sh : server_is_active_strict absent"
grep -q 'world_lock.sh' "${ROOT}/data/scripts/lib/common.sh" \
    && grep -q 'server_state.sh' "${ROOT}/data/scripts/lib/common.sh" \
    && ok "common.sh source les deux libs (optionnel)" \
    || ko "common.sh : sourcing des libs absent"

# --- (1) start pendant maintenance exclu -----------------------------------------
echo "== (1) start pendant maintenance =="
# `exec` : le subshell est REMPLACÉ par sleep (même pid, pas d'enfant héritier
# du fd) — le kill ci-dessous libère donc réellement le verrou (cf. cas 6).
with_world_lock --required exec sleep 15 &
MAINT_PID=$!
sleep 1
if acquire_world_lock --try; then
    ko "start concurrent : verrou acquis pendant une maintenance (aurait dû refuser)"
    release_world_lock
else
    ok "start concurrent exclu pendant maintenance"
fi
if with_world_lock --required true; then
    ko "with_world_lock --required a traversé une maintenance"
else
    ok "with_world_lock --required refuse pendant maintenance"
fi
kill "$MAINT_PID" 2>/dev/null || true
wait "$MAINT_PID" 2>/dev/null || true
if acquire_world_lock --try; then
    ok "verrou de nouveau prenable après la maintenance"
    release_world_lock
else
    ko "verrou toujours tenu après la fin de la maintenance"
fi

# --- (2) deux wipes concurrents ----------------------------------------------------
echo "== (2) wipes concurrents =="
with_world_lock --required exec sleep 3 &
WIPE_PID=$!
sleep 1
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --try"; then
    ko "2e wipe : verrou acquis pendant le 1er"
else
    ok "2e wipe exclu pendant le 1er (flock exclusif)"
fi
wait "$WIPE_PID" 2>/dev/null || true
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --try && release_world_lock"; then
    ok "wipe ultérieur prenable après libération"
else
    ko "verrou non libéré après le 1er wipe"
fi

# --- (3) restore pendant backup exclu -----------------------------------------------
echo "== (3) restore pendant backup =="
with_world_lock --required exec sleep 3 &
BACKUP_PID=$!
sleep 1
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --required" 2>/dev/null; then
    ko "restore : verrou acquis pendant un backup"
else
    ok "restore exclu pendant un backup"
fi
wait "$BACKUP_PID" 2>/dev/null || true
# Et inversement : backup --try pendant un restore.
with_world_lock --required exec sleep 3 &
RESTORE_PID=$!
sleep 1
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --try" 2>/dev/null; then
    ko "backup : verrou acquis pendant un restore"
else
    ok "backup exclu pendant un restore"
fi
wait "$RESTORE_PID" 2>/dev/null || true

# --- (4) bus systemd en erreur -> refus fail-closed ----------------------------------
echo "== (4) erreur bus systemd =="
export MOCK_SYSTEMCTL_MODE=error
if ( require_server_stopped "TestC1" ) 2>/dev/null; then
    ko "require_server_stopped a PASSÉ sur bus en erreur (aurait dû refuser)"
else
    ok "require_server_stopped refuse sur bus en erreur"
fi
if ( assert_server_stopped_proven "TestC1" ) 2>/dev/null; then
    ko "assert a PASSÉ sur bus en erreur"
else
    ok "assert refuse sur bus en erreur"
fi
if ( server_is_active_strict ) 2>/dev/null; then
    ko "strict a répondu actif sur bus en erreur"
else
    ok "strict ne répond pas « arrêté » sur bus en erreur"
fi
if server_is_active 2>/dev/null; then
    ko "server_is_active (compat) aurait dû rester faux sur erreur"
else
    ok "server_is_active (compat) reste faux sur erreur, sans mourir"
fi
[[ "$(server_state)" == "error" ]] \
    && ok "server_state=error sur bus en panne" \
    || ko "server_state=$(server_state) (attendu error)"

export MOCK_SYSTEMCTL_MODE=inactive
( require_server_stopped "TestC1" ) 2>/dev/null \
    && ok "require passe sur inactive prouvé" \
    || ko "require a refusé sur inactive prouvé"
( assert_server_stopped_proven "TestC1" ) 2>/dev/null \
    && ok "assert passe sur inactive prouvé" \
    || ko "assert a refusé sur inactive prouvé"

export MOCK_SYSTEMCTL_MODE=active
( require_server_stopped "TestC1" ) 2>/dev/null \
    && ko "require a PASSÉ sur serveur actif" \
    || ok "require refuse sur serveur actif"

export MOCK_SYSTEMCTL_MODE=failed
( assert_server_stopped_proven "TestC1" ) 2>/dev/null \
    && ko "assert a PASSÉ sur failed" \
    || ok "assert refuse sur failed (pas d'arrêt prouvé)"

export MOCK_SYSTEMCTL_MODE=activating
( assert_server_stopped_proven "TestC1" ) 2>/dev/null \
    && ko "assert a PASSÉ sur activating" \
    || ok "assert refuse sur activating (pas d'arrêt prouvé)"

export MOCK_SYSTEMCTL_MODE=weird
[[ "$(server_state)" == "unknown" ]] \
    && ok "server_state=unknown sur ActiveState inattendu" \
    || ko "server_state=$(server_state) (attendu unknown)"
( require_server_stopped "TestC1" ) 2>/dev/null \
    && ko "require a PASSÉ sur état unknown" \
    || ok "require refuse sur état unknown"

# Dégradation sans lib server_state (inspection directe du exit code) :
unset -f server_state
export MOCK_SYSTEMCTL_MODE=error
( require_server_stopped "TestC1" ) 2>/dev/null \
    && ko "require (dégradé) a PASSÉ sur bus en erreur" \
    || ok "require (dégradé, sans lib) refuse sur bus en erreur"
export MOCK_SYSTEMCTL_MODE=inactive
( require_server_stopped "TestC1" ) 2>/dev/null \
    && ok "require (dégradé) passe sur exit 3 (arrêté)" \
    || ko "require (dégradé) a refusé sur exit 3"
# shellcheck disable=SC1090
source "${LIB_DIR}/server_state.sh"

# --- (5) PrivateTmp : chemin sous XDG_RUNTIME_DIR -------------------------------------
echo "== (5) chemin du verrou =="
P="$(world_lock_path)"
if [[ "$P" == "${SANDBOX}/rt/pzmanager/world.lock" ]]; then
    ok "verrou sous XDG_RUNTIME_DIR : $P"
else
    ko "chemin inattendu : $P"
fi
if [[ "$P" == /tmp/* ]]; then
    ko "verrou sous /tmp malgré un runtime présent (sensible à PrivateTmp)"
else
    ok "verrou hors /tmp quand le runtime existe (insensible à PrivateTmp)"
fi
if [[ -d "${SANDBOX}/rt/pzmanager" ]]; then
    M="$(stat -c %a "${SANDBOX}/rt/pzmanager" 2>/dev/null || echo ?)"
    if [[ "$M" == "700" ]]; then
        ok "dossier verrou en 0700"
    elif [[ "$M" == "?" ]]; then
        echo "[SKIP-local] stat du mode indisponible sur cet hôte" >&2
    else
        # FS sans chmod réel (NTFS...) : prouver la commande émise, pas l'effet.
        if grep -q 'chmod 0700' "${LIB_DIR}/world_lock.sh"; then
            echo "[SKIP-local] mode lu=$M (FS sans chmod) — 0700 imposé par le code" >&2
        else
            ko "dossier verrou en mode $M (attendu 0700)"
        fi
    fi
else
    ko "dossier ${SANDBOX}/rt/pzmanager non créé"
fi
export XDG_RUNTIME_DIR="${SANDBOX}/inexistant"
P2="$(world_lock_path)"
EXPECTED_FALLBACK="/tmp/pzmanager-$(id -un)/world.lock"
if [[ "$P2" == "$EXPECTED_FALLBACK" ]]; then
    ok "repli /tmp si runtime absent : $P2"
else
    ko "repli inattendu : $P2 (attendu $EXPECTED_FALLBACK)"
fi
export XDG_RUNTIME_DIR="${SANDBOX}/rt"

# --- (5b) Chemins et fichiers prépositionnés : aucun effet hors du verrou ------
echo "== (5b) identité/permissions du verrou monde =="
STATE_DIR="${SANDBOX}/rt/pzmanager"
LOCK="${STATE_DIR}/world.lock"
TARGET="${SANDBOX}/external-data"
printf 'intact\n' > "$TARGET"
rm -f -- "$LOCK"
ln -s -- "$TARGET" "$LOCK"
if world_lock_path >/dev/null 2>&1; then
    ko "lien symbolique world.lock accepté"
else
    ok "lien symbolique world.lock rejeté"
fi
if acquire_world_lock --try >/dev/null 2>&1; then
    ko "acquire_world_lock a suivi le lien symbolique world.lock"
    release_world_lock
else
    ok "acquire_world_lock refuse le lien symbolique"
fi
[[ "$(cat "$TARGET")" == intact ]] &&
    ok "cible world.lock intacte" || ko "cible world.lock modifiée"
rm -f -- "$LOCK"

ln -- "$TARGET" "$LOCK"
if world_lock_path >/dev/null 2>&1; then
    ko "verrou hardlink accepté"
else
    ok "verrou hardlink rejeté"
fi
[[ "$(cat "$TARGET")" == intact ]] &&
    ok "cible hardlink intacte" || ko "cible hardlink modifiée"
rm -f -- "$LOCK"
: > "$LOCK"

mv -T -- "$STATE_DIR" "${SANDBOX}/pzmanager.saved"
mkdir -m 0755 -- "${SANDBOX}/other-state"
ln -s -- "${SANDBOX}/other-state" "$STATE_DIR"
if world_lock_path >/dev/null 2>&1; then
    ko "répertoire verrou symbolique accepté"
else
    ok "répertoire verrou symbolique rejeté"
fi
[[ "$(stat -c %a -- "${SANDBOX}/other-state")" == 755 ]] &&
    ok "permissions de la cible symlink inchangées" ||
    ko "chmod a suivi le lien symbolique du répertoire"
rm -f -- "$STATE_DIR"
mv -T -- "${SANDBOX}/pzmanager.saved" "$STATE_DIR"

mkdir -p -- "${SANDBOX}/untrusted/runtime"
chmod 0777 -- "${SANDBOX}/untrusted"
export XDG_RUNTIME_DIR="${SANDBOX}/untrusted/runtime"
if world_lock_path >/dev/null 2>&1; then
    ko "parent inscriptible non sticky accepté"
else
    ok "parent inscriptible non sticky rejeté"
fi
[[ ! -e "${SANDBOX}/untrusted/runtime/pzmanager" ]] &&
    ok "aucun état créé sous un parent remplaçable" ||
    ko "état créé sous un parent remplaçable"
export XDG_RUNTIME_DIR=rt
if world_lock_path >/dev/null 2>&1; then
    ko "XDG_RUNTIME_DIR relatif accepté"
else
    ok "XDG_RUNTIME_DIR relatif refusé"
fi
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
[[ "$(world_lock_path)" == "$LOCK" ]] &&
    ok "chemin nominal restauré après refus" ||
    ko "verrou indisponible après tests adverses"

# --- (6) kill -9 libère le verrou -------------------------------------------------------
echo "== (6) kill -9 =="
cat > "${SANDBOX}/holder.sh" <<'HOLDEREOF'
#!/usr/bin/env bash
set -euo pipefail
source "${1}/world_lock.sh"
export XDG_RUNTIME_DIR="${2}"
acquire_world_lock --required || exit 2
exec sleep 30
HOLDEREOF
bash "${SANDBOX}/holder.sh" "$LIB_DIR" "${SANDBOX}/rt" &
HOLDER_PID=$!
sleep 1
if acquire_world_lock --try; then
    ko "verrou prenable alors que le détenteur vit"
    release_world_lock
else
    ok "verrou tenu par le détenteur"
fi
kill -9 "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
sleep 1
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --try && release_world_lock"; then
    ok "kill -9 : verrou libéré par le noyau"
else
    ko "kill -9 : verrou toujours tenu (fantôme)"
fi

# --- (6b) l'environnement seul ne prouve pas la réentrance -----------------------
echo "== (6b) fausse réentrance =="
cat > "${SANDBOX}/forged-child.sh" <<'FORGEDEOF'
#!/usr/bin/env bash
set -euo pipefail
source "${1}/world_lock.sh"
case "$2" in
    stdout) PZ_WORLD_LOCK_DEPTH=1; PZ_WORLD_LOCK_FD=1 ;;
    other) exec {PZ_WORLD_LOCK_FD}>"$3"; flock -n "$PZ_WORLD_LOCK_FD"; PZ_WORLD_LOCK_DEPTH=1 ;;
    unlocked) exec {PZ_WORLD_LOCK_FD}>"$(world_lock_path)"; PZ_WORLD_LOCK_DEPTH=1 ;;
    missing-fd) PZ_WORLD_LOCK_DEPTH=1; PZ_WORLD_LOCK_FD= ;;
    missing-depth) exec {PZ_WORLD_LOCK_FD}>"$(world_lock_path)"; PZ_WORLD_LOCK_DEPTH=0 ;;
    malformed-depth) PZ_WORLD_LOCK_DEPTH=invalid; PZ_WORLD_LOCK_FD=1 ;;
esac
if acquire_world_lock --try; then exit 10; fi
# Un refus ne ferme ni ne déverrouille le descripteur reçu.
if [[ "$2" == other ]]; then
    [[ -e "/proc/self/fd/$PZ_WORLD_LOCK_FD" ]]
    if flock -n "$3" true; then exit 11; fi
fi
FORGEDEOF
acquire_world_lock --required
for forged in stdout other unlocked missing-fd missing-depth malformed-depth; do
    if bash "${SANDBOX}/forged-child.sh" "$LIB_DIR" "$forged" "${SANDBOX}/other.lock"; then
        ok "réentrance falsifiée refusée : $forged"
    else
        ko "réentrance falsifiée acceptée ou FD reçu altéré : $forged (rc=$?)"
    fi
done
release_world_lock
# Même libre, un état annoncé invalide ne devient pas une acquisition normale.
for forged in stdout other unlocked missing-fd missing-depth malformed-depth; do
    if bash "${SANDBOX}/forged-child.sh" "$LIB_DIR" "$forged" "${SANDBOX}/other.lock"; then
        ok "état invalide refusé sans détenteur : $forged"
    else
        ko "état invalide accepté sans détenteur : $forged (rc=$?)"
    fi
done

# --- (7) réentrance parent/enfant ----------------------------------------------------------
echo "== (7) réentrance =="
acquire_world_lock --required || { ko "acquisition initiale impossible"; }
acquire_world_lock --required \
    && ok "double acquire même processus sans deadlock" \
    || ko "double acquire même processus refusé"
[[ "${PZ_WORLD_LOCK_DEPTH:-0}" == "2" ]] \
    && ok "compteur de profondeur = 2" \
    || ko "compteur = ${PZ_WORLD_LOCK_DEPTH:-?} (attendu 2)"
cat > "${SANDBOX}/child.sh" <<'CHILDEOF'
#!/usr/bin/env bash
set -euo pipefail
source "${1}/world_lock.sh"
export XDG_RUNTIME_DIR="${2}"
acquire_world_lock --required || exit 3
echo "enfant participant (profondeur ${PZ_WORLD_LOCK_DEPTH})"
# Le petit-enfant doit vérifier le même OFD hérité, même après la fin de flock(1).
bash -c 'source "$1/world_lock.sh"; acquire_world_lock --required && release_world_lock' _ "$1"
release_world_lock
CHILDEOF
if timeout 10 bash "${SANDBOX}/child.sh" "$LIB_DIR" "${SANDBOX}/rt"; then
    ok "sous-script participant sans deadlock (fd hérité)"
else
    ko "sous-script bloqué/refusé alors que le parent tient le verrou (rc=$?)"
fi
release_world_lock
release_world_lock
[[ "${PZ_WORLD_LOCK_DEPTH:-?}" == "0" ]] \
    && ok "compteur revenu à 0 après releases" \
    || ko "compteur = ${PZ_WORLD_LOCK_DEPTH:-?} (attendu 0)"
release_world_lock \
    && ok "release surnuméraire sans effet (no-op)" \
    || ko "release surnuméraire en erreur"

# --- (8) l'enfant conserve le verrou après la mort du parent --------------------
echo "== (8) héritage après kill du parent =="
cat > "${SANDBOX}/inheriting-parent.sh" <<'PARENTEOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1/world_lock.sh"
acquire_world_lock --required
bash -c 'source "$1/world_lock.sh"; acquire_world_lock --required; echo "$BASHPID" > "$2/child.pid"; exec sleep 30' _ "$1" "$2" &
wait
PARENTEOF
bash "${SANDBOX}/inheriting-parent.sh" "$LIB_DIR" "$SANDBOX" &
PARENT_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "${SANDBOX}/child.pid" ]] && break
    sleep 0.05
done
if [[ -s "${SANDBOX}/child.pid" ]]; then
    CHILD_PID="$(cat "${SANDBOX}/child.pid")"
    kill -9 "$PARENT_PID"
    wait "$PARENT_PID" 2>/dev/null || true
    if acquire_world_lock --try; then
        ko "mort du parent : verrou perdu malgré l'enfant vivant"
        release_world_lock
    else
        ok "mort du parent : l'enfant conserve le verrou"
    fi
    kill "$CHILD_PID" 2>/dev/null || true
    for ((attempt=0; attempt<100; attempt++)); do
        if acquire_world_lock --try; then break; fi
        sleep 0.05
    done
    if [[ "$PZ_WORLD_LOCK_DEPTH" == 1 ]]; then
        ok "verrou libéré après la fin du dernier enfant"
        release_world_lock
    else
        ko "verrou encore tenu après la fin du dernier enfant"
    fi
else
    ko "enfant héritier non démarré"
fi

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C1 WORLD LOCK: OK (${PASS} contrôles)"
else
    echo "C1 WORLD LOCK: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
