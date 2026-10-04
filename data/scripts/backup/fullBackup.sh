#!/bin/bash
# ------------------------------------------------------------------------------
# fullBackup.sh - Sauvegarde off-site complète (UN seul ZIP)
# ------------------------------------------------------------------------------
# Produit UN seul ZIP horodaté : fullBackups/YYYY-MM-DD_HH-MM-SS-<pid>.zip,
# mirroré off-site par Syncthing (root, sendonly) -> PC fixe -> Google Drive.
# Le suffixe secondes+pid rend le nom unique même dans la même minute.
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
#
# C16 : chiffrement age avant sync hors-site. AGE_RECIPIENT (singulier) ou
# AGE_RECIPIENTS (pluriel, virgule = rotation multi-destinataires ; le pluriel
# gagne s'il est non vide). Destinataires résolus AVANT toute publication
# (fail-fast : RECIPIENT sans binaire `age` meurt avant même de zipper).
# Sans destinataire : WARNING + ZIP clair local seul (jamais de backup clair
# hors-site silencieux). Le ZIP clair ne passe jamais par le dossier
# synchronisé sous son nom final : seul le .age 0600 y est publié.
# ------------------------------------------------------------------------------

set -euo pipefail
# C6 : ZIP à 0600 dès la création (secrets .env dans config/).
umask 077

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

command -v zip &>/dev/null || die "zip non installé."
command -v unzip &>/dev/null || die "unzip non installé (validation requise)."

# C6 : verrou monde en lecture stable courte (réentrant : no-op si la
# maintenance appelante le tient déjà). Sans lui, `latest` peut basculer
# pendant le zip (backup horaire concurrent) et le ZIP mélange deux mondes.
if declare -F acquire_world_lock >/dev/null 2>&1; then
    acquire_world_lock --required || exit 1
fi

readonly TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
readonly ARCHIVE_NAME="${TIMESTAMP}-$$.zip"
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
    # Registre des dates de création des comptes : non reconstructible (il EST la
    # mémoire de l'ancienneté des comptes) et absent des snapshots incrémentaux,
    # qui ne couvrent que Zomboid/. Sans lui dans le ZIP hors-site, une
    # restauration de machine repartirait avec tous les comptes « vus
    # aujourd'hui ».
    "${WHITELIST_LEDGER}"
)

# Reconstructible, exclu de la sauvegarde des scripts : le venv se rebâtit via
# `pzm install discord`. Sans ça, sauvegarder PZ_SCRIPTS_DIR embarquerait des
# centaines de Mo. (Les logs, eux, ne sont plus sous scripts/ mais à la racine,
# et ne figurent pas dans DIRS_TO_SYNC : exclus par omission.)
readonly SYNC_EXCLUDES=(
    --exclude ".venv/"
    --exclude "__pycache__/"
)

# C6 : source monde épinglée au début (readlink -f sous verrou monde) et
# revérifiée après le zip : si `latest` a bougé entre-temps, on refuse.
PINNED_GAME_DIR=""

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

    # C6 : config attendue présente (au moins .env ou scripts) et staging non
    # vide : un ZIP sans config ni monde n'a aucune valeur de restauration.
    if [[ ! -e "${PZ_MANAGER_DIR}/.env" && ! -e "${PZ_SCRIPTS_DIR}" ]]; then
        die "Aucune config à sauvegarder (ni ${PZ_MANAGER_DIR}/.env ni ${PZ_SCRIPTS_DIR}) : on ne produit pas de ZIP vide."
    fi
    if [[ -z "$(ls -A "$dst" 2>/dev/null)" ]]; then
        die "Staging config vide (${dst}) : on ne produit pas de ZIP vide."
    fi
}

