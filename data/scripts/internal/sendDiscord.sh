#!/bin/bash
# ------------------------------------------------------------------------------
# sendDiscord.sh - Envoi de message à un webhook Discord
# ------------------------------------------------------------------------------
# Usage: ./sendDiscord.sh "message" [--webhook URL]
#
# Sans --webhook : DISCORD_WEBHOOK (.env), le canal PUBLIC des annonces joueurs.
# Avec --webhook : ce webhook-là et lui seul (ex. DISCORD_ADMIN_WEBHOOK pour le
# détail technique d'un incident, qui n'a rien à faire sur le canal public). Une
# URL vide passée explicitement = on n'envoie rien, plutôt que de retomber sur le
# canal public — se tromper de canal dans ce sens-là est ce qui coûte cher.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

message=""
webhook=""
webhook_set=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        # shift 2 échouerait (et sortirait, sous set -e) sur un « --webhook »
        # final sans URL : on ne consomme que ce qui existe.
        --webhook)   webhook="${2:-}"; webhook_set=true; shift; shift 2>/dev/null || true ;;
        --webhook=*) webhook="${1#--webhook=}"; webhook_set=true; shift ;;
        *)           [[ -n "$message" ]] || message="$1"; shift ;;
    esac
done

$webhook_set || webhook="${DISCORD_WEBHOOK:-}"

# Webhook non configuré : sortie silencieuse (Discord est optionnel).
[[ -n "$webhook" ]] || exit 0

if [[ -z "$message" ]]; then
    echo "Usage: pzm discord \"message\" [--webhook URL]" >&2
    exit 1
fi

# Utiliser jq si disponible (plus sûr), sinon curl avec échappement JSON manuel
if command -v jq &> /dev/null; then
    jq -n --arg content "$message" '{content: $content}' | \
        curl -s --connect-timeout 5 --max-time 10 -H "Content-Type: application/json" -d @- "${webhook}" > /dev/null 2>&1 || true
else
    # Échapper pour JSON: \ -> \\, " -> \", tab -> \t
    escaped_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')
    curl -s --connect-timeout 5 --max-time 10 -H "Content-Type: application/json" \
         -d "{\"content\": \"$escaped_message\"}" \
         "${webhook}" > /dev/null 2>&1 || true
fi
