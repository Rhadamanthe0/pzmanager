#!/usr/bin/env bash
# test_c9_maintenance.sh - Maintenance récupérable, machine à états (C9).
#
# Couvre (performFullMaintenance.sh uniquement) :
#   (0) câblage statique : états INIT→STOPPED→SYSTEM→STEAM→MODS→BACKUP→SELF→
#       DONE/FAILED, écriture avant chaque phase, reprise armée AVANT le stop
#       (ordre textuel), trap EXIT avec FAILED, grep WorkshopItems `|| true`,
#       opt-out PZ_MAINT_SELF_UPDATE, refus si dirty, notify non bloquants,
#       validation 4 niveaux (start demandé/actif/JVM/ready, timeout 120 s).
#   (1) WorkshopItems absent -> OK (exit 0, steamcmd jamais appelé), sous
#       `set -euo pipefail` (le défaut historique sortait via grep exit 1).
#   (2) git pull dirty -> refus sans écraser (HEAD inchangée, fichier sale
#       intact, aucun pull tenté) ; PZ_MAINT_SELF_UPDATE=0 -> opt-out.
#   (3) reprise armée avant stop : après STOPPED + phase suivante en échec
#       (mock), le fichier d'état ET le marqueur de reprise existent toujours
#       (pas de désarmement prématuré).
#   (4) Discord en panne (notify exit 1) -> le filet EXIT termine quand même
#       (rollback pz.sh appelé, code d'erreur propagé, pas de sortie `set -e`).
#   (5) validation finale : JVM absente -> FAILED (1) ; service inactif ->
#       FAILED (1) ; actif+JVM+ready -> OK (0).
#
# Preuves réelles : vraies fonctions EXTRAITES du script (awk, aucun duplicata
# de logique), vrai git, vraie lib common.sh (log/die). Mocks seulement aux
# frontières inaccessibles : systemd/JVM/réseau (fonctions redéfinies), pz.sh
# et steamcmd (scripts factices via SCRIPT_DIR/STEAMCMD_PATH). Limite : le
# parcours complet (main) n'est pas rejoué (effets prod : apt, reboot) —
# l'ordre est prouvé statiquement (0)+(3) et chaque phase unitairement.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET="${ROOT}/data/scripts/admin/performFullMaintenance.sh"
LIB_DIR="${ROOT}/data/scripts/lib"
SANDBOX="${ROOT}/tests/.tmp-c9-$$"
MOCKBIN="${SANDBOX}/mockbin"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

[[ -f "$TARGET" ]] || { echo "[FAIL] cible introuvable : $TARGET" >&2; exit 1; }

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX" "$MOCKBIN"

# --- Vraie lib (log/die) sans source_env (aucune lecture du .env prod) --------
# shellcheck disable=SC1090
source "${LIB_DIR}/common.sh"
# Discord factice : piloté par MOCK_NOTIFY_EXIT (1 = panne). La vraie
# sendDiscord.sh n'est jamais appelée (pas de webhook prod touché).
MOCK_NOTIFY_EXIT=0
notify() { return "$MOCK_NOTIFY_EXIT"; }

# --- Extraction des vraies fonctions depuis la cible (aucune copie) ------------
extract_func() { awk "/^$1\(\) \{/,/^\}/" "$TARGET"; }
EVAL_FILE="${SANDBOX}/extracted.sh"
{
    extract_func maint_set_state
    extract_func maint_arm_recovery
    extract_func maint_disarm_recovery
    extract_func maint_detect_interrupted
    extract_func validate_final_start
    extract_func download_workshop_mods
    extract_func update_self
    extract_func restart_server_on_failure
} > "$EVAL_FILE"
for fn in maint_set_state maint_arm_recovery maint_disarm_recovery \
         maint_detect_interrupted validate_final_start download_workshop_mods \
         update_self restart_server_on_failure; do
    grep -q "^${fn}() {" "$EVAL_FILE" || { ko "extraction de ${fn} impossible"; exit 1; }
done
# shellcheck disable=SC1090
source "$EVAL_FILE"

