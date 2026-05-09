#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, reboot)
# Usage: ./performFullMaintenance.sh [délai] [options]
# Options: --reason=TEXT (pour personnaliser le message), --silent
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
MAINTENANCE_REASON="Maintenance"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --reason)
            MAINTENANCE_REASON="$2"
            shift 2
            ;;
        --reason=*)
            MAINTENANCE_REASON="${1#--reason=}"
            shift
            ;;
        30m|15m|5m|2m|30s|now)
            DELAY="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

cd "${PZ_HOME}"

readonly MAINT_LOG="${LOG_MAINTENANCE_DIR}/maintenance_$(date +'%Y-%m-%d_%Hh%Mm%S').log"
ensure_directory "${LOG_MAINTENANCE_DIR}"
exec > >(tee -a "${MAINT_LOG}") 2>&1

stop_server() {
    local silent_opt=""
    [[ "$SILENT_MODE" == true ]] && silent_opt="--silent"
    log "Arrêt du serveur ($DELAY) pour maintenance..."
    "${SCRIPT_DIR}/../core/pz.sh" stop "$DELAY" --reason "$MAINTENANCE_REASON" --automatic $silent_opt
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

    # Nettoyer un éventuel état SteamCMD corrompu (manifest, staging)
    local steamapps="${PZ_INSTALL_DIR}/steamapps"
    rm -rf "${steamapps}/downloading" "${steamapps}/temp"
    local manifest="${steamapps}/appmanifest_${STEAM_APP_ID}.acf"
    if [[ -f "$manifest" ]]; then
        local state
        state=$(grep -oP '"StateFlags"\s*"\K[0-9]+' "$manifest" 2>/dev/null || echo "0")
        if [[ "$state" != "4" ]]; then
            log "Manifest corrompu (StateFlags=$state), réinitialisation..."
            rm -f "$manifest"
        fi
    fi

    "${STEAMCMD_PATH}" +force_install_dir "${PZ_INSTALL_DIR}" +login anonymous \
        +app_update "${STEAM_APP_ID}" -beta "${STEAM_BETA_BRANCH}" validate +quit
}

sync_external() {
    log "Synchronisation externe..."
    if [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]]; then
        "${SCRIPT_DIR}/../backup/fullBackup.sh" || log "WARNING: Synchronisation externe échouée (non bloquant)"
    fi
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
        "${SCRIPT_DIR}/../internal/sendDiscord.sh" "Maintenance terminée - Redémarrage machine" || true
        sudo /sbin/reboot
    else
        log "Maintenance terminée, redémarrage du service..."
        "${SCRIPT_DIR}/../core/pz.sh" start --reason "$MAINTENANCE_REASON" --automatic
    fi
}

main
