#!/bin/bash
# triggerMaintenanceOnModUpdate.sh - Déclenche maintenance si mods ou serveur mis à jour
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

    # Extract the status from "CheckModsNeedUpdate: <status>" lines
    # Possible responses: "Mods updated" (up to date) or "Mods need update" (outdated)
    local status
    status=$(echo "${output}" | grep -i "CheckModsNeedUpdate:" | sed 's/.*CheckModsNeedUpdate: *//' || true)

    if echo "${status}" | grep -iq "need.*update\|outdated"; then
        log_event "MOD UPDATES DETECTED (status: ${status})"
        return 0
    fi

    if echo "${status}" | grep -iq "mods updated\|up.*to.*date"; then
        log_event "OK - mods up to date"
        return 1
    fi

    log_event "OK - no updates (response: ${output:0:100})"
    return 1
}

# Returns: 0=server update available, 1=up to date or error
check_server_update() {
    local manifest="${PZ_INSTALL_DIR}/steamapps/appmanifest_${STEAM_APP_ID}.acf"

    if [[ ! -f "$manifest" ]]; then
        log_event "WARNING: App manifest not found, skipping server update check"
        return 1
    fi

    # Get installed build ID from local manifest
    local installed_buildid
    installed_buildid=$(grep -oP '"buildid"\s*"\K[0-9]+' "$manifest" 2>/dev/null || echo "")

    if [[ -z "$installed_buildid" ]]; then
        log_event "WARNING: Could not read installed build ID"
        return 1
    fi

    # Query SteamCMD for the latest build ID on the configured beta branch
    local steam_output
    steam_output=$(timeout 60 "${STEAMCMD_PATH}" +login anonymous \
        +app_info_update 1 \
        +app_info_print "${STEAM_APP_ID}" \
        +quit 2>/dev/null) || {
        log_event "WARNING: SteamCMD query failed"
        return 1
    }

    # Parse the build ID for the configured beta branch (e.g. "unstable")
    # The manifest structure has: "branches" { "<branch>" { "buildid" "<id>" } }
    local remote_buildid
    remote_buildid=$(echo "$steam_output" | awk -v branch="${STEAM_BETA_BRANCH}" '
        /"branches"/ { in_branches=1 }
        in_branches && $0 ~ "\"" branch "\"" { in_branch=1 }
        in_branch && /"buildid"/ {
            gsub(/[^0-9]/, "")
            print
            exit
        }
        in_branch && /^\t*\}/ { in_branch=0 }
    ')

    if [[ -z "$remote_buildid" ]]; then
        log_event "WARNING: Could not read remote build ID for branch ${STEAM_BETA_BRANCH}"
        return 1
    fi

    if [[ "$installed_buildid" != "$remote_buildid" ]]; then
        log_event "SERVER UPDATE AVAILABLE (installed: ${installed_buildid}, remote: ${remote_buildid}, branch: ${STEAM_BETA_BRANCH})"
        return 0
    fi

    log_event "OK - server up to date (buildid: ${installed_buildid}, branch: ${STEAM_BETA_BRANCH})"
    return 1
}

trigger_maintenance() {
    local reason="$1"
    log_event "Triggering maintenance (5m delay) - reason: ${reason}"
    flock -u 200
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m" --reason "$reason" --automatic
    log_event "Maintenance completed"
}

main() {
    cleanup_old_logs
    check_prerequisites

    if ! try_acquire_maintenance_lock; then
        log_event "Maintenance in progress - skipping"
        exit 0
    fi

    if check_mods; then
        trigger_maintenance "Mods mis à jour"
        exit 0
    fi

    if check_server_update; then
        trigger_maintenance "Mise à jour serveur disponible"
        exit 0
    fi
}

main
