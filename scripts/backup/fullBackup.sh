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
    "${PZ_DATA_DIR}/setupTemplates"
    "${PZ_SCRIPTS_DIR}"
)

# Contenu volumineux ou reconstructible, exclu de la sauvegarde des scripts :
# les logs sont déjà persistés ailleurs et le venv se rebâtit via `pzm install
# discord`. Sans ça, sauvegarder PZ_SCRIPTS_DIR embarquerait des centaines de Mo.
readonly SYNC_EXCLUDES=(
    --exclude "logs/"
    --exclude ".venv/"
    --exclude "__pycache__/"
)

trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND failed." >&2' ERR

sync_files() {
    log "Syncing configuration files..."
    mkdir -p "${BACKUP_DEST}"

    for item in "${DIRS_TO_SYNC[@]}"; do
        [[ -e "$item" ]] && rsync -aR --delete "${SYNC_EXCLUDES[@]}" "$item" "${BACKUP_DEST}/" || echo "Skipped: $item"
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

    if [[ ! -L "${BACKUP_LATEST_LINK}" ]]; then
        echo "Warning: Latest backup symlink not found (${BACKUP_LATEST_LINK}), skipping archive"
        return 0
    fi

    local archive_dest="${BACKUP_DEST}${PZ_HOME}/Zomboid_Latest_Full.zip"
    mkdir -p "$(dirname "$archive_dest")"

    cd "$(dirname "${BACKUP_LATEST_LINK}")"
    zip -r -q "$archive_dest" "latest"
}

cleanup_old_backups() {
    # Rétention off-site par COMPTE (pas par jours) : ces backups sont des ZIP
    # complets mirrorés par Syncthing vers le PC fixe. Chaque zip = ~monde complet,
    # donc on en garde un petit nombre fixe. Le nom horodaté YYYY-MM-DD_HH-MM trie
    # chronologiquement en lexicographique -> sort -r = du plus récent au plus vieux.
    local keep="${OFFSITE_BACKUP_COUNT:-7}"
    log "Nettoyage off-site : conservation des ${keep} derniers ZIP..."

    [[ -d "${SYNC_BACKUPS_DIR}" ]] || return 0

    local dirs=()
    mapfile -t dirs < <(find "${SYNC_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]" | sort -r)

    local i
    for (( i = keep; i < ${#dirs[@]}; i++ )); do
        rm -rf -- "${dirs[i]}"
        echo "  Supprimé (au-delà des ${keep}) : $(basename "${dirs[i]}")"
    done
}

sync_files
backup_sudoers
archive_game_data
cleanup_old_backups

log "Backup completed: ${BACKUP_DEST}"
