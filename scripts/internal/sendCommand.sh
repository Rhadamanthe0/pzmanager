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

# Send command
echo "$CMD" > "${PZ_CONTROL_PIPE}"

if [[ "$NO_OUTPUT" == true ]]; then
    echo "Commande envoyée: $CMD"
    exit 0
fi

# Wait for command to be processed
sleep 3

# Capture output from journald logs
# Look for the command entry and capture subsequent lines
OUTPUT=$(journalctl --user -u "${PZ_SERVICE_NAME}" --since "5 seconds ago" --no-pager 2>/dev/null | \
    awk -v cmd="$CMD" '
        BEGIN { found=0; capture=0 }
        /command entered via server console/ && $0 ~ cmd {
            found=1
            capture=1
            next
        }
        capture && /^[A-Z]+ *: / {
            # Stop capturing when we hit another log level line (new command/event)
            if (!/^-/) exit
        }
        capture {
            # Remove log prefix and print content
            sub(/^.*> [0-9,]+> /, "")
            sub(/^.*sh\[[0-9]+\]: /, "")
            print
        }
    ')

if [[ -n "$OUTPUT" ]]; then
    echo "$OUTPUT"
else
    echo "Commande envoyée: $CMD (aucune sortie capturée)"
fi
