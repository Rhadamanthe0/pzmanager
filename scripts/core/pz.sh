#!/bin/bash
# pz.sh - Gestion du serveur Project Zomboid
# Usage: ./pz.sh <start|stop|restart|status> [délai] [options]
# Options: --reason TEXT, --maintenance, --automatic, --silent
# Lock partagé avec modcheck/maintenance pour éviter les conflits

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly ACTION="${1:-}"
SILENT_MODE=false
REASON=""
IS_AUTOMATIC=false
IS_MAINTENANCE=false

# Delay: use $2 only if it's an explicit delay token, otherwise "auto".
# "auto" is resolved from the connected-player count at shutdown time
# (>=2 joueurs -> 5m, 1 joueur -> 2m, 0 joueur -> now). This also lets
# `restart --reason "..."` work without a leading delay token.
if [[ -n "${2:-}" && "$2" =~ ^(30m|15m|5m|2m|30s|now|auto)$ ]]; then
    DELAY="$2"
else
    DELAY="auto"
fi

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
        --maintenance)
            IS_MAINTENANCE=true
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

# Nombre de joueurs actuellement connectés (0 si serveur arrêté / indéterminé).
count_connected_players() {
    server_is_active || { echo 0; return; }
    local out n
    out="$("${SCRIPT_DIR}/../internal/sendCommand.sh" players 2>/dev/null || true)"
    n="$(printf '%s\n' "$out" | grep -oE 'Players connected \([0-9]+\)' | grep -oE '[0-9]+' | head -1)"
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Mappe un nombre de joueurs vers un délai :
#   >=2 -> 5m, 1 -> 2m, 0 -> now (aucun avertissement).
delay_for_player_count() {
    local n="$1"
    if   (( n >= 2 )); then echo "5m"
    elif (( n == 1 )); then echo "2m"
    else                    echo "now"
    fi
}

# Envoie le même message en jeu et sur Discord. $2 = préfixe Discord seulement
# (ex. "@here "), qui n'a pas de sens dans le chat du serveur.
send_msg() {
    local msg="$1" discord_prefix="${2:-}"
    "${SCRIPT_DIR}/../internal/sendCommand.sh" servermsg "$msg" --no-output
    send_discord "${discord_prefix}${msg}"
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
    server_is_active || return 0

    local -A delays=(
        ["30m"]="30_MINUTES:900 15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["15m"]="15_MINUTES:600 5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["5m"]="5_MINUTES:180 2_MINUTES:90 30_SECONDES:30"
        ["2m"]="2_MINUTES:90 30_SECONDES:30"
        ["30s"]="30_SECONDES:30"
    )

    echo "Envoi des avertissements ($DELAY)..."

    # Determine display action type
    local display_action="$action_type"
    if [[ "$IS_MAINTENANCE" == true ]]; then
        display_action="MAINTENANCE"
    fi

    local first=true
    for entry in ${delays[$DELAY]}; do
        local label="${entry%%:*}" secs="${entry##*:}"
        local simple_msg="ATTENTION : ${display_action} DANS ${label//_/ } !"

        if $first; then
            # Premier avertissement : @here + le motif. format_context "" rend
            # le suffixe seul (vide si ni motif ni --automatic).
            send_msg "${simple_msg}$(format_context "")" "@here "
            first=false
        else
            # Avertissements suivants : message simple, sans ping ni motif.
            send_msg "$simple_msg"
        fi
        sleep "$secs"
    done

    # Final message: depends on action type
    if [[ "$IS_MAINTENANCE" == true ]]; then
        send_msg "DÉBUT MAINTENANCE"
    else
        local context_msg=$(format_context "$display_action")
        send_msg "$context_msg"
    fi
    sleep 5
}

shutdown_server() {
    local action="$1"
    try_acquire_maintenance_lock || true

    # Délai automatique selon le nombre de joueurs connectés
    if [[ "$DELAY" == "auto" ]]; then
        local players; players="$(count_connected_players)"
        DELAY="$(delay_for_player_count "$players")"
        echo "Délai auto (${players} joueur(s) connecté(s)) → $DELAY"
    fi

    if [[ "$DELAY" == "now" ]]; then
        local context_msg=$(format_context "$action IMMÉDIAT")
        send_discord "@here $context_msg"
    else
        warn_players "$action"
    fi

    if server_is_active; then
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
    # Only send message if started with reason but NOT a maintenance
    # (maintenance already sends DÉBUT MAINTENANCE before shutdown)
    if [[ -n "$REASON" ]] && [[ "$IS_MAINTENANCE" != true ]]; then
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

    if server_is_active; then
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
        echo "Délais: 30m|15m|5m|2m|30s|now|auto (défaut: auto)"
        echo "  auto = 5m si >=2 joueurs, 2m si 1 joueur, now si 0 joueur"
        echo "Options:"
        echo "  --reason=TEXT   Raison de l'action (ex: 'Maintenance', 'Mods')"
        echo "  --automatic     Marquer l'action comme automatique"
        echo "  --silent        Supprimer les messages Discord"
        exit 1
        ;;
esac
