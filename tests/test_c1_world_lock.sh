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

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB_DIR="${ROOT}/data/scripts/lib"
SANDBOX="${ROOT}/tests/.tmp-c1-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    release_world_lock 2>/dev/null || true
    rm -rf "$SANDBOX"
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
rm -rf "$SANDBOX"
mkdir -p "${SANDBOX}/rt" "$BIN"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
# État verrou assaini pour ce shell de test (ou participation si né sous verrou).
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
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
         admin/purgeInactivePlayers.sh admin/resetServer.sh admin/performFullMaintenance.sh; do
    if grep -q 'acquire_world_lock' "${ROOT}/data/scripts/${f}"; then
        ok "${f} acquiert le verrou monde"
    else
        ko "${f} n'acquiert PAS le verrou monde"
    fi
done
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
with_world_lock --required sleep 3 &
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
with_world_lock --required sleep 3 &
BACKUP_PID=$!
sleep 1
if timeout 10 bash -c "source '${LIB_DIR}/world_lock.sh'; export XDG_RUNTIME_DIR='${SANDBOX}/rt'; acquire_world_lock --required" 2>/dev/null; then
    ko "restore : verrou acquis pendant un backup"
else
    ok "restore exclu pendant un backup"
fi
wait "$BACKUP_PID" 2>/dev/null || true
# Et inversement : backup --try pendant un restore.
with_world_lock --required sleep 3 &
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

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C1 WORLD LOCK: OK (${PASS} contrôles)"
else
    echo "C1 WORLD LOCK: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
