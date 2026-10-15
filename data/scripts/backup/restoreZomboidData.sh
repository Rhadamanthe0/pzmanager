#!/bin/bash
# ------------------------------------------------------------------------------
# restoreZomboidData.sh - Restauration des données Zomboid uniquement
# ------------------------------------------------------------------------------
# Usage: ./restoreZomboidData.sh <chemin_backup>
#
# Restaure les données sauvegardées (Saves, db, Server, Lua) et laisse le reste
# du live en place. Les répertoires remplacés sont gardés le temps de la
# bascule, puis supprimés quand la restauration a réussi.
# Pour restauration système complète, utiliser configurationInitiale.sh restore.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly BACKUP_PATH="${1:-}"

# Répertoires remplacés par la restauration (ceux que dataBackup.sh copie).
# Un répertoire absent du backup reste tel quel dans le live.
readonly RESTORED_DIRS=(Saves db Server Lua)

# C7 : staging (copie validée avant bascule) et copie temporaire des
# répertoires remplacés. Globaux car posés par une étape et relus par une
# autre (swap/rollback).
STAGING_DIR=""
PREVIOUS_DIR=""
MOVED_DIRS=()
INSTALLED_DIRS=()
SWAP_IN_PROGRESS=false

# C7 : le staging est jetable : il est nettoyé sur sortie/interruption. La
# copie temporaire n'est supprimée qu'après succès (ou rollback réussi).
cleanup_restore_staging() {
    if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR:-}" ]]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    fi
    # Réservée mais jamais remplie (échec avant la bascule).
    [[ -z "${PREVIOUS_DIR:-}" ]] || rmdir -- "${PREVIOUS_DIR}" 2>/dev/null || true
}

on_restore_interrupt() {
    trap '' INT TERM
    if [[ "$SWAP_IN_PROGRESS" == true ]]; then
        restore_previous_dirs || true
    fi
    cleanup_restore_staging
    exit 143
}

show_usage() {
    echo "Usage: pzm backup restore <chemin_backup>"
    echo ""
    echo "Exemples:"
    echo "  pzm backup restore ${BACKUP_DIR}/backup_2026-01-11_14h15m00s"
    echo "  pzm backup restore ${BACKUP_DIR}/latest"
    echo ""
    echo "Backups disponibles (10 plus récents):"
    if [[ -d "${BACKUP_DIR}" ]]; then
        ls -1t "${BACKUP_DIR}" | grep -E "^backup_|^latest$" | head -10
    else
        echo "  Aucun backup trouvé dans ${BACKUP_DIR}"
    fi
}

validate_backup_path() {
    [[ -n "$BACKUP_PATH" ]] || { show_usage; exit 1; }
    [[ -d "$BACKUP_PATH" ]] || die "Backup introuvable: $BACKUP_PATH"

    # Vérifier que le backup contient bien des données Zomboid
    if [[ ! -d "$BACKUP_PATH/Saves" ]] && [[ ! -d "$BACKUP_PATH/Server" ]]; then
        die "Le backup ne semble pas contenir de données Zomboid (Saves/ ou Server/ manquant)"
    fi

    # C7 : ici la source est un répertoire (pas de ZIP : rien à filtrer côté
    # chemins absolus/`..`), on vérifie sa lisibilité AVANT de toucher au live.
    for d in Saves Server; do
        if [[ -d "$BACKUP_PATH/$d" && ! -r "$BACKUP_PATH/$d" ]]; then
            die "Backup illisible: $BACKUP_PATH/$d"
        fi
    done
}

