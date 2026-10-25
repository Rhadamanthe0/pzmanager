#!/bin/bash
# ------------------------------------------------------------------------------
# manageWhitelist.sh - Gestion de la whitelist du serveur (B42 par SteamID)
# ------------------------------------------------------------------------------
# Usage: pzm whitelist <list|add|remove|remove-account|rename-account|resetpassword|purge> [arguments]
#
# Modèle B42 (>= 42.13.2) : le serveur tourne en Open=false et autorise les
# joueurs via une LISTE BLANCHE DE STEAMID (table `allowedsteamid`). Le joueur
# se connecte ensuite avec son pseudo et CHOISIT lui-même son mot de passe
# (hashé en bcrypt par le serveur). add/remove pilotent la console
# du serveur (addsteamid/removesteamid/banid) via sendCommand.sh.
# Le serveur DOIT être démarré pour add/remove.
#
# Deux niveaux distincts, à ne pas confondre — d'où le suffixe -account :
#   - remove          agit sur le STEAMID : retire l'autorisation, donc TOUS les
#                     comptes qui la partagent (B42 en autorise 2 par SteamID).
#                     N'accepte QUE le SteamID64, jamais un pseudo : « remove
#                     <pseudo> » se lirait « retirer ce joueur » et éjecterait
#                     silencieusement l'autre compte du même SteamID.
#   - remove-account  agit sur le COMPTE : en supprime un ; le SteamID reste
#                     autorisé tant qu'un autre compte le porte.
#   - rename-account  agit sur le COMPTE : ne supprime rien.
# Aucune ne supprime un PERSONNAGE (players.db/networkPlayers) : seul
# `rename-account` y touche, pour réattacher le perso au nouveau login.
#
# Commandes:
#   list                          - Afficher la liste blanche SteamID + comptes
#   add <steamID64> [pseudo]      - Autoriser un SteamID (pseudo = info facultatif)
#   remove <steamID64> [--ban]    - Retirer un SteamID (--ban = bannir aussi)
#   remove-account <pseudo|steamID64>... [--dry-run] - Supprimer des comptes
#   rename-account <ancien> <nouveau> [--dry-run] - Renommer un compte
#   resetpassword <username>      - Reset le mot de passe d'un joueur
#   purge [delay] [--delete]      - Lister/supprimer les comptes inactifs
#
# add/remove passent par la console -> SERVEUR DÉMARRÉ.
# remove-account/rename-account/resetpassword/purge --delete écrivent en base
# -> SERVEUR ARRÊTÉ (refus explicite sinon). Pas de snapshot dédié : le serveur est déjà
# arrêté (donc le backup fait à l'arrêt couvre l'état) et les backups horaires
# GFS (pzm backup list) sont là -> restauration via pzm backup restore.
#
# Exemples:
#   pzm whitelist list
#   pzm whitelist add "76561198012345678" "PlayerName"
#   pzm whitelist remove "76561198012345678" --ban
#   pzm whitelist remove-account "PlayerName"
#   pzm whitelist resetpassword "PlayerName"
#   pzm whitelist purge 3m --delete
#
# Note: Utiliser Steam ID 64 (17 chiffres, commence par 7656119...)
#       Trouver sur le profil Steam ou via https://steamid.xyz/
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Nom affiché dans les usages : $0 vaut le chemin absolu (`pzm` fait un exec
# dessus), donc des commandes suggérées impossibles à recopier.
readonly CMD="pzm whitelist"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly DB_PATH="${PZ_DB_PATH}"
readonly SEND_COMMAND="${SCRIPT_DIR}/../internal/sendCommand.sh"
readonly ACTION="${1:-}"

check_database() {
    python3 "${SCRIPT_DIR}/../lib/account_safety.py" validate-db --db "$DB_PATH" || exit 1
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

# Transport success only proves an exchange. Require the native command result
# AND the effective SQLite postcondition before claiming an access change.
run_console_confirmed() {
    local command="$1" steamid="$2" table="$3" expected="$4" pattern="$5"
    local output observed attempt
    output="$(run_console "$command" "$steamid")" || die "Résultat indéterminé : commande console en échec."
    printf '%s\n' "$output"
    grep -qE "$pattern" <<< "$output" \
        || die "Résultat indéterminé : aucune confirmation métier de ${command} pour ${steamid}."
    for attempt in {1..20}; do
        observed="$(sqlite3 -readonly "$DB_PATH" "SELECT EXISTS(SELECT 1 FROM ${table} WHERE steamid='${steamid}');" 2>/dev/null)" || observed=""
        [[ "$observed" != "$expected" ]] || return 0
        sleep 0.1
    done
    die "Résultat indéterminé : état SQLite attendu non confirmé pour ${steamid} ; vérifier la liste avant de réessayer."
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

# Colonnes affichées pour un compte. La table whitelist de B42 n'a PAS de
# created_at (schéma vérifié en production le 19/08/2026) : l'ancienneté vit
# désormais dans le registre CSV, hors base — cf. common.sh. L'ancienne détection
# conditionnelle d'une colonne created_at portait donc sur une colonne qui
# n'existe nulle part — d'où une CONSTANTE et non plus une fonction `detect_schema`
# qu'il fallait penser à appeler dans chaque branche (et qui manquait dans deux).
readonly WHITELIST_COLUMNS="id, username, lastConnection, steamid, role, displayName"

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

    [[ -n "$steamid" ]] || die "Usage: ${CMD} add <steamID64> [pseudo]
Exemple: ${CMD} add \"76561198012345678\" \"PlayerName\"
Le SteamID64 fait 17 chiffres et commence par 7656119 (https://steamid.xyz/)."
    validate_steamid "$steamid"

    require_server_running

    # Déjà autorisé ?
    local already
    wl_sql_or_die already "$DB_PATH" "SELECT COUNT(*) FROM allowedsteamid WHERE steamid = '$steamid'"
    if [[ "$already" -ge 1 ]]; then
        echo "ℹ️  SteamID déjà autorisé: $steamid"
        exit 0
    fi

    echo "Autorisation du SteamID sur le serveur..."
    run_console_confirmed addsteamid "$steamid" allowedsteamid 1 "^SteamID ${steamid} added to allowed SteamIDs$"

    echo ""
    echo "✓ SteamID autorisé: $steamid${label:+  (joueur: $label)}"
    echo "  Le joueur peut se connecter avec son pseudo et choisir SON mot de passe."
}

# Un pseudo a été passé à `remove`. On refuse, mais on résout le pseudo pour
# donner les deux commandes exactes : c'est précisément là qu'on se trompe.
reject_name_for_remove() {
    local name="$1" esc sid shared
    esc="$(sql_escape "$name")"
    sid=$(sqlite3 "$DB_PATH" "SELECT steamid FROM whitelist WHERE username = '${esc}' LIMIT 1" 2>/dev/null || true)

    if [[ -z "$sid" ]]; then
        die "'${name}' n'est pas un SteamID64, et aucun compte de ce nom n'existe.
  remove attend un SteamID64 (17 chiffres) : ${CMD} remove <steamID64> [--ban]
  Pour supprimer un COMPTE par son pseudo :  ${CMD} remove-account <pseudo>"
    fi

    shared=$(sqlite3 "$DB_PATH" "SELECT GROUP_CONCAT(username, ', ') FROM whitelist WHERE steamid = '$(sql_escape "$sid")'" 2>/dev/null || echo "$name")

    die "remove attend un SteamID64, pas un pseudo — les deux ne font pas la même chose.

  '${name}' utilise le SteamID ${sid}, porté par : ${shared}

  Retirer l'ACCÈS de ce SteamID (donc TOUS les comptes ci-dessus, serveur démarré) :
      ${CMD} remove ${sid}
  Supprimer le seul compte '${name}' (garde les autres et le perso, serveur arrêté) :
      ${CMD} remove-account \"${name}\""
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

    [[ -n "$identifier" ]] || die "Usage: ${CMD} remove <steamID64> [--ban]
Exemple: ${CMD} remove \"76561198012345678\" --ban"

    # remove n'accepte QUE le SteamID64. Accepter un pseudo ici brouillait la
    # frontière avec remove-account : « remove <pseudo> » ressemble à « retirer
    # ce joueur » alors que ça retire le SteamID, donc TOUS les comptes qui le
    # partagent (B42 en autorise 2). On refuse, en montrant les deux options.
    if ! is_steamid64 "$identifier"; then
        reject_name_for_remove "$identifier"
    fi
    local steamid="$identifier" username="" banned=0
    validate_steamid "$steamid"

    require_server_running

    if [[ "$do_ban" == true ]]; then
        wl_sql_or_die banned "$DB_PATH" "SELECT COUNT(*) FROM bannedid WHERE steamid='${steamid}'"
    fi

    username=$(sqlite3 "$DB_PATH" "SELECT GROUP_CONCAT(username, ', ') FROM whitelist WHERE steamid = '$(sql_escape "$steamid")'" 2>/dev/null || true)

    echo "Retrait de l'autorisation du SteamID: $steamid${username:+  (comptes: $username)}"
    local allowed
    wl_sql_or_die allowed "$DB_PATH" "SELECT COUNT(*) FROM allowedsteamid WHERE steamid='${steamid}'"
    if [[ "$allowed" == 0 ]]; then
        echo "SteamID déjà retiré de la liste blanche: $steamid"
    else
        run_console_confirmed removesteamid "$steamid" allowedsteamid 0 "^SteamID ${steamid} removed from allowed SteamIDs$"
    fi

    if [[ "$do_ban" == true ]]; then
        echo ""
        echo "Bannissement définitif du SteamID..."
        if [[ "$banned" == 0 ]]; then
            run_console_confirmed banid "$steamid" bannedid 1 "^System banned SteamID ${steamid}\([^)]*\).*$"
        else
            echo "SteamID déjà banni: $steamid"
        fi
        echo "✓ SteamID banni: il ne pourra plus revenir, même renommé."
    fi

    echo ""
    echo "✓ SteamID retiré de la liste blanche: $steamid"
    # `if` et non `[[ ... ]] && echo` : en tant que DERNIÈRE commande de la fonction,
    # le test faux (cas --ban) renvoyait 1, ce qui sous `set -e` faisait sortir tout
    # le script en erreur alors que le bannissement avait réussi — le bot Discord
    # affichait « ❌ ... (exit=1) » sur une commande qui avait fonctionné.
    if [[ "$do_ban" == false ]]; then
        echo "  (Pour un bannissement définitif, relance avec --ban.)"
    fi
}

reset_password() {
    local username="${1:-}"

    [[ -n "$username" ]] || die "Usage: ${CMD} resetpassword <username>"

    # Écriture directe dans <world>.db : même section critique que
    # remove-account/rename-account (WORLD -> SERVERCTL, cf. wl_acquire ci-dessous),
    # tenue du plan jusqu'à l'UPDATE : un `pzm server start` concurrent est exclu.
    # L'en-tête du fichier prétendait que ce chemin « passe par la console » —
    # c'est faux, il fait un UPDATE sur la base live.
    wl_acquire_write_locks_or_die

    # Échappement obligatoire : le pseudo vient de l'utilisateur (et du champ libre
    # `nom` du bot Discord). Interpolé brut, « O'Brien » cassait la requête et
    # « x' OR '1'='1 » vidait le mot de passe de TOUS les comptes.
    local esc_u; esc_u="$(sql_escape "$username")"

    # Vérifier si existe (fail-closed : erreur SQLite = mort, pas 0).
    local existing
    wl_sql_or_die existing "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username = '${esc_u}'"
    [[ "$existing" =~ ^[0-9]+$ ]] || die "Lecture SQLite inattendue — reset annulé, rien n'a été modifié (fail-closed)."

    if [[ "$existing" -eq 0 ]]; then
        die "Aucun utilisateur trouvé: $username"
    fi

    # Afficher l'utilisateur
    echo "Reset mot de passe pour:"
    sqlite3 -header -column "$DB_PATH" "SELECT $WHITELIST_COLUMNS FROM whitelist WHERE username = '${esc_u}'"
    echo ""

    # Arrêt PROUVÉ juste avant écriture (TOCTOU) : inactive seule,
    # failed/activating/error -> refus fail-closed (cf. remove/rename).
    wl_assert_stopped_or_die "Reset mot de passe"

    # Vider le mot de passe : le joueur en choisira un nouveau à la prochaine connexion.
    sqlite3 "$DB_PATH" "UPDATE whitelist SET password = '' WHERE username = '${esc_u}';" || \
        die "Échec du reset de mot de passe"
    echo "✓ Mot de passe de '$username' réinitialisé"
    echo "  Le joueur devra choisir un nouveau mot de passe à sa prochaine connexion."
}

purge_whitelist() {
    # Parsé par forme, pas par position : le délai étant facultatif,
    # « purge --delete » atterrissait dans $delay -> « Format invalide ».
    local delay="" do_delete="" a
    for a in "$@"; do
        case "$a" in
            --delete) do_delete="--delete" ;;
            "") ;;
            *) delay="$a" ;;
        esac
    done

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

    # C5 : --delete écrit en base : mêmes verrous que remove-account, pris
    # AVANT le plan (registre + SELECT) et tenus jusqu'au DELETE : un
    # `pzm server start` concurrent est exclu pendant toute la section critique.
    # Lecture seule (sans --delete) : aucun verrou.
    if [[ "$do_delete" == "--delete" ]]; then
        wl_acquire_write_locks_or_die
    fi

    # Comptes inactifs (prédicat partagé avec la purge auto — cf. common.sh).
    # Registre à jour avant de lister, pour que la purge interactive montre
    # exactement ce que la purge automatique retirerait.
    "${SCRIPT_DIR}/creationDateInit.sh" >/dev/null 2>&1 || true
    local where_clause; where_clause="$(inactive_where_clause "$days")"
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
        # La liste ci-dessus EST l'aperçu : arrêt PROUVÉ (inactive seule ;
        # failed/activating/error -> refus fail-closed), pas server_is_active
        # qui vaut faux sur erreur bus. Re-vérifié après confirmation : le
        # `read` laisse le temps à un démarrage de s'intercaler (TOCTOU).
        wl_assert_stopped_or_die "Purge whitelist"

        echo ""
        read -p "Supprimer ces $count compte(s) ? [oui/NON]: " confirm
        if [[ "$confirm" == "oui" ]]; then
            wl_assert_stopped_or_die "Purge whitelist"
            sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE $where_clause;" || \
                die "Échec de la suppression"
            echo "✓ $count compte(s) supprimé(s)"
            echo "Note: cela supprime le compte, pas l'autorisation SteamID."
            echo "      Pour bloquer le retour, utilise: ${CMD} remove <steamID64> --ban"
        else
            echo "Suppression annulée."
        fi
    fi
}