stage_game_data() {
    # C6 : le monde est EXIGÉ. L'ancien warning + ZIP sans données de jeu
    # produisait un ZIP « réussi » inutilisable qui écrasait la rotation.
    [[ -L "${BACKUP_LATEST_LINK}" ]] \
        || die "Snapshot 'latest' invalide (${BACKUP_LATEST_LINK}) : lien attendu vers un snapshot — pas de ZIP vide."
    # Symlink vers le VRAI snapshot : `zip -r` déréférence un lien de dossier
    # (contenu réel, pas le lien) et l'archive sous zomboid/ (Saves/db/Server),
    # aplatissant du même coup les hardlinks -> ZIP autoportant pour le PC.
    local game_dir
    game_dir="$(readlink -f "${BACKUP_LATEST_LINK}")"
    [[ -n "$game_dir" && -d "$game_dir" ]] \
        || die "Snapshot 'latest' invalide (${BACKUP_LATEST_LINK}) : cible non résolue (${game_dir:-?}) — pas de ZIP vide."
    if [[ ! -d "${game_dir}/Saves" && ! -d "${game_dir}/db" && ! -d "${game_dir}/Server" ]]; then
        die "Snapshot 'latest' invalide (${game_dir}) : aucun répertoire Saves/db/Server — pas de ZIP vide."
    fi
    PINNED_GAME_DIR="$game_dir"
    ln -s "$game_dir" "${WORK}/zomboid"
}

