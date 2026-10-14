#!/bin/bash
# Envoi de message à un webhook Discord (canal public par défaut).
# --strict : retourne une erreur à l'appelant, utile pour l'annonce de disponibilité.
# Sans --strict, reste non bloquant pour les arrêts et maintenances.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

message=""
webhook=""
webhook_set=false
strict=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)    strict=true; shift ;;
        --webhook)   webhook="${2:-}"; webhook_set=true; shift; shift 2>/dev/null || true ;;
        --webhook=*) webhook="${1#--webhook=}"; webhook_set=true; shift ;;
        *)           [[ -n "$message" ]] || message="$1"; shift ;;
    esac
done

$webhook_set || webhook="${DISCORD_WEBHOOK:-}"
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

# Python est déjà requis par common.sh/source_env ; son encodeur JSON gère
# aussi les retours ligne, les tabulations, les contrôles et les caractères UTF-8.
# L'échappement sed précédent produisait du JSON invalide pour les multilignes.
if ! payload="$(python3 -c 'import json, sys; print(json.dumps({"content": sys.argv[1]}, ensure_ascii=False))' "$message")"; then
    echo "[pz-discord] Impossible de générer le JSON de notification." >&2
    if $strict; then exit 1; else exit 0; fi
fi

# curl sans --fail peut réussir (code 0) alors que Discord répond HTTP 400/429/500.
# Ne jamais journaliser l'URL du webhook, son token ou le corps de la réponse.
curl_rc=0
http_code="$(curl --silent --connect-timeout 5 --max-time 10 \
    --output /dev/null --write-out '%{http_code}' \
    -H "Content-Type: application/json" -d "$payload" "$webhook" 2>/dev/null)" || curl_rc=$?
if (( curl_rc != 0 )) || [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "[pz-discord] Échec d'envoi (curl=${curl_rc}, HTTP=${http_code:-inconnu})." >&2
    if $strict; then exit 1; else exit 0; fi
fi
exit 0
