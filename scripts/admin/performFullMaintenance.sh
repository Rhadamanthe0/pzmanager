#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, reboot)
# Usage: ./performFullMaintenance.sh [délai] [--silent]
# Lock partagé avec pz.sh/triggerMaintenanceOnModUpdate.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/.silent_next_start"

# Acquire lock
if ! try_acquire_maintenance_lock; then
    echo "[$(date +'%H:%M:%S')] Maintenance already running, skipping."
    exit 0
fi

# Parse arguments
DELAY="30m"
SILENT_MODE=false
for arg in "$@"; do
    [[ "$arg" == "--silent" ]] && SILENT_MODE=true
    [[ "$arg" =~ ^(30m|15m|5m|2m|30s|now)$ ]] && DELAY="$arg"
done

cd "${PZ_HOME}"

readonly MAINT_LOG="${LOG_MAINTENANCE_DIR}/maintenance_$(date +'%Y-%m-%d_%Hh%Mm%S').log"
ensure_directory "${LOG_MAINTENANCE_DIR}"
exec > >(tee -a "${MAINT_LOG}") 2>&1

stop_server() {
    local silent_opt=""
    [[ "$SILENT_MODE" == true ]] && silent_opt="--silent"
    log "Arrêt du serveur ($DELAY)..."
    "${SCRIPT_DIR}/../core/pz.sh" stop "$DELAY" $silent_opt
}

rotate_backups() {
    log "Rotation des backups (${BACKUP_RETENTION_DAYS} jours)..."
    [[ -d "${BACKUP_DIR}" ]] || return 0
    find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
}

update_system() {
    log "Mise à jour système..."
    local apt_lock_timeout="-o DPkg::Lock::Timeout=300"
    sudo /usr/bin/apt-get update -qq "$apt_lock_timeout"
    sudo /usr/bin/apt-get upgrade -y -qq "$apt_lock_timeout"
    sudo /usr/bin/apt-get install -y -qq "$apt_lock_timeout" "${JAVA_PACKAGE}"
    sudo /usr/bin/apt-get autoremove -y -qq "$apt_lock_timeout"
    sudo /usr/bin/apt-get autoclean -qq "$apt_lock_timeout"
    [[ -d "${JAVA_PATH}" ]] || die "Java non installé"
}

update_game_server() {
    log "Mise à jour SteamCMD..."
    if [[ "${REPLACE_JRE:-true}" == true ]]; then
        sudo rm -rf "${PZ_JRE_LINK}"
    fi
    "${STEAMCMD_PATH}" +login anonymous +force_install_dir "${PZ_INSTALL_DIR}" \
        +app_update "${STEAM_APP_ID}" -beta "${STEAM_BETA_BRANCH}" validate +quit
    if [[ "${REPLACE_JRE:-true}" == true ]]; then
        sudo ln -s "${JAVA_PATH}" "${PZ_JRE_LINK}"
    fi
}

sync_external() {
    log "Synchronisation externe..."
    [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]] && "${SCRIPT_DIR}/../backup/fullBackup.sh"
}

main() {
    log "=== MAINTENANCE DEMARREE ==="
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"

    stop_server
    rotate_backups
    update_system
    update_game_server
    sync_external

    [[ "$SILENT_MODE" == true ]] && touch "${SILENT_FLAG_FILE}"

    if [[ "${REBOOT_ON_MAINTENANCE:-true}" == true ]]; then
        log "Maintenance terminée, redémarrage machine..."
        sudo /sbin/reboot
    else
        log "Maintenance terminée, redémarrage du service..."
        "${SCRIPT_DIR}/../core/pz.sh" start
    fi
}

main
