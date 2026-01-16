#!/bin/bash
# ------------------------------------------------------------------------------
# triggerMaintenanceOnModUpdate.sh - Auto-trigger maintenance if mods need update
# ------------------------------------------------------------------------------
# Usage: ./triggerMaintenanceOnModUpdate.sh
#
# Checks if Workshop mods have updates via RCON checkModsNeedUpdate command.
# If updates detected, triggers performFullMaintenance.sh with 5m delay
# (server shutdown with player warnings, updates, reboot).
#
# Execution: pzuser (via systemd timer every 5 minutes)
# Logs: LOG_BASE_DIR/mod_checks/YYYY-MM-DD_HHhMMmSS.log (7-day retention)
# Lock: Skips if maintenance already running (shared lock with performFullMaintenance.sh)
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Set XDG_RUNTIME_DIR for systemctl --user (required when running via cron)
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Lock file shared with performFullMaintenance.sh
readonly MAINTENANCE_LOCK_FILE="/tmp/pzmanager-maintenance.lock"

readonly MOD_CHECK_LOG_DIR="${LOG_BASE_DIR}/mod_checks"
readonly MOD_CHECK_RETENTION_DAYS=7
readonly LOG_FILE="${MOD_CHECK_LOG_DIR}/$(date +'%Y-%m-%d_%Hh%Mm%S').log"

ensure_directory "${MOD_CHECK_LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

is_server_running() {
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"
}

has_control_pipe() {
    [[ -p "${PZ_CONTROL_PIPE}" ]]
}

has_maintenance_script() {
    [[ -x "${SCRIPT_DIR}/performFullMaintenance.sh" ]]
}

is_maintenance_running() {
    # Check if maintenance lock is held
    if [[ -f "${MAINTENANCE_LOCK_FILE}" ]]; then
        if flock -n 200 200>"${MAINTENANCE_LOCK_FILE}" 2>/dev/null; then
            # Lock acquired, maintenance not running - release immediately
            flock -u 200
            return 1
        else
            # Lock held by another process
            return 0
        fi
    fi
    return 1
}

check_prerequisites() {
    log "Checking prerequisites..."

    if is_maintenance_running; then
        log "Maintenance already in progress - skipping check"
        exit 0
    fi

    if ! is_server_running; then
        log "Server not running - cannot check mods"
        exit 0
    fi

    has_control_pipe || die "Control pipe unavailable: ${PZ_CONTROL_PIPE}"
    has_maintenance_script || die "Maintenance script not found"

    log "Prerequisites OK"
}

send_rcon_command() {
    "${SCRIPT_DIR}/../internal/sendCommand.sh" "checkModsNeedUpdate" 2>&1
}

is_mods_up_to_date() {
    local output="$1"
    echo "${output}" | grep -iq "mods updated\|up.*to.*date\|all.*current\|no.*update"
}

has_mod_updates() {
    local output="$1"
    echo "${output}" | grep -iq "need.*update\|outdated\|new.*version\|update.*available"
}

send_error_notification() {
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "❌ ERROR: Mod update check failed - see logs" || true
}

check_mods() {
    log "Checking for mod updates via RCON..."

    local output
    local exit_code=0

    output=$(send_rcon_command) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR: Failed to send RCON command (exit code: $exit_code)"
        log "Output: ${output}"
        send_error_notification
        return 1
    fi

    log "RCON output: ${output}"

    if is_mods_up_to_date "${output}"; then
        log "Mods are up to date"
        return 1
    fi

    if has_mod_updates "${output}"; then
        log "Mod updates detected!"
        return 0
    fi

    log "Unknown RCON output format - assuming no updates"
    return 1
}

send_update_notification() {
    local message="⚠️ MOD UPDATES DETECTED - Starting maintenance in 5 minutes"
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "${message}" || true
    log "Discord notification sent"
}

trigger_maintenance() {
    log "Triggering maintenance with 5-minute delay..."
    send_update_notification
    log "Launching performFullMaintenance.sh..."
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m"
}

cleanup_old_logs() {
    find "${MOD_CHECK_LOG_DIR}" -name "*.log" -type f -mtime "+${MOD_CHECK_RETENTION_DAYS}" -delete 2>/dev/null || true
}

main() {
    log "=== MOD UPDATE CHECK STARTED ==="

    cleanup_old_logs
    check_prerequisites

    if check_mods; then
        trigger_maintenance
    else
        log "No action needed"
    fi

    log "=== MOD UPDATE CHECK COMPLETED ==="
}

main
