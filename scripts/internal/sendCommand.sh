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
source_env "${SCRIPT_DIR}/.."

# Set XDG_RUNTIME_DIR for journalctl --user (required when running via cron)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Parse arguments
NO_OUTPUT=false
CMD_ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "--no-output" ]]; then
        NO_OUTPUT=true
    else
        CMD_ARGS+=("$arg")
    fi
done

readonly CMD="${CMD_ARGS[*]}"

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
echo "$CMD" > "${PZ_CONTROL_PIPE}"

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

        # Start capturing when we find our command
        /command entered via server console/ && $0 ~ cmd {
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
