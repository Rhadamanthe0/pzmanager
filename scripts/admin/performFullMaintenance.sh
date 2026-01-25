#!/bin/bash
# ------------------------------------------------------------------------------
# performFullMaintenance.sh - Maintenance quotidienne du serveur
# ------------------------------------------------------------------------------
# Usage: ./performFullMaintenance.sh [délai] [--silent]
# Délais: 30m|15m|5m|2m|30s|now (défaut: 30m)
#
# Options:
#   --silent  Pas de notifications Discord, marque le prochain démarrage silencieux
#
# Verrou: Une seule instance (flock), nettoyage si >1h
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly LOCK_FILE="/tmp/pzmanager-maintenance.lock"
readonly SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/.silent_next_start"
readonly LOCK_MAX_AGE_SECONDS=3600

# Clean stale lock (>1 hour old)
if [[ -f "${LOCK_FILE}" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0) ))
    if (( lock_age > LOCK_MAX_AGE_SECONDS )); then
        rm -f "${LOCK_FILE}"
    fi
fi

# Acquire exclusive lock (non-blocking)
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[$(date +'%H:%M:%S')] Maintenance already running, skipping."
    exit 0
fi

# Parse arguments
DELAY="30m"
SILENT_MODE=false
for arg in "${SSH_ORIGINAL_COMMAND:-}" "$@"; do
    [[ -z "$arg" ]] && continue
    [[ "$arg" == "--silent" ]] && SILENT_MODE=true && continue
    [[ "$arg" =~ ^(30m|15m|5m|2m|30s|now)$ ]] && DELAY="$arg"
done

cd "${PZ_HOME}"

readonly LOG_FILE="${LOG_MAINTENANCE_DIR}/maintenance_$(date +'%Y-%m-%d_%Hh%Mm%S').log"
ensure_directory "${LOG_MAINTENANCE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

validate_prerequisites() {
    log "Validation des prérequis..."
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"
}

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
    log "Mise à jour des paquets..."
    sudo /usr/bin/apt-get update -qq
    log "Mise à niveau du système..."
    sudo /usr/bin/apt-get upgrade -y -qq
    log "Installation de ${JAVA_PACKAGE}..."
    sudo /usr/bin/apt-get install -y -qq "${JAVA_PACKAGE}"
    log "Nettoyage des paquets obsolètes..."
    sudo /usr/bin/apt-get autoremove -y -qq
    sudo /usr/bin/apt-get autoclean -qq
    [[ -d "${JAVA_PATH}" ]] || die "Java non installé dans ${JAVA_PATH}"
}

update_game_server() {
    log "Mise à jour SteamCMD..."
    sudo rm -rf "${PZ_JRE_LINK}"
    "${STEAMCMD_PATH}" +login anonymous +force_install_dir "${PZ_INSTALL_DIR}" \
        +app_update "${STEAM_APP_ID}" -beta "${STEAM_BETA_BRANCH}" validate +quit
}

restore_java_symlink() {
    log "Restauration symlink Java..."
    sudo rm -rf "${PZ_JRE_LINK}"
    sudo ln -s "${JAVA_PATH}" "${PZ_JRE_LINK}"
}

sync_external_data() {
    log "Synchronisation externe..."
    [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]] && "${SCRIPT_DIR}/../backup/fullBackup.sh"
}

main() {
    log "=== MAINTENANCE DEMARREE ==="
    validate_prerequisites
    stop_server
    rotate_backups
    update_system
    update_game_server
    restore_java_symlink
    sync_external_data

    # Mark next server start as silent (persists after reboot)
    [[ "$SILENT_MODE" == true ]] && touch "${SILENT_FLAG_FILE}"

    log "Maintenance terminée, redémarrage..."
    sudo /sbin/reboot
}

main
