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
source_env

readonly BACKUP_PATH="${1:-}"

show_usage() {
    echo "Usage: pzm backup restore <chemin_backup>"
    echo ""
    echo "Exemples:"
    echo "  pzm backup restore ${BACKUP_DIR}/backup_2026-01-11_14h15m00s"
    echo "  pzm backup restore ${BACKUP_DIR}/latest"
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

    # Garde ajoutée le 2026-08-18 : ce chemin DÉPLACE le monde live (mv) puis
    # rsync par-dessus. Fait serveur allumé, la JVM continue d'écrire dans ses
    # descripteurs déjà ouverts — donc dans l'arbre RENOMMÉ — et sauvegarde son
    # état dedans à l'arrêt : la restauration est écrasée en silence, les deux
    # mondes se mélangent. Les autres écrivains du monde (restore-character,
    # map wipe, remove-account) avaient déjà cette garde, pas celui-ci, qui est
    # pourtant le plus destructeur.
    require_server_stopped "Restauration d'une sauvegarde"

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

    # || true : `pzm backup restore` tourne en utilisateur non privilégié, un
    # seul fichier au propriétaire inattendu faisait échouer chown et, sous
    # `set -e`, interrompait la restauration à mi-parcours — pire que de laisser
    # un fichier mal possédé.
    chown -R "${PZ_USER}:${PZ_USER}" "${PZ_SOURCE_DIR}" 2>/dev/null || \
        echo "  (chown partiel : certains fichiers gardent leur propriétaire d'origine)"

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
