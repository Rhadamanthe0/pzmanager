#!/usr/bin/env bash
# Local Build 42 terrain restoration; all writes share the world lock.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
# Public options only: do not allow helper paths or abbreviated options to
# change the operation that the stopped-server guard has inspected.
remaining=("$@")
while (( ${#remaining[@]} )); do
    case "${remaining[0]}" in
        --apply|--dry-run|--help|-h|--save=*) remaining=("${remaining[@]:1}") ;;
        --save)
            (( ${#remaining[@]} >= 2 )) || die "Option --save attend un nom."
            remaining=("${remaining[@]:2}") ;;
        --*) die "Option inconnue : ${remaining[0]}" ;;
        *) remaining=("${remaining[@]:1}") ;;
    esac
done
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
trap 'trap "" INT TERM; kill -TERM "$restore_pid" 2>/dev/null || true; wait "$restore_pid" || true; exit 143' INT TERM
wait "$restore_pid"
