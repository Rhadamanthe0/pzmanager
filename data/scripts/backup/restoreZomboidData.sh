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
RESTORE_MANIFEST=""
RESTORE_TXN=""

# C7 : le staging est jetable (le live et OLD ne le sont pas) : seul lui est
# nettoyé sur sortie/interruption. OLD n'est jamais supprimé par ce script.
cleanup_restore_staging() {
    [[ -z "${RESTORE_MANIFEST:-}" ]] || rm -f -- "$RESTORE_MANIFEST"
    if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR:-}" ]]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    fi
}

# Bind both copies to the same complete file inventory, including empty dirs
# and link targets. Never follow symlinks or silently omit special files.
restore_tree_manifest() {
    python3 - "$1" <<'PYMANIFEST'
import hashlib, json, os, stat, sys
from pathlib import Path
root = Path(sys.argv[1])
entries = {}
def refuse(error): raise error
for base, directories, files in os.walk(root, followlinks=False, onerror=refuse):
    for name in directories + files:
        path = Path(base) / name
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            value = ['link', os.readlink(path)]
        elif stat.S_ISDIR(info.st_mode):
            value = ['directory']
        elif stat.S_ISREG(info.st_mode):
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                before = os.fstat(stream.fileno())
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                after = os.fstat(stream.fileno())
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError('File changed during inventory')
            value = ['file', after.st_size, digest]
        else:
            raise ValueError('Unsupported file type: ' + str(path))
        entries[str(path.relative_to(root))] = value
print(json.dumps(entries, sort_keys=True, ensure_ascii=True))
PYMANIFEST
}

verify_restore_tree() {
    local actual status=0
    actual="$(mktemp "${PZ_HOME}/.restore-verify-XXXXXX")" || return 1
    restore_tree_manifest "$1" > "$actual" && cmp -s -- "$actual" "$RESTORE_MANIFEST" || status=1
    rm -f -- "$actual"
    return "$status"
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
    local source_real live_real
    source_real="$(realpath -e -- "$BACKUP_PATH")" || die "Chemin source invalide."
    live_real="$(realpath -m -- "$PZ_SOURCE_DIR")" || die "Chemin destination invalide."
    case "$source_real/" in "$live_real/"*) die "Source et destination imbriquées : source intacte, restauration refusée." ;; esac
    case "$live_real/" in "$source_real/"*) die "Source et destination imbriquées : source intacte, restauration refusée." ;; esac

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

reserve_old_backup() {
    [[ -d "${PZ_SOURCE_DIR}" ]] || return 0
    mkdir -p "${PZ_HOME}/OLD"
    RESTORE_OLD_BACKUP="$(mktemp -d "${PZ_HOME}/OLD/ZomboidBROKEN_$(date +"%Y-%m-%d_%Hh%Mm%Ss")_XXXXXX")" \
        || die "Impossible de réserver le backup de sécurité — live intact."
    RESTORE_OLD_RESERVED=1
}

backup_current_zomboid() {
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
    # L'absence du répertoire live ne prouve pas l'absence d'une JVM : après
    # une interruption elle peut encore écrire via ses descripteurs ouverts.
    [[ -d "${PZ_SOURCE_DIR}" ]] || return 0

    # C7 : ce mv n'est appelé qu'APRÈS staging validé (voir main) — on ne
    # déplace jamais le live sans copie prête à basculer. Réserver une
    # destination unique : deux opérations dans la même seconde ne doivent
    # jamais imbriquer le second monde dans le premier OLD.
    [[ "${RESTORE_OLD_RESERVED:-0}" == 1 ]] || reserve_old_backup

    echo "Création backup de sécurité..."
    # -T interdit la sémantique « déplacer dans » ; le répertoire réservé
    # est vide et peut être remplacé, sans effacer un autre monde.
    mv -T -- "${PZ_SOURCE_DIR}" "$RESTORE_OLD_BACKUP"
    RESTORE_OLD_RESERVED=0
    python3 - "$PZ_SOURCE_DIR" "$RESTORE_OLD_BACKUP" <<'PYSYNC'
import os,sys
from pathlib import Path
for parent in {Path(p).parent for p in sys.argv[1:]}:
    fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
PYSYNC
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
    # Le live peut contenir des fichiers du swap échoué. Un miroir exact
    # les retire ; OLD reste intact même si la copie de rollback échoue.
    rsync -a --delete "${old_backup}/" "${PZ_SOURCE_DIR}/" \
        || die "Échec du swap ET du rollback — restaure manuellement : $old_backup → ${PZ_SOURCE_DIR}."
    if [[ -n "${RESTORE_TXN:-}" ]]; then
        python3 "${SCRIPT_DIR}/../lib/world_transaction.py" finish --world "$PZ_SOURCE_DIR" --token "$RESTORE_TXN" --state reverted \
            || die "Rollback non vérifié : journal conservé."
    fi
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

    verify_restore_tree "$PZ_SOURCE_DIR" \
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
    assert_server_stopped_proven "Restauration d'une sauvegarde"

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

    RESTORE_MANIFEST="$(mktemp "${PZ_HOME}/.restore-manifest-XXXXXX")" \
        || die "Impossible de réserver le manifest de restauration."
    restore_tree_manifest "$BACKUP_PATH" > "$RESTORE_MANIFEST" \
        || die "Inventaire source impossible — live intact."
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" check --world "$PZ_SOURCE_DIR" || die "Récupération explicite requise."
    copy_backup_to_staging
    verify_restore_tree "$BACKUP_PATH" && verify_restore_tree "$STAGING_DIR" \
        || die "Copie de staging différente du manifest source — live intact."
    validate_staging_dir "$STAGING_DIR"
    # La postcondition structurelle est déjà vérifiable sur la copie : ne
    # déplacer aucun monde live si elle impose ensuite un rollback certain.
    validate_restored_live "$STAGING_DIR" \
        || die "Staging sans monde restaurable — live intact, aucune bascule."
    verify_restore_tree "$STAGING_DIR" \
        || die "Staging modifié après validation — live intact."
    reserve_old_backup
    RESTORE_TXN="$(python3 "${SCRIPT_DIR}/../lib/world_transaction.py" begin --world "$PZ_SOURCE_DIR" \
        --kind full-restore --recovery "${RESTORE_OLD_BACKUP:-${PZ_HOME}/OLD}" --after-tree "$STAGING_DIR")" || die "Journal durable indisponible."
    backup_current_zomboid
    restore_zomboid_data
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" finish --world "$PZ_SOURCE_DIR" --token "$RESTORE_TXN" --state complete \
        || die "Restauration copiée mais non clôturée : vérification explicite requise."
    show_summary
    # C1 : fin de section critique.
    release_world_lock
}

main
