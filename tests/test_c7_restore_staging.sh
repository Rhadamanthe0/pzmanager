#!/usr/bin/env bash
# test_c7_restore_staging.sh - Restauration via staging + rollback (C7).
#
# Couvre (data/scripts/backup/restoreZomboidData.sh uniquement) :
#   (0) câblage statique : staging mktemp -d sous PZ_HOME + trap EXIT/INT/TERM,
#       ordre main (copie -> validation staging -> mv OLD -> swap),
#       validate_staging_dir, validate_restored_live (compte mondes > 0),
#       rollback_live, verrou monde --required + arrêt prouvé (non-régression
#       C1), OLD jamais supprimé, pas de start auto.
#   (1) succès nominal : live remplacé par le backup, OLD conservé (contenu
#       live d'origine), staging nettoyé, résumé à 1 monde.
#   (2) archive corrompue (Saves vide ; dir totalement vide) -> die, live
#       intact, aucun OLD créé.
#   (3) manque d'espace (mock rsync exit 11 sur swap) -> rollback, live
#       intact (= contenu d'origine), OLD conservé.
#   (4) erreur extraction/copie (mock rsync exit 23 sur copie staging) ->
#       die, live intact, aucun OLD créé (mv jamais atteint).
#   (5) SIGTERM pendant le swap -> exit non-zéro, live ou OLD récupérable
#       (non vide), staging nettoyé.
#   (6) validation finale : backup Server seul (0 monde) -> swap puis échec
#       final + rollback, live intact, OLD conservé ; staging vide (mock
#       EMPTY) -> refus avant bascule, live intact.
#
# Preuves réelles : vrai script restoreZomboidData.sh, vrai flock/mv/rsync
# (rsync mocké par PATH mais DÉLÉGUÉ au vrai /usr/bin/rsync pour la copie —
# seuls le code de sortie et le sommeil sont pilotés), mock systemctl par
# PATH (état serveur piloté). Isolé : XDG_RUNTIME_DIR + PZ_HOME +
# PZ_SOURCE_DIR sous sandbox, stub .env (sauvegarde + restauration du .env
# préexistant via trap EXIT). Ne touche à aucun monde réel.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/backup/restoreZomboidData.sh"
SANDBOX="${ROOT}/tests/.tmp-c7-$$"
BIN="${SANDBOX}/bin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"

cleanup() {
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
    echo "[SKIP-local] flock indisponible — test C7 à exécuter sous Linux/WSL." >&2
    exit 0
fi
if ! command -v /usr/bin/rsync >/dev/null 2>&1; then
    echo "[SKIP-local] rsync absent — test C7 à exécuter sous Linux/WSL." >&2
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
# Stub .env (cf. tests C2/C3) : source_env le lit puis applique les défauts
# `:=`, donc l'env sandbox exporté ci-dessous survit.
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C7 (restauré en fin de test)\n' > "$REPO_ENV"

# --- Mocks -------------------------------------------------------------------
# systemctl : état serveur piloté (défaut inactive = arrêt prouvé).
cat > "${BIN}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
mode="${MOCK_SYSTEMCTL_MODE:-inactive}"
if [[ " $* " == *" show "* ]]; then
    case "$mode" in
        error) echo "Failed to connect to bus: No medium found" >&2; exit 1 ;;
        active) printf 'ActiveState=active\nSubState=running\nResult=success\n' ;;
        inactive) printf 'ActiveState=inactive\nSubState=dead\nResult=success\n' ;;
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
# rsync : DÉLÈGUE la copie au vrai /usr/bin/rsync (fichiers réels), puis
# pilote le code de sortie par n° d'appel (1 = backup->staging,
# 2 = staging->live, 3 = rollback OLD->live, jamais forcé en échec).
# MOCK_RSYNC_FAIL_FIRST / MOCK_RSYNC_FAIL_SECOND : code forcé sur l'appel
# 1 / 2. MOCK_RSYNC_SLEEP_SECOND : sommeil avant la copie de l'appel 2.
# MOCK_RSYNC_EMPTY=1 : ne copie rien (staging vide).
cat > "${BIN}/rsync" <<'MOCKEOF'
#!/usr/bin/env bash
dest="${@: -1}"
countfile="${MOCK_RSYNC_COUNT:-/tmp/pzm-c7-rsync-count}"
n=0
[[ -f "$countfile" ]] && n=$(cat "$countfile" 2>/dev/null || echo 0)
n=$(( n + 1 )); echo "$n" > "$countfile"
if [[ -n "${MOCK_RSYNC_EMPTY:-}" ]]; then
    mkdir -p "$dest"
    exit 0
