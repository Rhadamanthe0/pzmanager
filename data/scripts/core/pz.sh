#!/bin/bash
# pz.sh - Gestion du serveur Project Zomboid
# Usage: ./pz.sh <start|stop|restart|status> [délai] [options]
# Options: --reason TEXT, --maintenance, --automatic, --silent
# Lock partagé avec modcheck/maintenance pour éviter les conflits

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

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
            # Garde explicite : sous set -u, un « --reason » final sans texte
            # sortait sur un message bash brut (« $2 : variable sans liaison »),
            # illisible pour qui tape la commande depuis Discord.
            [[ $# -ge 2 ]] || die "--reason attend un texte (ex: --reason \"Ajout de mods\")"
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
    notify "$1"
}

# Verrou d'opération stop/restart : interdit deux arrêts/redémarrages simultanés.
# C'est le garde-fou contre l'incident du 2026-07-20 (un 2e `pzm server restart`
# lancé pendant le 1er -> `quit` en plein chargement de map -> crash-loop B42).
# Le verrou est libéré automatiquement par le noyau à la mort du process (pas de
# verrou fantôme). Tenu pour TOUTE la durée de pz.sh (préavis + arrêt + backup +
# démarrage). try_lock (common.sh) alloue le descripteur : le numéro codé en dur
# valait aussi 201 dans dataBackup.sh, que ce script APPELLE — ça marchait, mais
# par chance, et la lecture laissait croire à un conflit.
readonly SERVERCTL_LOCK_FILE="/tmp/pzmanager-serverctl-$(id -un).lock"
SERVERCTL_LOCK_FD=""
acquire_serverctl_lock_or_die() {
    try_lock "$SERVERCTL_LOCK_FILE" SERVERCTL_LOCK_FD \
        || die "Un arrêt/redémarrage est déjà en cours. Attends qu'il se termine (le serveur doit être « en ligne » avant toute nouvelle action)."
}

# Nombre de joueurs actuellement connectés.
#   "0"     = serveur arrêté, ou serveur qui répond « 0 joueur »
#   ""      = INDÉTERMINÉ (la console n'a rien renvoyé d'exploitable)
# La distinction est essentielle : renvoyer 0 dans le cas indéterminé faisait
# choisir le délai « now » à delay_for_player_count, donc un arrêt SANS AUCUN
# préavis. Or le scrape journald de sendCommand.sh rate sa fenêtre précisément
# quand la boucle principale est gelée — c'est-à-dire au moment où on redémarre,
# avec des joueurs connectés. On préfère un préavis inutile à un kick surprise.
count_connected_players() {
    server_is_active || { echo 0; return; }
    local out n
    out="$("${SCRIPT_DIR}/../internal/sendCommand.sh" players 2>/dev/null || true)"
    n="$(printf '%s\n' "$out" | grep -oE 'Players connected \([0-9]+\)' | grep -oE '[0-9]+' | head -1)"
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo ""
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

# L'origine (manuelle/automatique) est TOUJOURS affichée, motif ou pas : sans
# elle, un arrêt manuel sans --reason est indistinguable d'un arrêt programmé.
format_context() {
    local action="$1"
    local msg="$action"
    local origin="Lancé manuellement"

    [[ "$IS_AUTOMATIC" == true ]] && origin="Lancé automatiquement"

    if [[ -n "$REASON" ]]; then
        msg="$msg ($origin - $REASON)"
    else
        msg="$msg ($origin)"
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
            # Premier avertissement : @here + le motif. format_context ""
            # rend le suffixe seul (jamais vide, cf. plus haut).
            send_msg "${simple_msg}$(format_context "")" "@here "
            first=false
        else
            # Avertissements suivants : message simple, sans ping ni motif.
            send_msg "$simple_msg"
        fi
        sleep "$secs"
    done

    # Message final : le motif a déjà été donné sur le premier avertissement
    # (avec @here), on ne le répète pas ici — juste le marqueur « ça part ».
    if [[ "$IS_MAINTENANCE" == true ]]; then
        send_msg "DÉBUT MAINTENANCE"
    else
        send_msg "$display_action"
    fi
    sleep 5
}

shutdown_server() {
    local action="$1"
    try_acquire_maintenance_lock || true

    # Ne jamais agir sur un serveur qui charge encore la map : un `quit`/stop
    # pendant le boot fait planter B42 (NPE IsoMetaGrid.save, grid=null) ->
    # crash-loop. On attend la fin du boot courant AVANT préavis, comptage et
    # arrêt. Cas normal (serveur déjà prêt) : retour immédiat.
    if server_is_active && ! wait_for_server_ready; then
        log "AVERTISSEMENT : la boucle de jeu n'a toujours pas démarré (timeout)."
        log "  Le serveur charge encore, ou son chargement est bloqué (cas du 02/09/2026)."
        log "  On poursuit l'arrêt, mais le \`quit\` ne peut pas être exécuté dans cet état :"
        log "  systemd attendra 120 s (TimeoutStopSec) puis fera un SIGKILL, SANS sauvegarde finale."
        log "  Le dernier backup horaire reste le point de restauration (\`pzm backup list\`)."
    fi

    # Sonde de vivacité de la console, faite UNE fois puis réutilisée pour le
    # délai auto. Elle était jusqu'ici lancée UNIQUEMENT en délai auto, et son
    # résultat « indéterminé » servait seulement à choisir un préavis prudent.
    #
    # Or une console muette veut dire quelque chose de bien plus grave : l'arrêt
    # repose ENTIÈREMENT sur le `quit` que l'ExecStop écrit dans le même FIFO.
    # Si la console ne lit plus, le `quit` reste dans le tampon du tube, le
    # service ne s'arrête jamais de lui-même, et systemd finit par le SIGKILL au
    # bout de TimeoutStopSec (120 s) — sans sauvegarde. C'est exactement le
    # déroulé du 02/09/2026 à 13:45. Les avertissements en jeu passent d'ailleurs
    # par ce même canal : ils ne seraient lus par personne non plus.
    #
    # On ne peut pas y remédier ici, mais on peut le DIRE, au lieu de laisser
    # l'opérateur découvrir un « Failed with result 'timeout' » deux minutes plus
    # tard sans explication.
    local players=""
    if server_is_active; then
        players="$(count_connected_players)"
        if [[ -z "$players" ]]; then
            log "AVERTISSEMENT : la console du serveur ne répond pas."
            log "  Le 'quit' d'arrêt passe par ce même canal : il a de fortes chances"
            log "  de ne pas être traité, auquel cas systemd tuera le serveur au bout"
            log "  de 120 s (arrêt brutal, sans sauvegarde finale)."
            log "  Le dernier backup horaire reste le point de restauration."
            send_discord "⚠️ Console du serveur muette avant l'arrêt — le redémarrage risque de se terminer par un arrêt brutal (sans sauvegarde finale)."
        fi
    fi

    # Délai automatique selon le nombre de joueurs connectés
    if [[ "$DELAY" == "auto" ]]; then
        if [[ -z "$players" ]]; then
            # Comptage impossible : on ne sait pas si la salle est vide ou pleine,
            # donc on préavise comme s'il y avait du monde.
            DELAY="2m"
            echo "Délai auto : nombre de joueurs indéterminé (console muette) → $DELAY par sécurité"
        else
            DELAY="$(delay_for_player_count "$players")"
            echo "Délai auto (${players} joueur(s) connecté(s)) → $DELAY"
        fi
    fi

    if [[ "$DELAY" == "now" ]]; then
        local context_msg; context_msg="$(format_context "$action IMMÉDIAT")"
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
        local context_msg; context_msg="$(format_context "Serveur démarré")"
        send_discord "$context_msg"
    fi
    echo "Terminé."
}

do_stop() {
    acquire_serverctl_lock_or_die
    shutdown_server "ARRÊT"
    echo "Terminé."
}

do_restart() {
    acquire_serverctl_lock_or_die
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
        local result; result="$(systemctl --user show "${PZ_SERVICE_NAME}" -p Result --value)"
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
        echo "Usage: pzm server <start|stop|restart|status> [délai] [options]"
        echo "Délais: 30m|15m|5m|2m|30s|now|auto (défaut: auto)"
        echo "  auto = 5m si >=2 joueurs, 2m si 1 joueur, now si 0 joueur"
        echo "Options:"
        echo "  --reason=TEXT   Raison de l'action (ex: 'Maintenance', 'Mods')"
        echo "  --automatic     Marquer l'action comme automatique"
        echo "  --silent        Supprimer les messages Discord"
        exit 1
        ;;
esac
