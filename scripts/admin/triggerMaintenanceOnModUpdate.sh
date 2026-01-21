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
# Logs: LOG_BASE_DIR/mod_checks/mod_checks_YYYY-MM-DD.log (daily, 7-day retention)
#       Only logs significant events (updates, errors, maintenance triggered)
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
readonly LOCK_MAX_AGE_SECONDS=3600

readonly MOD_CHECK_LOG_DIR="${LOG_BASE_DIR}/mod_checks"
readonly MOD_CHECK_RETENTION_DAYS=7
readonly LOG_FILE="${MOD_CHECK_LOG_DIR}/mod_checks_$(date +'%Y-%m-%d').log"

ensure_directory "${MOD_CHECK_LOG_DIR}"

# Log function that writes to daily file (only called for significant events)
log_event() {
    echo "[$(date +'%H:%M:%S')] $*" >> "${LOG_FILE}"
}

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
    # Clean stale lock (>1 hour old)
    if [[ -f "${MAINTENANCE_LOCK_FILE}" ]]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "${MAINTENANCE_LOCK_FILE}" 2>/dev/null || echo 0) ))
        if (( lock_age > LOCK_MAX_AGE_SECONDS )); then
            rm -f "${MAINTENANCE_LOCK_FILE}"
            return 1
        fi

        # Check if lock is held
        if flock -n 200 200>"${MAINTENANCE_LOCK_FILE}" 2>/dev/null; then
            flock -u 200
            return 1
        fi
        return 0
    fi
    return 1
}

check_prerequisites() {
    # Maintenance running - log and skip
    if is_maintenance_running; then
        log_event "Maintenance in progress - skipping"
        exit 0
    fi

    # Server not running - silent exit (normal state)
    if ! is_server_running; then
        exit 0
    fi

    # Critical errors - log and die
    has_control_pipe || { log_event "ERROR: Control pipe unavailable"; exit 1; }
    has_maintenance_script || { log_event "ERROR: Maintenance script not found"; exit 1; }
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
    local output
    local exit_code=0

    output=$(send_rcon_command) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_event "ERROR: RCON command failed (exit: $exit_code) - ${output}"
        send_error_notification
        return 1
    fi

    if is_mods_up_to_date "${output}"; then
        log_event "OK - mods up to date"
        return 1
    fi

    if has_mod_updates "${output}"; then
        log_event "MOD UPDATES DETECTED"
        return 0
    fi

    log_event "OK - no updates"
    return 1
}

send_update_notification() {
    local message="⚠️ Mods mis à jour ⚠️"
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "${message}" || true
}

trigger_maintenance() {
    log_event "Triggering maintenance (5m delay)"
    send_update_notification
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m"
    log_event "Maintenance completed"
}

cleanup_old_logs() {
    find "${MOD_CHECK_LOG_DIR}" -name "*.log" -type f -mtime "+${MOD_CHECK_RETENTION_DAYS}" -delete 2>/dev/null || true
}

main() {
    cleanup_old_logs
    check_prerequisites

    if check_mods; then
        trigger_maintenance
    fi
    # No log if no updates (routine - silent)
}

main
