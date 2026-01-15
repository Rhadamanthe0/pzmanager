#!/bin/bash
# ------------------------------------------------------------------------------
# pz.sh - Gestion du serveur Project Zomboid
# ------------------------------------------------------------------------------
# Usage: ./pz.sh <start|stop|restart|status> [délai] [--silent]
# Délais: 30m|15m|5m|2m|30s|now (défaut: 2m)
#
# Actions:
#   start   - Démarre le serveur
#   stop    - Arrête avec avertissements, sauvegarde, notif Discord
#   restart - Redémarre avec avertissements, sauvegarde, notif Discord
#   status  - Affiche l'état du serveur et derniers logs journald
#
# Options:
#   --silent - Désactive les notifications Discord
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly ACTION="${1:-}"
DELAY="${2:-2m}"
SILENT_MODE=false

# Valider DELAY immédiatement
if [[ "$DELAY" != "now" ]] && [[ ! "$DELAY" =~ ^(30m|15m|5m|2m|30s)$ ]]; then
    echo "Erreur: Délai invalide '$DELAY'" >&2
    echo "Délais valides: 30m, 15m, 5m, 2m, 30s, now" >&2
    exit 1
fi

# Parse arguments pour détecter --silent
for arg in "$@"; do
    if [[ "$arg" == "--silent" ]]; then
        SILENT_MODE=true
    fi
done

send_discord() {
    [[ "$SILENT_MODE" == true ]] && return 0
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "$1"
}

send_msg() {
    "${SCRIPT_DIR}/../internal/sendCommand.sh" "servermsg \"$1\"" --no-output
    send_discord "$1"
}

warn_players() {
    local action_type="$1"

    [[ "$DELAY" == "now" ]] && return 0

    if ! systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        echo "Serveur non actif, pas d'avertissements."
        return 0
    fi

    local -A sequences=(
        ["30m"]="30_MINUTES:900 15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["15m"]="15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["5m"]="5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["2m"]="2_MINUTES:90 30_SECONDES:30"
        ["30s"]="30_SECONDES:30"
    )

    [[ -z "${sequences[$DELAY]:-}" ]] && { echo "Délai invalide: $DELAY" >&2; exit 1; }

    echo "Envoi des avertissements ($DELAY)..."
    for entry in ${sequences[$DELAY]}; do
        local time_label="${entry%%:*}"
        time_label="${time_label//_/ }"
        local wait_seconds="${entry##*:}"
        send_msg "ATTENTION : ${action_type} DU SERVEUR DANS ${time_label} !"
        sleep "$wait_seconds"
    done
    send_msg "${action_type} DU SERVEUR"
    sleep 5
}

do_start() {
    echo "Démarrage du service..."
    systemctl --user start "${PZ_SERVICE_NAME}"
    echo "Terminé."
}

do_stop() {
    warn_players "ARRET"

    if systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        echo "Arrêt du service..."
        systemctl --user stop "${PZ_SERVICE_NAME}"
        sleep 5
    fi

    echo "Sauvegarde..."
    "${SCRIPT_DIR}/../backup/dataBackup.sh"
    echo "Terminé."
}

do_restart() {
    warn_players "REDEMARRAGE"

    echo "Arrêt du service..."
    systemctl --user stop "${PZ_SERVICE_NAME}"
    sleep 5

    echo "Sauvegarde..."
    "${SCRIPT_DIR}/../backup/dataBackup.sh"

    echo "Démarrage du service..."
    systemctl --user start "${PZ_SERVICE_NAME}"
    echo "Terminé."
}

do_status() {
    echo "=== Project Zomboid Server Status ==="
    echo ""

    # État du service
    if systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        echo "Status: RUNNING"

        # Uptime
        local active_since=$(systemctl --user show "${PZ_SERVICE_NAME}" -p ActiveEnterTimestamp --value)
        echo "Active since: $active_since"

        # Pipe de contrôle
        if [[ -p "${PZ_CONTROL_PIPE}" ]]; then
            echo "Control pipe: Available"
        else
            echo "Control pipe: Not available"
        fi
    else
        echo "Status: STOPPED"

        # Raison du dernier arrêt
        local result=$(systemctl --user show "${PZ_SERVICE_NAME}" -p Result --value)
        [[ "$result" != "success" ]] && echo "Last exit: $result"
    fi

    # Info dernière sauvegarde
    if [[ -L "${BACKUP_LATEST_LINK}" ]]; then
        local backup_time=$(stat -c %y "${BACKUP_LATEST_LINK}" | cut -d' ' -f1,2 | cut -d. -f1)
        echo "Last backup: $backup_time"
    fi

    # Logs récents
    echo ""
    echo "=== Recent Logs (last 30 lines) ==="
    journalctl --user -u "${PZ_SERVICE_NAME}" -n 30 --no-pager
}

case "$ACTION" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    *)
        echo "Usage: $0 <start|stop|restart|status> [délai]"
        echo "Délais: 30m|15m|5m|2m|30s|now (défaut: 2m)"
        exit 1
        ;;
esac
