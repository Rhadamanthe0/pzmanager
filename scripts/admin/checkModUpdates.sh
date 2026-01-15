#!/bin/bash
# ------------------------------------------------------------------------------
# checkModUpdates.sh - Check for Project Zomboid mod updates
# ------------------------------------------------------------------------------
# Usage: ./checkModUpdates.sh
#
# Checks if Workshop mods have updates via RCON checkModsNeedUpdate command.
# If updates detected:
#   - Send Discord notification
#   - Trigger performFullMaintenance.sh with 5m delay
#
# Execution: pzuser (via crontab)
# Schedule: Twice daily at 10:00 AM and 8:00 PM
# Logs: LOG_MAINTENANCE_DIR/mod_check_YYYY-MM-DD_HHhMMmSSs.log
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly LOG_FILE="${LOG_MAINTENANCE_DIR}/mod_check_$(date +'%Y-%m-%d_%Hh%Mm%S').log"

ensure_directory "${LOG_MAINTENANCE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if server is running
    if ! systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        log "Server not running - cannot check mods"
        exit 0
    fi

    # Check if control pipe exists
    if [[ ! -p "${PZ_CONTROL_PIPE}" ]]; then
        log "ERROR: Control pipe unavailable: ${PZ_CONTROL_PIPE}"
        exit 1
    fi

    # Check if maintenance script exists
    if [[ ! -x "${SCRIPT_DIR}/performFullMaintenance.sh" ]]; then
        log "ERROR: Maintenance script not found: ${SCRIPT_DIR}/performFullMaintenance.sh"
        exit 1
    fi

    log "Prerequisites OK"
}

check_mods() {
    log "Checking for mod updates via RCON..."

    # Send command and capture output
    local output
    local exit_code=0

    output=$("${SCRIPT_DIR}/../internal/sendCommand.sh" "checkModsNeedUpdate" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR: Failed to send RCON command (exit code: $exit_code)"
        log "Output: ${output}"
        "${SCRIPT_DIR}/../internal/sendDiscord.sh" "❌ ERROR: Mod update check failed - see logs" || true
        return 1
    fi

    log "RCON output: ${output}"

    # Parse output for update indicators
    # "Mods updated" or "up to date" = NO updates needed
    if echo "${output}" | grep -iq "mods updated\|up.*to.*date\|all.*current\|no.*update"; then
        log "Mods are up to date"
        return 1
    fi

    # "Need update" or "outdated" or "new version" = Updates needed
    if echo "${output}" | grep -iq "need.*update\|outdated\|new.*version\|update.*available"; then
        log "Mod updates detected!"
        return 0
    fi

    # Unknown output - assume no updates (safe default)
    log "Unknown RCON output format - assuming no updates"
    return 1
}

trigger_maintenance() {
    log "Triggering maintenance with 5-minute delay..."

    # Send Discord notification
    local message="⚠️ MOD UPDATES DETECTED - Starting maintenance in 5 minutes"
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "${message}" || true

    log "Discord notification sent"

    # Trigger maintenance
    log "Launching performFullMaintenance.sh with 5m delay..."
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m"
}

main() {
    log "=== MOD UPDATE CHECK STARTED ==="

    check_prerequisites

    if check_mods; then
        trigger_maintenance
    else
        log "No action needed"
    fi

    log "=== MOD UPDATE CHECK COMPLETED ==="
}

main
