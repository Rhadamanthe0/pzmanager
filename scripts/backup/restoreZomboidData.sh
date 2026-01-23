#!/bin/bash
# ------------------------------------------------------------------------------
# restoreZomboidData.sh - Restauration des données Zomboid uniquement
# ------------------------------------------------------------------------------
# Usage: ./restoreZomboidData.sh <chemin_backup>
#
# Restaure uniquement les données Zomboid (Saves, db, Server).
# Crée backup de sécurité avant écrasement.
# Pour restauration système complète, utiliser configurationInitiale.sh restore.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly BACKUP_PATH="${1:-}"

show_usage() {
    echo "Usage: $0 <chemin_backup>"
    echo ""
    echo "Exemples:"
    echo "  $0 ${BACKUP_DIR}/backup_2026-01-11_14h15m00s"
    echo "  $0 ${BACKUP_DIR}/latest"
    echo ""
    echo "Backups disponibles (10 plus récents):"
    if [[ -d "${BACKUP_DIR}" ]]; then
        ls -1t "${BACKUP_DIR}" | grep -E "^backup_|^latest$" | head -10
    else
        echo "  Aucun backup trouvé dans ${BACKUP_DIR}"
    fi
}

validate_backup_path() {
    [[ -n "$BACKUP_PATH" ]] || { show_usage; exit 1; }
    [[ -d "$BACKUP_PATH" ]] || die "Backup introuvable: $BACKUP_PATH"

    # Vérifier que le backup contient bien des données Zomboid
    if [[ ! -d "$BACKUP_PATH/Saves" ]] && [[ ! -d "$BACKUP_PATH/Server" ]]; then
        die "Le backup ne semble pas contenir de données Zomboid (Saves/ ou Server/ manquant)"
    fi
}

backup_current_zomboid() {
    [[ -d "${PZ_SOURCE_DIR}" ]] || return 0

    local backup_name="${PZ_HOME}/OLD/ZomboidBROKEN_$(date +"%Y-%m-%d_%Hh%Mm%Ss")"

    echo "Création backup de sécurité..."
    mkdir -p "${PZ_HOME}/OLD"
    mv "${PZ_SOURCE_DIR}" "$backup_name"
    echo "✓ Backup sécurité: $backup_name"
}

restore_zomboid_data() {
    echo "Restauration des données Zomboid..."
    mkdir -p "${PZ_SOURCE_DIR}"

    rsync -a --info=progress2 "${BACKUP_PATH}/" "${PZ_SOURCE_DIR}/"

    chown -R "${PZ_USER}:${PZ_USER}" "${PZ_SOURCE_DIR}"

    echo "✓ Restauration terminée: $BACKUP_PATH → ${PZ_SOURCE_DIR}"
}

show_summary() {
    echo ""
    echo "=== Résumé ==="
    echo "Source: $BACKUP_PATH"
    echo "Destination: ${PZ_SOURCE_DIR}"

    if [[ -d "${PZ_SOURCE_DIR}/Saves" ]]; then
        local save_count=$(find "${PZ_SOURCE_DIR}/Saves" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "Sauvegardes restaurées: $save_count monde(s)"
    fi

    echo ""
    echo "Pour appliquer les changements:"
    echo "  pzm server restart 2m"
}

main() {
    validate_backup_path

    echo "=== Restauration données Zomboid ==="
    echo "Backup source: $BACKUP_PATH"
    echo ""

    backup_current_zomboid
    restore_zomboid_data
    show_summary
}

main