# --- Helpers pour remove-account / rename-account (écriture DB, serveur arrêté) --
# La garde « serveur arrêté » vit maintenant dans common.sh (require_server_stopped) :
# elle était recopiée dans quatre scripts avec quatre messages différents, et
# manquait justement là où on écrivait dans le monde (backup restore, resetpassword).

# Les mutations multi-bases utilisent account_safety.py : une connexion SQLite,
# ATTACH paramétré et un COMMIT commun avec journaux rollback durables.
wl_acquire_write_locks_or_die() {
    # Ordre global WORLD -> SERVERCTL (cf. lib/world_lock.sh) : jamais l'inverse.
    if declare -F acquire_world_lock >/dev/null 2>&1; then
        acquire_world_lock --required || die "Une opération monde est déjà en cours. Attends qu'elle se termine."
    fi
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" check --world "$PZ_SOURCE_DIR" || exit 1
    acquire_serverctl_lock_or_die "$@"
}
wl_assert_stopped_or_die() {
    if declare -F assert_server_stopped_proven >/dev/null 2>&1; then
        assert_server_stopped_proven "$1"
    else
        require_server_stopped "$1"
    fi
}
# Lecture fail-closed : toute erreur SQLite MEURT au lieu de se lire comme 0
# ou vide (l'ancien `2>/dev/null || echo 0` transformait une base verrouillée
# ou un schéma absent en décision). Usage: wl_sql_or_die VAR DB "SELECT ..."
wl_sql_or_die() {
    local __var="$1" __db="$2" __sql="$3" __out __rc=0
    python3 "${SCRIPT_DIR}/../lib/account_safety.py" validate-db --db "$__db" || exit 1
    __out="$(sqlite3 "$__db" "$__sql")" || __rc=$?
    if (( __rc != 0 )); then
        die "Lecture SQLite impossible (sqlite exit=${__rc}) — opération annulée, rien n'a été modifié (fail-closed)."
    fi
    printf -v "$__var" '%s' "$__out"
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
    [[ "${#targets[@]}" -gt 0 ]] || die "Usage: ${CMD} remove-account <pseudo|steamID64> [...] [--dry-run]"

    # Conservé jusqu'à la fin du process : un `pzm server start` concurrent ne
    # peut pas rendre obsolète le contrôle d'état pendant la construction du plan.
    # C5 : verrou monde (si dispo) AVANT serverctl, ordre WORLD -> SERVERCTL.
    [[ "$dry_run" == true ]] || wl_acquire_write_locks_or_die

    # Serveur actif sans --dry-run : on bascule en aperçu au lieu de refuser
    # sèchement. L'utilisateur voit ce que la commande aurait fait, et le refus
    # est donné à la fin — sinon il fallait couper le serveur pour le savoir.
    local refused=false
    if [[ "$dry_run" != true ]] && server_is_active; then
        dry_run=true; refused=true
    fi

    [[ "$dry_run" == true ]] || wl_assert_stopped_or_die "Nettoyage whitelist"
    local -a options=()
    [[ "$dry_run" != true ]] || options+=(--dry-run)
    python3 "${SCRIPT_DIR}/../lib/account_safety.py" remove --db "$DB_PATH" "${options[@]}" -- "${targets[@]}" \
        || die "Suppression annulée : transaction ROLLBACK, aucune modification partielle."
    [[ "$refused" == false ]] || die_server_active "Nettoyage whitelist"

}