fi
if [[ "$n" -eq 2 && -n "${MOCK_RSYNC_SLEEP_SECOND:-}" ]]; then
    sleep "${MOCK_RSYNC_SLEEP_SECOND}"
fi
/usr/bin/rsync "$@"
rc=$?
if [[ "$n" -eq 1 && -n "${MOCK_RSYNC_FAIL_FIRST:-}" ]]; then exit "${MOCK_RSYNC_FAIL_FIRST}"; fi
if [[ "$n" -eq 2 && -n "${MOCK_RSYNC_FAIL_SECOND:-}" ]]; then exit "${MOCK_RSYNC_FAIL_SECOND}"; fi
exit "$rc"
MOCKEOF
chmod +x "${BIN}/rsync"
export PATH="${BIN}:$PATH"

# --- Helpers -----------------------------------------------------------------
# make_world <racine> <marqueur> : monde plausible (Saves/world1/players.db +
# map, Server/ini, db/sqlite) marqué pour distinguer live d'origine / backup.
make_world() {
    local root="$1" mark="$2"
    mkdir -p "$root/Saves/Multiplayer/world1" "$root/Server" "$root/db"
    echo "${mark}-players" > "$root/Saves/Multiplayer/world1/players.db"
    echo "${mark}-map" > "$root/Saves/Multiplayer/world1/map.bin"
    echo "${mark}-ini" > "$root/Server/servertest.ini"
    echo "${mark}-db" > "$root/db/servertest.db"
}
# fresh_case <nom> : LIVE (marqueur LIVE) + BKP bon (marqueur BKP) vierges,
# env sandbox exporté, mocks réinitialisés.
LIVE=""; HOME_DIR=""; BKP=""
fresh_case() {
    local name="$1"
    LIVE="${SANDBOX}/live-${name}"
    HOME_DIR="${SANDBOX}/home-${name}"
    BKP="${SANDBOX}/bkp-${name}"
    rm -rf "$LIVE" "$HOME_DIR" "$BKP"
    mkdir -p "$HOME_DIR"
    make_world "$LIVE" "LIVE"
    make_world "$BKP" "BKP"
    export PZ_SOURCE_DIR="$LIVE" PZ_HOME="$HOME_DIR"
    export BACKUP_DIR="${SANDBOX}/bdir-${name}"
    export PZ_USER="$(id -un)" PZ_SERVICE_NAME="zomboid.service"
    export MOCK_SYSTEMCTL_MODE=inactive
    export MOCK_RSYNC_COUNT="${SANDBOX}/rsync-count-${name}"
    rm -f "$MOCK_RSYNC_COUNT"
    unset MOCK_RSYNC_FAIL_FIRST MOCK_RSYNC_FAIL_SECOND MOCK_RSYNC_SLEEP_SECOND MOCK_RSYNC_EMPTY
}
live_marker() { cat "$LIVE/Saves/Multiplayer/world1/players.db" 2>/dev/null || echo "(absent)"; }
old_count() { find "${HOME_DIR}/OLD" -maxdepth 1 -mindepth 1 -name 'ZomboidBROKEN_*' 2>/dev/null | wc -l | tr -d ' '; }
staging_left() { find "$HOME_DIR" -maxdepth 1 -name '.restore-staging-*' 2>/dev/null | wc -l | tr -d ' '; }
run_restore() { bash "$SCRIPT" "$1" >"${SANDBOX}/out.log" 2>&1; }
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'mktemp -d "${PZ_HOME}/.restore-staging-' "$SCRIPT" \
    && ok "staging mktemp -d sous PZ_HOME" \
    || ko "staging mktemp sous PZ_HOME absent"
grep -q 'trap.*EXIT' "$SCRIPT" && grep -q "trap.*INT.*TERM" "$SCRIPT" \
    && ok "trap EXIT/INT/TERM (nettoie staging)" \
    || ko "trap interruption absent"
grep -q 'validate_staging_dir' "$SCRIPT" \
    && ok "validation staging présente" \
    || ko "validate_staging_dir absent"
grep -q 'validate_restored_live' "$SCRIPT" \
    && ok "validation finale présente (compte mondes)" \
    || ko "validate_restored_live absent"
grep -q 'rollback_live' "$SCRIPT" \
    && ok "rollback auto présent" \
    || ko "rollback_live absent"
