#!/bin/bash
# ------------------------------------------------------------------------------
# fullBackup.sh - Sauvegarde off-site complète (UN seul ZIP)
# ------------------------------------------------------------------------------
# Produit UN seul ZIP horodaté : fullBackups/YYYY-MM-DD_HH-MM.zip, mirroré
# off-site par Syncthing (root, sendonly) -> PC fixe -> Google Drive.
#
# Contenu = UNIQUEMENT les données à valeur, PAS ce qui se reconstruit :
#   config/   .ssh, units systemd --user, setupTemplates, data/scripts (SANS
#             .venv/ __pycache__), le .env de la racine, versionning/ (ledger des
#             versions de mods, gitignoré), /etc/sudoers.d/<user>
#   zomboid/  le dernier snapshot de jeu (Saves/ db/ Server/ = monde, joueurs,
#             config serveur), déréférencé depuis dataBackups/latest.
#
# EXCLU car reconstructible : data/pzserver (install SteamCMD + mods Workshop,
# re-téléchargés par SteamCMD / pzm install), data/dataBackups & data/fullBackups
# (les backups eux-mêmes), logs, venv Discord. Le ZIP est le format de transport
# car Syncthing ignore les hardlinks (un arbre hardlinké exploserait sur le PC).
#
# Rétention : OFFSITE_BACKUP_COUNT derniers ZIP (.env, défaut 7).
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

command -v zip &>/dev/null || die "zip non installé."

readonly TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
readonly ARCHIVE_NAME="${TIMESTAMP}.zip"
readonly FINAL_ARCHIVE="${SYNC_BACKUPS_DIR}/${ARCHIVE_NAME}"
# On construit dans un .partial du MÊME dossier que la cible : le mv final est
# alors un rename atomique (même système de fichiers), donc Syncthing ne voit
# jamais un ZIP en cours d'écriture — il n'apparaît qu'entier.
readonly TMP_ARCHIVE="${SYNC_BACKUPS_DIR}/.${ARCHIVE_NAME}.partial"

# Config à sauvegarder (petits fichiers, non reconstructibles). rsync -aR conserve
# le chemin absolu de chaque entrée, ce qui vaut aussi bien pour un fichier que pour
# un dossier : le .env, seul fichier de la liste, est donc archivé sous
# home/<user>/pzmanager/.env et remis en place par la restauration, qui rsync tout
# le sous-arbre pzmanager/. Il est le SEUL élément vraiment irremplaçable ici
# (secrets webhook/bot/Google) — le code, lui, se reprend depuis git.
readonly DIRS_TO_SYNC=(
    "${PZ_HOME}/.ssh"
    "${PZ_HOME}/.config/systemd/user"
    "${PZ_DATA_DIR}/setupTemplates"
    "${PZ_SCRIPTS_DIR}"
    "${PZ_MANAGER_DIR}/.env"
    "${PZ_MANAGER_DIR}/versionning"
)

# Reconstructible, exclu de la sauvegarde des scripts : le venv se rebâtit via
# `pzm install discord`. Sans ça, sauvegarder PZ_SCRIPTS_DIR embarquerait des
# centaines de Mo. (Les logs, eux, ne sont plus sous scripts/ mais à la racine,
# et ne figurent pas dans DIRS_TO_SYNC : exclus par omission.)
readonly SYNC_EXCLUDES=(
    --exclude ".venv/"
    --exclude "__pycache__/"
)

# Staging des petits fichiers de config HORS du dossier synchronisé (le gros des
# données de jeu n'est pas copié : zip le lit à la volée via un symlink).
readonly WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}" "${TMP_ARCHIVE}" 2>/dev/null || true' EXIT
trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND failed." >&2' ERR

