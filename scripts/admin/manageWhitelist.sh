#!/bin/bash
# ------------------------------------------------------------------------------
# manageWhitelist.sh - Gestion de la whitelist du serveur (B42 par SteamID)
# ------------------------------------------------------------------------------
# Usage: ./manageWhitelist.sh <list|add|remove|resetpassword|purge> [arguments]
#
# Modèle B42 (>= 42.13.2) : le serveur tourne en Open=false et autorise les
# joueurs via une LISTE BLANCHE DE STEAMID (table `allowedsteamid`). Le joueur
# se connecte ensuite avec son pseudo et CHOISIT lui-même son mot de passe
# (hashé en bcrypt par le serveur). On ne touche donc plus au mot de passe en
# base : add/remove pilotent la console du serveur (addsteamid/removesteamid/
# banid) via sendCommand.sh. Le serveur DOIT être démarré pour add/remove.
#
# Commandes:
#   list                          - Afficher la liste blanche SteamID + comptes
#   add <steamID64> [pseudo]      - Autoriser un SteamID (pseudo = info facultatif)
#   remove <steamID64|pseudo> [--ban]  - Retirer un SteamID (--ban = bannir aussi)
#   resetpassword <username>      - Reset le mot de passe d'un joueur
#   purge [delay] [--delete]      - Lister/supprimer les comptes inactifs
#
# Exemples:
#   ./manageWhitelist.sh list
#   ./manageWhitelist.sh add "76561198012345678" "PlayerName"
#   ./manageWhitelist.sh remove "PlayerName"
#   ./manageWhitelist.sh remove "76561198012345678" --ban
#   ./manageWhitelist.sh resetpassword "PlayerName"
#   ./manageWhitelist.sh purge 3m --delete
#
# Note: Utiliser Steam ID 64 (17 chiffres, commence par 7656119...)
#       Trouver sur le profil Steam ou via https://steamid.xyz/
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly DB_PATH="${PZ_SOURCE_DIR}/db/servertest.db"
readonly SEND_COMMAND="${SCRIPT_DIR}/../internal/sendCommand.sh"
readonly ACTION="${1:-}"

check_sqlite() {
    command -v sqlite3 &>/dev/null || die "sqlite3 non installé. Installer avec: sudo apt install sqlite3"
}

check_database() {
    [[ -f "$DB_PATH" ]] || die "Base de données introuvable: $DB_PATH"
}

# add/remove passent par la console : le serveur doit tourner (FIFO présente).
require_server_running() {
    [[ -p "${PZ_CONTROL_PIPE}" ]] || die "Le serveur doit être démarré pour gérer la whitelist SteamID.
Pipe de contrôle absente: ${PZ_CONTROL_PIPE}
Lancer le serveur: pzm server start"
}

