#!/bin/bash
# ------------------------------------------------------------------------------
# sendCommand.sh - Envoi de commande RCON au serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./sendCommand.sh <commande>
#
# Exemples:
#   ./sendCommand.sh servermsg "Message aux joueurs"
#   ./sendCommand.sh save
#   ./sendCommand.sh quit
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly CMD="$*"

if [[ -z "$CMD" ]]; then
    echo "Usage: $0 <commande>"
    exit 1
fi

if [[ ! -p "${PZ_CONTROL_PIPE}" ]]; then
    echo "Erreur: ${PZ_CONTROL_PIPE} n'existe pas. Le serveur est-il lancé ?"
    exit 1
fi

echo "$CMD" > "${PZ_CONTROL_PIPE}"
echo "Commande envoyée: $CMD"
