#!/usr/bin/env bash
# Annonce Discord uniquement après la première frame de la boucle de jeu.
# Le marqueur "*** SERVER STARTED ****" (f:0) ne suffit pas en B42.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# ProtectSystem=strict rend la racine pzmanager non inscriptible. Le sous-dossier
# logs est explicitement autorisé par ReadWritePaths=zomboid.service, persistant
# pendant les reboots machine et exclu du nettoyage de captureLogs.sh.
readonly SILENT_FLAG="${PZ_MANAGER_DIR}/logs/.silent_next_start"
readonly LEGACY_SILENT_FLAG="${PZ_MANAGER_DIR}/.silent_next_start"
readonly LEGACY_CONSUMED_FLAG="${PZ_MANAGER_DIR}/logs/.legacy_silent_next_start_consumed"
# Les démarrages moddés sains peuvent durer plus de 40 minutes.
readonly READY_TIMEOUT="${PZ_NOTIFY_READY_TIMEOUT:-3600}"
readonly POLL_INTERVAL="${PZ_NOTIFY_READY_POLL_INTERVAL:-5}"

if [[ ! "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || \
   (( ${#READY_TIMEOUT} > 5 )) || (( 10#$READY_TIMEOUT > 86400 )); then
    echo "[pz-ready] PZ_NOTIFY_READY_TIMEOUT invalide (1..86400 s)." >&2
    exit 1
fi
if [[ ! "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || \
   (( ${#POLL_INTERVAL} > 2 )) || (( 10#$POLL_INTERVAL > 30 )); then
    echo "[pz-ready] PZ_NOTIFY_READY_POLL_INTERVAL invalide (1..30 s)." >&2
    exit 1
fi

# Capturer l'invocation du démarrage courant. Sans identité vérifiable,
# refuser d'annoncer une disponibilité potentiellement périmée.
unit_invocation="$(systemctl --user show "${PZ_SERVICE_NAME}" -p InvocationID --value 2>/dev/null)" || {
    echo "[pz-ready] Impossible de lire l'InvocationID de ${PZ_SERVICE_NAME}." >&2
    exit 1
}
readonly BOOT_ID="${INVOCATION_ID:-$unit_invocation}"
if [[ -z "$BOOT_ID" || "$unit_invocation" != "$BOOT_ID" ]]; then
    echo "[pz-ready] Invocation absente ou remplacée : notification annulée." >&2
    exit 0
fi
if [[ ! "$BOOT_ID" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo "[pz-ready] InvocationID malformé : notification annulée." >&2
    exit 1
fi

# Verrou par invocation, non un cooldown global de cinq minutes : deux boots
# rapprochés ont chacun droit à leur annonce. Le fichier conserve l'envoi réussi.
umask 077
# Réutiliser le résolveur du démarrage, adapté aux propriétaires remappés par
# le confinement systemd, sans acquérir WORLD ni assouplir common.sh.
# Le répertoire final reste privé, possédé par cet UID et sans lien symbolique.
# Le chemin /tmp/pzmanager non personnalisé n'est pas sûr en mode dégradé.
LOCK_FILE="$(python3 "${SCRIPT_DIR}/writing_start_admission.py" path --name "notify-ready-${BOOT_ID}.lock")" || {
    echo "[pz-ready] Chemin privé ou fichier de verrou invalide (permissions ou lien)." >&2
    exit 1
}
readonly LOCK_FILE
# Un fichier déjà présent ne doit pas rediriger l'ouverture du verrou.
if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
    if [[ ! -f "$LOCK_FILE" || -L "$LOCK_FILE" || ! -O "$LOCK_FILE" ]] ||
       [[ "$(stat -c %h -- "$LOCK_FILE" 2>/dev/null)" != 1 ]]; then
        echo "[pz-ready] Fichier de verrou invalide (lien ou propriétaire)." >&2
        exit 1
    fi
fi
exec {LOCK_FD}<>"$LOCK_FILE"
flock -n "$LOCK_FD" || exit 0
if grep -qxF "$BOOT_ID" "$LOCK_FILE" 2>/dev/null; then
    exit 0
fi

# Une notification du boot précédent ne doit jamais partir après un restart.
same_running_boot() {
    local properties key value state="" invocation=""
    properties="$(systemctl --user show "${PZ_SERVICE_NAME}" \
        -p ActiveState -p InvocationID --no-pager 2>/dev/null)" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState) state="$value" ;;
            InvocationID) invocation="$value" ;;
        esac
    done <<< "$properties"
    [[ "$invocation" == "$BOOT_ID" ]] && [[ "$state" == active || "$state" == activating ]]
}

if ! same_running_boot; then
    echo "[pz-ready] Service arrêté ou invocation remplacée avant l'attente." >&2
    exit 0
fi

# Après authentification de l'invocation et acquisition du verrou, un
# démarrage silencieux est marqué comme consommé. Une seconde exécution pour la
# même invocation ne doit pas envoyer une annonce après consommation du drapeau.
if [[ -f "$SILENT_FLAG" ]]; then
    rm -f -- "$SILENT_FLAG"
    if [[ -f "$LEGACY_SILENT_FLAG" ]]; then
        : > "$LEGACY_CONSUMED_FLAG"
    fi
    printf '%s\n' "$BOOT_ID" > "$LOCK_FILE"
    exit 0
fi
if [[ -f "$LEGACY_SILENT_FLAG" && ! -f "$LEGACY_CONSUMED_FLAG" ]]; then
    : > "$LEGACY_CONSUMED_FLAG"
    echo "[pz-ready] Ancien marqueur de maintenance consommé une fois (nettoyage hors sandbox requis)." >&2
    printf '%s\n' "$BOOT_ID" > "$LOCK_FILE"
    exit 0
fi

# Ne suivre QUE l'invocation courante, sans borne temporelle à la seconde :
# lors d'un restart rapproché, --since pourrait inclure une frame de l'ancien boot.
# -n all rejoue aussi les frames déjà émises avant le lancement du lecteur.
# Lecture en flux filtrée dans journald : ne pas rescanner tout le journal
# toutes les cinq secondes (des milliers de lignes pendant le chargement).
JOURNAL_PID=""
JOURNAL_FD=""
cleanup() {
    if [[ -n "$JOURNAL_FD" ]]; then
        exec {JOURNAL_FD}<&- 2>/dev/null || true
    fi
    if [[ -n "$JOURNAL_PID" ]]; then
        kill "$JOURNAL_PID" 2>/dev/null || true
        wait "$JOURNAL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 0' TERM INT
exec {JOURNAL_FD}< <(
    # Les journaux d'unités utilisateur peuvent avoir INVOCATION_ID mais
    # pas _SYSTEMD_INVOCATION_ID. Reprendre le OU de captureLogs.sh.
    # L'ID reste celui du démarrage courant, pas une fenêtre horodatée.
    journalctl -n all --follow --no-pager -o cat \
        "INVOCATION_ID=${BOOT_ID}" + "_SYSTEMD_INVOCATION_ID=${BOOT_ID}" \
        --grep 'f:[1-9][0-9]* st:'
)
JOURNAL_PID=$!

deadline=$((SECONDS + READY_TIMEOUT))
while (( SECONDS < deadline )); do
    if ! same_running_boot; then
        echo "[pz-ready] Attente annulée : serveur arrêté ou redémarré." >&2
        exit 0
    fi

    result=0
    line=""
    IFS= read -r -t "$POLL_INTERVAL" -u "$JOURNAL_FD" line || result=$?
    if (( result == 0 )); then
        [[ "$line" =~ f:[1-9][0-9]*[[:space:]]st: ]] || continue
        if ! same_running_boot; then
            echo "[pz-ready] Démarrage remplacé avant l'annonce : abandon." >&2
            exit 0
        fi
        if "${SCRIPT_DIR}/sendDiscord.sh" \
                "Le serveur Project Zomboid est en ligne !" --strict; then
            printf '%s\n' "$BOOT_ID" > "$LOCK_FILE"
            echo "[pz-ready] Notification de disponibilité envoyée." >&2
            exit 0
        fi
        echo "[pz-ready] Échec de la notification Discord de disponibilité." >&2
        exit 1
    fi
    # Bash read -t : un dépassement d'attente rend >128 ; EOF rend 1.
    if (( result <= 128 )); then
        echo "[pz-ready] Le suivi journald s'est terminé avant la première frame." >&2
        exit 1
    fi
done

echo "[pz-ready] Aucune frame après ${READY_TIMEOUT}s : annonce abandonnée." >&2
exit 1
