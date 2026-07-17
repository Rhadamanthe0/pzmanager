#!/bin/bash
# ------------------------------------------------------------------------------
# listBackups.sh - Liste les backups disponibles
# ------------------------------------------------------------------------------
# Usage: ./listBackups.sh
#
# Lit BACKUP_DIR / SYNC_BACKUPS_DIR / BACKUP_RETENTION_DAYS depuis .env : les
# chemins et la rétention suivent la config, ils ne sont pas codés en dur.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Liste le contenu d'un répertoire de backups, du plus récent au plus ancien.
list_dir() {
    local dir="$1" pattern="$2" limit="$3"
    local candidates=()

    if [[ -d "$dir" ]]; then
        # nullglob : un motif sans correspondance donne un tableau vide plutôt
        # que le motif littéral. Le glob doit rester non quoté pour s'expanser.
        shopt -s nullglob
        candidates=( "${dir}"/${pattern} )
        shopt -u nullglob
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "Aucun backup trouvé"
        return 0
    fi

    # Tri par date via ls, puis découpe du tableau : un `| head` ferait recevoir
    # un SIGPIPE à ls, que `set -o pipefail` transformerait en échec du script.
    local sorted=()
    mapfile -t sorted < <(ls -1td -- "${candidates[@]}")
    printf '%s\n' "${sorted[@]:0:$limit}"
}

echo "=== Backups incrémentiaux (${BACKUP_RETENTION_DAYS}j rétention) ==="
list_dir "${BACKUP_DIR}" "backup_*" 20

echo ""
echo "=== Backups complets ==="
list_dir "${SYNC_BACKUPS_DIR}" "*" 10
