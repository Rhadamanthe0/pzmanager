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
RESTORE_MANIFEST=""
RESTORE_TXN=""
RESTORE_PLAN_DIRS=()
PREVIOUS_DIR=""
MOVED_DIRS=()
INSTALLED_DIRS=()
SWAP_IN_PROGRESS=false

# C7 : le staging est jetable : il est nettoyé sur sortie/interruption. La
# copie temporaire n'est supprimée qu'après succès (ou rollback réussi).
cleanup_restore_staging() {
    [[ -z "${RESTORE_MANIFEST:-}" ]] || rm -f -- "$RESTORE_MANIFEST"
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

# Bind both copies to the same complete file inventory, including empty dirs
# and link targets. Never follow symlinks or silently omit special files.
restore_tree_manifest() {
    python3 - "$1" "${RESTORE_PLAN_DIRS[@]}" <<'PYMANIFEST'
import hashlib, json, os, stat, sys
from pathlib import Path
root = Path(sys.argv[1])
entries = {}
def refuse(error): raise error
selected = set(sys.argv[2:])
for base, directories, files in os.walk(root, followlinks=False, onerror=refuse):
    if Path(base) == root and selected:
        directories[:] = [d for d in directories if d in selected]
        files[:] = [f for f in files if f in selected]
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
    local source_real live_real d
    source_real="$(realpath -e -- "$BACKUP_PATH")" || die "Chemin source invalide."
    live_real="$(realpath -m -- "$PZ_SOURCE_DIR")" || die "Chemin destination invalide."
    case "$source_real/" in "$live_real/"*) die "Source et destination imbriquées : restauration refusée." ;; esac
    case "$live_real/" in "$source_real/"*) die "Source et destination imbriquées : restauration refusée." ;; esac
    for d in "${RESTORED_DIRS[@]}"; do
        if [[ -e "$BACKUP_PATH/$d" || -L "$BACKUP_PATH/$d" ]]; then
            [[ -d "$BACKUP_PATH/$d" && ! -L "$BACKUP_PATH/$d" ]] || die "Répertoire source non régulier : $d"
            RESTORE_PLAN_DIRS+=("$d")
        fi
    done
    (( ${#RESTORE_PLAN_DIRS[@]} > 0 )) || die "Aucun répertoire restaurable."

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
sync_restore_parents() {
    python3 - "$@" <<'PYSYNC'
import os,sys
from pathlib import Path
for parent in {Path(p).parent for p in sys.argv[1:]}:
    fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
PYSYNC
}

restore_previous_dirs() {
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
        sync_restore_parents "${PREVIOUS_DIR}/${d}" "${PZ_SOURCE_DIR}/${d}" || return 1
    done
    if [[ -n "$RESTORE_TXN" ]]; then
        python3 "${SCRIPT_DIR}/../lib/world_transaction.py" finish --world "$PZ_SOURCE_DIR" --token "$RESTORE_TXN" --state reverted || return 1
    fi
    rmdir -- "${PREVIOUS_DIR}" 2>/dev/null || true
    SWAP_IN_PROGRESS=false
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
            sync_restore_parents "${PZ_SOURCE_DIR}/${d}" "${PREVIOUS_DIR}/${d}" || rollback_live
        fi
        INSTALLED_DIRS+=("$d")
        mv -T -- "${STAGING_DIR}/${d}" "${PZ_SOURCE_DIR}/${d}" || rollback_live
        sync_restore_parents "${STAGING_DIR}/${d}" "${PZ_SOURCE_DIR}/${d}" || rollback_live
    done

    verify_restore_tree "$PZ_SOURCE_DIR" || rollback_live

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
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" finish --world "$PZ_SOURCE_DIR" --token "$RESTORE_TXN" --state complete || rollback_live
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
    assert_server_stopped_proven "Restauration d'une sauvegarde"
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" check --world "$PZ_SOURCE_DIR" || die "Récupération explicite requise."

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

    RESTORE_MANIFEST="$(mktemp "${PZ_HOME}/.restore-manifest-XXXXXX")" || die "Inventaire impossible."
    restore_tree_manifest "$BACKUP_PATH" > "$RESTORE_MANIFEST" || die "Inventaire source refusé — live intact."
    copy_backup_to_staging
    validate_staging_dir "$STAGING_DIR"
    verify_restore_tree "$STAGING_DIR" || die "Staging différent de la source — live intact."
    verify_restore_tree "$BACKUP_PATH" || die "Source modifiée — live intact."
    # Validate the resulting world's structure before any directory is moved.
    if [[ -d "$STAGING_DIR/Saves" ]]; then
        validate_restored_live "$STAGING_DIR" || die "Staging sans monde — live intact."
    else
        validate_restored_live "$PZ_SOURCE_DIR" || die "Destination sans monde — live intact."
    fi
    prepare_previous_dir
    local -a directory_args=()
    local d
    for d in "${RESTORE_PLAN_DIRS[@]}"; do directory_args+=(--directory "$d"); done
    RESTORE_TXN="$(python3 "${SCRIPT_DIR}/../lib/world_transaction.py" begin --world "$PZ_SOURCE_DIR" --kind full-restore --recovery "$PREVIOUS_DIR" --after-tree "$STAGING_DIR" "${directory_args[@]}")" || die "Journal durable refusé — live intact."
    restore_zomboid_data
    show_summary
    # C1 : fin de section critique.
    release_world_lock
}

main
