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
source_env

require_sqlite

# --- C3 : résolution stricte du monde ---------------------------------------
# Remplace le choix arbitraire sur plusieurs mondes (ancien head -1) : échoue
# s'il y a 0 ou >1 monde sans correspondance PZ_SERVER_NAME. `find_players_db`
# (lib/common.sh) est conservée pour les autres scripts (compat).
find_players_db_strict() {
    local root="$1"
    local -a dbs=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && dbs+=("$line")
    done < <(find "${root}/Saves/Multiplayer" -maxdepth 2 -name 'players.db' 2>/dev/null | sort)
    if (( ${#dbs[@]} == 0 )); then
        echo "ERREUR: aucun players.db sous ${root}/Saves/Multiplayer." >&2
        return 1
    fi
    if (( ${#dbs[@]} == 1 )); then
        printf '%s\n' "${dbs[0]}"
        return 0
    fi
    if [[ -n "${PZ_SERVER_NAME:-}" && -f "${root}/Saves/Multiplayer/${PZ_SERVER_NAME}/players.db" ]]; then
        printf '%s\n' "${root}/Saves/Multiplayer/${PZ_SERVER_NAME}/players.db"
        return 0
    fi
    {
        echo "ERREUR: plusieurs mondes sous ${root}/Saves/Multiplayer : refus de choisir arbitrairement."
        echo "Mondes trouvés :"
        for line in "${dbs[@]}"; do echo "  - $(basename "$(dirname "$line")")  ($line)"; done
        echo "Précise le monde : PZ_SERVER_NAME=<monde>, ou passe un backup pointant un monde précis (dossier du monde ou players.db)."
    } >&2
    return 1
}

# Vrai (code 0) si les deux chemins désignent le même fichier (realpath puis
# inode, puis comparaison littérale). Sert la garde source == dest.
_same_file() {
    local a="$1" b="$2" ra rb ia ib
    if command -v realpath >/dev/null 2>&1; then
        ra="$(realpath -m "$a" 2>/dev/null || true)"; rb="$(realpath -m "$b" 2>/dev/null || true)"
        [[ -n "$ra" && "$ra" == "$rb" ]] && return 0
    elif command -v readlink >/dev/null 2>&1; then
        ra="$(readlink -f "$a" 2>/dev/null || true)"; rb="$(readlink -f "$b" 2>/dev/null || true)"
        [[ -n "$ra" && "$ra" == "$rb" ]] && return 0
    fi
    ia="$(stat -c '%d:%i' "$a" 2>/dev/null || true)"; ib="$(stat -c '%d:%i' "$b" 2>/dev/null || true)"
    [[ -n "$ia" && "$ia" == "$ib" ]] && return 0
    [[ "$a" == "$b" ]] && return 0
    return 1
}

# Vérifie la table networkPlayers et les colonnes attendues via PRAGMA.
# Meurt (die) avant toute modification si le schéma est incompatible.
REQUIRED_PLAYER_COLS="world username playerIndex name steamid x y z worldversion data isDead"
assert_players_schema() {
    local db="$1" label="$2" tbl cols c
    tbl="$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='networkPlayers';" 2>/dev/null || true)"
    [[ "$tbl" == "networkPlayers" ]] || die "Schéma incompatible (${label}) : table 'networkPlayers' absente dans ${db}."
    cols="$(sqlite3 "$db" "PRAGMA table_info(networkPlayers);" 2>/dev/null || true)"
    for c in $REQUIRED_PLAYER_COLS; do
        awk -F'|' -v want="$c" '$2 == want { found=1 } END { exit !found }' <<<"$cols" \
            || die "Schéma incompatible (${label}) : colonne '${c}' absente dans ${db} (attendu : ${REQUIRED_PLAYER_COLS})."
    done
}

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

[[ -n "$USERNAME" && -n "$BACKUP_ARG" ]] || die "Usage: pzm backup restore-character <pseudo> <backup> [--dry-run]
Le backup est OBLIGATOIRE : nom du dossier (ex: backup_2026-06-23_23h15m29s) ou chemin complet."

# --- Résoudre le backup : nom sous ${BACKUP_DIR} OU chemin -------------------
# Un fichier players.db direct (backup pointant un monde précis) est accepté.
BK_PRECISE=""
if [[ -d "$BACKUP_ARG" ]]; then
    BACKUP_PATH="$BACKUP_ARG"
elif [[ -d "${BACKUP_DIR}/${BACKUP_ARG}" ]]; then
    BACKUP_PATH="${BACKUP_DIR}/${BACKUP_ARG}"
elif [[ -f "$BACKUP_ARG" ]]; then
    BK_PRECISE="$BACKUP_ARG"
    BACKUP_PATH="$(dirname "$BACKUP_ARG")"
else
    die "Backup introuvable: '${BACKUP_ARG}' (ni un dossier, ni un nom sous ${BACKUP_DIR})."
fi

# --- Serveur arrêté obligatoire ---------------------------------------------
# Serveur actif sans --dry-run : on bascule en aperçu et on refuse à la fin,
# une fois le perso concerné affiché — refuser d'emblée obligeait à couper le
# serveur juste pour savoir quel personnage aurait été remplacé.
REFUSED=false
if [[ "$DRY_RUN" != true ]] && server_is_active; then
    DRY_RUN=true; REFUSED=true
fi

# --- C1 : section critique monde (écriture) ----------------------------------
# Verrou monde autour de l'écriture + arrêt prouvé avant la transaction.
# (Aperçu --dry-run : pas de verrou, lecture seule.)
if [[ "$DRY_RUN" != true ]]; then
    # Vérifié : lib/world_lock.sh ne redirige jamais stderr (son `exec {fd}>…`
    # ne porte aucun `2>/dev/null`, seul le `flock -n` sonde est masqué) —
    # aucune sauvegarde/restauration de fd n'est nécessaire ici.
    acquire_world_lock --required || exit 1
    if declare -F assert_server_stopped_proven >/dev/null 2>&1; then
        assert_server_stopped_proven "Restauration personnage"
    else
        require_server_stopped "Restauration personnage"
    fi
fi

# --- Localiser players.db (live + backup, strict) ----------------------------
# C3 : refuse si 0 ou >1 monde sans correspondance PZ_SERVER_NAME (au lieu de
# choisir arbitrairement). Un backup pointant un monde précis (dossier du
# monde avec players.db, ou players.db lui-même) est accepté tel quel.
if [[ -n "$BK_PRECISE" ]]; then
    BK_DB="$BK_PRECISE"
elif [[ -f "${BACKUP_PATH}/players.db" ]]; then
    BK_DB="${BACKUP_PATH}/players.db"
else
    BK_DB="$(find_players_db_strict "${BACKUP_PATH}")" || die "players.db introuvable ou ambigu dans le backup ${BACKUP_PATH} (voir détail ci-dessus). Rien n'a été modifié."
fi
LIVE_DB="$(find_players_db_strict "${PZ_SOURCE_DIR}")" || die "players.db live introuvable ou ambigu sous ${PZ_SOURCE_DIR}/Saves/Multiplayer (voir détail ci-dessus). Rien n'a été modifié."

# --- C3 : pré-validations avant toute modification ---------------------------
if _same_file "$LIVE_DB" "$BK_DB"; then
    die "Source et destination identiques (${LIVE_DB}) : refuse de restaurer un monde sur lui-même. Rien n'a été modifié."
fi
assert_players_schema "$BK_DB" "backup"
assert_players_schema "$LIVE_DB" "live"

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
    log "Remplacerait ${in_live} perso(s) live de '${USERNAME}' par celui du backup."
    # Le refus dit déjà « rien n'a été modifié » : ne pas le répéter ici.
    [[ "$REFUSED" == false ]] || die_server_active "Restauration personnage"
    log "[dry-run] Rien n'a été modifié."
    exit 0
fi

# --- Écriture transactionnelle : écrase le perso live puis ré-insère -------
# On copie toutes les colonnes SAUF id (PK auto-assignée pour éviter les
# collisions) : le jeu identifie le perso par username/steamid, pas par cet id.
# C3 : transaction explicite (BEGIN IMMEDIATE ... COMMIT) dans un fichier SQL
# tmp (mktemp + trap rm) exécuté avec -bail/.bail on : toute erreur annule
# DELETE + INSERT (ROLLBACK), exit non nul, base live inchangée.
# Ordre imposé par SQLite : DETACH échoue DANS une transaction ouverte
# (« database bk is locked », prouvé) — ATTACH la précède donc et DETACH la
# suit ; DELETE + INSERT restent atomiques.
SQL_TMP="$(mktemp)" || die "Impossible de créer le fichier SQL temporaire."
trap 'rm -f "$SQL_TMP"' EXIT
{
    printf '.bail on\n'
    printf "ATTACH DATABASE '%s' AS bk;\n" "$(sql_escape "$BK_DB")"
    printf 'BEGIN IMMEDIATE;\n'
    printf "DELETE FROM networkPlayers WHERE username='%s';\n" "$ESC_USER"
    printf 'INSERT INTO networkPlayers (world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead)\n'
    printf "SELECT world,username,playerIndex,name,steamid,x,y,z,worldversion,data,isDead\n"
    printf "FROM bk.networkPlayers WHERE username='%s';\n" "$ESC_USER"
    printf 'COMMIT;\n'
    printf 'DETACH DATABASE bk;\n'
} > "$SQL_TMP"

if ! sqlite3 -bail "$LIVE_DB" < "$SQL_TMP"; then
    sqlite3 "$LIVE_DB" "ROLLBACK;" >/dev/null 2>&1 || true
    die "Échec de la restauration du personnage '${USERNAME}' (transaction annulée, base live inchangée)."
fi
rm -f "$SQL_TMP"
trap - EXIT
# (cf. acquisition ci-dessus : ni acquire ni release ne touche à stderr.)
release_world_lock 2>/dev/null || true

# --- Vérification -----------------------------------------------------------
log "=== Personnage restauré (état live) ==="
show_char "$LIVE_DB"

log "OK. Redémarre le serveur : pzm server start"
