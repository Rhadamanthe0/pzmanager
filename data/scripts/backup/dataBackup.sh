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
source_env

# --snapshot-only : crée un snapshot NORMAL (backup_<ts>, comme le backup horaire)
# sans déclencher la sauvegarde in-game ni le prune GFS. Utilisé par les opérations
# destructrices (purge whitelist, wipe de tuiles) pour se garder un filet de sécurité
# = un vrai snapshot (visible dans `pzm backup list`, purgé par le timer horaire),
# au lieu d'un dossier à part bizarrement nommé. On saute le save (serveur arrêté /
# en cours de boot dans ces cas) et le prune (laissé au timer horaire, pour ne pas
# traîner des centaines d'unlink() dans le chemin d'un ExecStartPre / d'un wipe).
SNAPSHOT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --snapshot-only) SNAPSHOT_ONLY=1 ;;
        *) die "Option inconnue: $arg (seul --snapshot-only est accepté)" ;;
    esac
done

# Valider répertoires
validate_directory "${PZ_SOURCE_DIR}" "Répertoire source Zomboid"
ensure_directory "${BACKUP_DIR}"

# Verrou d'instance unique. Un run peut durer longtemps (le prune GFS d'un gros
# backlog de snapshots hardlinkés se compte en dizaines de minutes/heures), donc
# le timer horaire pourrait relancer un backup alors que le précédent tourne
# encore — ou un lancement manuel se superposer. flock non-bloquant : si un backup
# tient déjà le verrou, on skippe proprement ce run (exit 0) au lieu de paralléliser
# deux rsync/rm sur le même arbre. Le verrou est tenu (fd 201) jusqu'à la fin du
# script ; libéré automatiquement si le process est tué (timeout systemd inclus).
readonly BACKUP_LOCK_FILE="/tmp/pzmanager-backup-$(id -un).lock"
exec 201>"${BACKUP_LOCK_FILE}"
if ! flock -n 201; then
    echo "Un backup est déjà en cours (${BACKUP_LOCK_FILE}) — run ignoré."
    exit 0
fi

# Trigger in-game save if server is running (sauté en --snapshot-only : le serveur
# est arrêté / en cours de boot, il n'y a personne pour lire le pipe).
#
# ⚠ NE PAS SUPPRIMER CE SAVE. Depuis le 2026-08-16, `SaveWorldEveryMinutes=0`
# dans servertest.ini : le serveur n'écrit plus le monde périodiquement de
# lui-même, ce `save` horaire est donc la SEULE sauvegarde sur disque entre deux
# arrêts propres. Le retirer ferait perdre tout le monde depuis le démarrage au
# prochain gel dur de la box / OOM heap (mort non propre = pas d'ExecStop).
# Pourquoi 0 : chaque save fige la boucle principale (`ServerMap.SaveAll` est
# synchrone) et PZ met alors les clients en pause au-delà de 600 ms
# (« Pausing clients because saving is taking longer than 600ms » dans le log)
# -> micro-lag ressenti par tous les joueurs. À 5 min c'était 12 saves/heure ;
# à 0 il n'en reste qu'un (celui-ci), au prix d'un RPO d'une heure — assouplir
# le RPO était une décision admin explicite.
if [[ "$SNAPSHOT_ONLY" != "1" && -p "${PZ_CONTROL_PIPE}" ]]; then
    # Préavis joueurs : le gel étant inévitable, on l'annonce pour qu'il soit
    # attendu plutôt que subi (0 = pas de préavis ni d'attente). On écrit
    # directement dans le FIFO comme pour le `save` ci-dessous, sans passer par
    # sendCommand.sh : celui-ci rescrape journald pour récupérer la sortie de la
    # commande, ce qui coûte plusieurs secondes ici pour rien.
    #
    # UN SEUL message, EN JEU UNIQUEMENT : pas de send_discord (contrairement à
    # pz.sh, qui double ses avertissements sur le webhook) — une notification
    # Discord toutes les heures pour un gel d'une seconde serait du bruit. Et pas
    # de marqueur au déclenchement non plus : le préavis suffit.
    #
    # Gabarit repris de warn_players() dans core/pz.sh pour rester cohérent avec
    # les avertissements d'arrêt/redémarrage : « ATTENTION : <ACTION> DANS
    # <durée> ! » en majuscules. Le délai est interpolé pour que le texte suive
    # BACKUP_WARN_DELAY au lieu de mentir si on le change.
    warn_delay="${BACKUP_WARN_DELAY:-10}"
    if (( warn_delay > 0 )); then
        warn_msg="ATTENTION : SAUVEGARDE DANS ${warn_delay} SECONDES !"
        # Message passé en ARGUMENT, jamais interpolé dans la chaîne `bash -c` :
        # ça met le quoting à l'abri quel que soit le texte (une apostrophe dans
        # le message casserait la chaîne mono-quotée).
        if ! timeout 10 bash -c 'printf "servermsg \"%s\"\n" "$1" > "$2"' _ "$warn_msg" "${PZ_CONTROL_PIPE}" 2>/dev/null; then
            echo "Warning: préavis joueurs non envoyé (pipe timeout ou serveur muet) — on sauvegarde quand même."
        fi
        sleep "$warn_delay"
    fi

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
    # Plafond de suppressions par run (0 = illimité). Supprimer un snapshot hardlinké
    # = des centaines de milliers d'unlink() ; à CPUQuota 20% c'est lent. On borne
    # donc chaque run pour qu'il finisse dans le TimeoutStartSec de l'unité (pas de
    # kill/failed), et un gros backlog s'écoule proprement sur plusieurs runs horaires.
    local max_delete="${BACKUP_PRUNE_MAX_DELETE:-0}"
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
        if (( max_delete > 0 && dropped >= max_delete )); then
            echo "Prune plafonné à ${max_delete} suppressions ce run — backlog restant traité aux runs suivants."
            break
        fi
    done
    echo "Rétention GFS : ${kept} gardés, ${dropped} supprimés ce run (${hourly_h}h horaires / ${sixh_d}j@6h / ${daily_d}j daily)."
}

if [[ "$SNAPSHOT_ONLY" == "1" ]]; then
    echo "Snapshot ponctuel créé (prune GFS laissé au timer horaire) : ${BACKUP_PATH}"
else
    prune_gfs
fi

total_count=$(find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" | wc -l)
echo "Backup completed. Total: $total_count snapshots."