grep -q 'assert_server_stopped_proven' "$SCRIPT" \
    && ok "arrêt prouvé exigé (non-régression C1)" \
    || ko "assert_server_stopped_proven absent (régression C1)"
grep -q 'acquire_world_lock.*--required' "$SCRIPT" \
    && ok "verrou monde --required (non-régression C1)" \
    || ko "acquire_world_lock --required absent (régression C1)"
if grep -q 'rm -rf.*OLD' "$SCRIPT"; then
    ko "OLD supprimé quelque part (doit être conservé)"
else
    ok "OLD jamais supprimé (conservé jusqu'à validation finale)"
fi
if grep -qE 'systemctl.*start|server start' "$SCRIPT"; then
    ko "démarrage auto détecté (comportement : pas de start)"
else
    ok "pas de démarrage auto (comportement conservé)"
fi
# Ordre du processus dans main : copie -> validation -> mv OLD -> swap.
main_body="$(sed -n '/^main()/,/^}/p' "$SCRIPT")"
line_of() { grep -n "$1" <<<"$main_body" | head -1 | cut -d: -f1; }
l_copy="$(line_of 'copy_backup_to_staging')"; l_val="$(line_of 'validate_staging_dir')"
l_old="$(line_of 'backup_current_zomboid')"; l_swap="$(line_of 'restore_zomboid_data')"
if [[ -n "$l_copy" && -n "$l_val" && -n "$l_old" && -n "$l_swap" ]] \
    && (( l_copy < l_val && l_val < l_old && l_old < l_swap )); then
    ok "ordre main : staging copié+validé AVANT mv OLD puis swap"
else
    ko "ordre main incorrect (copie=$l_copy validation=$l_val mv-OLD=$l_old swap=$l_swap)"
fi

# --- (1) succès nominal ----------------------------------------------------------
echo "== (1) succès =="
fresh_case ok
if run_restore "$BKP"; then
    ok "restore nominal : exit 0"
else
    ko "restore nominal : échec"; show_out
fi
[[ "$(live_marker)" == "BKP-players" ]] \
    && ok "live remplacé par le backup" \
    || { ko "live non remplacé (marqueur: $(live_marker))"; show_out; }
if ! grep -rq "LIVE-players" "$LIVE" 2>/dev/null; then
    ok "aucune trace du live d'origine dans live"
else
    ko "live d'origine encore présent dans live"
fi
if (( $(old_count) == 1 )) && grep -rq "LIVE-players" "${HOME_DIR}/OLD" 2>/dev/null; then
    ok "OLD conservé avec le live d'origine"
else
    ko "OLD absent ou sans le live d'origine (old_count=$(old_count))"; show_out
fi
(( $(staging_left) == 0 )) && ok "staging nettoyé" || ko "staging résiduel"
grep -q "1 monde" "${SANDBOX}/out.log" \
    && ok "résumé : 1 monde restauré" \
    || { ko "résumé sans compte monde"; show_out; }

# --- (2) archive corrompue ----------------------------------------------------------
echo "== (2) corrompu =="
fresh_case corrupt
rm -rf "${BKP}/Server" "${BKP}/db" "$BKP/Saves/Multiplayer"
mkdir -p "$BKP/Saves"  # Saves présent mais vide -> passe validate, échoue staging
if run_restore "$BKP"; then
    ko "Saves vide : succès à tort"; show_out
else
    ok "Saves vide : die (exit $?)"
fi
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "Saves vide : live intact" \
    || ko "Saves vide : live altéré (marqueur: $(live_marker))"
(( $(old_count) == 0 )) && ok "Saves vide : aucun OLD créé (mv jamais atteint)" \
    || ko "Saves vide : OLD créé à tort"

fresh_case corruptdir
rm -rf "$BKP" && mkdir -p "$BKP"  # dir totalement vide
if run_restore "$BKP"; then
    ko "dir vide : succès à tort"; show_out
else
    ok "dir vide : die (exit $?)"
fi
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "dir vide : live intact" \
    || ko "dir vide : live altéré"
(( $(old_count) == 0 )) && ok "dir vide : aucun OLD créé" \
    || ko "dir vide : OLD créé à tort"

# --- (3) manque d'espace (exit 11 sur swap) -> rollback ---------------------------------
echo "== (3) disque plein =="
fresh_case full
export MOCK_RSYNC_FAIL_SECOND=11
if run_restore "$BKP"; then
    ko "exit 11 : succès à tort"; show_out
