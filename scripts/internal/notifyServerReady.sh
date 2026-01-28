#!/bin/bash
# Attend que le RCON soit prêt et envoie une notification Discord
# Silencieux si fichier .silent_next_start existe (créé par maintenance)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/../logs/zomboid"
readonly SILENT_FLAG="${SCRIPT_DIR}/../../.silent_next_start"
readonly NOTIFY_LOCK="/tmp/pzmanager-notify-ready.lock"
readonly TIMEOUT=300

# Check and consume silent flag
if [[ -f "$SILENT_FLAG" ]]; then
    rm -f "$SILENT_FLAG"
    exit 0
fi

# Prevent duplicate notifications (lock for 5 minutes)
if [[ -f "$NOTIFY_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "$NOTIFY_LOCK" 2>/dev/null || echo 0) ))
    if (( lock_age < 300 )); then
        exit 0
    fi
fi
touch "$NOTIFY_LOCK"

start_time=$(date +%s)
elapsed=0

while (( elapsed < TIMEOUT )); do
    latest_log=$(find "$LOG_DIR" -name "zomboid_*.log" -newermt "@$start_time" 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]] && grep -q "RCON: listening on port" "$latest_log" 2>/dev/null; then
        "${SCRIPT_DIR}/sendDiscord.sh" "Le serveur Project Zomboid est en ligne !"
        exit 0
    fi
    sleep 2
    (( elapsed += 2 ))
done

exit 0
