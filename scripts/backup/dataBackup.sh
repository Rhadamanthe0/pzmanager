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

rsync_status=0
rsync "${rsync_opts[@]}" --relative "${backup_dirs[@]}" "${BACKUP_PATH}" || rsync_status=$?

# On sauvegarde un monde VIVANT : PZ écrit/consolide ses chunks de carte en
# continu, donc un fichier listé par rsync peut disparaître avant d'être copié.
# rsync le signale par le code 24 (fichiers disparus) ou 23 (transfert partiel,
# ex. « open .../map/NN/NNN.bin: No such file or directory »). Ces deux cas sont
# bénins : le snapshot reste un incrément valide et le run horaire suivant
# recopiera le chunk manquant. Seul un autre code est une vraie erreur.
if (( rsync_status == 23 || rsync_status == 24 )); then
    echo "Warning: rsync a ignoré des fichiers disparus pendant la copie (code ${rsync_status}) — normal sur un monde en cours, snapshot conservé."
elif (( rsync_status != 0 )); then
    die "rsync a échoué (code ${rsync_status})."
fi

rm -rf "${BACKUP_LATEST_LINK}"
ln -s "${BACKUP_PATH}" "${BACKUP_LATEST_LINK}"

# Cleanup old backups
cd "${BACKUP_DIR}"

# Un seul parcours : la liste sert à la fois au compte et à la suppression.
old_backups=()
mapfile -t old_backups < <(find . -maxdepth 1 -type d -name "backup_*" -mtime "+${BACKUP_RETENTION_DAYS}")

if (( ${#old_backups[@]} > 0 )); then
    rm -rf -- "${old_backups[@]}"
    echo "Cleaned: ${#old_backups[@]} backup(s) older than ${BACKUP_RETENTION_DAYS} days."
fi

total_count=$(find . -maxdepth 1 -type d -name "backup_*" | wc -l)
echo "Backup completed. Total: $total_count snapshots."