else
    ok "exit 11 : échec (exit $?)"
fi
grep -q "Rollback" "${SANDBOX}/out.log" \
    && ok "exit 11 : rollback annoncé" \
    || { ko "exit 11 : aucun rollback visible"; show_out; }
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "exit 11 : live intact (= origine, rollback effectif)" \
    || { ko "exit 11 : live altéré (marqueur: $(live_marker))"; show_out; }
(( $(old_count) == 1 )) && ok "exit 11 : OLD conservé" \
    || ko "exit 11 : OLD manquant (count=$(old_count))"
(( $(staging_left) == 0 )) && ok "exit 11 : staging nettoyé" || ko "exit 11 : staging résiduel"

# --- (4) erreur extraction/copie (exit 23 sur copie staging) --------------------------------
echo "== (4) copie staging =="
fresh_case copyerr
export MOCK_RSYNC_FAIL_FIRST=23
if run_restore "$BKP"; then
    ko "copie 23 : succès à tort"; show_out
else
    ok "copie 23 : die (exit $?)"
fi
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "copie 23 : live intact" \
    || ko "copie 23 : live altéré"
(( $(old_count) == 0 )) && ok "copie 23 : aucun OLD créé (mv jamais atteint)" \
    || ko "copie 23 : OLD créé à tort"
(( $(staging_left) == 0 )) && ok "copie 23 : staging nettoyé" || ko "copie 23 : staging résiduel"

# --- (5) SIGTERM pendant le swap --------------------------------------------------------------
echo "== (5) SIGTERM =="
fresh_case term
export MOCK_RSYNC_SLEEP_SECOND=4
bash "$SCRIPT" "$BKP" >"${SANDBOX}/out.log" 2>&1 &
TPID=$!
sleep 1.5
kill -TERM "$TPID" 2>/dev/null || true
if wait "$TPID" 2>/dev/null; then
    ko "SIGTERM : exit 0 (attendu non-zéro)"; show_out
else
    ok "SIGTERM : interrompu (non-zéro)"
fi
live_n="$(find "$LIVE" -type f 2>/dev/null | wc -l | tr -d ' ')"
old_n="$(find "${HOME_DIR}/OLD" -type f 2>/dev/null | wc -l | tr -d ' ')"
if (( live_n > 0 )) || (( old_n > 0 )); then
    ok "SIGTERM : live ou OLD récupérable, jamais vide (live=${live_n} fichiers, OLD=${old_n} fichiers)"
else
    ko "SIGTERM : live ET OLD vides/absents"
fi
if (( old_n > 0 )) && grep -rq "LIVE-players" "${HOME_DIR}/OLD" 2>/dev/null; then
    ok "SIGTERM : OLD contient le live d'origine"
else
    ko "SIGTERM : OLD sans le live d'origine (old_n=${old_n})"
fi
(( $(staging_left) == 0 )) && ok "SIGTERM : staging nettoyé" || ko "SIGTERM : staging résiduel"

# --- (6) validation finale ------------------------------------------------------------------
echo "== (6) validation finale =="
fresh_case srvonly
rm -rf "$BKP/Saves" "$BKP/db"  # Server seul : 0 monde -> échec final + rollback
if run_restore "$BKP"; then
    ko "Server seul : succès à tort (0 monde accepté)"; show_out
else
    ok "Server seul : validation finale refuse (exit $?)"
fi
grep -q "Validation finale" "${SANDBOX}/out.log" \
    && ok "Server seul : échec imputé à la validation finale" \
    || { ko "Server seul : cause non identifiée"; show_out; }
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "Server seul : live intact (rollback effectif)" \
    || ko "Server seul : live altéré"
(( $(old_count) == 1 )) && ok "Server seul : OLD conservé" \
    || ko "Server seul : OLD manquant"

fresh_case stagingempty
export MOCK_RSYNC_EMPTY=1  # copie ne produisant rien -> staging vide
if run_restore "$BKP"; then
    ko "staging vide : succès à tort"; show_out
else
    ok "staging vide : refusé (exit $?)"
fi
[[ "$(live_marker)" == "LIVE-players" ]] \
    && ok "staging vide : live intact" \
    || ko "staging vide : live altéré"
(( $(old_count) == 0 )) && ok "staging vide : aucun OLD créé (rien basculé)" \
    || ko "staging vide : OLD créé à tort"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C7 RESTORE STAGING: OK (${PASS} contrôles)"
else
    echo "C7 RESTORE STAGING: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
