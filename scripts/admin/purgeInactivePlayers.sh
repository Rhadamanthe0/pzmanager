#!/bin/bash
# ------------------------------------------------------------------------------
# purgeInactivePlayers.sh - Purge AUTOMATIQUE des accès inactifs
# ------------------------------------------------------------------------------
# Pour chaque compte inactif depuis >= WHITELIST_PURGE_DAYS jours, retire SES
# ACCÈS au serveur :
#   - l'autorisation SteamID (servertest.db: allowedsteamid) -- seulement si
#     aucun autre compte encore présent ne partage ce SteamID ;
#   - le compte de la liste blanche (servertest.db: whitelist).
#
# Le PERSONNAGE est CONSERVÉ (players.db / networkPlayers n'est PAS touché) :
# si le joueur revient et qu'on ré-autorise son SteamID, il retrouve son perso.
#
# Le compte interne 'admin' est TOUJOURS préservé (sinon perte d'administration).
#
# Écrit directement dans servertest.db -> DOIT tourner SERVEUR ARRÊTÉ. Conçu
# pour être appelé par performFullMaintenance.sh dans la fenêtre serveur-arrêté.
# Une sauvegarde de servertest.db est faite avant toute suppression.
#
# Usage: ./purgeInactivePlayers.sh [--force] [--dry-run]
#   --force    Ne pas refuser même si le service zomboid est actif (usage maint.)
#   --dry-run  Affiche ce qui serait supprimé sans rien modifier
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly DB_PATH="${PZ_SOURCE_DIR}/db/servertest.db"

FORCE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        *) ;;
    esac
done

command -v sqlite3 &>/dev/null || die "sqlite3 non installé."
[[ -f "$DB_PATH" ]] || { log "Base introuvable: $DB_PATH (purge ignorée)"; exit 0; }

# Refuser si le serveur tourne (écriture DB live dangereuse), sauf --force.
# (sql_escape et server_is_active viennent de lib/common.sh)
if [[ "$FORCE" != true ]] && server_is_active; then
    die "Le serveur est actif : la purge écrit dans servertest.db et doit se faire serveur arrêté.
Lance-la pendant la maintenance, ou utilise --force en connaissance de cause."
fi

# Détecter la colonne created_at (présente après creationDateInit.sh)
HAS_CREATED_AT=false
sqlite3 "$DB_PATH" "PRAGMA table_info(whitelist)" 2>/dev/null | grep -q '|created_at|' && HAS_CREATED_AT=true

readonly DAYS="${WHITELIST_PURGE_DAYS:-90}"

# Comptes inactifs (prédicat partagé avec la purge interactive — cf. common.sh).
WHERE="$(inactive_where_clause "$DAYS" "$HAS_CREATED_AT")"

log "=== Purge des accès inactifs (>= ${DAYS} jours) ==="

# Récupérer les victimes : id|username|steamid
mapfile -t VICTIMS < <(sqlite3 -separator '|' "$DB_PATH" \
    "SELECT id, username, COALESCE(steamid,'') FROM whitelist WHERE $WHERE ORDER BY lastConnection" 2>/dev/null)

if [[ "${#VICTIMS[@]}" -eq 0 ]]; then
    log "Aucun compte inactif à purger."
    exit 0
fi

log "${#VICTIMS[@]} compte(s) inactif(s) détecté(s) :"
for row in "${VICTIMS[@]}"; do
    IFS='|' read -r id uname sid <<< "$row"
    log "  - ${uname} (steamid: ${sid:-aucun})"
done

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Aucune modification effectuée."
    exit 0
fi

# Sauvegarde de sécurité avant suppression
SNAP_DIR="${BACKUP_DIR}/purge-snapshots"
ensure_directory "$SNAP_DIR"
SNAP="${SNAP_DIR}/servertest_$(date +'%Y-%m-%d_%Hh%Mm%S').db"
cp -f "$DB_PATH" "$SNAP" && log "Sauvegarde: $SNAP"

removed_accounts=0
removed_steamids=0
declare -a SUMMARY=()

for row in "${VICTIMS[@]}"; do
    IFS='|' read -r id uname sid <<< "$row"
    local_label="$uname"

    # 1) Retirer le compte de la liste blanche
    sqlite3 "$DB_PATH" "DELETE FROM whitelist WHERE id = ${id};" || { log "WARNING: échec suppression compte id=$id"; continue; }
    removed_accounts=$((removed_accounts + 1))

    # 2) Retirer le SteamID des autorisations, seulement si plus aucun compte
    #    restant ne l'utilise (SteamID partagé entre 2 comptes possible).
    if [[ -n "$sid" ]]; then
        esc_sid="$(sql_escape "$sid")"
        still_used=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE steamid = '${esc_sid}'" 2>/dev/null || echo "0")
        if [[ "$still_used" -eq 0 ]]; then
            sqlite3 "$DB_PATH" "DELETE FROM allowedsteamid WHERE steamid = '${esc_sid}';" || log "WARNING: échec suppression steamid $sid"
            removed_steamids=$((removed_steamids + 1))
            local_label="$uname (accès SteamID retiré)"
        else
            local_label="$uname (SteamID conservé, partagé)"
        fi
    fi

    SUMMARY+=("$local_label")
done

log "Purge terminée : ${removed_accounts} compte(s) retiré(s), ${removed_steamids} SteamID désautorisé(s). Personnages conservés."

# Notification Discord (non bloquant)
if [[ "$removed_accounts" -gt 0 && -x "${SCRIPT_DIR}/../internal/sendDiscord.sh" ]]; then
    msg="🧹 Purge whitelist (inactifs >= ${DAYS}j) : ${removed_accounts} accès retiré(s), personnages conservés."$'\n'"$(printf '• %s\n' "${SUMMARY[@]}")"
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "$msg" || true
fi
