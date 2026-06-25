#!/bin/bash
# ------------------------------------------------------------------------------
# restoreCharacter.sh - Restaurer LE PERSONNAGE d'un joueur depuis un backup
# ------------------------------------------------------------------------------
# Ré-injecte la ligne `networkPlayers` (le personnage multijoueur) d'un joueur
# depuis un backup vers la base live `players.db`. Utile quand un perso a été
# perdu/corrompu (ex: échec de chargement après un changement de mod) alors que
# l'accès (whitelist) est intact.
#
# Écrit dans players.db -> le serveur DOIT être arrêté (sinon la sauvegarde
# auto du serveur écrase la modif et risque de corrompre la base).
#
# Par sécurité : un snapshot de la base live est fait avant toute écriture, et
# on REFUSE d'écraser un perso déjà présent en live sauf --overwrite explicite.
#
# Usage: ./restoreCharacter.sh <pseudo> [chemin_backup] [--overwrite] [--dry-run]
#   <pseudo>        Username du joueur (table networkPlayers)
#   [chemin_backup] Dossier backup (défaut: le plus récent data/dataBackups/backup_*)
#   --overwrite     Remplacer le perso live existant (sinon refus si déjà présent)
#   --dry-run       Montre ce qui serait fait sans rien modifier
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

command -v sqlite3 &>/dev/null || die "sqlite3 non installé."

# --- Parsing des arguments --------------------------------------------------
USERNAME=""
BACKUP_PATH=""
OVERWRITE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --overwrite) OVERWRITE=true ;;
        --dry-run)   DRY_RUN=true ;;
        --*)         die "Option inconnue: $arg" ;;
        *)
            if [[ -z "$USERNAME" ]]; then USERNAME="$arg"
            elif [[ -z "$BACKUP_PATH" ]]; then BACKUP_PATH="$arg"
            else die "Argument en trop: $arg"
            fi
            ;;
    esac
done

[[ -n "$USERNAME" ]] || die "Usage: $0 <pseudo> [chemin_backup] [--overwrite] [--dry-run]"

# --- Serveur arrêté obligatoire ---------------------------------------------
if server_is_active; then
    die "Le serveur est actif : la restauration écrit dans players.db et doit se faire serveur arrêté.
Arrête-le d'abord :  pzm server stop 2m --reason \"Restauration personnage\""
fi

# --- Résoudre le backup -----------------------------------------------------
if [[ -z "$BACKUP_PATH" ]]; then
    BACKUP_PATH=$(ls -1td "${BACKUP_DIR}/backup_"* 2>/dev/null | head -1)
    [[ -n "$BACKUP_PATH" ]] || die "Aucun backup trouvé dans ${BACKUP_DIR}"
    log "Backup utilisé (le plus récent) : $(basename "$BACKUP_PATH")"
fi
[[ -d "$BACKUP_PATH" ]] || die "Dossier backup introuvable: $BACKUP_PATH"

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

# --- Conflit avec un perso live existant ? ----------------------------------
in_live=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM networkPlayers WHERE username='${ESC_USER}';" 2>/dev/null || echo "0")
if [[ "$in_live" -gt 0 && "$OVERWRITE" != true ]]; then
    die "Un personnage '${USERNAME}' existe déjà en live (${in_live} ligne(s)).
Pour le REMPLACER (écrase la progression actuelle), relance avec --overwrite."
fi

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Live actuel: ${in_live} ligne(s). Aucune modification effectuée."
    exit 0
fi

# --- Snapshot de sécurité de la base live -----------------------------------
SNAP_DIR="${BACKUP_DIR}/character-restores"
ensure_directory "$SNAP_DIR"
SNAP="${SNAP_DIR}/players_$(date +'%Y-%m-%d_%Hh%Mm%S')_pre-${USERNAME//[^A-Za-z0-9]/_}.db"
cp -f "$LIVE_DB" "$SNAP" && log "Snapshot live -> $SNAP"

# --- Écriture : (optionnel) suppression puis ré-insertion -------------------
# On copie toutes les colonnes SAUF id (PK auto-assignée pour éviter les
# collisions) : le jeu identifie le perso par username/steamid, pas par cet id.
DELETE_SQL=""
if [[ "$OVERWRITE" == true ]]; then
    DELETE_SQL="DELETE FROM networkPlayers WHERE username='${ESC_USER}';"
fi
sqlite3 "$LIVE_DB" <<SQL
ATTACH DATABASE '$(sql_escape "$BK_DB")' AS bk;
${DELETE_SQL}
INSERT INTO networkPlayers (world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead)
SELECT world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead
FROM bk.networkPlayers WHERE username='${ESC_USER}';
DETACH DATABASE bk;
SQL

# --- Vérification -----------------------------------------------------------
log "=== Personnage restauré (état live) ==="
show_char "$LIVE_DB"

log "OK. Redémarre le serveur : pzm server start"
