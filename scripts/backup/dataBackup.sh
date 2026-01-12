#!/bin/bash
# ------------------------------------------------------------------------------
# dataBackup.sh - Incremental Zomboid data backup
# ------------------------------------------------------------------------------
# Backs up Saves/, db/, Server/ with hardlinks (rsync --link-dest)
# Triggers in-game save if server is running
# Auto-rotation: removes backups older than BACKUP_RETENTION_DAYS
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Valider répertoires
validate_directory "${PZ_SOURCE_DIR}" "Répertoire source Zomboid"
ensure_directory "${BACKUP_DIR}"

# Trigger in-game save if server is running
if [[ -p "${PZ_CONTROL_PIPE}" ]]; then
    echo "save" > "${PZ_CONTROL_PIPE}"
    sleep 60
fi

readonly TIMESTAMP=$(date +"%Y-%m-%d_%Hh%Mm%Ss")
readonly BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"

echo "Backing up to ${BACKUP_PATH}..."

rsync_opts=(-a --delete)
[[ -d "${BACKUP_LATEST_LINK}" ]] && rsync_opts+=(--link-dest="${BACKUP_LATEST_LINK}")

cd "${PZ_SOURCE_DIR}"
rsync "${rsync_opts[@]}" --relative Saves db Server "${BACKUP_PATH}"

rm -rf "${BACKUP_LATEST_LINK}"
ln -s "${BACKUP_PATH}" "${BACKUP_LATEST_LINK}"

# Cleanup old backups
cd "${BACKUP_DIR}"

deleted_count=$(find . -maxdepth 1 -type d -name "backup_*" -mtime "+${BACKUP_RETENTION_DAYS}" -print | wc -l)

if (( deleted_count > 0 )); then
    find . -maxdepth 1 -type d -name "backup_*" -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
    echo "Cleaned: $deleted_count backup(s) older than ${BACKUP_RETENTION_DAYS} days."
fi

total_count=$(find . -maxdepth 1 -type d -name "backup_*" | wc -l)
echo "Backup completed. Total: $total_count snapshots."
