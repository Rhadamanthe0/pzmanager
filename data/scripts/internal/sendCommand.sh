#!/bin/bash
# ------------------------------------------------------------------------------
# sendCommand.sh - Envoi de commande RCON au serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./sendCommand.sh <commande> [--no-output]
#
# Exemples:
#   ./sendCommand.sh servermsg "Message aux joueurs"
#   ./sendCommand.sh save
#   ./sendCommand.sh players
#   ./sendCommand.sh quit --no-output
#
# Options:
#   --no-output  Ne pas attendre ni afficher la sortie de la commande
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# Set XDG_RUNTIME_DIR for journalctl --user (required when running via cron)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Parse arguments
NO_OUTPUT=false
CMD_PARTS=()

for arg in "$@"; do
    if [[ "$arg" == "--no-output" ]]; then
        NO_OUTPUT=true
    elif [[ "$arg" == *" "* ]]; then
        CMD_PARTS+=("\"$arg\"")
    else
        CMD_PARTS+=("$arg")
    fi
done

readonly CMD="${CMD_PARTS[*]}"

if [[ -z "$CMD" ]]; then
    echo "Usage: $0 <commande> [--no-output]"
    exit 1
fi

if [[ ! -p "${PZ_CONTROL_PIPE}" ]]; then
    echo "Erreur: ${PZ_CONTROL_PIPE} n'existe pas. Le serveur est-il lancé ?"
    exit 1
fi

# Capture timestamp BEFORE sending command
TIMESTAMP_BEFORE=$(date +%s.%N)

# Send command
# timeout : écrire dans une FIFO dont plus personne ne lit BLOQUE indéfiniment
# (serveur figé ou tué entre le test -p ci-dessus et ici). Sans borne, un préavis
# joueur en plein compte à rebours pouvait rester coincé là pour toujours.
# C'est aussi ce qui avait poussé dataBackup.sh à réécrire sa propre écriture FIFO
# sous `timeout 10` au lieu d'appeler ce script.
if ! timeout "${PZ_PIPE_WRITE_TIMEOUT:-10}" bash -c 'printf "%s\n" "$1" > "$2"' _ "$CMD" "${PZ_CONTROL_PIPE}"; then
    echo "Erreur: écriture dans ${PZ_CONTROL_PIPE} impossible (serveur figé ?)" >&2
    exit 1
fi

if [[ "$NO_OUTPUT" == true ]]; then
    echo "Commande envoyée: $CMD"
    exit 0
fi

# Wait for command to be processed
sleep 3

# Capture output from journald logs (only after our timestamp)
OUTPUT=$(journalctl --user -u "${PZ_SERVICE_NAME}" \
    --since "@${TIMESTAMP_BEFORE}" --no-pager 2>/dev/null | \
    awk -v cmd="$CMD" '
        BEGIN { capture=0 }

        # Start capturing when we find our command.
        # index() plutot que $0 ~ cmd : cmd vient de la ligne de commande (pzm
        # rcon, champ libre du bot) et etait donc interprete comme EXPRESSION
        # REGULIERE. Un servermsg contenant une parenthese ouvrante tuait awk
        # (regex non terminee), le pipeline echouait sous pipefail et aucune
        # sortie n etait affichee.
        # NB : pas d apostrophe dans ce bloc, il est lui-meme entre quotes simples.
        /command entered via server console/ && index($0, cmd) > 0 {
            capture=1
            next
        }

        # Stop on new command or unrelated events
        capture && /command entered via server console/ { exit }
        capture && /ConnectionManager:/ { exit }
        capture && /ChatMessage\{/ { exit }
        capture && /User:.*is trying to connect/ { exit }

        # Capture response lines
        capture {
            sub(/^.*> [0-9,]+> /, "")
            sub(/^.*sh\[[0-9]+\]: /, "")
            if ($0 !~ /^[[:space:]]*$/) print
        }
    ')

if [[ -n "$OUTPUT" ]]; then
    echo "$OUTPUT"
else
    echo "Commande envoyée: $CMD (aucune sortie capturée)"
fi