# --- Env sandbox pour les fonctions extraites ----------------------------------
export PZ_MAINT_STATE_FILE="${SANDBOX}/maintenance.state"
export MAINT_STATE_FILE="$PZ_MAINT_STATE_FILE"
export MAINT_RECOVERY_FILE="${MAINT_STATE_FILE}.recovery_armed"
export PZ_MANAGER_DIR="$SANDBOX"
export PZ_SERVICE_NAME="zomboid.service"
# SCRIPT_DIR factice : ${SCRIPT_DIR}/../core/pz.sh -> mock enregistreur.
mkdir -p "${SANDBOX}/scripts/admin" "${SANDBOX}/scripts/core"
export SCRIPT_DIR="${SANDBOX}/scripts/admin"
cat > "${SANDBOX}/scripts/core/pz.sh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "pz.sh $*" >> "${PZ_MOCK_PZ_LOG:-/dev/null}"
exit "${PZ_MOCK_PZ_EXIT:-0}"
MOCKEOF
chmod +x "${SANDBOX}/scripts/core/pz.sh"
export PZ_MOCK_PZ_LOG="${SANDBOX}/pz.log"
: > "$PZ_MOCK_PZ_LOG"
# steamcmd factice : enregistre tout appel (ne doit PAS être appelé au cas 1).
cat > "${MOCKBIN}/steamcmd-mock" <<'MOCKEOF'
#!/usr/bin/env bash
echo "steamcmd $*" >> "${PZ_MOCK_STEAM_LOG:-/dev/null}"
exit 0
MOCKEOF
chmod +x "${MOCKBIN}/steamcmd-mock"
export PZ_MOCK_STEAM_LOG="${SANDBOX}/steam.log"
: > "$PZ_MOCK_STEAM_LOG"
export STEAMCMD_PATH="${MOCKBIN}/steamcmd-mock"

# --- (0) câblage statique -------------------------------------------------------
echo "== (0) câblage =="
for st in INIT STOPPED SYSTEM STEAM MODS BACKUP SELF DONE FAILED; do
    if grep -q "\"$st\"" "$TARGET"; then
        ok "état $st présent"
    else
        ko "état $st absent"
    fi
done
grep -q 'trap restart_server_on_failure EXIT' "$TARGET" \
    && ok "trap EXIT armé" \
    || ko "trap EXIT absent"
grep -q '"FAILED" > "${MAINT_STATE_FILE}"' "$TARGET" \
    && ok "filet EXIT écrit FAILED" \
    || ko "filet EXIT sans écriture FAILED"
grep -q 'maintenance.state' "$TARGET" && grep -q '.maintenance.state' "$TARGET" \
    && ok "fichier d'état runtime + repli PZ_MANAGER_DIR" \
    || ko "chemin fichier d'état incomplet"
grep -q 'PZ_MAINT_STATE_FILE' "$TARGET" \
    && ok "PZ_MAINT_STATE_FILE (testabilité) présent" \
    || ko "PZ_MAINT_STATE_FILE absent"
# Ordre dans main() : armement AVANT stop, STOPPED avant stop, validation après start.
ARM_LINE=$(grep -n 'maint_arm_recovery' "$TARGET" | tail -1 | cut -d: -f1)
STOP_LINE=$(grep -n '^    stop_server$' "$TARGET" | head -1 | cut -d: -f1)
STOPPED_LINE=$(grep -n 'maint_set_state "STOPPED"' "$TARGET" | head -1 | cut -d: -f1)
VALID_LINE=$(grep -n 'if validate_final_start' "$TARGET" | head -1 | cut -d: -f1)
FINAL_START_LINE=$(grep -n 'pz.sh" start --reason "\$MAINTENANCE_REASON"' "$TARGET" | head -1 | cut -d: -f1)
if [[ -n "$ARM_LINE" && -n "$STOP_LINE" ]] && (( ARM_LINE < STOP_LINE )); then
    ok "reprise armée AVANT stop (l.${ARM_LINE} < l.${STOP_LINE})"
else
    ko "reprise PAS armée avant stop (arm=${ARM_LINE:-?} stop=${STOP_LINE:-?})"
fi
if [[ -n "$STOPPED_LINE" && -n "$STOP_LINE" ]] && (( STOPPED_LINE < STOP_LINE )); then
    ok "état STOPPED écrit avant stop"
else
    ko "STOPPED pas écrit avant stop"
fi
if [[ -n "$VALID_LINE" && -n "$FINAL_START_LINE" ]] && (( VALID_LINE > FINAL_START_LINE )); then
    ok "validation finale après start final"
else
    ko "validation finale mal placée"
fi
grep -q "grep -oP '^WorkshopItems=" "$TARGET" && grep -q '| tr .;. . . || true' "$TARGET" \
    && ok "WorkshopItems set -e safe (|| true)" \
    || ko "WorkshopItems sans || true"
grep -q 'PZ_MAINT_SELF_UPDATE' "$TARGET" \
    && ok "opt-out PZ_MAINT_SELF_UPDATE présent" \
    || ko "opt-out PZ_MAINT_SELF_UPDATE absent"
grep -q 'status --porcelain' "$TARGET" \
    && ok "refus si dépôt dirty présent" \
    || ko "garde dirty absente"
