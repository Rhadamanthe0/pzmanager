#!/bin/bash
# ------------------------------------------------------------------------------
# restoreCharacter.sh - Restaurer LE PERSONNAGE d'un joueur depuis un backup
# ------------------------------------------------------------------------------
# Ré-injecte la ligne `networkPlayers` (le personnage multijoueur) d'un joueur
# depuis un backup DONNÉ vers la base live `players.db`. Utile quand un perso a
# été perdu/corrompu (ex: échec de chargement après un changement de mod) alors
# que l'accès (whitelist) est intact.
#
# Écrit dans players.db -> le serveur DOIT être arrêté (sinon la sauvegarde
# auto du serveur écrase la modif et risque de corrompre la base).
#
# Comportement : ÉCRASE toujours le perso live existant du joueur par celui du
# backup. Pas de sauvegarde de sécurité ici : `pzm server stop` fait déjà une
# sauvegarde complète juste avant l'arrêt (et le serveur doit être arrêté).
#
# Usage: ./restoreCharacter.sh <pseudo> <backup> [--dry-run]
#   <pseudo>   Username du joueur (table networkPlayers)
#   <backup>   Dossier de sauvegarde OBLIGATOIRE : nom (ex: backup_2026-06-23_23h15m29s)
#              résolu sous ${BACKUP_DIR}, ou chemin complet
#   --dry-run  Montre ce qui serait fait sans rien modifier
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

command -v sqlite3 &>/dev/null || die "sqlite3 non installé."

# --- Parsing des arguments --------------------------------------------------
USERNAME=""
BACKUP_ARG=""
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --*)       die "Option inconnue: $arg" ;;
        *)
            if [[ -z "$USERNAME" ]]; then USERNAME="$arg"
            elif [[ -z "$BACKUP_ARG" ]]; then BACKUP_ARG="$arg"
            else die "Argument en trop: $arg"
            fi
            ;;
    esac
done

[[ -n "$USERNAME" && -n "$BACKUP_ARG" ]] || die "Usage: $0 <pseudo> <backup> [--dry-run]
Le backup est OBLIGATOIRE : nom du dossier (ex: backup_2026-06-23_23h15m29s) ou chemin complet."

# --- Résoudre le backup : nom sous ${BACKUP_DIR} OU chemin -------------------
if [[ -d "$BACKUP_ARG" ]]; then
    BACKUP_PATH="$BACKUP_ARG"
elif [[ -d "${BACKUP_DIR}/${BACKUP_ARG}" ]]; then
    BACKUP_PATH="${BACKUP_DIR}/${BACKUP_ARG}"
else
    die "Backup introuvable: '${BACKUP_ARG}' (ni un dossier, ni un nom sous ${BACKUP_DIR})."
fi

# --- Serveur arrêté obligatoire ---------------------------------------------
if server_is_active; then
    die "Le serveur est actif : la restauration écrit dans players.db et doit se faire serveur arrêté.
Arrête-le d'abord :  pzm server stop 2m --reason \"Restauration personnage\""
fi

# --- Localiser players.db (live + backup) -----------------------------------
LIVE_DB=$(find "${PZ_SOURCE_DIR}/Saves/Multiplayer" -name 'players.db' 2>/dev/null | head -1)
[[ -f "$LIVE_DB" ]] || die "players.db live introuvable sous ${PZ_SOURCE_DIR}/Saves/Multiplayer"

BK_DB=$(find "${BACKUP_PATH}/Saves/Multiplayer" -name 'players.db' 2>/dev/null | head -1)
[[ -f "$BK_DB" ]] || die "players.db introuvable dans le backup: ${BACKUP_PATH}/Saves/Multiplayer"

# sql_escape vient de lib/common.sh
ESC_USER="$(sql_escape "$USERNAME")"

# Affiche le(s) perso(s) du joueur (table networkPlayers) dans la base donnée.
show_char() {
    sqlite3 -header -column "$1" \
        "SELECT id, username, name, steamid, isDead, length(data) AS datalen FROM networkPlayers WHERE username='${ESC_USER}';" 2>/dev/null || true
}

# --- Le perso existe-t-il dans le backup ? ----------------------------------
in_backup=$(sqlite3 "$BK_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${ESC_USER}';" 2>/dev/null || echo "0")
if [[ "$in_backup" -eq 0 ]]; then
    die "Aucun personnage '${USERNAME}' dans ce backup ($(basename "$BACKUP_PATH")).
Vérifie le pseudo (sensible à la casse) ou choisis un autre backup."
fi

log "=== Restauration du personnage '${USERNAME}' ==="
log "Source : $(basename "$BACKUP_PATH")  (${in_backup} ligne(s))"
show_char "$BK_DB"

if [[ "$DRY_RUN" == true ]]; then
    in_live=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${ESC_USER}';" 2>/dev/null || echo "0")
    log "[dry-run] Remplacerait ${in_live} perso(s) live de '${USERNAME}' par celui du backup. Rien modifié."
    exit 0
fi

# --- Écriture : on écrase le perso live existant puis on ré-insère ----------
# On copie toutes les colonnes SAUF id (PK auto-assignée pour éviter les
# collisions) : le jeu identifie le perso par username/steamid, pas par cet id.
sqlite3 "$LIVE_DB" <<SQL
ATTACH DATABASE '$(sql_escape "$BK_DB")' AS bk;
DELETE FROM networkPlayers WHERE username='${ESC_USER}';
INSERT INTO networkPlayers (world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead)
SELECT world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead
FROM bk.networkPlayers WHERE username='${ESC_USER}';
DETACH DATABASE bk;
SQL

# --- Vérification -----------------------------------------------------------
log "=== Personnage restauré (état live) ==="
show_char "$LIVE_DB"

log "OK. Redémarre le serveur : pzm server start"
