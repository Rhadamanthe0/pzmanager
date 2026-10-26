#!/bin/bash
# Envoi de message à un webhook Discord (canal public par défaut).
# --strict : retourne une erreur à l'appelant, utile pour l'annonce de disponibilité.
# Sans --strict, reste non bloquant pour les arrêts et maintenances.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Capturer le canal interne avant que .env ne réexporte sa configuration.
readonly private_webhook_set="${PZ_DISCORD_WEBHOOK_OVERRIDE+x}"
readonly private_webhook="${PZ_DISCORD_WEBHOOK_OVERRIDE-}"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

message=""
webhook=""
webhook_set=false
strict=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)    strict=true; shift ;;
        --webhook)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                echo "[pz-discord] L'option --webhook requiert une URL." >&2
                exit 2
            fi
            webhook="$2"
            webhook_set=true
            shift 2
            ;;
        --webhook=)
            echo "[pz-discord] L'option --webhook requiert une URL." >&2
            exit 2
            ;;
        --webhook=*) webhook="${1#--webhook=}"; webhook_set=true; shift ;;
        *)           [[ -n "$message" ]] || message="$1"; shift ;;
    esac
done

if ! $webhook_set; then
    if [[ "$private_webhook_set" == x ]]; then
        webhook="$private_webhook"
    else
        webhook="${DISCORD_WEBHOOK:-}"
    fi
fi
if [[ -z "$webhook" ]]; then
    if $strict; then
        echo "[pz-discord] Webhook non configuré : envoi impossible." >&2
        exit 1
    fi
    exit 0
fi

if [[ -z "$message" ]]; then
    echo "Usage: pzm discord \"message\" [--webhook URL] [--strict]" >&2
    exit 1
fi

# URL et message entrent par stdin : aucun secret n'est interpolé dans les
# arguments de Python/curl. Le quoting suit les échappements de curl config,
# distincts de JSON ; le JSON du message est ensuite conservé littéralement.
if ! config="$(printf '%s\0%s' "$webhook" "$message" | python3 -c '
import json, sys
url, message = sys.stdin.buffer.read().decode("utf-8").split("\0", 1)
def quote(value):
    value = value.replace("\\", "\\\\").replace("\"", "\\\"")
    for char, escaped in (("\t", "\\t"), ("\n", "\\n"), ("\r", "\\r"), ("\v", "\\v")):
        value = value.replace(char, escaped)
    return "\"" + value + "\""
print("url = " + quote(url))
print("data = " + quote(json.dumps({"content": message}, ensure_ascii=False)))
' 2>/dev/null)"; then
    echo "[pz-discord] Impossible de générer la notification." >&2
    if $strict; then exit 1; else exit 0; fi
fi

# curl sans --fail peut réussir (code 0) alors que Discord répond HTTP 400/429/500.
# Ne jamais journaliser l'URL du webhook, son token ou le corps de la réponse.
curl_rc=0
http_code="$(curl --silent --connect-timeout 5 --max-time 10 \
    --output /dev/null --write-out '%{http_code}' \
    -H "Content-Type: application/json" --config - <<< "$config" 2>/dev/null)" || curl_rc=$?
if (( curl_rc != 0 )) || [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "[pz-discord] Échec d'envoi (curl=${curl_rc}, HTTP=${http_code:-inconnu})." >&2
    if $strict; then exit 1; else exit 0; fi
fi
exit 0
