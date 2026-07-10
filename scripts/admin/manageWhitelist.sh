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
    if ! is_steamid64 "$steamid"; then
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

list_whitelist() {
    echo "=== Liste blanche SteamID (autorisations d'accès) ==="
    echo ""
    # `allowedsteamid` est la vraie barrière en Open=false : UNE ligne par SteamID
    # autorisé. Un même SteamID peut porter plusieurs comptes (B42 autorise 2
    # comptes/SteamID) -> on REGROUPE par SteamID (GROUP BY) et on concatène les
    # pseudos, sinon le LEFT JOIN démultiplie les lignes et le nombre affiché ne
    # correspond plus au total d'autorisations.
    if ! sqlite3 -header -column "$DB_PATH" \
        "SELECT a.steamid AS steamid,
                COALESCE(GROUP_CONCAT(w.username, ', '), '(jamais connecté)') AS comptes,
                MAX(w.lastConnection) AS derniere_connexion
         FROM allowedsteamid a
         LEFT JOIN whitelist w ON w.steamid = a.steamid
         GROUP BY a.steamid
         ORDER BY derniere_connexion DESC" 2>/dev/null; then
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
        if is_steamid64 "$a"; then
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
    if is_steamid64 "$identifier"; then
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

    # Comptes inactifs (prédicat partagé avec la purge auto — cf. common.sh).
    local where_clause; where_clause="$(inactive_where_clause "$days" "$HAS_CREATED_AT")"
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

# --- Helpers pour remove-account / rename (écriture DB, serveur arrêté) -------

# Refuse d'écrire si le serveur tourne (la sauvegarde auto écraserait la modif).
require_server_stopped() {
    if server_is_active; then
        die "Le serveur est actif : cette opération écrit dans la base et doit se faire SERVEUR ARRÊTÉ.
Arrête-le d'abord :  pzm server stop 2m --reason \"Nettoyage whitelist\""
    fi
}

# Localise le players.db live (perso multijoueur, table networkPlayers).
locate_players_db() {
    PLAYERS_DB="$(find "${PZ_SOURCE_DIR}/Saves/Multiplayer" -name 'players.db' 2>/dev/null | head -1)"
}

# Snapshot de sécurité des bases avant toute écriture.
snapshot_dbs() {
    local snap_dir="${PZ_SOURCE_DIR}/db/whitelist-snapshots"
    ensure_directory "$snap_dir"
    local ts; ts="$(date +'%Y-%m-%d_%Hh%Mm%S')"
    cp -f "$DB_PATH" "${snap_dir}/servertest_${ts}.db" && log "Snapshot: ${snap_dir}/servertest_${ts}.db"
    if [[ -n "${PLAYERS_DB:-}" && -f "${PLAYERS_DB:-}" ]]; then
        cp -f "$PLAYERS_DB" "${snap_dir}/players_${ts}.db" && log "Snapshot: ${snap_dir}/players_${ts}.db"
    fi
}

# remove-account <pseudo|steamID64>... [--dry-run]
# Supprime des COMPTES précis (par pseudo) ou tous les comptes d'un SteamID.
# Retire l'autorisation `allowedsteamid` uniquement si plus aucun compte restant
# ne partage ce SteamID. Le PERSONNAGE (networkPlayers) est CONSERVÉ.
remove_accounts() {
    local dry_run=false a
    local -a targets=()
    for a in "$@"; do
        case "$a" in
            --dry-run) dry_run=true ;;
            *) [[ -n "$a" ]] && targets+=("$a") ;;
        esac
    done
    [[ "${#targets[@]}" -gt 0 ]] || die "Usage: $0 remove-account <pseudo|steamID64> [...] [--dry-run]"

    detect_schema

    # Construire la liste des id de comptes à supprimer + SteamID orphelins.
    local -a del_ids=() del_sids=() plan=()
    local t
    for t in "${targets[@]}"; do
        if is_steamid64 "$t"; then
            local esc_sid; esc_sid="$(sql_escape "$t")"
            local -a rows=()
            mapfile -t rows < <(sqlite3 -separator '|' "$DB_PATH" "SELECT id, username FROM whitelist WHERE steamid='${esc_sid}'" 2>/dev/null)
            if [[ "${#rows[@]}" -eq 0 ]]; then
                local exists; exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM allowedsteamid WHERE steamid='${esc_sid}'" 2>/dev/null || echo 0)
                if [[ "$exists" -ge 1 ]]; then
                    del_sids+=("$t"); plan+=("SteamID ${t} (aucun compte) -> autorisation retirée")
                else
                    plan+=("SteamID ${t} : introuvable, ignoré")
                fi
            else
                local r rid runame
                for r in "${rows[@]}"; do
                    IFS='|' read -r rid runame <<< "$r"
                    [[ "$runame" == "admin" ]] && { plan+=("compte 'admin' : protégé, ignoré"); continue; }
                    del_ids+=("$rid"); plan+=("compte '${runame}' (id ${rid}, steamid ${t}) -> supprimé")
                done
            fi
        else
            [[ "$t" == "admin" ]] && { plan+=("compte 'admin' : protégé, ignoré"); continue; }
            local esc_u; esc_u="$(sql_escape "$t")"
            local -a rows=()
            mapfile -t rows < <(sqlite3 -separator '|' "$DB_PATH" "SELECT id, COALESCE(steamid,'') FROM whitelist WHERE username='${esc_u}'" 2>/dev/null)
            if [[ "${#rows[@]}" -eq 0 ]]; then
                plan+=("compte '${t}' : introuvable, ignoré"); continue
            fi
            local r rid rsid
            for r in "${rows[@]}"; do
                IFS='|' read -r rid rsid <<< "$r"
                del_ids+=("$rid"); plan+=("compte '${t}' (id ${rid}, steamid ${rsid:-aucun}) -> supprimé")
            done
        fi
    done

    echo "=== remove-account : plan ==="
    local line; for line in "${plan[@]}"; do echo "  - $line"; done
    echo ""

    if [[ "${#del_ids[@]}" -eq 0 && "${#del_sids[@]}" -eq 0 ]]; then
        echo "Rien à supprimer."; return 0
    fi

    if [[ "$dry_run" == true ]]; then
        echo "[dry-run] Aucune modification effectuée."; return 0
    fi

    require_server_stopped
    snapshot_dbs

    # 1) Supprimer les comptes whitelist ciblés
    local id
    for id in "${del_ids[@]}"; do
        sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE id = ${id};" || log "WARNING: échec suppression compte id=$id"
    done

    # 2) Retirer allowedsteamid des SteamID explicitement ciblés (sans compte)
    local sid esc
    for sid in "${del_sids[@]}"; do
        esc="$(sql_escape "$sid")"
        sqlite3 "$DB_PATH" "DELETE FROM allowedsteamid WHERE steamid='${esc}';" || log "WARNING: échec suppression steamid $sid"
    done

    # 3) Retirer allowedsteamid des SteamID qui n'ont plus aucun compte associé
    #    (nettoyage des autorisations devenues orphelines après les suppressions).
    sqlite3 "$DB_PATH" \
        "DELETE FROM allowedsteamid WHERE steamid NOT IN (SELECT steamid FROM whitelist WHERE steamid IS NOT NULL AND steamid <> '');" \
        || log "WARNING: échec nettoyage allowedsteamid orphelins"

    echo ""
    echo "✓ Suppression effectuée. Personnages (networkPlayers) conservés."
    echo "  (Les SteamID encore partagés par un compte gardé restent autorisés.)"
}

