#!/usr/bin/env bash
# test_c7_restore_staging.sh - Restauration via staging + rollback (C7).
#
# Couvre (data/scripts/backup/restoreZomboidData.sh uniquement) :
#   (0) câblage statique : staging mktemp -d sous PZ_HOME + trap EXIT/INT/TERM,
#       ordre main (copie -> validation staging -> copie temporaire -> swap),
#       validate_staging_dir, validate_restored_live (compte mondes > 0),
#       rollback_live, verrou monde --required + arrêt prouvé (non-régression
#       C1), répertoires restaurés (dont Lua), plus de OLD, pas de start auto.
#   (1) succès nominal : Saves/db/Server/Lua remplacés par le backup, autres
#       fichiers du live conservés, copie temporaire et staging supprimés ;
#       backup sans Lua -> Lua du live conservé ; Server seul -> seul Server
#       remplacé.
#   (2) archive corrompue (Saves vide ; dir totalement vide) -> die, live
#       intact, aucune copie laissée.
#   (3) échec d'un mv pendant la bascule -> rollback, live = arbre d'origine
#       exact, copie supprimée ; échec du rollback -> copie conservée ; deux
#       restaurations successives à horodatage identique.
#   (4) erreur de copie (mock rsync exit 23 sur copie staging) -> die, live
#       intact, aucune copie laissée.
#   (5) SIGTERM pendant la bascule -> exit non-zéro, live remis à l'origine,
#       staging et copie supprimés.
#   (6) validation finale : Saves sans monde -> bascule puis rollback, live
#       intact ; staging vide (mock EMPTY) -> refus avant bascule.
#
# Preuves réelles : vrai script restoreZomboidData.sh, vrai flock/mv/rsync
# (rsync et mv mockés par PATH mais DÉLÉGUÉS aux vrais binaires — seuls le
# code de sortie et le sommeil sont pilotés), mock systemctl par PATH (état
# serveur piloté). Isolé : XDG_RUNTIME_DIR + PZ_HOME + PZ_SOURCE_DIR sous
# sandbox, stub .env (sauvegarde + restauration du .env préexistant via trap
# EXIT). Ne touche à aucun monde réel.
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
    || ! { : 1>&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
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
# rsync : DÉLÈGUE la copie au vrai /usr/bin/rsync (seul appel : backup ->
# staging). MOCK_RSYNC_FAIL_FIRST : code forcé. MOCK_RSYNC_EMPTY=1 : ne copie
# rien (staging vide).
cat > "${BIN}/rsync" <<'MOCKEOF'
#!/usr/bin/env bash
dest="${@: -1}"
if [[ -n "${MOCK_RSYNC_EMPTY:-}" ]]; then
    mkdir -p "$dest"
    exit 0
fi
/usr/bin/rsync "$@"
rc=$?
if [[ -n "${MOCK_RSYNC_FAIL_FIRST:-}" ]]; then exit "${MOCK_RSYNC_FAIL_FIRST}"; fi
exit "$rc"
MOCKEOF
chmod +x "${BIN}/rsync"
# mv : DÉLÈGUE au vrai mv. Seuls les appels touchant le staging ou la copie
# temporaire (.restore-*) sont numérotés : 1 = live/Saves -> copie,
# 2 = staging/Saves -> live, 3 = live/db -> copie, 4 = staging/db -> live...
# MOCK_MV_FAIL_AT=N : seul l'appel N échoue ; MOCK_MV_FAIL_FROM=N : tous les
# appels >= N échouent (rollback compris) ; MOCK_MV_SLEEP_AT=N : sommeil avant
# l'appel N.
REAL_MV="$(command -v mv)"
export REAL_MV
cat > "${BIN}/mv" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$*" == *.restore-* ]]; then
    countfile="${MOCK_MV_COUNT:?}"
    n=0
    [[ -f "$countfile" ]] && n=$(cat "$countfile" 2>/dev/null || echo 0)
    n=$(( n + 1 )); echo "$n" > "$countfile"
    [[ "$n" == "${MOCK_MV_SLEEP_AT:-}" ]] && sleep 4
    [[ "$n" == "${MOCK_MV_FAIL_AT:-}" ]] && exit 1
    [[ -n "${MOCK_MV_FAIL_FROM:-}" ]] && (( n >= MOCK_MV_FAIL_FROM )) && exit 1
fi
exec "$REAL_MV" "$@"
MOCKEOF
chmod +x "${BIN}/mv"
REAL_DATE="$(command -v date)"
export REAL_DATE
cat > "${BIN}/date" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_FIXED_DATE:-}" ]]; then
    printf '%s\n' '2026-10-12_12h00m00s'
else
    exec "$REAL_DATE" "$@"
