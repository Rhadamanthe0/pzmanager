#!/bin/bash
# pz.sh - Gestion du serveur Project Zomboid
# Usage: ./pz.sh <start|stop|restart|status> [délai] [--silent]
# Lock partagé avec modcheck/maintenance pour éviter les conflits

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly ACTION="${1:-}"
DELAY="${2:-2m}"
SILENT_MODE=false

# Validate delay
[[ "$DELAY" =~ ^(30m|15m|5m|2m|30s|now)$ ]] || {
    echo "Délais valides: 30m, 15m, 5m, 2m, 30s, now" >&2
    exit 1
}

# Parse --silent
for arg in "$@"; do [[ "$arg" == "--silent" ]] && SILENT_MODE=true; done

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
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" || return 0

    local -A delays=(
        ["30m"]="30_MINUTES:900 15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["15m"]="15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["5m"]="5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["2m"]="2_MINUTES:90 30_SECONDES:30"
        ["30s"]="30_SECONDES:30"
    )

    echo "Envoi des avertissements ($DELAY)..."
    local first=true
    for entry in ${delays[$DELAY]}; do
        local label="${entry%%:*}" secs="${entry##*:}"
        local msg="ATTENTION : ${action_type} DU SERVEUR DANS ${label//_/ } !"
        if $first; then
            "${SCRIPT_DIR}/../internal/sendCommand.sh" "servermsg \"$msg\"" --no-output
            send_discord "@here $msg"
            first=false
        else
            send_msg "$msg"
        fi
        sleep "$secs"
    done
    send_msg "${action_type} DU SERVEUR"
    sleep 5
}

shutdown_server() {
    local action="$1"
    try_acquire_maintenance_lock || true

    if [[ "$DELAY" == "now" ]]; then
        send_discord "@here ${action} IMMÉDIAT DU SERVEUR"
    else
        warn_players "$action"
    fi

    if systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        echo "Arrêt du service..."
        systemctl --user stop "${PZ_SERVICE_NAME}"
        sleep 5
    fi

    echo "Sauvegarde..."
    "${SCRIPT_DIR}/../backup/dataBackup.sh"
}

do_start() {
    echo "Démarrage du service..."
    systemctl --user start "${PZ_SERVICE_NAME}"
    echo "Terminé."
}

do_stop() {
    shutdown_server "ARRÊT"
    echo "Terminé."
}

do_restart() {
    shutdown_server "REDÉMARRAGE"
    echo "Démarrage du service..."
    systemctl --user start "${PZ_SERVICE_NAME}"
    echo "Terminé."
}

do_status() {
    echo "=== Project Zomboid Server Status ==="
    echo ""

    if systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        echo "Status: RUNNING"
        echo "Active since: $(systemctl --user show "${PZ_SERVICE_NAME}" -p ActiveEnterTimestamp --value)"
        [[ -p "${PZ_CONTROL_PIPE}" ]] && echo "Control pipe: Available" || echo "Control pipe: Not available"
    else
        echo "Status: STOPPED"
        local result=$(systemctl --user show "${PZ_SERVICE_NAME}" -p Result --value)
        [[ "$result" != "success" ]] && echo "Last exit: $result"
    fi

    [[ -L "${BACKUP_LATEST_LINK}" ]] && echo "Last backup: $(stat -c %y "${BACKUP_LATEST_LINK}" | cut -d. -f1)"

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
