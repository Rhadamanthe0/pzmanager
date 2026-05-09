#!/bin/bash
# pz.sh - Gestion du serveur Project Zomboid
# Usage: ./pz.sh <start|stop|restart|status> [délai] [options]
# Options: --reason=TEXT, --automatic, --silent
# Lock partagé avec modcheck/maintenance pour éviter les conflits

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly ACTION="${1:-}"
DELAY="${2:-2m}"
SILENT_MODE=false
REASON=""
IS_AUTOMATIC=false

# Validate delay
[[ "$DELAY" =~ ^(30m|15m|5m|2m|30s|now)$ ]] || {
    echo "Délais valides: 30m, 15m, 5m, 2m, 30s, now" >&2
    exit 1
}

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --automatic)
            IS_AUTOMATIC=true
            shift
            ;;
        --reason)
            REASON="$2"
            shift 2
            ;;
        --reason=*)
            REASON="${1#--reason=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

send_discord() {
    [[ "$SILENT_MODE" == true ]] && return 0
    "${SCRIPT_DIR}/../internal/sendDiscord.sh" "$1"
}

send_msg() {
    "${SCRIPT_DIR}/../internal/sendCommand.sh" servermsg "$1" --no-output
    send_discord "$1"
}

format_context() {
    local action="$1"
    local msg="$action"

    if [[ -n "$REASON" ]]; then
        if [[ "$IS_AUTOMATIC" == true ]]; then
            msg="$msg (Lancé automatiquement - $REASON)"
        else
            msg="$msg (Lancé manuellement - $REASON)"
        fi
    elif [[ "$IS_AUTOMATIC" == true ]]; then
        msg="$msg (Lancé automatiquement)"
    fi
    echo "$msg"
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
    local context_msg=$(format_context "$action_type")
    local first=true
    for entry in ${delays[$DELAY]}; do
        local label="${entry%%:*}" secs="${entry##*:}"
        local simple_msg="ATTENTION : ${action_type} DANS ${label//_/ } !"
        local context_suffix=""

        # Add context only to first message and only if reason/automatic
        if $first && ([[ -n "$REASON" ]] || [[ "$IS_AUTOMATIC" == true ]]); then
            # Extract context without the action type (already in message)
            local reason_part="$REASON"
            if [[ "$IS_AUTOMATIC" == true ]]; then
                if [[ -z "$REASON" ]]; then
                    reason_part="Lancé automatiquement"
                else
                    reason_part="Lancé automatiquement - $REASON"
                fi
            else
                reason_part="Lancé manuellement - $REASON"
            fi
            context_suffix=" ($reason_part)"
        fi

        if $first; then
            # First warning with @here and context
            "${SCRIPT_DIR}/../internal/sendCommand.sh" servermsg "$simple_msg$context_suffix" --no-output
            send_discord "@here $simple_msg$context_suffix"
            first=false
        else
            # Subsequent warnings: simple message only
            send_msg "$simple_msg"
        fi
        sleep "$secs"
    done
    # Final message: action with context
    send_msg "$context_msg"
    sleep 5
}

shutdown_server() {
    local action="$1"
    try_acquire_maintenance_lock || true

    if [[ "$DELAY" == "now" ]]; then
        local context_msg=$(format_context "$action IMMÉDIAT")
        send_discord "@here $context_msg"
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
    if [[ -n "$REASON" ]]; then
        local context_msg=$(format_context "Serveur démarré")
        send_discord "$context_msg"
    fi
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
        echo "Usage: $0 <start|stop|restart|status> [délai] [options]"
        echo "Délais: 30m|15m|5m|2m|30s|now (défaut: 2m)"
        echo "Options:"
        echo "  --reason=TEXT   Raison de l'action (ex: 'Maintenance', 'Mods')"
        echo "  --automatic     Marquer l'action comme automatique"
        echo "  --silent        Supprimer les messages Discord"
        exit 1
        ;;
esac
