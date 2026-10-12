#!/usr/bin/env bash
# Local Build 42 terrain restoration; all writes share the world lock.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
# Preview also holds the lock so snapshots cannot be pruned while inspected.
acquire_world_lock --required || exit 1
trap release_world_lock EXIT
apply=false
for arg in "$@"; do [[ "$arg" != --apply ]] || apply=true; done
if [[ "$apply" == true ]]; then
    assert_server_stopped_proven "Restauration de zone"
fi
python3 "${SCRIPT_DIR}/../lib/restore_zone.py" \
    --live-root "$PZ_SOURCE_DIR" --backup-root "$BACKUP_DIR" \
    --recovery-root "${PZ_HOME}/OLD" "$@" &
restore_pid=$!
# Keep the world lock until the child finishes recovering on interruption.
trap 'kill -TERM "$restore_pid" 2>/dev/null || true; wait "$restore_pid" || true; exit 143' INT TERM
wait "$restore_pid"