prepare_previous_dir() {
    [[ -d "${PZ_SOURCE_DIR}" ]] || return 0

    # Garde ajoutée le 2026-08-18 : ce chemin DÉPLACE les répertoires du monde
    # live (mv) puis installe ceux du backup. Fait serveur allumé, la JVM
    # continue d'écrire dans ses descripteurs déjà ouverts — donc dans l'arbre
    # RENOMMÉ — et sauvegarde son état dedans à l'arrêt : la restauration est
    # écrasée en silence, les deux mondes se mélangent. Les autres écrivains du
    # monde (restore-character, map wipe, remove-account) avaient déjà cette
    # garde, pas celui-ci, qui est pourtant le plus destructeur.
    # C1 : arrêt PROUVÉ (inactive seule ; failed/unknown/error -> refus
    # fail-closed — un bus systemd en panne n'est plus un « serveur arrêté »).
    if declare -F assert_server_stopped_proven >/dev/null 2>&1; then
        assert_server_stopped_proven "Restauration d'une sauvegarde"
    else
        require_server_stopped "Restauration d'une sauvegarde"
    fi

    # C7 : appelé seulement APRÈS staging validé (voir main). Destination
    # unique sous PZ_HOME (même FS : les mv sont des renommages).
    PREVIOUS_DIR="$(mktemp -d "${PZ_HOME}/.restore-previous-XXXXXX")" \
        || die "Impossible de réserver la copie temporaire — live intact."
}

# C7 : copie backup → staging (le live n'est pas encore touché : toute erreur
# ici meurt avec le live intact).
copy_backup_to_staging() {
    echo "Copie du backup vers le staging..."
    rsync -a --info=progress2 "${BACKUP_PATH}/" "${STAGING_DIR}/" \
        || die "Copie vers le staging impossible — live intact, rien n'est basculé."
}

# C7 : le staging ne bascule que s'il ressemble à un monde (Saves/Server, non
# vide, .db présent si le backup en contenait un). Meurt AVANT tout mv du live.
validate_staging_dir() {
    local staging="$1"
    if [[ ! -d "$staging/Saves" && ! -d "$staging/Server" ]]; then
        die "Staging invalide dans $staging (Saves/ ou Server/ manquant) — live intact, rien n'est basculé."
    fi
    local entries=0
    if [[ -d "$staging/Saves" ]]; then
        entries=$(( entries + $(find "$staging/Saves" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) ))
    fi
    if [[ -d "$staging/Server" ]]; then
        entries=$(( entries + $(find "$staging/Server" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) ))
    fi
    (( entries > 0 )) || die "Staging vide dans $staging — live intact, rien n'est basculé."
    if [[ -n "$(find "$BACKUP_PATH" -name '*.db' -print -quit 2>/dev/null)" ]] \
        && [[ -z "$(find "$staging" -name '*.db' -print -quit 2>/dev/null)" ]]; then
        die "Staging invalide : .db attendu (présent dans le backup) absent — live intact, rien n'est basculé."
    fi
}