# rename <ancien_pseudo> <nouveau_pseudo> [--dry-run]
# Renomme le LOGIN d'un compte dans whitelist ET dans players.db (networkPlayers)
# pour garder le personnage attaché. Le mot de passe est conservé.
rename_account() {
    local dry_run=false a
    local -a pos=()
    for a in "$@"; do
        case "$a" in
            --dry-run) dry_run=true ;;
            *) pos+=("$a") ;;
        esac
    done
    local old="${pos[0]:-}" new="${pos[1]:-}"
    [[ -n "$old" && -n "$new" ]] || die "Usage: $0 rename <ancien_pseudo> <nouveau_pseudo> [--dry-run]"
    [[ "$old" != "admin" ]] || die "Le compte 'admin' ne peut pas être renommé."

    local esc_old esc_new
    esc_old="$(sql_escape "$old")"; esc_new="$(sql_escape "$new")"

    local exists; exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username='${esc_old}'" 2>/dev/null || echo 0)
    [[ "$exists" -ge 1 ]] || die "Aucun compte '${old}' dans la whitelist."
    local clash; clash=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username='${esc_new}'" 2>/dev/null || echo 0)
    [[ "$clash" -eq 0 ]] || die "Un compte '${new}' existe déjà : renommage refusé (collision)."

    locate_players_db
    local char_count=0
    if [[ -n "${PLAYERS_DB:-}" && -f "${PLAYERS_DB:-}" ]]; then
        char_count=$(sqlite3 "$PLAYERS_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${esc_old}'" 2>/dev/null || echo 0)
    fi

    echo "=== rename : '${old}' -> '${new}' ==="
    echo "  whitelist : ${exists} compte(s) à renommer (mot de passe conservé)"
    echo "  players.db: ${char_count} personnage(s) networkPlayers à réattacher"
    echo "  ⚠ Le joueur devra désormais se connecter avec le login '${new}'."
    echo ""

    if [[ "$dry_run" == true ]]; then
        echo "[dry-run] Aucune modification effectuée."; return 0
    fi

    require_server_stopped
    snapshot_dbs

    sqlite3 "$DB_PATH" "UPDATE whitelist SET username='${esc_new}' WHERE username='${esc_old}';" \
        || die "Échec du renommage dans whitelist"
    if [[ "$char_count" -gt 0 ]]; then
        sqlite3 "$PLAYERS_DB" "UPDATE networkPlayers SET username='${esc_new}' WHERE username='${esc_old}';" \
            || die "Échec du renommage dans networkPlayers (players.db)"
    fi

    echo "✓ '${old}' renommé en '${new}' (whitelist + personnage)."
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
        remove-account)
            check_database
            remove_accounts "${@:2}"
            ;;
        rename)
            check_database
            rename_account "${@:2}"
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
