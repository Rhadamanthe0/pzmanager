#!/bin/bash
# ------------------------------------------------------------------------------
# manageWhitelist.sh - Gestion de la whitelist du serveur
# ------------------------------------------------------------------------------
# Usage: ./manageWhitelist.sh <list|add|remove> [arguments]
#
# Commandes:
#   list                        - Afficher tous les utilisateurs whitelistés
#   add <username> <steam64>    - Ajouter un utilisateur (Steam ID 64)
#   remove <steam64>            - Retirer un utilisateur
#
# Exemples:
#   ./manageWhitelist.sh list
#   ./manageWhitelist.sh add "PlayerName" "76561198012345678"
#   ./manageWhitelist.sh remove "76561198012345678"
#
# Note: Utiliser Steam ID 64 (17 chiffres, commence par 7656119...)
#       Trouver sur le profil Steam ou via https://steamid.xyz/
#       Maximum 2 comptes autorisés par Steam ID
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

    # Steam ID 64 format: 17 chiffres commençant par 7656119
    if [[ ! "$steamid" =~ ^7656119[0-9]{10}$ ]]; then
        die "Steam ID invalide: $steamid
Format attendu: Steam ID 64 (17 chiffres, ex: 76561198012345678)
Trouver sur le profil Steam ou via https://steamid.xyz/"
    fi
}

add_to_whitelist() {
    local username="${1:-}"
    local steamid="${2:-}"

    [[ -n "$username" ]] || die "Usage: $0 add <username> <steam64>
Exemple: $0 add \"PlayerName\" \"76561198012345678\""
    [[ -n "$steamid" ]] || die "Usage: $0 add <username> <steam64>"

    validate_steamid "$steamid"

    # Vérifier limite de 2 comptes par steamid
    local existing_steamid=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE steamid = '$steamid'" 2>/dev/null || echo "0")
    if [[ "$existing_steamid" -ge 2 ]]; then
        echo "⚠️  Steam ID a déjà 2 comptes (limite atteinte): $steamid"
        sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist WHERE steamid = '$steamid'"
        exit 1
    elif [[ "$existing_steamid" -eq 1 ]]; then
        echo "ℹ️  Steam ID a déjà 1 compte, ajout du 2ème:"
        sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist WHERE steamid = '$steamid'"
        echo ""
    fi

    # Vérifier doublon sur username
    local existing_username=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username = '$username'" 2>/dev/null || echo "0")
    if [[ "$existing_username" -gt 0 ]]; then
        echo "⚠️  Username déjà whitelisté: $username"
        sqlite3 -header -column "$DB_PATH" "SELECT * FROM whitelist WHERE username = '$username'"
        exit 1
    fi

    # Ajouter
    sqlite3 "$DB_PATH" "INSERT INTO whitelist (username, steamid) VALUES ('$username', '$steamid');" || \
        die "Échec de l'ajout à la whitelist"

    echo "✓ Utilisateur ajouté à la whitelist:"
    echo "  Nom: $username"
    echo "  Steam ID 64: $steamid"
}

remove_from_whitelist() {
    local steamid="${1:-}"

    [[ -n "$steamid" ]] || die "Usage: $0 remove <steam64>"

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
  list                        Afficher tous les utilisateurs whitelistés
  add <username> <steam64>    Ajouter un utilisateur
  remove <steam64>            Retirer un utilisateur

Exemples:
  $0 list
  $0 add "PlayerName" "76561198012345678"
  $0 remove "76561198012345678"

Notes:
  - Steam ID requis: Steam ID 64 (17 chiffres, ex: 76561198012345678)
  - Trouver sur le profil Steam ou via https://steamid.xyz/
  - Maximum 2 comptes autorisés par Steam ID
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
