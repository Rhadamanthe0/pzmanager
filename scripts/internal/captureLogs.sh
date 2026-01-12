#!/bin/bash
# ------------------------------------------------------------------------------
# captureLogs.sh - Capture des logs du serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./captureLogs.sh
#
# Suit les logs journald du service zomboid en temps réel.
# Supprime automatiquement les logs selon la rétention définie dans .env.
# Appelé par zomboid_logger.service.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Valider variables .env requises
[[ -n "${LOG_ZOMBOID_DIR:-}" ]] || die "Variable LOG_ZOMBOID_DIR non définie dans .env"
[[ -n "${LOG_RETENTION_DAYS:-}" ]] || die "Variable LOG_RETENTION_DAYS non définie dans .env"
[[ -n "${PZ_SERVICE_NAME:-}" ]] || die "Variable PZ_SERVICE_NAME non définie dans .env"

cleanup_old_logs() {
    find "${LOG_ZOMBOID_DIR}" -name "zomboid_*.log" -type f -mtime "+${LOG_RETENTION_DAYS}" -delete
}

capture_logs() {
    local iid=$(systemctl --user show -p InvocationID --value "${PZ_SERVICE_NAME}")
    local start_time=$(systemctl --user show -p ActiveEnterTimestamp --value "${PZ_SERVICE_NAME}")
    local timestamp=$(date -d "$start_time" +"%Y-%m-%d_%Hh%Mm%S")

    journalctl -n all -f INVOCATION_ID=$iid + _SYSTEMD_INVOCATION_ID=$iid > "${LOG_ZOMBOID_DIR}/zomboid_${timestamp}.log"
}

ensure_directory "${LOG_ZOMBOID_DIR}"
cleanup_old_logs
capture_logs