fi
MOCKEOF
chmod +x "${BIN}/date"
export PATH="${BIN}:$PATH"

# --- Helpers -----------------------------------------------------------------
# make_world <racine> <marqueur> : monde plausible (Saves/world1/players.db +
# map, Server/ini, db/sqlite, Lua/Aegis) marqué pour distinguer live d'origine
# / backup.
make_world() {
    local root="$1" mark="$2"
    mkdir -p "$root/Saves/Multiplayer/world1" "$root/Server" "$root/db" "$root/Lua/Aegis/Roles"
    echo "${mark}-players" > "$root/Saves/Multiplayer/world1/players.db"
    echo "${mark}-map" > "$root/Saves/Multiplayer/world1/map.bin"
    echo "${mark}-ini" > "$root/Server/servertest.ini"
    echo "${mark}-db" > "$root/db/servertest.db"
    echo "${mark}-roles" > "$root/Lua/Aegis/Roles/roles.txt"
}
# fresh_case <nom> : LIVE (marqueur LIVE, plus des fichiers non sauvegardés)
# + BKP bon (marqueur BKP) vierges, env sandbox exporté, mocks réinitialisés.
# ORIG = copie de référence du live d'origine.
LIVE=""; HOME_DIR=""; BKP=""; ORIG=""
fresh_case() {
    local name="$1"
    LIVE="${SANDBOX}/live-${name}"
    HOME_DIR="${SANDBOX}/home-${name}"
    BKP="${SANDBOX}/bkp-${name}"
    ORIG="${SANDBOX}/orig-${name}"
    rm -rf "$LIVE" "$HOME_DIR" "$BKP" "$ORIG"
    mkdir -p "$HOME_DIR"
    make_world "$LIVE" "LIVE"
    mkdir -p "$LIVE/Logs"
    echo "live-log" > "$LIVE/Logs/console.txt"
    echo "live-options" > "$LIVE/options.ini"
    make_world "$BKP" "BKP"
    cp -a "$LIVE" "$ORIG"
    export PZ_SOURCE_DIR="$LIVE" PZ_HOME="$HOME_DIR"
    export BACKUP_DIR="${SANDBOX}/bdir-${name}"
    export PZ_USER="$(id -un)" PZ_SERVICE_NAME="zomboid.service"
    export MOCK_SYSTEMCTL_MODE=inactive
    export MOCK_MV_COUNT="${SANDBOX}/mv-count-${name}"
    rm -f "$MOCK_MV_COUNT"
    unset MOCK_RSYNC_FAIL_FIRST MOCK_RSYNC_EMPTY MOCK_MV_FAIL_AT MOCK_MV_FAIL_FROM MOCK_MV_SLEEP_AT MOCK_FIXED_DATE
}
live_marker() { cat "$LIVE/Saves/Multiplayer/world1/players.db" 2>/dev/null || echo "(absent)"; }
previous_count() { find "$HOME_DIR" -maxdepth 1 -name '.restore-previous-*' 2>/dev/null | wc -l | tr -d ' '; }
staging_left() { find "$HOME_DIR" -maxdepth 1 -name '.restore-staging-*' 2>/dev/null | wc -l | tr -d ' '; }
live_is_original() { diff -r -- "$ORIG" "$LIVE" >/dev/null; }
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
grep -q '^readonly RESTORED_DIRS=(Saves db Server Lua)' "$SCRIPT" \
    && ok "répertoires restaurés : Saves db Server Lua" \
    || ko "liste RESTORED_DIRS inattendue"
if grep -q 'OLD' "$SCRIPT"; then
    ko "référence à OLD restante"
else
    ok "plus de copie persistante dans OLD"
fi
if grep -qE 'systemctl.*start|server start' "$SCRIPT"; then
    ko "démarrage auto détecté (comportement : pas de start)"
else
    ok "pas de démarrage auto (comportement conservé)"
fi
# Ordre du processus dans main : copie -> validation -> copie temporaire -> swap.
main_body="$(sed -n '/^main()/,/^}/p' "$SCRIPT")"
line_of() { grep -n "$1" <<<"$main_body" | head -1 | cut -d: -f1; }
l_copy="$(line_of 'copy_backup_to_staging')"; l_val="$(line_of 'validate_staging_dir')"
l_prev="$(line_of 'prepare_previous_dir')"; l_swap="$(line_of 'restore_zomboid_data')"
if [[ -n "$l_copy" && -n "$l_val" && -n "$l_prev" && -n "$l_swap" ]] \
    && (( l_copy < l_val && l_val < l_prev && l_prev < l_swap )); then
    ok "ordre main : staging copié+validé AVANT copie temporaire puis swap"
