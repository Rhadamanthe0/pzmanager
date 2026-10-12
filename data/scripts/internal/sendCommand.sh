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
    echo "Usage: pzm rcon <commande> [--no-output]"
    exit 1
fi

if [[ ! -p "${PZ_CONTROL_PIPE}" ]]; then
    echo "Erreur: ${PZ_CONTROL_PIPE} n'existe pas. Le serveur est-il lancé ?"
    exit 1
fi

# La collecte est bornée et liée à l'invocation ; une connexion intercalée ne
# coupe plus la réponse. --no-output garde une écriture seule, sans attente.
output_timeout=8
# Le contrôle Workshop est asynchrone ; attendre son statut final au plus 30 s.
[[ "$CMD" != "checkModsNeedUpdate" ]] || output_timeout=30
args=(--unit "$PZ_SERVICE_NAME" --pipe "$PZ_CONTROL_PIPE"
      --write-timeout "${PZ_PIPE_WRITE_TIMEOUT:-10}"
      --output-timeout "${PZ_CONSOLE_OUTPUT_TIMEOUT:-$output_timeout}")
[[ "$NO_OUTPUT" == false ]] || args+=(--no-output)
exec python3 "${SCRIPT_DIR}/../lib/console_command.py" "${args[@]}" -- "$CMD"
