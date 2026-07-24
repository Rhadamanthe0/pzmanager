#!/bin/bash
# ------------------------------------------------------------------------------
# dataBackup.sh - Incremental Zomboid data backup
# ------------------------------------------------------------------------------
# Backs up Saves/, db/, Server/ with hardlinks (rsync --link-dest)
# Triggers in-game save if server is running
# Rétention GFS (prune_gfs) : horaire récent, puis 6h, puis journalier (voir .env)
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Valider répertoires
validate_directory "${PZ_SOURCE_DIR}" "Répertoire source Zomboid"
ensure_directory "${BACKUP_DIR}"

# Trigger in-game save if server is running
if [[ -p "${PZ_CONTROL_PIPE}" ]]; then
    if timeout 10 bash -c "echo 'save' > '${PZ_CONTROL_PIPE}'" 2>/dev/null; then
        sleep 60
    else
        echo "Warning: Could not send save command (pipe timeout or server not responding)"
    fi
fi

readonly TIMESTAMP=$(date +"%Y-%m-%d_%Hh%Mm%Ss")
readonly BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"

echo "Backing up to ${BACKUP_PATH}..."

rsync_opts=(-a --delete --partial)
[[ -d "${BACKUP_LATEST_LINK}" ]] && rsync_opts+=(--link-dest="${BACKUP_LATEST_LINK}")

cd "${PZ_SOURCE_DIR}"

# Build list of directories to backup (skip missing ones)
backup_dirs=()
for dir in Saves db Server; do
    [[ -d "$dir" ]] && backup_dirs+=("$dir")
done

if [[ ${#backup_dirs[@]} -eq 0 ]]; then
    echo "Error: No directories to backup in ${PZ_SOURCE_DIR}"
    exit 1
fi

# rsync est bridé en CPU (systemd CPUQuota) : il peut donc être plus lent, et un
# aléa I/O transitoire ne doit pas perdre le snapshot. On retente jusqu'à 3 fois ;
# --partial (dans rsync_opts) conserve les fichiers déjà transférés d'une tentative
# à l'autre, donc une reprise ne recopie que ce qui manque.
readonly RSYNC_MAX_ATTEMPTS=3
rsync_status=0
for (( attempt = 1; attempt <= RSYNC_MAX_ATTEMPTS; attempt++ )); do
    rsync_status=0
    rsync "${rsync_opts[@]}" --relative "${backup_dirs[@]}" "${BACKUP_PATH}" || rsync_status=$?

    # 0 = OK. On sauvegarde un monde VIVANT : PZ écrit/consolide ses chunks de
    # carte en continu, donc un fichier listé par rsync peut disparaître avant
    # d'être copié. rsync le signale par le code 24 (fichiers disparus) ou 23
    # (transfert partiel, ex. « open .../map/NN/NNN.bin: No such file »). Ces
    # deux cas sont bénins et ne se « réparent » pas par une reprise (le fichier
    # a disparu à la source) : on les accepte tels quels sans retenter.
    if (( rsync_status == 0 || rsync_status == 23 || rsync_status == 24 )); then
        break
    fi

    echo "Warning: rsync a échoué (code ${rsync_status}), nouvelle tentative ${attempt}/${RSYNC_MAX_ATTEMPTS} dans 5s..."
    sleep 5
done

if (( rsync_status == 23 || rsync_status == 24 )); then
    echo "Warning: rsync a ignoré des fichiers disparus pendant la copie (code ${rsync_status}) — normal sur un monde en cours, snapshot conservé."
elif (( rsync_status != 0 )); then
    die "rsync a échoué après ${RSYNC_MAX_ATTEMPTS} tentatives (code ${rsync_status})."
fi

rm -rf "${BACKUP_LATEST_LINK}"
ln -s "${BACKUP_PATH}" "${BACKUP_LATEST_LINK}"

# Rétention grand-père/père/fils (GFS). Remplace l'ancienne rotation plate à N
# jours. Chaque snapshot étant complet et indépendant (hardlinks --link-dest),
# en supprimer un ne touche jamais les données des autres. On garde :
#   - une granularité HORAIRE sur les dernières BACKUP_GFS_HOURLY_HOURS heures ;
#   - 1 snapshot par fenêtre de 6 h jusqu'à BACKUP_GFS_SIXHOURLY_DAYS jours ;
#   - 1 snapshot par jour jusqu'à BACKUP_GFS_DAILY_DAYS jours ;
#   - au-delà : supprimé.
# On traite du plus récent au plus ancien et on garde le 1er de chaque bucket
# (= le plus récent de la fenêtre). BACKUP_PRUNE_DRY_RUN=1 => plan seul, sans rien
# supprimer (pour inspecter la rétention sur un serveur vivant).
prune_gfs() {
    local hourly_h="${BACKUP_GFS_HOURLY_HOURS:-24}"
    local sixh_d="${BACKUP_GFS_SIXHOURLY_DAYS:-7}"
    local daily_d="${BACKUP_GFS_DAILY_DAYS:-30}"
    local dry="${BACKUP_PRUNE_DRY_RUN:-0}"
    local now; now=$(date +%s)
    local -A seen_bucket=()
    local entries=() d name ts epoch
    for d in "${BACKUP_DIR}"/backup_*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        # backup_2026-07-24_22h57m54s -> 2026-07-24 22:57:54
        ts=${name#backup_}
        ts=${ts/_/ }; ts=${ts/h/:}; ts=${ts/m/:}; ts=${ts%s}
        epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
        entries+=("$epoch|$name")
    done
    (( ${#entries[@]} == 0 )) && return 0

    local sorted=() kept=0 dropped=0 e age bucket
    mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1nr)
    for e in "${sorted[@]}"; do
        epoch=${e%%|*}; name=${e#*|}
        age=$(( now - epoch ))
        if (( age <= hourly_h * 3600 )); then
            kept=$(( kept + 1 )); continue
        elif (( age <= sixh_d * 86400 )); then
            bucket="6h_$(( epoch / 21600 ))"
        elif (( age <= daily_d * 86400 )); then
            bucket="d_$(( epoch / 86400 ))"
        else
            bucket="expired"
        fi
        if [[ "$bucket" != "expired" && -z "${seen_bucket[$bucket]:-}" ]]; then
            seen_bucket[$bucket]=1; kept=$(( kept + 1 )); continue
        fi
        dropped=$(( dropped + 1 ))
        if [[ "$dry" == "1" ]]; then
            echo "DRY-RUN prune: ${name}"
        else
            rm -rf -- "${BACKUP_DIR:?}/${name}"
        fi
    done
    echo "Rétention GFS : ${kept} gardés, ${dropped} supprimés (${hourly_h}h horaires / ${sixh_d}j@6h / ${daily_d}j daily)."
}

prune_gfs

total_count=$(find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" | wc -l)
echo "Backup completed. Total: $total_count snapshots."