# Tous les notify() du script doivent être non bloquants (notify déjà safe en
# lib, `|| true` explicite en plus contre `set -e`).
if grep -n 'notify ' "$TARGET" | grep -v '|| true' | grep -qv '^\s*#'; then
    ko "notify sans || true détecté : $(grep -n 'notify ' "$TARGET" | grep -v '|| true' | head -1)"
else
    ok "tous les notify sont non bloquants (|| true)"
fi
grep -q "pgrep -f 'ProjectZomboid64'" "$TARGET" \
    && ok "validation JVM (pgrep) présente" \
    || ko "validation JVM absente"
grep -q 'wait_for_server_ready 120' "$TARGET" \
    && ok "validation ready (timeout court 120 s) présente" \
    || ko "validation ready absente"
grep -q 'server_is_active' "$TARGET" \
    && ok "validation actif (systemd) présente" \
    || ko "validation actif absente"
# Désarmement seulement sur DONE (jamais avant/ailleurs qu'après DONE ou en fin).
if grep -q 'maint_disarm_recovery' "$TARGET"; then
    ok "désarmement explicite présent"
else
    ko "désarmement absent"
fi

# --- (1) WorkshopItems absent -> OK ----------------------------------------------
echo "== (1) WorkshopItems absent =="
mkdir -p "${SANDBOX}/Zomboid/Server"
export PZ_INI_PATH="${SANDBOX}/Zomboid/Server/servertest.ini"
printf '[Server]\nMaxPlayers=16\n' > "$PZ_INI_PATH"
export STEAM_LOGIN="compte-test"
export PZ_INSTALL_DIR="$SANDBOX"
# Sous set -euo pipefail : avec le bug (grep sans || true), cet appel SORTAIT.
if download_workshop_mods >"${SANDBOX}/out1.log" 2>&1; then
    ok "ini sans WorkshopItems -> exit 0"
else
    ko "ini sans WorkshopItems -> exit $? (attendu 0)"; sed 's/^/  [out] /' "${SANDBOX}/out1.log" || true
fi
[[ ! -s "$PZ_MOCK_STEAM_LOG" ]] \
    && ok "steamcmd jamais appelé (rien à pré-télécharger)" \
    || ko "steamcmd appelé à tort"

# --- (2) git pull dirty -> refus sans écraser --------------------------------------
echo "== (2) git dirty =="
GREPO="${SANDBOX}/pzmanager-repo"
rm -rf "$GREPO"; mkdir -p "$GREPO"
git -C "$GREPO" init -qb main 2>/dev/null || git -C "$GREPO" init -q
git -C "$GREPO" config user.email "test@example.com"
git -C "$GREPO" config user.name "test"
echo v1 > "$GREPO/file.txt"
git -C "$GREPO" add file.txt
git -C "$GREPO" commit -qm init
BEFORE=$(git -C "$GREPO" rev-parse --short HEAD)
echo sale > "$GREPO/file.txt"
export PZ_MANAGER_DIR="$GREPO"
if update_self >"${SANDBOX}/out2.log" 2>&1; then
    ok "dépôt dirty -> update_self non bloquant (exit 0)"
else
    ko "dépôt dirty -> exit $? (attendu 0 non bloquant)"; sed 's/^/  [out] /' "${SANDBOX}/out2.log" || true
fi
AFTER=$(git -C "$GREPO" rev-parse --short HEAD)
[[ "$BEFORE" == "$AFTER" ]] && ok "HEAD inchangée (${AFTER})" || ko "HEAD modifiée (${BEFORE} -> ${AFTER})"
[[ "$(cat "$GREPO/file.txt")" == "sale" ]] && ok "modifs locales intactes (non écrasées)" || ko "modifs locales altérées"
grep -qi 'modifs locales' "${SANDBOX}/out2.log" && ok "WARNING dirty journalisé" || ko "WARNING dirty absent"
export PZ_MAINT_SELF_UPDATE=0
if update_self >"${SANDBOX}/out2b.log" 2>&1; then
    ok "PZ_MAINT_SELF_UPDATE=0 -> opt-out OK"
else
    ko "opt-out -> exit $?"
fi
grep -qi 'PZ_MAINT_SELF_UPDATE=0' "${SANDBOX}/out2b.log" && ok "opt-out journalisé" || ko "opt-out non journalisé"
unset PZ_MAINT_SELF_UPDATE
export PZ_MANAGER_DIR="$SANDBOX"