else
    ko "ordre main incorrect (copie=$l_copy validation=$l_val copie-temp=$l_prev swap=$l_swap)"
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
if [[ "$(cat "$LIVE/Server/servertest.ini")" == BKP-ini && "$(cat "$LIVE/db/servertest.db")" == BKP-db \
    && "$(cat "$LIVE/Lua/Aegis/Roles/roles.txt")" == BKP-roles ]]; then
    ok "Server, db et Lua restaurés comme Saves"
else
    ko "Server/db/Lua non restaurés"
fi
if ! grep -rq "LIVE-" "$LIVE" 2>/dev/null; then
    ok "aucune trace du live d'origine dans les répertoires restaurés"
else
    ko "données d'origine encore présentes dans live"
fi
[[ "$(cat "$LIVE/Logs/console.txt" 2>/dev/null)" == live-log && "$(cat "$LIVE/options.ini" 2>/dev/null)" == live-options ]] \
    && ok "fichiers non sauvegardés du live conservés (Logs, options.ini)" \
    || ko "fichiers non sauvegardés du live perdus"
(( $(previous_count) == 0 )) && [[ ! -e "$HOME_DIR/OLD" ]] \
    && ok "copie temporaire supprimée après succès, aucun OLD" \
    || ko "copie résiduelle après succès"
(( $(staging_left) == 0 )) && ok "staging nettoyé" || ko "staging résiduel"
grep -q "1 monde" "${SANDBOX}/out.log" \
    && ok "résumé : 1 monde restauré" \
    || { ko "résumé sans compte monde"; show_out; }

fresh_case nolua
rm -rf "$BKP/Lua"
if run_restore "$BKP" && [[ "$(live_marker)" == BKP-players ]] \
    && [[ "$(cat "$LIVE/Lua/Aegis/Roles/roles.txt")" == LIVE-roles ]]; then
    ok "backup sans Lua : monde restauré, Lua du live conservé"
else
    ko "backup sans Lua : résultat inattendu"; show_out
fi

fresh_case srvonly
rm -rf "$BKP/Saves" "$BKP/db" "$BKP/Lua"
if run_restore "$BKP" && [[ "$(live_marker)" == LIVE-players ]] \
    && [[ "$(cat "$LIVE/Server/servertest.ini")" == BKP-ini ]]; then
    ok "backup Server seul : seul Server remplacé, monde conservé"
else
    ko "backup Server seul : résultat inattendu"; show_out
fi

# --- (2) archive corrompue ----------------------------------------------------------
echo "== (2) corrompu =="
fresh_case corrupt
rm -rf "${BKP}/Server" "${BKP}/db" "${BKP}/Lua" "$BKP/Saves/Multiplayer"
mkdir -p "$BKP/Saves"  # Saves présent mais vide -> passe validate, échoue staging
if run_restore "$BKP"; then
    ko "Saves vide : succès à tort"; show_out
else
    ok "Saves vide : die (exit $?)"
fi
live_is_original && ok "Saves vide : live intact" || ko "Saves vide : live altéré"
(( $(previous_count) == 0 )) && ok "Saves vide : aucune copie laissée" \
    || ko "Saves vide : copie laissée à tort"

fresh_case corruptdir
rm -rf "$BKP" && mkdir -p "$BKP"  # dir totalement vide
if run_restore "$BKP"; then
    ko "dir vide : succès à tort"; show_out
else
    ok "dir vide : die (exit $?)"
fi
live_is_original && ok "dir vide : live intact" || ko "dir vide : live altéré"
(( $(previous_count) == 0 )) && ok "dir vide : aucune copie laissée" \
    || ko "dir vide : copie laissée à tort"

# --- (3) échec pendant la bascule -> rollback ---------------------------------------
echo "== (3) échec de bascule =="
fresh_case swapfail
# Le backup contient des entrées absentes du live (dossier + lien) : la
# comparaison d'arbres complets détecte un monde mélangé.
mkdir -p "$BKP/Saves/Multiplayer/new-world"
printf 'new only\n' > "$BKP/Saves/Multiplayer/new-world/partial.bin"
ln -s new-world/partial.bin "$BKP/Saves/Multiplayer/new-link"
export MOCK_MV_FAIL_AT=4   # installation de db : Saves déjà basculé
if run_restore "$BKP"; then
    ko "mv en échec : succès à tort"; show_out
else
    ok "mv en échec : échec (exit $?)"
fi
grep -q "remise en place" "${SANDBOX}/out.log" \
    && ok "mv en échec : rollback annoncé" \
    || { ko "mv en échec : aucun rollback visible"; show_out; }
if live_is_original; then
    ok "rollback : arbre exact, aucun fichier/dossier/lien de la bascule échouée"
else
    ko "rollback : monde mélangé après échec"; diff -r -- "$ORIG" "$LIVE" || true
