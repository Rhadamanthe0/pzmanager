#!/bin/bash
# ------------------------------------------------------------------------------
# sendDiscord.sh - Envoi de message au webhook Discord
# ------------------------------------------------------------------------------
# Usage: ./sendDiscord.sh "message"
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Exit silently if Discord webhook is not configured
if [[ -z "${DISCORD_WEBHOOK:-}" ]] || [[ "${DISCORD_WEBHOOK}" == "" ]]; then
    exit 0
fi

message="${1:-}"

if [[ -z "$message" ]]; then
    echo "Usage: $0 \"message\"" >&2
    exit 1
fi

# Échapper les caractères spéciaux pour JSON
# Remplace: \ par \\, " par \", newline par \n, tab par \t
escaped_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')

# Utiliser jq si disponible (plus sûr), sinon curl avec heredoc
if command -v jq &> /dev/null; then
    jq -n --arg content "$message" '{content: $content}' | \
        curl -s -H "Content-Type: application/json" -d @- "${DISCORD_WEBHOOK}" > /dev/null 2>&1 || true
else
    curl -s -H "Content-Type: application/json" \
         -d "{\"content\": \"$escaped_message\"}" \
         "${DISCORD_WEBHOOK}" > /dev/null 2>&1 || true
fi