# rename-account <ancien_pseudo> <nouveau_pseudo> [--dry-run]
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
    [[ -n "$old" && -n "$new" ]] || die "Usage: ${CMD} rename-account <ancien_pseudo> <nouveau_pseudo> [--dry-run]"
    [[ "$old" != "admin" ]] || die "Le compte 'admin' ne peut pas être renommé."

    # Même verrou que `pzm server start`, tenu pendant le plan et les deux UPDATE.
    # C5 : verrou monde (si dispo) AVANT serverctl, ordre WORLD -> SERVERCTL.
    [[ "$dry_run" == true ]] || wl_acquire_write_locks_or_die

    # Bascule en aperçu plutôt qu'un refus nu (cf. remove-account).
    local refused=false
    if [[ "$dry_run" != true ]] && server_is_active; then
        dry_run=true; refused=true
    fi

    local esc_old esc_new
    esc_old="$(sql_escape "$old")"; esc_new="$(sql_escape "$new")"

    # C5 : prévalidation TOTALE avant toute écriture (fail-closed : toute
    # lecture en erreur MEURT au lieu de se lire comme 0). Schéma OK = tables
    # et colonne username lisibles dans les deux bases.
    local exists clash _schema
    wl_sql_or_die _schema "$DB_PATH" "SELECT username FROM whitelist LIMIT 0;"
    wl_sql_or_die exists "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username='${esc_old}'"
    [[ "$exists" =~ ^[0-9]+$ ]] || die "Lecture SQLite inattendue — renommage annulé, rien n'a été modifié (fail-closed)."
    [[ "$exists" -ge 1 ]] || die "Aucun compte '${old}' dans la whitelist."
    wl_sql_or_die clash "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username='${esc_new}'"
    [[ "$clash" =~ ^[0-9]+$ ]] || die "Lecture SQLite inattendue — renommage annulé, rien n'a été modifié (fail-closed)."
    [[ "$clash" -eq 0 ]] || die "Un compte '${new}' existe déjà : renommage refusé (collision)."

    local PLAYERS_DB="" char_count=0 new_in_players=0 _pschema=""
    PLAYERS_DB="$(python3 "${SCRIPT_DIR}/../lib/account_safety.py" select-players \
        --world "${PZ_SOURCE_DIR}" --server "${PZ_SERVER_NAME}")" \
        || die "Sélection du monde ambiguë ou illisible — renommage annulé avant mutation."
    if [[ -n "$PLAYERS_DB" && -f "$PLAYERS_DB" ]]; then
        wl_sql_or_die _pschema "$PLAYERS_DB" "SELECT username FROM networkPlayers LIMIT 0;"
        wl_sql_or_die char_count "$PLAYERS_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${esc_old}'"
        [[ "$char_count" =~ ^[0-9]+$ ]] || die "Lecture SQLite inattendue — renommage annulé, rien n'a été modifié (fail-closed)."
        wl_sql_or_die new_in_players "$PLAYERS_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${esc_new}'"
        [[ "$new_in_players" =~ ^[0-9]+$ ]] || die "Lecture SQLite inattendue — renommage annulé, rien n'a été modifié (fail-closed)."
        [[ "$new_in_players" -eq 0 ]] || die "Un personnage '${new}' existe déjà dans players.db : renommage refusé (collision)."
    fi
    unset _schema _pschema

    echo "=== rename-account : plan ('${old}' -> '${new}') ==="
    echo "  whitelist : ${exists} compte(s) seraient renommés (mot de passe conservé)"
    echo "  players.db: ${char_count} personnage(s) networkPlayers seraient réattachés"
    echo "  ⚠ Le joueur devra désormais se connecter avec le login '${new}'."
    echo ""

    if [[ "$dry_run" == true ]]; then
        [[ "$refused" == false ]] || die_server_active "Renommage de compte"
        echo "[dry-run] Rien n'a été modifié."; return 0
    fi

    # Défense supplémentaire contre un démarrage extérieur à `pzm`.
    # C5 : arrêt PROUVÉ (assert) quand dispo, sinon garde historique.
    wl_assert_stopped_or_die "Renommage de compte"

    # C5 : re-vérification juste avant écriture (TOCTOU) : le nouveau login
    # n'est apparu ni en whitelist ni en players.db entre le plan et ici.
    local _reclash _replayers=0
    wl_sql_or_die _reclash "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE username='${esc_new}'"
    [[ "$_reclash" -eq 0 ]] || die "Collision apparue avant écriture ('${new}' existe désormais) : renommage annulé, rien n'a été modifié (fail-closed)."
    if [[ -n "$PLAYERS_DB" && -f "$PLAYERS_DB" ]]; then
        wl_sql_or_die _replayers "$PLAYERS_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${esc_new}'"
        [[ "$_replayers" -eq 0 ]] || die "Collision apparue avant écriture (personnage '${new}' existe désormais) : renommage annulé, rien n'a été modifié (fail-closed)."
    fi
    unset _reclash _replayers

    local -a options=()
    [[ -z "$PLAYERS_DB" ]] || options+=(--players "$PLAYERS_DB")
    python3 "${SCRIPT_DIR}/../lib/account_safety.py" rename --db "$DB_PATH" "${options[@]}" -- "$old" "$new" \
        || die "Renommage annulé : transaction commune ROLLBACK, aucune modification partielle."

    echo "✓ '${old}' renommé en '${new}' (whitelist + personnage)."
}