run_console() {
    "${SEND_COMMAND}" "$@"
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

detect_schema() {
    local columns
    columns=$(sqlite3 "$DB_PATH" "PRAGMA table_info(whitelist)" 2>/dev/null)

    HAS_CREATED_AT=false
    echo "$columns" | grep -q '|created_at|' && HAS_CREATED_AT=true

    local created_col=""
    if [[ "$HAS_CREATED_AT" == true ]]; then
        created_col="created_at, "
    fi

    WHITELIST_COLUMNS="id, username, ${created_col}lastConnection, steamid, role, displayName"
}

ensure_created_at_column() {
    if [[ "$HAS_CREATED_AT" == false ]]; then
        sqlite3 "$DB_PATH" "ALTER TABLE whitelist ADD COLUMN created_at TEXT DEFAULT NULL" 2>/dev/null || true
        HAS_CREATED_AT=true
        detect_schema
    fi
}

list_whitelist() {
    echo "=== Liste blanche SteamID (autorisations d'accès) ==="
    echo ""
    # `allowedsteamid` est la vraie barrière en Open=false. On joint la table
    # whitelist pour afficher le pseudo/role si le joueur s'est déjà connecté.
    if ! sqlite3 -header -column "$DB_PATH" \
        "SELECT a.steamid AS steamid,
                COALESCE(w.username, '(jamais connecté)') AS username,
                w.role AS role,
                w.lastConnection AS lastConnection
         FROM allowedsteamid a
         LEFT JOIN whitelist w ON w.steamid = a.steamid
         ORDER BY w.lastConnection DESC" 2>/dev/null; then
        echo "(table allowedsteamid illisible)"
    fi
    local allowed_count
    allowed_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM allowedsteamid" 2>/dev/null || echo "0")
    echo ""
    echo "Total: $allowed_count SteamID autorisé(s)"

    echo ""
    echo "=== Comptes enregistrés (table whitelist) ==="
    echo ""
    sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist ORDER BY lastConnection DESC" 2>/dev/null || true
    local count
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist" 2>/dev/null || echo "0")
    echo ""
    echo "Total: $count compte(s)"

    local banned_count
    banned_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM bannedid" 2>/dev/null || echo "0")
    if [[ "$banned_count" -gt 0 ]]; then
        echo ""
        echo "=== SteamID bannis ($banned_count) ==="
        echo ""
        sqlite3 -header -column "$DB_PATH" "SELECT steamid, reason FROM bannedid" 2>/dev/null || true
    fi
}

add_to_whitelist() {
    # Arguments dans n'importe quel ordre : un SteamID64 (requis) + un pseudo
    # (optionnel, purement informatif/loggé).
    local steamid="" label="" a
    for a in "$@"; do
        if [[ "$a" =~ ^7656119[0-9]{10}$ ]]; then
            steamid="$a"
        elif [[ -n "$a" ]]; then
            label="$a"
        fi
    done

    [[ -n "$steamid" ]] || die "Usage: $0 add <steamID64> [pseudo]
Exemple: $0 add \"76561198012345678\" \"PlayerName\"
Le SteamID64 fait 17 chiffres et commence par 7656119 (https://steamid.xyz/)."
    validate_steamid "$steamid"

    require_server_running

    # Déjà autorisé ?
    local already
    already=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM allowedsteamid WHERE steamid = '$steamid'" 2>/dev/null || echo "0")
    if [[ "$already" -ge 1 ]]; then
        echo "ℹ️  SteamID déjà autorisé: $steamid"
        exit 0
    fi

    echo "Autorisation du SteamID sur le serveur..."
    run_console addsteamid "$steamid"

    echo ""
    echo "✓ SteamID autorisé: $steamid${label:+  (joueur: $label)}"
    echo "  Le joueur peut se connecter avec son pseudo et choisir SON mot de passe."
}

remove_from_whitelist() {
    local do_ban=false identifier="" a
    for a in "$@"; do
        if [[ "$a" == "--ban" ]]; then
            do_ban=true
        elif [[ -n "$a" ]]; then
            identifier="$a"
        fi
    done

    [[ -n "$identifier" ]] || die "Usage: $0 remove <steamID64|pseudo> [--ban]
Exemple: $0 remove \"76561198012345678\" --ban"

    require_server_running

    # Résoudre l'identifiant vers un SteamID (et un pseudo si connu).
    local steamid="" username=""
    if [[ "$identifier" =~ ^7656119[0-9]{10}$ ]]; then
        steamid="$identifier"
        username=$(sqlite3 "$DB_PATH" "SELECT username FROM whitelist WHERE steamid = '$steamid' LIMIT 1" 2>/dev/null || true)
    else
        username="$identifier"
        steamid=$(sqlite3 "$DB_PATH" "SELECT steamid FROM whitelist WHERE username = '$username' LIMIT 1" 2>/dev/null || true)
        [[ -n "$steamid" ]] || die "Aucun SteamID connu pour '$username' en base.
Passe directement le SteamID64: $0 remove <steamID64> [--ban]"
    fi
    validate_steamid "$steamid"

    echo "Retrait de l'autorisation du SteamID: $steamid${username:+  (joueur: $username)}"
    run_console removesteamid "$steamid"

    if [[ "$do_ban" == true ]]; then
        echo ""
        echo "Bannissement définitif du SteamID..."
        run_console banid "$steamid"
        echo "✓ SteamID banni: il ne pourra plus revenir, même renommé."
    fi

    echo ""
    echo "✓ SteamID retiré de la liste blanche: $steamid"
    [[ "$do_ban" == false ]] && echo "  (Pour un bannissement définitif, relance avec --ban.)"
}

reset_password() {
    local username="${1:-}"

    [[ -n "$username" ]] || die "Usage: $0 resetpassword <username>"

    # Vérifier si existe
    local existing
    existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username = '$username'" 2>/dev/null || echo "0")

    if [[ "$existing" -eq 0 ]]; then
        die "Aucun utilisateur trouvé: $username"
    fi

    # Afficher l'utilisateur
    echo "Reset mot de passe pour:"
    sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE username = '$username'"
    echo ""

    # Vider le mot de passe : le joueur en choisira un nouveau à la prochaine connexion.
    sqlite3 "$DB_PATH" "UPDATE whitelist SET password = '' WHERE username = '$username';" || \
        die "Échec du reset de mot de passe"
    echo "✓ Mot de passe de '$username' réinitialisé"
    echo "  Le joueur devra choisir un nouveau mot de passe à sa prochaine connexion."
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
    local where_clause
    if [[ "$HAS_CREATED_AT" == true ]]; then
        where_clause="(((lastConnection IS NULL OR lastConnection = '') AND (created_at IS NULL OR created_at < date('now', '-$days days'))) OR (lastConnection < date('now', '-$days days') AND lastConnection <> '')) AND username <> 'admin'"
    else
        where_clause="((lastConnection IS NULL OR lastConnection = '' OR (lastConnection < date('now', '-$days days') AND lastConnection <> '')) AND username <> 'admin')"
    fi
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
            echo "Note: cela supprime le compte, pas l'autorisation SteamID."
            echo "      Pour bloquer le retour, utilise: $0 remove <steamID64> --ban"
        else
            echo "Suppression annulée."
        fi
    fi
}

show_help() {
    cat <<HELPEOF
Gestion de la whitelist du serveur Project Zomboid (B42, par SteamID)

Usage: $0 <commande> [arguments]

Commandes:
  list                              Liste blanche SteamID + comptes + bannis
  add <steamID64> [pseudo]          Autoriser un SteamID (serveur démarré requis)
  remove <steamID64|pseudo> [--ban] Retirer un SteamID (--ban = bannir aussi)
  resetpassword <username>          Reset le mot de passe d'un joueur
  purge [delay] [--delete]          Lister/supprimer les comptes inactifs

Exemples:
  $0 list
  $0 add "76561198012345678" "PlayerName"
  $0 remove "PlayerName"
  $0 remove "76561198012345678" --ban
  $0 resetpassword "PlayerName"
  $0 purge                          # Inactifs depuis ${WHITELIST_PURGE_DAYS}j (défaut)
  $0 purge 3m --delete              # Supprime après confirmation

Notes:
  - Serveur en Open=false : seuls les SteamID autorisés peuvent se connecter.
  - Le joueur choisit lui-même son mot de passe à la première connexion.
  - add/remove pilotent la console du serveur -> le serveur doit être démarré.
  - Steam ID 64 (17 chiffres, ex: 76561198012345678) via https://steamid.xyz/
  - --ban ajoute un bannissement définitif (banid) : retour impossible même renommé.
  - Délai purge: Xm (mois) ou Xj (jours) ; purge exclut toujours 'admin'.
HELPEOF
}

main() {
    check_sqlite

    case "$ACTION" in
        list)
            check_database
            detect_schema
            list_whitelist
            ;;
        add)
            check_database
            add_to_whitelist "${@:2}"
            ;;
        remove)
            check_database
            remove_from_whitelist "${@:2}"
            ;;
        resetpassword)
            check_database
            detect_schema
            reset_password "${*:2}"
            ;;
        purge)
            check_database
            detect_schema
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