build_archive() {
    log "Création du ZIP off-site unique : ${ARCHIVE_NAME}..."
    ensure_directory "${SYNC_BACKUPS_DIR}"
    rm -f "${TMP_ARCHIVE}"

    local members=(config)
    [[ -L "${WORK}/zomboid" ]] || die "Staging monde absent (${WORK}/zomboid) : on ne produit pas de ZIP sans données de jeu."
    members+=(zomboid)

    ( cd "${WORK}" && zip -r -q "${TMP_ARCHIVE}" "${members[@]}" )
    chmod 600 "${TMP_ARCHIVE}" || { rm -f -- "${TMP_ARCHIVE}"; die "chmod 600 impossible sur ${TMP_ARCHIVE}."; }

    # C6 : `latest` stable pendant le zip ? Sinon le ZIP mélange deux mondes.
    local current_src
    current_src="$(readlink -f "${BACKUP_LATEST_LINK}" 2>/dev/null || true)"
    if [[ "$current_src" != "$PINNED_GAME_DIR" ]]; then
        rm -f -- "${TMP_ARCHIVE}"
        die "Snapshot 'latest' a changé pendant la création (${PINNED_GAME_DIR} -> ${current_src:-?}) : ZIP rejeté, réessaie."
    fi

    # C6 : validation AVANT publication. Échec -> .partial supprimé, PAS de
    # publish ni de rotation.
    if ! unzip -t "${TMP_ARCHIVE}" >/dev/null 2>&1; then
        rm -f -- "${TMP_ARCHIVE}"
        die "ZIP invalide (${TMP_ARCHIVE}, unzip -t en échec) : rien n'est publié."
    fi
    # C16 : avec destinataires, seul le .age est publié (le clair ne porte
    # jamais son nom final) ; sinon ZIP clair historique (WARNING déjà émis).
    if (( ${#C16_AGE_ARGS[@]} > 0 )); then
        publish_encrypted_archive
        return 0
    fi
    mv -f "${TMP_ARCHIVE}" "${FINAL_ARCHIVE}"
    chmod 600 "${FINAL_ARCHIVE}" || die "chmod 600 impossible sur ${FINAL_ARCHIVE}."
    [[ "$(stat -c %a "${FINAL_ARCHIVE}" 2>/dev/null || echo ?)" == "600" ]] \
        || die "Permissions inattendues sur ${FINAL_ARCHIVE} (attendu 600)."
    log "ZIP prêt : ${FINAL_ARCHIVE} ($(du -h "${FINAL_ARCHIVE}" | cut -f1))"
}

# C16 : destinataires age résolus AVANT toute publication (fail-fast).
# La clé PRIVÉE (PZ_AGE_IDENTITY, ex. /root/.age/key en 0600 lisible par
# pzmanager seul, jamais accessible à pzgame) ne figure JAMAIS dans le backup :
# elle n'est ni lue ni embarquée ici, ce chemin reste hors backup.
C16_AGE_ARGS=()
resolve_age_recipients() {
    C16_AGE_ARGS=()
    local recipients="${AGE_RECIPIENTS:-${AGE_RECIPIENT:-}}"
    if [[ -z "${recipients//[[:space:],]/}" ]]; then
        echo "[WARNING] AGE_RECIPIENT(S) vide : ZIP clair local seul, pas de chiffrement hors-site." >&2
        return 0
    fi
    command -v age &>/dev/null || die "AGE_RECIPIENT défini mais binaire 'age' absent : pas de backup clair hors-site silencieux."
    local -a recips=()
    local r
    IFS=',' read -ra recips <<< "$recipients"
    for r in "${recips[@]}"; do
        r="${r//[[:space:]]/}"
        [[ -n "$r" ]] && C16_AGE_ARGS+=(-r "$r")
    done
    (( ${#C16_AGE_ARGS[@]} > 0 )) || die "AGE_RECIPIENT(S) sans destinataire exploitable : pas de backup clair hors-site silencieux."
}

# C16 : publie SEUL le .age chiffré (rename atomique, 0600) depuis le .partial
# clair, qui est ensuite supprimé : le clair ne porte jamais son nom final
# dans le dossier synchronisé. Échec -> .partial supprimés, RIEN publié.
publish_encrypted_archive() {
    age "${C16_AGE_ARGS[@]}" -o "${TMP_ARCHIVE}.age" "${TMP_ARCHIVE}" \
        || { rm -f -- "${TMP_ARCHIVE}" "${TMP_ARCHIVE}.age"; die "Chiffrement age en échec : rien n'est publié."; }
    chmod 600 "${TMP_ARCHIVE}.age" || { rm -f -- "${TMP_ARCHIVE}" "${TMP_ARCHIVE}.age"; die "chmod 600 impossible sur ${TMP_ARCHIVE}.age."; }
    mv -f "${TMP_ARCHIVE}.age" "${FINAL_ARCHIVE}.age"
    chmod 600 "${FINAL_ARCHIVE}.age" || die "chmod 600 impossible sur ${FINAL_ARCHIVE}.age."
    [[ "$(stat -c %a "${FINAL_ARCHIVE}.age" 2>/dev/null || echo ?)" == "600" ]] \
        || die "Permissions inattendues sur ${FINAL_ARCHIVE}.age (attendu 600)."
    rm -f -- "${TMP_ARCHIVE}"
    log "Archive chiffrée : ${FINAL_ARCHIVE}.age (ZIP clair jamais publié hors-site)."
}

cleanup_old_backups() {
    # Rétention off-site par COMPTE (pas par jours) : ces ZIP complets sont
    # mirrorés par Syncthing. Le nom horodaté YYYY-MM-DD_HH-MM-SS-<pid> trie
    # chronologiquement en lexicographique -> sort -r = du plus récent au plus vieux.
    # L'ancien format minute (YYYY-MM-DD_HH-MM.zip) reste compté pour purger
    # l'historique existant.
    local keep="${OFFSITE_BACKUP_COUNT:-7}"
    log "Nettoyage off-site : conservation des ${keep} derniers ZIP..."

    [[ -d "${SYNC_BACKUPS_DIR}" ]] || return 0

    local zips=()
    # C16 : les .age chiffrés suivent la même rotation que les ZIP clairs.
    mapfile -t zips < <(find "${SYNC_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type f \
        \( -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9].zip" \
        -o -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.zip" \
        -o -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9].zip.age" \
        -o -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.zip.age" \) | sort -r)

    local i
    for (( i = keep; i < ${#zips[@]}; i++ )); do
        rm -f -- "${zips[i]}"
        echo "  Supprimé (au-delà des ${keep}) : $(basename "${zips[i]}")"
    done

    # C6 : les anciens backups au format DOSSIER (fullBackups/<ts>/) ne sont
    # JAMAIS supprimés par ce workflow sauf opt-in explicite : une purge
    # silencieuse ici détruisait un autre format de sauvegarde.
    if [[ "${PZ_PURGE_LEGACY:-0}" != "1" ]]; then
        return 0
    fi
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
resolve_age_recipients
build_archive
cleanup_old_backups

# C16 : le message final cite l'artefact réellement publié (.age ou ZIP clair).
if (( ${#C16_AGE_ARGS[@]} > 0 )); then
    log "Backup off-site terminé : ${FINAL_ARCHIVE}.age"
else
    log "Backup off-site terminé : ${FINAL_ARCHIVE}"
fi
