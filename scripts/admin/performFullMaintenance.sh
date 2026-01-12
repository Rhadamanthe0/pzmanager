#!/bin/bash
# ------------------------------------------------------------------------------
# performFullMaintenance.sh - Maintenance quotidienne du serveur
# ------------------------------------------------------------------------------
# Usage: ./performFullMaintenance.sh [délai]
# Délais: 30m|15m|5m|2m|30s (défaut: 30m)
#
# Exécution: pzuser (via crontab pzuser)
#
# Étapes:
#   1. Arrêt du serveur (avec avertissements)
#   2. Rotation des backups (suppression > 30 jours)
#   3. Mise à jour système (apt + Java)
#   4. Mise à jour SteamCMD
#   5. Restauration symlink Java
#   6. Synchronisation externe (fullBackup.sh)
#   7. Reboot système
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

cd "${PZ_HOME}"

readonly DELAY="${SSH_ORIGINAL_COMMAND:-${1:-30m}}"

readonly LOG_FILE="${LOG_MAINTENANCE_DIR}/maintenance_$(date +'%Y-%m-%d_%Hh%Mm%S').log"

ensure_directory "${LOG_MAINTENANCE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

validate_prerequisites() {
    log "Validation des prérequis..."
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"
    [[ "$DELAY" =~ ^(30m|15m|5m|2m|30s)$ ]] || die "Délai '$DELAY' invalide"
}

stop_server() {
    log "Arrêt du serveur ($DELAY)..."
    "${SCRIPT_DIR}/../core/pz.sh" stop "$DELAY"
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
    sudo rm -f "${PZ_JRE_LINK}"
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
    [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]] && sudo "${SCRIPT_DIR}/../backup/fullBackup.sh"
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
    log "Maintenance terminée, redémarrage..."
    sudo /sbin/reboot
}

main