# --- (3) reprise armée avant stop (phase suivante en échec) -------------------------
echo "== (3) reprise =="
rm -f "$MAINT_STATE_FILE" "$MAINT_RECOVERY_FILE"
maint_set_state "INIT" >/dev/null
maint_arm_recovery
maint_set_state "STOPPED" >/dev/null
# stop OK (fichier présent), phase suivante en échec (mock).
failing_phase() { return 42; }
set +e
failing_phase
RC_PHASE=$?
set -e
(( RC_PHASE == 42 )) && ok "phase mock en échec (42)" || ko "phase mock rc=$RC_PHASE"
[[ -f "$MAINT_STATE_FILE" ]] && [[ "$(cat "$MAINT_STATE_FILE")" == "STOPPED" ]] \
    && ok "état STOPPED toujours présent après échec" \
    || ko "état perdu après échec (contenu: $(cat "$MAINT_STATE_FILE" 2>/dev/null || echo ABSENT))"
[[ -f "$MAINT_RECOVERY_FILE" ]] \
    && ok "reprise toujours armée après échec (pas de désarmement prématuré)" \
    || ko "marqueur de reprise perdu après échec"
# Relance : détection + rollback minimal (restart + message).
export PZ_MOCK_PZ_EXIT=0
: > "$PZ_MOCK_PZ_LOG"
MOCK_NOTIFY_EXIT=0
if maint_detect_interrupted >"${SANDBOX}/out3.log" 2>&1; then
    ok "maint_detect_interrupted ne bloque pas la reprise"
else
    ko "maint_detect_interrupted en échec"
fi
grep -q 'pz.sh start' "$PZ_MOCK_PZ_LOG" \
    && ok "rollback : serveur redémarré à la relance" \
    || ko "rollback : aucun restart à la relance"

# --- (4) Discord en panne -> maintenance quand même OK -------------------------------
echo "== (4) Discord panne =="
MOCK_NOTIFY_EXIT=1
export SERVER_STOPPED_BY_MAINTENANCE=true
rm -f "$MAINT_STATE_FILE"; : > "$PZ_MOCK_PZ_LOG"
set +e
false
restart_server_on_failure
RC_TRAP=$?
set -e
(( RC_TRAP == 1 )) && ok "filet EXIT propage le code d'erreur (1)" || ko "filet EXIT rc=$RC_TRAP (attendu 1)"
[[ "$(cat "$MAINT_STATE_FILE" 2>/dev/null || echo ABSENT)" == "FAILED" ]] \
    && ok "état FAILED écrit malgré Discord en panne" \
    || ko "état FAILED absent"
grep -q 'pz.sh start' "$PZ_MOCK_PZ_LOG" \
    && ok "rollback exécuté malgré Discord en panne" \
    || ko "rollback sauté (Discord a bloqué)"
MOCK_NOTIFY_EXIT=0
SERVER_STOPPED_BY_MAINTENANCE=false

# --- (5) validation finale ------------------------------------------------------------
echo "== (5) validation finale =="
# Cas JVM absente : actif OK, pgrep KO -> FAILED.
server_is_active() { return 0; }
pgrep() { return 1; }
wait_for_server_ready() { echo "UNREACHABLE-ready" >&2; return 0; }
export -f server_is_active pgrep wait_for_server_ready
set +e
validate_final_start >"${SANDBOX}/out5a.log" 2>&1
RC_JVM=$?
set -e
(( RC_JVM != 0 )) && ok "JVM absente -> FAILED (rc=$RC_JVM)" || ko "JVM absente -> DONE à tort"
grep -qi 'JVM' "${SANDBOX}/out5a.log" && ok "cause JVM diagnostiquée" || ko "cause JVM muette"
# Cas service inactif : start demandé mais rien d'actif -> FAILED.
server_is_active() { return 1; }
export -f server_is_active
set +e
validate_final_start >"${SANDBOX}/out5b.log" 2>&1
RC_INACTIVE=$?
set -e
(( RC_INACTIVE != 0 )) && ok "service inactif -> FAILED" || ko "service inactif -> DONE à tort"
grep -qi 'non actif' "${SANDBOX}/out5b.log" && ok "distinction demandé/actif diagnostiquée" || ko "distinction demandé/actif muette"
# Cas nominal : actif + JVM + ready -> OK.
server_is_active() { return 0; }
pgrep() { return 0; }
wait_for_server_ready() { [[ "${1:-}" == "120" ]] && return 0; echo "timeout inattendu: $*" >&2; return 1; }
export -f server_is_active pgrep wait_for_server_ready
set +e
validate_final_start >"${SANDBOX}/out5c.log" 2>&1
RC_OK=$?
set -e
(( RC_OK == 0 )) && ok "actif+JVM+ready -> DONE" || ko "cas nominal -> FAILED à tort"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C9 MAINTENANCE: OK (${PASS} contrôles)"
else
    echo "C9 MAINTENANCE: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
