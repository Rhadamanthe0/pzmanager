#!/bin/bash
# ------------------------------------------------------------------------------
# manageWhitelist.sh - Gestion de la whitelist du serveur
# ------------------------------------------------------------------------------
# Usage: ./manageWhitelist.sh <list|add|remove> [arguments]
#
# Commandes:
#   list                        - Afficher tous les utilisateurs whitelistés
#   add <username> <steam64>    - Ajouter un utilisateur (Steam ID 64)
#   remove <username>           - Retirer un utilisateur par son nom
#   purge [delay] [--delete]    - Lister/supprimer les comptes inactifs
#
# Exemples:
#   ./manageWhitelist.sh list
#   ./manageWhitelist.sh add "PlayerName" "76561198012345678"
#   ./manageWhitelist.sh remove "PlayerName"
#   ./manageWhitelist.sh purge              # Inactifs depuis WHITELIST_PURGE_DAYS
#   ./manageWhitelist.sh purge 3m           # Inactifs depuis 3 mois
#   ./manageWhitelist.sh purge 3m --delete  # Supprime après confirmation
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

ensure_created_at_column() {
    # Ajouter la colonne created_at si elle n'existe pas
    local has_column=$(sqlite3 "$DB_PATH" "PRAGMA table_info(whitelist)" 2>/dev/null | grep -c "created_at" || echo "0")
    if [[ "$has_column" -eq 0 ]]; then
        sqlite3 "$DB_PATH" "ALTER TABLE whitelist ADD COLUMN created_at TEXT DEFAULT NULL" 2>/dev/null || true
    fi
}

readonly WHITELIST_COLUMNS="id, username, created_at, lastConnection, steamid, accesslevel, displayName"

list_whitelist() {
    echo "=== Whitelist du serveur ==="
    echo ""

    if ! sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist ORDER BY lastConnection DESC" 2>/dev/null; then
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
        sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE steamid = '$steamid'"
        exit 1
    elif [[ "$existing_steamid" -eq 1 ]]; then
        echo "ℹ️  Steam ID a déjà 1 compte, ajout du 2ème:"
        sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE steamid = '$steamid'"
        echo ""
    fi

    # Vérifier doublon sur username
    local existing_username=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username = '$username'" 2>/dev/null || echo "0")
    if [[ "$existing_username" -gt 0 ]]; then
        echo "⚠️  Username déjà whitelisté: $username"
        sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE username = '$username'"
        exit 1
    fi

    # Ajouter avec date de création
    sqlite3 "$DB_PATH" "INSERT INTO whitelist (username, steamid, created_at) VALUES ('$username', '$steamid', datetime('now'));" || \
        die "Échec de l'ajout à la whitelist"

    echo "✓ Utilisateur ajouté à la whitelist:"
    echo "  Nom: $username"
    echo "  Steam ID 64: $steamid"
    echo "  Créé le: $(date '+%Y-%m-%d %H:%M:%S')"
}

remove_from_whitelist() {
    local username="${1:-}"

    [[ -n "$username" ]] || die "Usage: $0 remove <username>"

    # Vérifier si existe
    local existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username = '$username'" 2>/dev/null || echo "0")

    if [[ "$existing" -eq 0 ]]; then
        die "Aucun utilisateur trouvé: $username"
    fi

    # Afficher avant suppression
    echo "Utilisateur à retirer:"
    sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE username = '$username'"
    echo ""

    # Supprimer
    sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE username = '$username';" || \
        die "Échec de la suppression de la whitelist"
    echo "✓ Utilisateur '$username' retiré de la whitelist"
}

purge_whitelist() {
    local delay="${1:-}"
    local do_delete="${2:-}"

    # Utiliser le délai par défaut si non spécifié
    if [[ -z "$delay" ]]; then
        delay="${WHITELIST_PURGE_DAYS}d"
    fi

    # Parser le format (ex: 3m pour 3 mois, 60d pour 60 jours)
    local num="${delay%[mMjJdD]}"
    local unit="${delay: -1}"

    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        die "Format invalide: $delay (utiliser ex: 3m pour 3 mois, 30j pour 30 jours)"
    fi

    local days unit_label
    case "$unit" in
        m|M) days=$((num * 30)); unit_label="mois" ;;
        j|J|d|D) days=$num; unit_label="jour(s)" ;;
        *) die "Unité inconnue: $unit (utiliser m=mois, j/d=jours)" ;;
    esac

    # Comptes inactifs: jamais connectés (créés il y a +X jours) OU dernière connexion > X jours
    # Exclut toujours l'utilisateur 'admin'
    local where_clause="(((lastConnection IS NULL OR lastConnection = '') AND (created_at IS NULL OR created_at < date('now', '-$days days'))) OR (lastConnection < date('now', '-$days days') AND lastConnection != '')) AND username != 'admin'"
    local description="Comptes inactifs depuis $num $unit_label"

    # Lister les comptes concernés
    echo "=== $description ==="
    echo ""

    local results=$(sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE $where_clause ORDER BY lastConnection" 2>/dev/null)

    if [[ -z "$results" ]]; then
        echo "Aucun compte trouvé."
        return 0
    fi

    echo "$results"
    echo ""

    local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE $where_clause" 2>/dev/null || echo "0")
    echo "Total: $count compte(s)"

    # Suppression si demandée
    if [[ "$do_delete" == "--delete" ]]; then
        echo ""
        read -p "Supprimer ces $count compte(s) ? [oui/NON]: " confirm
        if [[ "$confirm" == "oui" ]]; then
            sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE $where_clause;" || \
                die "Échec de la suppression"
            echo "✓ $count compte(s) supprimé(s)"
        else
            echo "Suppression annulée."
        fi
    fi
}

show_help() {
    cat <<HELPEOF
Gestion de la whitelist du serveur Project Zomboid

Usage: $0 <commande> [arguments]

Commandes:
  list                        Afficher tous les utilisateurs whitelistés
  add <username> <steam64>    Ajouter un utilisateur
  remove <username>           Retirer un utilisateur par son nom
  purge [delay] [--delete]    Lister/supprimer les comptes inactifs

Exemples:
  $0 list
  $0 add "PlayerName" "76561198012345678"
  $0 remove "PlayerName"
  $0 purge                    # Inactifs depuis ${WHITELIST_PURGE_DAYS}j (défaut)
  $0 purge 3m                 # Inactifs depuis 3 mois
  $0 purge 3m --delete        # Supprime après confirmation

Notes:
  - Steam ID requis: Steam ID 64 (17 chiffres, ex: 76561198012345678)
  - Trouver sur le profil Steam ou via https://steamid.xyz/
  - Maximum 2 comptes autorisés par Steam ID
  - Chaque username doit être unique
  - Délai purge par défaut: WHITELIST_PURGE_DAYS dans .env
  - Délai purge: Xm (mois) ou Xj (jours)
  - Purge exclut toujours l'utilisateur 'admin'
HELPEOF
}

main() {
    check_sqlite

    case "$ACTION" in
        list)
            check_database
            ensure_created_at_column
            list_whitelist
            ;;
        add)
            check_database
            ensure_created_at_column
            add_to_whitelist "${2:-}" "${3:-}"
            ;;
        remove)
            check_database
            remove_from_whitelist "${*:2}"
            ;;
        purge)
            check_database
            ensure_created_at_column
            purge_whitelist "${2:-}" "${3:-}"
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