show_help() {
    cat <<HELPEOF
Gestion de la whitelist du serveur Project Zomboid (B42, par SteamID)

Usage: ${CMD} <commande> [arguments]

Commandes agissant sur le STEAMID (l'autorisation d'accès) :
  list                              Liste blanche SteamID + comptes + bannis
  add <steamID64> [pseudo]          Autoriser un SteamID (serveur démarré requis)
  remove <steamID64> [--ban]        Retirer l'accès d'un SteamID, donc TOUS les
                                    comptes qui le partagent (serveur démarré ;
                                    --ban = bannir aussi). SteamID64 uniquement.

Commandes agissant sur un COMPTE (le pseudo de connexion) :
  remove-account <pseudo|steamID64> [...] [--dry-run]
                                    Supprimer des comptes (serveur arrêté requis)
  rename-account <ancien> <nouveau> [--dry-run]
                                    Renommer un compte (serveur arrêté requis)
  resetpassword <username>          Reset le mot de passe (serveur arrêté)
  purge [delay] [--delete]          Lister/supprimer les comptes inactifs

Exemples:
  ${CMD} list
  ${CMD} add "76561198012345678" "PlayerName"
  ${CMD} remove "76561198012345678" --ban
  ${CMD} remove-account "PlayerName" --dry-run
  ${CMD} rename-account "AncienPseudo" "NouveauPseudo"
  ${CMD} resetpassword "PlayerName"
  ${CMD} purge                          # Inactifs depuis ${WHITELIST_PURGE_DAYS}j (défaut)
  ${CMD} purge 3m --delete              # Supprime après confirmation

Notes:
  - Serveur en Open=false : seuls les SteamID autorisés peuvent se connecter.
  - Un SteamID peut porter 2 comptes : c'est pourquoi remove (SteamID) et
    remove-account (un compte) sont deux commandes différentes. remove refuse un
    pseudo, sinon « remove <pseudo> » couperait aussi l'autre compte sans le dire.
  - Le joueur choisit lui-même son mot de passe à la première connexion.
  - add/remove pilotent la console du serveur -> le serveur doit être démarré.
  - Steam ID 64 (17 chiffres, ex: 76561198012345678) via https://steamid.xyz/
  - --ban ajoute un bannissement définitif (banid) : retour impossible même renommé.
  - Délai purge: Xm (mois) ou Xj (jours) ; purge exclut toujours 'admin'.
  - remove-account/rename-account/resetpassword/purge --delete : serveur arrêté.
    Les personnages sont conservés ; remove-account retire les SteamID devenus
    orphelins. Le compte 'admin' est protégé.
HELPEOF
}

main() {
    # Toutes les commandes réelles lisent la base : les prérequis sont vérifiés
    # une fois ici plutôt que recopiés dans chacune des sept branches. L'aide et
    # une commande inconnue doivent répondre AVANT ces prérequis : sinon un appel
    # direct avec un monde non généré répondrait « base introuvable » là où le
    # vrai problème est le nom de la commande.
    case "$ACTION" in
        help|--help|-h|"")
            show_help
            return 0
            ;;
        list|add|remove|remove-account|rename-account|resetpassword|purge) ;;
        *)
            echo "Commande inconnue: $ACTION"
            echo ""
            show_help
            exit 1
            ;;
    esac

    require_sqlite
    check_database

    case "$ACTION" in
        list)
            list_whitelist
            ;;
        add)
            add_to_whitelist "${@:2}"
            ;;
        remove)
            remove_from_whitelist "${@:2}"
            ;;
        remove-account)
            remove_accounts "${@:2}"
            ;;
        rename-account)
            rename_account "${@:2}"
            ;;
        resetpassword)
            reset_password "${*:2}"
            ;;
        purge)
            purge_whitelist "${@:2}"
            ;;
    esac
}

main "$@"
