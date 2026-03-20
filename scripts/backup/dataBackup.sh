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
    if timeout 10 bash -c "echo 'save' > '${PZ_CONTROL_PIPE}'" 2>/dev/null; then
        sleep 60
    else
        echo "Warning: Could not send save command (pipe timeout or server not responding)"
    fi
fi

readonly TIMESTAMP=$(date +"%Y-%m-%d_%Hh%Mm%Ss")
readonly BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"

echo "Backing up to ${BACKUP_PATH}..."

rsync_opts=(-a --delete)
[[ -d "${BACKUP_LATEST_LINK}" ]] && rsync_opts+=(--link-dest="${BACKUP_LATEST_LINK}")

cd "${PZ_SOURCE_DIR}"

# Build list of directories to backup (skip missing ones)
backup_dirs=()
for dir in Saves db Server; do
    [[ -d "$dir" ]] && backup_dirs+=("$dir")
done

if [[ ${#backup_dirs[@]} -eq 0 ]]; then
    echo "Error: No directories to backup in ${PZ_SOURCE_DIR}"
    exit 1
fi

rsync "${rsync_opts[@]}" --relative "${backup_dirs[@]}" "${BACKUP_PATH}"

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
