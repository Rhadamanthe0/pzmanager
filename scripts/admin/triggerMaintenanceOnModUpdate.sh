#!/bin/bash
# triggerMaintenanceOnModUpdate.sh - Déclenche maintenance si mods mis à jour
# Timer systemd toutes les 5 min. Lock partagé avec pz.sh/performFullMaintenance.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

export XDG_RUNTIME_DIR="/run/user/$(id -u)"

readonly LOG_DIR="${LOG_BASE_DIR}/mod_checks"
readonly LOG_FILE="${LOG_DIR}/mod_checks_$(date +'%Y-%m-%d').log"
readonly RETENTION_DAYS=7

ensure_directory "${LOG_DIR}"

log_event() { echo "[$(date +'%H:%M:%S')] $*" >> "${LOG_FILE}"; }

cleanup_old_logs() {
    find "${LOG_DIR}" -name "*.log" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
}

check_prerequisites() {
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" || exit 0
    [[ -p "${PZ_CONTROL_PIPE}" ]] || { log_event "ERROR: Control pipe unavailable"; exit 1; }
    [[ -x "${SCRIPT_DIR}/performFullMaintenance.sh" ]] || { log_event "ERROR: Maintenance script not found"; exit 1; }
}

# Returns: 0=updates needed, 1=up to date or error
check_mods() {
    local output exit_code=0
    output=$("${SCRIPT_DIR}/../internal/sendCommand.sh" "checkModsNeedUpdate" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_event "ERROR: RCON failed - ${output}"
        "${SCRIPT_DIR}/../internal/sendDiscord.sh" "ERROR: Mod check failed" || true
        return 1
    fi

    if echo "${output}" | grep -iq "mods updated\|up.*to.*date"; then
        log_event "OK - mods up to date"
        return 1
    fi

    if echo "${output}" | grep -iq "need.*update\|outdated"; then
        log_event "MOD UPDATES DETECTED"
        return 0
    fi

    log_event "OK - no updates"
    return 1
}

trigger_maintenance() {
    log_event "Triggering maintenance (5m delay)"
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "Mods mis à jour" || true
    flock -u 200
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m"
    log_event "Maintenance completed"
}

main() {
    cleanup_old_logs
    check_prerequisites

    if ! try_acquire_maintenance_lock; then
        log_event "Maintenance in progress - skipping"
        exit 0
    fi

    check_mods && trigger_maintenance
}

main