stage_config() {
    log "Assemblage des fichiers de config..."
    local dst="${WORK}/config"
    mkdir -p "$dst"

    # Distinguer « absent » (normal, on ignore) de « rsync a échoué » (anormal).
    # L'ancienne forme `[[ -e ]] && rsync ... || echo "Ignoré"` rapportait un
    # ÉCHEC de rsync (droits, disque plein) comme une simple absence : le ZIP
    # hors-site était ensuite construit et mis en rotation sans le .env ni les
    # units systemd, tout en se déclarant réussi.
    local item
    for item in "${DIRS_TO_SYNC[@]}"; do
        if [[ ! -e "$item" ]]; then
            echo "Ignoré (absent): $item"
        elif ! rsync -aR --delete "${SYNC_EXCLUDES[@]}" "$item" "${dst}/"; then
            die "rsync a échoué sur '$item' : sauvegarde hors-site incomplète, on n'écrase pas la rotation."
        fi
    done

    # sudoers : lecture root en read-only, sortie redirigée par le shell user.
    mkdir -p "${dst}/etc/sudoers.d"
    sudo /bin/cat "/etc/sudoers.d/${PZ_USER}" > "${dst}/etc/sudoers.d/${PZ_USER}" 2>/dev/null \
        || echo "Ignoré: /etc/sudoers.d/${PZ_USER}"
}

stage_game_data() {
    if [[ ! -e "${BACKUP_LATEST_LINK}" ]]; then
        echo "Warning: snapshot 'latest' introuvable (${BACKUP_LATEST_LINK}) — ZIP produit sans données de jeu."
        return 0
    fi
    # Symlink vers le VRAI snapshot : `zip -r` déréférence un lien de dossier
    # (contenu réel, pas le lien) et l'archive sous zomboid/ (Saves/db/Server),
    # aplatissant du même coup les hardlinks -> ZIP autoportant pour le PC.
    local game_dir
    game_dir="$(readlink -f "${BACKUP_LATEST_LINK}")"
    ln -s "$game_dir" "${WORK}/zomboid"
}

build_archive() {
    log "Création du ZIP off-site unique : ${ARCHIVE_NAME}..."
    ensure_directory "${SYNC_BACKUPS_DIR}"
    rm -f "${TMP_ARCHIVE}"

    local members=(config)
    [[ -L "${WORK}/zomboid" ]] && members+=(zomboid)

    ( cd "${WORK}" && zip -r -q "${TMP_ARCHIVE}" "${members[@]}" )
    mv -f "${TMP_ARCHIVE}" "${FINAL_ARCHIVE}"
    log "ZIP prêt : ${FINAL_ARCHIVE} ($(du -h "${FINAL_ARCHIVE}" | cut -f1))"
}

cleanup_old_backups() {
    # Rétention off-site par COMPTE (pas par jours) : ces ZIP complets sont
    # mirrorés par Syncthing. Le nom horodaté YYYY-MM-DD_HH-MM trie
    # chronologiquement en lexicographique -> sort -r = du plus récent au plus vieux.
    local keep="${OFFSITE_BACKUP_COUNT:-7}"
    log "Nettoyage off-site : conservation des ${keep} derniers ZIP..."

    [[ -d "${SYNC_BACKUPS_DIR}" ]] || return 0

    local zips=()
    mapfile -t zips < <(find "${SYNC_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type f \
        -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9].zip" | sort -r)

    local i
    for (( i = keep; i < ${#zips[@]}; i++ )); do
        rm -f -- "${zips[i]}"
        echo "  Supprimé (au-delà des ${keep}) : $(basename "${zips[i]}")"
    done

    # Purge des anciens backups au format DOSSIER (fullBackups/<ts>/), remplacés
    # par les ZIP uniques : sinon ils traîneraient indéfiniment (et sur le PC).
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        rm -rf -- "$d"
        echo "  Supprimé (ancien format dossier) : $(basename "$d")"
    done < <(find "${SYNC_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d \
        -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]")
}

stage_config
stage_game_data
build_archive
cleanup_old_backups

log "Backup off-site terminé : ${FINAL_ARCHIVE}"