# C7 : validation finale — au moins un monde restauré (compte mondes > 0).
# Retourne 1 (sans mourir) pour laisser l'appelant déclencher le rollback.
validate_restored_live() {
    local dest="$1" worlds=0
    if [[ -d "$dest/Saves" ]]; then
        worlds=$(find "$dest/Saves" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi
    if (( worlds == 0 )); then
        echo "ERREUR: Validation finale échouée : aucun monde dans $dest." >&2
        return 1
    fi
}

# C7 : retire les répertoires installés et remet les anciens en place. La
# copie temporaire n'est conservée que si cette remise échoue.
restore_previous_dirs() {
    SWAP_IN_PROGRESS=false
    echo "Échec du swap — remise en place des répertoires d'origine..." >&2
    local d
    for d in "${INSTALLED_DIRS[@]}"; do
        if ! rm -rf -- "${PZ_SOURCE_DIR:?}/${d}"; then
            echo "ERREUR: rollback incomplet — restaure manuellement depuis ${PREVIOUS_DIR}." >&2
            return 1
        fi
    done
    for d in "${MOVED_DIRS[@]}"; do
        [[ -e "${PREVIOUS_DIR}/${d}" || -L "${PREVIOUS_DIR}/${d}" ]] || continue
        if ! mv -T -- "${PREVIOUS_DIR}/${d}" "${PZ_SOURCE_DIR}/${d}"; then
            echo "ERREUR: rollback incomplet — restaure manuellement depuis ${PREVIOUS_DIR}." >&2
            return 1
        fi
    done
    rmdir -- "${PREVIOUS_DIR}" 2>/dev/null || true
    echo "✓ Live remis dans son état d'origine." >&2
}

rollback_live() {
    restore_previous_dirs || die "Échec du swap ET du rollback — copie temporaire : ${PREVIOUS_DIR}."
    die "Restauration interrompue (swap incomplet) — live remis dans son état d'origine."
}

restore_zomboid_data() {
    echo "Restauration des données Zomboid..."
    mkdir -p "${PZ_SOURCE_DIR}"

    # C7 : bascule répertoire par répertoire (renommages sous PZ_HOME). Un
    # répertoire absent du backup n'est pas touché ; le reste du live
    # (Logs, options.ini...) reste en place.
    SWAP_IN_PROGRESS=true
    local d
    for d in "${RESTORED_DIRS[@]}"; do
        [[ -e "${STAGING_DIR}/${d}" ]] || continue
        # Noté AVANT le mv : un signal traité juste après le mv ne doit pas
        # laisser un répertoire déplacé que le rollback ignorerait.
        if [[ -e "${PZ_SOURCE_DIR}/${d}" || -L "${PZ_SOURCE_DIR}/${d}" ]]; then
            MOVED_DIRS+=("$d")
            mv -T -- "${PZ_SOURCE_DIR}/${d}" "${PREVIOUS_DIR}/${d}" || rollback_live
        fi
        INSTALLED_DIRS+=("$d")
        mv -T -- "${STAGING_DIR}/${d}" "${PZ_SOURCE_DIR}/${d}" || rollback_live
    done

    # || true : `pzm backup restore` tourne en utilisateur non privilégié, un
    # seul fichier au propriétaire inattendu faisait échouer chown et, sous
    # `set -e`, interrompait la restauration à mi-parcours — pire que de laisser
    # un fichier mal possédé.
    for d in "${INSTALLED_DIRS[@]}"; do
        chown -R "${PZ_USER}:${PZ_USER}" "${PZ_SOURCE_DIR}/${d}" 2>/dev/null || \
            echo "  (chown partiel : certains fichiers gardent leur propriétaire d'origine)"
    done

    # C7 : validation finale AVANT de rendre la main — un live vide repart en
    # rollback plutôt que de rester en place.
    if ! validate_restored_live "${PZ_SOURCE_DIR}"; then
        rollback_live
    fi
    SWAP_IN_PROGRESS=false

    # Succès : la copie temporaire n'a plus d'usage.
    if [[ -n "$PREVIOUS_DIR" ]]; then
        rm -rf -- "${PREVIOUS_DIR}" \
            || echo "⚠ Copie temporaire non supprimée : ${PREVIOUS_DIR}"
    fi
    PREVIOUS_DIR=""

    echo "✓ Restauration terminée: $BACKUP_PATH → ${PZ_SOURCE_DIR} (${INSTALLED_DIRS[*]})"
}

show_summary() {
    echo ""
    echo "=== Résumé ==="
    echo "Source: $BACKUP_PATH"
    echo "Destination: ${PZ_SOURCE_DIR}"
    if [[ -d "${PZ_SOURCE_DIR}/Saves" ]]; then
        local save_count=$(find "${PZ_SOURCE_DIR}/Saves" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "Sauvegardes restaurées: $save_count monde(s)"
    fi

    echo ""
    echo "Pour appliquer les changements:"
    echo "  pzm server restart 2m"
}

main() {
    # C1 : verrou monde autour de toute la section critique (exclut backup,
    # start, wipe, 2e restore...), sans le relâcher au milieu.
    acquire_world_lock --required || exit 1
    validate_backup_path

    echo "=== Restauration données Zomboid ==="
    echo "Backup source: $BACKUP_PATH"
    echo ""

    # C7 : staging sous PZ_HOME (même FS que le live), nettoyé sur toute
    # sortie. Le live n'est touché qu'une fois le staging validé ; une
    # interruption pendant la bascule remet les répertoires d'origine.
    STAGING_DIR="$(mktemp -d "${PZ_HOME}/.restore-staging-XXXXXX")" \
        || die "Impossible de créer le staging sous ${PZ_HOME}."
    trap cleanup_restore_staging EXIT
    trap on_restore_interrupt INT TERM

    copy_backup_to_staging
    validate_staging_dir "$STAGING_DIR"
    prepare_previous_dir
    restore_zomboid_data
    show_summary
    # C1 : fin de section critique.
    release_world_lock
}

main
