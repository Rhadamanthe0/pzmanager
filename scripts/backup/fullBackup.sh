#!/bin/bash
# ------------------------------------------------------------------------------
# fullBackup.sh - Complete backup for external synchronization
# ------------------------------------------------------------------------------
# Creates timestamped backup in fullBackups/YYYY-MM-DD_HH-MM/ containing:
#   - System config (sudoers)
#   - SSH keys, systemd services/timers, scripts
#   - ZIP archive of latest Zomboid backup
# Retention defined in .env
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
readonly BACKUP_DEST="${SYNC_BACKUPS_DIR}/${TIMESTAMP}"

readonly DIRS_TO_SYNC=(
    "${PZ_HOME}/.ssh"
    "${PZ_HOME}/.config/systemd/user"
    "${PZ_HOME}/pzmanager/data/setupTemplates"
    "${SCRIPT_DIR}"
)

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND failed." >&2' ERR

sync_files() {
    log "Syncing configuration files..."
    mkdir -p "${BACKUP_DEST}"

    for item in "${DIRS_TO_SYNC[@]}"; do
        [[ -e "$item" ]] && rsync -aR --delete "$item" "${BACKUP_DEST}/" || echo "Skipped: $item"
    done
}

backup_sudoers() {
    log "Backing up sudoers configuration..."
    local sudoers_dest="${BACKUP_DEST}/etc/sudoers.d"
    mkdir -p "$sudoers_dest"

    # Use sudo cat (read-only, output redirected by user shell)
    sudo /bin/cat "/etc/sudoers.d/${PZ_USER}" > "$sudoers_dest/${PZ_USER}" 2>/dev/null || echo "Skipped: /etc/sudoers.d/${PZ_USER}"
}

archive_game_data() {
    log "Creating Zomboid ZIP archive..."

    [[ -L "${BACKUP_LATEST_LINK}" ]] || { echo "Erreur: Lien dernier backup introuvable: ${BACKUP_LATEST_LINK}"; exit 1; }

    local archive_dest="${BACKUP_DEST}${PZ_HOME}/Zomboid_Latest_Full.zip"
    mkdir -p "$(dirname "$archive_dest")"

    cd "$(dirname "${BACKUP_LATEST_LINK}")"
    zip -r -q "$archive_dest" "latest"
}

cleanup_old_backups() {
    log "Cleaning backups older than ${BACKUP_RETENTION_DAYS} days..."

    [[ -d "${SYNC_BACKUPS_DIR}" ]] || return 0

    find "${SYNC_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]" -mtime "+${BACKUP_RETENTION_DAYS}" -print -exec rm -rf {} +
}

sync_files
backup_sudoers
archive_game_data
cleanup_old_backups

log "Backup completed: ${BACKUP_DEST}"
