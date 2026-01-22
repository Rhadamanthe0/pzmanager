#!/bin/bash
# ------------------------------------------------------------------------------
# manageWhitelist.sh - Gestion de la whitelist du serveur
# ------------------------------------------------------------------------------
# Usage: ./manageWhitelist.sh <list|add|remove> [arguments]
#
# Commandes:
#   list                          - Afficher tous les utilisateurs whitelistés
#   add <username> <steamid32>    - Ajouter un utilisateur (Steam ID 32)
#   remove <steamid32>            - Retirer un utilisateur
#
# Exemples:
#   ./manageWhitelist.sh list
#   ./manageWhitelist.sh add "PlayerName" "STEAM_0:1:12345678"
#   ./manageWhitelist.sh remove "STEAM_0:1:12345678"
#
# Note: Utiliser Steam ID 32 (STEAM_0:X:YYYYYYYY)
#       Convertir depuis Steam64 ID: https://steamid.xyz/
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly DB_PATH="${PZ_SOURCE_DIR}/db/servertest.db"
readonly ACTION="${1:-}"

check_sqlite() {
    command -v sqlite3 &>/dev/null || die "sqlite3 non installé. Installer avec: sudo apt install sqlite3"
}

check_database() {
    [[ -f "$DB_PATH" ]] || die "Base de données introuvable: $DB_PATH"
}

list_whitelist() {
    echo "=== Whitelist du serveur ==="
    echo ""

    if ! sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist ORDER BY lastConnection DESC" 2>/dev/null; then
        die "Impossible de lire la whitelist. La table existe-t-elle ?"
    fi

    echo ""
    local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist" 2>/dev/null || echo "0")
    echo "Total: $count utilisateur(s) whitelisté(s)"
}

validate_steamid() {
    local steamid="$1"

    # Steam ID 32 format: STEAM_0:X:YYYYYYYY
    if [[ ! "$steamid" =~ ^STEAM_[0-5]:[0-1]:[0-9]+$ ]]; then
        die "Steam ID invalide: $steamid (doit être un Steam ID 32 format STEAM_0:X:YYYYYYYY)
Convertir depuis Steam64 ID sur: https://steamid.xyz/"
    fi
}

add_to_whitelist() {
    local username="${1:-}"
    local steamid="${2:-}"

    [[ -n "$username" ]] || die "Usage: $0 add <username> <steamid32>
Exemple: $0 add \"PlayerName\" \"STEAM_0:1:12345678\"
Convertir Steam64 → Steam32: https://steamid.xyz/"
    [[ -n "$steamid" ]] || die "Usage: $0 add <username> <steamid32>"

    validate_steamid "$steamid"

    # Vérifier si déjà whitelisté
    local existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE steamid = '$steamid'" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
        echo "⚠️  Utilisateur déjà whitelisté avec Steam ID: $steamid"
        sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist WHERE steamid = '$steamid'"
        exit 0
    fi

    # Ajouter
    sqlite3 "$DB_PATH" "INSERT INTO whitelist (username, steamid) VALUES ('$username', '$steamid');" || \
        die "Échec de l'ajout à la whitelist"

    echo "✓ Utilisateur ajouté à la whitelist:"
    echo "  Nom: $username"
    echo "  Steam ID 32: $steamid"
}

remove_from_whitelist() {
    local steamid="${1:-}"

    [[ -n "$steamid" ]] || die "Usage: $0 remove <steamid>"

    validate_steamid "$steamid"

    # Vérifier si existe
    local existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE steamid = '$steamid'" 2>/dev/null || echo "0")

    if [[ "$existing" -eq 0 ]]; then
        die "Aucun utilisateur trouvé avec Steam ID: $steamid"
    fi

    # Afficher avant suppression
    echo "Utilisateur à retirer:"
    sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist WHERE steamid = '$steamid'"
    echo ""

    # Supprimer
    sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE steamid = '$steamid';" || \
        die "Échec de la suppression de la whitelist"

    echo "✓ Utilisateur retiré de la whitelist"
}

show_help() {
    cat <<HELPEOF
Gestion de la whitelist du serveur Project Zomboid

Usage: $0 <commande> [arguments]

Commandes:
  list                          Afficher tous les utilisateurs whitelistés
  add <username> <steamid32>    Ajouter un utilisateur
  remove <steamid32>            Retirer un utilisateur

Exemples:
  $0 list
  $0 add "PlayerName" "STEAM_0:1:12345678"
  $0 remove "STEAM_0:1:12345678"

Notes:
  - Steam ID requis: Steam ID 32 (format STEAM_0:X:YYYYYYYY)
  - Convertir Steam64 → Steam32: https://steamid.xyz/
HELPEOF
}

main() {
    check_sqlite

    case "$ACTION" in
        list)
            check_database
            list_whitelist
            ;;
        add)
            check_database
            add_to_whitelist "${2:-}" "${3:-}"
            ;;
        remove)
            check_database
            remove_from_whitelist "${2:-}"
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            echo "Commande inconnue: $ACTION"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
