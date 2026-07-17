#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, reboot)
# Usage: ./performFullMaintenance.sh [délai] [options]
# Options: --reason TEXT (raison de maintenance), --automatic (flag si auto), --silent
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
AUTOMATIC_MODE=false
MAINTENANCE_REASON="Maintenance"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --automatic)
            AUTOMATIC_MODE=true
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
        30m|15m|5m|2m|30s|now|auto)
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
    local automatic_opt=""
    [[ "$SILENT_MODE" == true ]] && silent_opt="--silent"
    [[ "$AUTOMATIC_MODE" == true ]] && automatic_opt="--automatic"
    log "Arrêt du serveur ($DELAY) pour maintenance..."
    "${SCRIPT_DIR}/../core/pz.sh" stop "$DELAY" --maintenance --reason "$MAINTENANCE_REASON" $automatic_opt $silent_opt
}

rotate_backups() {
    log "Rotation des backups (${BACKUP_RETENTION_DAYS} jours)..."
    [[ -d "${BACKUP_DIR}" ]] || return 0
    find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
}

update_system() {
    log "Mise à jour système..."
    # Deux arguments distincts, pas une chaîne unique : la forme doit rester
    # alignée sur les règles de data/setupTemplates/pzuser-sudoers.
    local -a apt_lock=(-o DPkg::Lock::Timeout=300)
    sudo /usr/bin/apt-get update -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get upgrade -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get install -y -qq "${apt_lock[@]}" "${JAVA_PACKAGE}"
    sudo /usr/bin/apt-get autoremove -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get autoclean -qq "${apt_lock[@]}"
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

    "${STEAMCMD_PATH}" +force_install_dir "${PZ_INSTALL_DIR}" +login "${STEAM_LOGIN:-anonymous}" \
        +app_update "${STEAM_APP_ID}" -beta "${STEAM_BETA_BRANCH}" validate +quit

    # Le validate restaure le ProjectZomboid64.json vanilla : réappliquer le tuning
    "${SCRIPT_DIR}/../internal/configureJvm.sh"
}

# App ID du JEU (108600) pour les mods Workshop — distinct du serveur dédié (380870)
readonly STEAM_WORKSHOP_APP_ID=108600

download_workshop_mods() {
    # Pré-télécharge les mods Workshop listés dans servertest.ini avec le compte
    # STEAM_LOGIN. Depuis 2026 Steam a retiré PZ des DL Workshop anonymes : le
    # serveur ne peut plus télécharger lui-même un mod NEUF ou MIS À JOUR au boot
    # (onItemNotDownloaded result=3 -> NPE -> crash-loop). En les pré-tirant ici
    # (serveur arrêté -> écriture du dossier workshop sûre) avec un compte possédant
    # PZ, le serveur les retrouve "Installed/Ready" au démarrage. Non bloquant.
    local login="${STEAM_LOGIN:-anonymous}"
    if [[ "$login" == "anonymous" ]]; then
        log "STEAM_LOGIN non défini : pré-DL des mods ignoré (DL anonyme cassé pour les items neufs/mis à jour)."
        return 0
    fi
    local ini="${PZ_INI_PATH}"
    if [[ ! -f "$ini" ]]; then
        log "WARNING: $ini introuvable, pré-DL des mods ignoré"
        return 0
    fi
    local items
    items=$(grep -oP '^WorkshopItems=\K.*' "$ini" | tr ';' ' ')
    if [[ -z "${items// }" ]]; then
        log "Aucun WorkshopItems à pré-télécharger."
        return 0
    fi
    log "Pré-téléchargement des mods Workshop (compte ${login})..."
    local args=(+force_install_dir "${PZ_INSTALL_DIR}" +login "${login}")
    local id
    for id in $items; do
        args+=(+workshop_download_item "${STEAM_WORKSHOP_APP_ID}" "${id}")
    done
    args+=(+quit)
    if "${STEAMCMD_PATH}" "${args[@]}"; then
        log "Pré-téléchargement des mods Workshop terminé."
    else
        log "WARNING: pré-DL des mods Workshop en échec (non bloquant) — vérifier le login '${login}' (jeton steamcmd expiré ?)."
    fi
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

    # La purge des accès inactifs n'est plus déclenchée ici : elle est en
    # ExecStartPre de zomboid.service, donc rejouée à chaque démarrage (dont
    # celui qui suit cette maintenance), toujours monde fermé.
    stop_server
    rotate_backups
    update_system
    update_game_server
    download_workshop_mods
    sync_external

    [[ "$SILENT_MODE" == true ]] && touch "${SILENT_FLAG_FILE}"

    if [[ "${REBOOT_ON_MAINTENANCE:-true}" == true ]]; then
        log "Maintenance terminée, redémarrage machine..."
        [[ "$SILENT_MODE" != true ]] && "${SCRIPT_DIR}/../internal/sendDiscord.sh" "Maintenance terminée - Redémarrage machine" || true
        sudo /sbin/reboot
    else
        log "Maintenance terminée, redémarrage du service..."
        local automatic_opt=""
        [[ "$AUTOMATIC_MODE" == true ]] && automatic_opt="--automatic"
        "${SCRIPT_DIR}/../core/pz.sh" start --reason "$MAINTENANCE_REASON" $automatic_opt
    fi
}

main