fi
(( $(previous_count) == 0 )) && ok "rollback réussi : copie temporaire supprimée" \
    || ko "rollback réussi : copie laissée"
(( $(staging_left) == 0 )) && ok "mv en échec : staging nettoyé" || ko "mv en échec : staging résiduel"

fresh_case rollbackerr
export MOCK_MV_FAIL_FROM=4
if run_restore "$BKP"; then
    ko "échec rollback : succès à tort"
else
    ok "échec rollback : erreur explicite"
fi
prev="$(find "$HOME_DIR" -maxdepth 1 -name '.restore-previous-*' -print -quit)"
if [[ -n "$prev" ]] && diff -r -- "$ORIG/Saves" "$prev/Saves" >/dev/null \
    && diff -r -- "$ORIG/db" "$prev/db" >/dev/null && grep -q "$prev" "${SANDBOX}/out.log"; then
    ok "échec rollback : copie conservée, complète et signalée"
else
    ko "échec rollback : copie absente, altérée ou non signalée"; show_out
fi

fresh_case collision
export MOCK_FIXED_DATE=1
if run_restore "$BKP" && run_restore "$BKP"; then
    ok "deux restaurations à horodatage identique réussissent"
else
    ko "deux restaurations : erreur"; show_out
fi
[[ "$(live_marker)" == BKP-players ]] && (( $(previous_count) == 0 )) \
    && ok "deux restaurations : live restauré, aucune copie laissée" \
    || ko "deux restaurations : état inattendu"

# --- (4) erreur de copie (exit 23 sur copie staging) --------------------------------
echo "== (4) copie staging =="
fresh_case copyerr
export MOCK_RSYNC_FAIL_FIRST=23
if run_restore "$BKP"; then
    ko "copie 23 : succès à tort"; show_out
else
    ok "copie 23 : die (exit $?)"
fi
live_is_original && ok "copie 23 : live intact" || ko "copie 23 : live altéré"
(( $(previous_count) == 0 )) && ok "copie 23 : aucune copie laissée" \
    || ko "copie 23 : copie laissée à tort"
(( $(staging_left) == 0 )) && ok "copie 23 : staging nettoyé" || ko "copie 23 : staging résiduel"

# --- (5) SIGTERM pendant la bascule ---------------------------------------------------
echo "== (5) SIGTERM =="
fresh_case term
export MOCK_MV_SLEEP_AT=3   # live/db -> copie, après bascule de Saves
bash "$SCRIPT" "$BKP" >"${SANDBOX}/out.log" 2>&1 &
TPID=$!
sleep 1.5
kill -TERM "$TPID" 2>/dev/null || true
if wait "$TPID" 2>/dev/null; then
    ko "SIGTERM : exit 0 (attendu non-zéro)"; show_out
else
    ok "SIGTERM : interrompu (non-zéro)"
fi
if live_is_original; then
    ok "SIGTERM : live remis dans son état d'origine"
else
    ko "SIGTERM : live altéré"; show_out
fi
(( $(previous_count) == 0 )) && ok "SIGTERM : copie temporaire supprimée" \
    || ko "SIGTERM : copie laissée"
(( $(staging_left) == 0 )) && ok "SIGTERM : staging nettoyé" || ko "SIGTERM : staging résiduel"

# --- (6) validation finale ------------------------------------------------------------------
echo "== (6) validation finale =="
fresh_case noworld
rm -rf "$BKP/Saves/Multiplayer" && echo x > "$BKP/Saves/readme.txt"  # Saves sans monde
if run_restore "$BKP"; then
    ko "Saves sans monde : succès à tort (0 monde accepté)"; show_out
else
    ok "Saves sans monde : validation finale refuse (exit $?)"
fi
grep -q "Validation finale" "${SANDBOX}/out.log" \
    && ok "Saves sans monde : échec imputé à la validation finale" \
    || { ko "Saves sans monde : cause non identifiée"; show_out; }
live_is_original && ok "Saves sans monde : live intact (rollback effectif)" \
    || ko "Saves sans monde : live altéré"
(( $(previous_count) == 0 )) && ok "Saves sans monde : copie supprimée après rollback" \
    || ko "Saves sans monde : copie laissée"

fresh_case stagingempty
export MOCK_RSYNC_EMPTY=1  # copie ne produisant rien -> staging vide
if run_restore "$BKP"; then
    ko "staging vide : succès à tort"; show_out
else
    ok "staging vide : refusé (exit $?)"
fi
live_is_original && ok "staging vide : live intact" || ko "staging vide : live altéré"
(( $(previous_count) == 0 )) && ok "staging vide : aucune copie laissée" \
    || ko "staging vide : copie laissée à tort"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C7 RESTORE STAGING: OK (${PASS} contrôles)"
else
    echo "C7 RESTORE STAGING: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
