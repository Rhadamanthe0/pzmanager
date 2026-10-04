#!/bin/bash
# ------------------------------------------------------------------------------
# restoreZomboidData.sh - Restauration des données Zomboid uniquement
# ------------------------------------------------------------------------------
# Usage: ./restoreZomboidData.sh <chemin_backup>
#
# Restaure uniquement les données Zomboid (Saves, db, Server).
# Crée backup de sécurité avant écrasement.
# Pour restauration système complète, utiliser configurationInitiale.sh restore.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly BACKUP_PATH="${1:-}"

# C7 : staging (copie validée avant bascule) et OLD de rollback. Globaux car
# posés par une étape et relus par une autre (swap/rollback/résumé).
STAGING_DIR=""
RESTORE_OLD_BACKUP=""

# C7 : le staging est jetable (le live et OLD ne le sont pas) : seul lui est
# nettoyé sur sortie/interruption. OLD n'est jamais supprimé par ce script.
cleanup_restore_staging() {
    if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR:-}" ]]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    fi
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

backup_current_zomboid() {
    [[ -d "${PZ_SOURCE_DIR}" ]] || return 0

    # Garde ajoutée le 2026-08-18 : ce chemin DÉPLACE le monde live (mv) puis
    # rsync par-dessus. Fait serveur allumé, la JVM continue d'écrire dans ses
    # descripteurs déjà ouverts — donc dans l'arbre RENOMMÉ — et sauvegarde son
    # état dedans à l'arrêt : la restauration est écrasée en silence, les deux
    # mondes se mélangent. Les autres écrivains du monde (restore-character,
    # map wipe, remove-account) avaient déjà cette garde, pas celui-ci, qui est
    # pourtant le plus destructeur.
    # C1 : arrêt PROUVÉ (inactive seule ; failed/unknown/error -> refus
    # fail-closed — un bus systemd en panne n'est plus un « serveur arrêté »).
    if declare -F assert_server_stopped_proven >/dev/null 2>&1; then
        assert_server_stopped_proven "Restauration d'une sauvegarde"
    else
        require_server_stopped "Restauration d'une sauvegarde"
    fi

    # C7 : ce mv n'est appelé qu'APRÈS staging validé (voir main) — on ne
    # déplace jamais le live sans copie prête à basculer. Horodatage à la
    # seconde. OLD est conservé jusqu'à la validation finale (jamais supprimé).
    RESTORE_OLD_BACKUP="${PZ_HOME}/OLD/ZomboidBROKEN_$(date +"%Y-%m-%d_%Hh%Mm%Ss")"

    echo "Création backup de sécurité..."
    mkdir -p "${PZ_HOME}/OLD"
    mv "${PZ_SOURCE_DIR}" "$RESTORE_OLD_BACKUP"
    echo "✓ Backup sécurité: $RESTORE_OLD_BACKUP"
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

# C7 : rollback — le swap a échoué, on remet OLD en place puis on meurt
# (OLD est conservé dans tous les cas, même si le rollback lui-même échoue).
rollback_live() {
    local old_backup="$1"
    [[ -n "$old_backup" && -d "$old_backup" ]] \
        || die "Échec du swap et aucun OLD à restaurer — live incomplet dans ${PZ_SOURCE_DIR}."
    echo "Échec du swap — rollback depuis $old_backup ..."
    mkdir -p "${PZ_SOURCE_DIR}"
    rsync -a "${old_backup}/" "${PZ_SOURCE_DIR}/" \
        || die "Échec du swap ET du rollback — restaure manuellement : $old_backup → ${PZ_SOURCE_DIR}."
    echo "✓ Rollback terminé: $old_backup → ${PZ_SOURCE_DIR}"
    die "Restauration interrompue (swap incomplet) — live restauré depuis $old_backup, OLD conservé."
}

restore_zomboid_data() {
    echo "Restauration des données Zomboid..."
    mkdir -p "${PZ_SOURCE_DIR}"

    # C7 : rsync (et non mv -T) : le staging vit sous PZ_HOME donc le plus
    # souvent sur le même FS, mais rsync reste correct dans tous les cas et
    # rend les pannes partielles détectables (code retour) pour le rollback.
    rsync -a --info=progress2 "${STAGING_DIR}/" "${PZ_SOURCE_DIR}/" \
        || rollback_live "$RESTORE_OLD_BACKUP"

    # || true : `pzm backup restore` tourne en utilisateur non privilégié, un
    # seul fichier au propriétaire inattendu faisait échouer chown et, sous
    # `set -e`, interrompait la restauration à mi-parcours — pire que de laisser
    # un fichier mal possédé.
    chown -R "${PZ_USER}:${PZ_USER}" "${PZ_SOURCE_DIR}" 2>/dev/null || \
        echo "  (chown partiel : certains fichiers gardent leur propriétaire d'origine)"

    # C7 : validation finale AVANT de rendre la main — un live vide repart en
    # rollback plutôt que de rester en place.
    if ! validate_restored_live "${PZ_SOURCE_DIR}"; then
        rollback_live "$RESTORE_OLD_BACKUP"
    fi

    echo "✓ Restauration terminée: $BACKUP_PATH → ${PZ_SOURCE_DIR}"
}

show_summary() {
    echo ""
    echo "=== Résumé ==="
    echo "Source: $BACKUP_PATH"
    echo "Destination: ${PZ_SOURCE_DIR}"
    if [[ -n "$RESTORE_OLD_BACKUP" ]]; then
        echo "Backup sécurité conservé: $RESTORE_OLD_BACKUP"
    fi

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
    # sortie. Le live n'est déplacé vers OLD qu'une fois le staging validé :
    # on ne supprime jamais le live sans copie prête, et une interruption
    # (INT/TERM) laisse toujours live ou OLD récupérable, jamais le vide.
    STAGING_DIR="$(mktemp -d "${PZ_HOME}/.restore-staging-XXXXXX")" \
        || die "Impossible de créer le staging sous ${PZ_HOME}."
    trap cleanup_restore_staging EXIT
    trap 'cleanup_restore_staging; exit 143' INT TERM

    copy_backup_to_staging
    validate_staging_dir "$STAGING_DIR"
    backup_current_zomboid
    restore_zomboid_data
    show_summary
    # C1 : fin de section critique.
    release_world_lock
}

main
