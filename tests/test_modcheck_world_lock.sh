#!/usr/bin/env bash
# Régression : backup concurrent -> report sans échec ; retry -> action protégée.
# Vraies fonctions du modcheck et vrais flock, effets serveur/Steam simulés.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET="${ROOT}/data/scripts/admin/triggerMaintenanceOnModUpdate.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/rt" "$SANDBOX/scripts/admin" "$SANDBOX/scripts/core"
export XDG_RUNTIME_DIR="$SANDBOX/rt"
export PZ_WORLD_LOCK_DEPTH=0 PZ_WORLD_LOCK_FD=""
export PZ_TEST_SANDBOX="$SANDBOX" PZ_TEST_ROOT="$ROOT"

# Les enfants exigent un fd hérité valide et une participation au vrai verrou.
cat > "$SANDBOX/child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
source "$PZ_TEST_ROOT/data/scripts/lib/world_lock.sh"
[[ "$PZ_WORLD_LOCK_DEPTH" == 1 && -e "/proc/$$/fd/$PZ_WORLD_LOCK_FD" ]]
acquire_world_lock --required
# Un arbre indépendant ne doit pas pouvoir entrer pendant l'action.
if PZ_WORLD_LOCK_DEPTH=0 PZ_WORLD_LOCK_FD="" bash -c '
    source "$PZ_TEST_ROOT/data/scripts/lib/world_lock.sh"
    acquire_world_lock --try
'; then
    echo 'World lock lost during action' >&2
    exit 90
fi
case "$(basename "$0")" in
    pz.sh)
        [[ "$*" == 'restart 5m --reason Test mods --automatic' ]]
        # Le parent conserve aussi le verrou maintenance pour le restart.
        if flock -n "$PZ_TEST_SANDBOX/maintenance.lock" true; then exit 91; fi
        echo restart >> "$PZ_TEST_SANDBOX/events"
        ;;
    performFullMaintenance.sh)
        [[ "$*" == '5m --reason Mise à jour serveur disponible --automatic --no-reboot' ]]
        # La maintenance doit pouvoir reprendre son verrou spécifique.
        flock -n "$PZ_TEST_SANDBOX/maintenance.lock" true
        echo maintenance >> "$PZ_TEST_SANDBOX/events"
        ;;
esac
release_world_lock
exit "${PZ_TEST_ACTION_RC:-0}"
CHILD
cp "$SANDBOX/child.sh" "$SANDBOX/scripts/core/pz.sh"
cp "$SANDBOX/child.sh" "$SANDBOX/scripts/admin/performFullMaintenance.sh"
chmod +x "$SANDBOX/scripts/core/pz.sh" "$SANDBOX/scripts/admin/performFullMaintenance.sh"

# Exécution normale (pas de main dans un if, qui désactiverait set -e).
cat > "$SANDBOX/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source "$PZ_TEST_ROOT/data/scripts/lib/common.sh"
SCRIPT_DIR="$PZ_TEST_SANDBOX/scripts/admin"
log_event() { echo "$*" >> "$PZ_TEST_SANDBOX/events"; }
cleanup_old_logs() { :; }
check_prerequisites() { :; }
try_acquire_maintenance_lock() {
    try_lock "$PZ_TEST_SANDBOX/maintenance.lock" MAINTENANCE_LOCK_FD
}
check_mods() {
    echo check_mods >> "$PZ_TEST_SANDBOX/events"
    [[ "$PZ_TEST_UPDATE" == mod ]]
}
check_server_update() {
    echo check_server >> "$PZ_TEST_SANDBOX/events"
    [[ "$PZ_TEST_UPDATE" == server ]]
}
server_update_check_due() { return 0; }
build_mod_update_reason() { echo 'Test mods'; }
RUNNER
for fn in trigger_restart trigger_maintenance main; do
    awk "/^${fn}\(\) \{/,/^\}/" "$TARGET" >> "$SANDBOX/runner.sh"
done
echo main >> "$SANDBOX/runner.sh"
export PZ_TEST_UPDATE=mod
source "$ROOT/data/scripts/lib/world_lock.sh"

# Simule la sauvegarde qui détient le monde dans un autre arbre.
acquire_world_lock --required
PZ_WORLD_LOCK_DEPTH=0 PZ_WORLD_LOCK_FD="" bash "$SANDBOX/runner.sh"
grep -qx 'World operation in progress - skipping' "$SANDBOX/events"
! grep -qE 'check_mods|restart|check_server|maintenance$' "$SANDBOX/events"
release_world_lock

# La mise à jour reste détectable au passage suivant, sous verrou hérité.
: > "$SANDBOX/events"
bash "$SANDBOX/runner.sh"
grep -qx restart "$SANDBOX/events"
grep -qx 'Restart completed' "$SANDBOX/events"
acquire_world_lock --try
release_world_lock

# Même protocole pour une mise à jour du build et pour un passage sans MAJ.
export PZ_TEST_UPDATE=server
: > "$SANDBOX/events"
bash "$SANDBOX/runner.sh"
grep -qx maintenance "$SANDBOX/events"
grep -qx 'Maintenance completed' "$SANDBOX/events"
export PZ_TEST_UPDATE=none
: > "$SANDBOX/events"
bash "$SANDBOX/runner.sh"
grep -qx check_server "$SANDBOX/events"
! grep -qE '^(restart|maintenance)$' "$SANDBOX/events"

# Maintenance déjà en cours : report et libération du verrou monde.
exec {maint_fd}> "$SANDBOX/maintenance.lock"
flock -n "$maint_fd"
: > "$SANDBOX/events"
bash "$SANDBOX/runner.sh"
grep -qx 'Maintenance in progress - skipping' "$SANDBOX/events"
! grep -q check_mods "$SANDBOX/events"
acquire_world_lock --try
release_world_lock
exec {maint_fd}>&-

# Un vrai échec de l'action garde son code d'erreur pour systemd.
for PZ_TEST_UPDATE in mod server; do
    export PZ_TEST_UPDATE PZ_TEST_ACTION_RC=7
    : > "$SANDBOX/events"
    rc=0
    bash "$SANDBOX/runner.sh" || rc=$?
    [[ "$rc" == 7 ]]
    ! grep -q completed "$SANDBOX/events"
    acquire_world_lock --try
    release_world_lock
done
echo 'MODCHECK WORLD LOCK: OK (contention, retry, inheritance, maintenance, no update, action failures)'
