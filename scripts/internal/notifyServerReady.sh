#!/bin/bash
# Attend que le RCON soit prêt et envoie une notification Discord

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs/zomboid"
readonly TIMEOUT=300

start_time=$(date +%s)
elapsed=0

while [[ $elapsed -lt $TIMEOUT ]]; do
    latest_log=$(find "$LOG_DIR" -name "zomboid_*.log" -newermt "@$start_time" 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]] && grep -q "RCON: listening on port" "$latest_log" 2>/dev/null; then
        "${SCRIPT_DIR}/sendDiscord.sh" "Le serveur Project Zomboid est en ligne !"
        exit 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

exit 0
