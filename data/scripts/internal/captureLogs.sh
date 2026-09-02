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
source_env

# Valider variables .env requises
[[ -n "${LOG_ZOMBOID_DIR:-}" ]] || die "Variable LOG_ZOMBOID_DIR non définie dans .env"
[[ -n "${LOG_RETENTION_DAYS:-}" ]] || die "Variable LOG_RETENTION_DAYS non définie dans .env"
[[ -n "${PZ_SERVICE_NAME:-}" ]] || die "Variable PZ_SERVICE_NAME non définie dans .env"

cleanup_old_logs() {
    find "${LOG_ZOMBOID_DIR}" -name "zomboid_*.log" -type f -mtime "+${LOG_RETENTION_DAYS}" -delete
}

capture_logs() {
    # L'unité a Restart=always et peut donc démarrer avant que zomboid.service ne
    # soit actif : systemctl renvoie alors un InvocationID VIDE. Non quotée, la
    # ligne journalctl devenait « INVOCATION_ID= + _SYSTEMD_INVOCATION_ID= »,
    # rejetée par journalctl -> sortie en erreur -> redémarrage toutes les 5 s,
    # en boucle et sans capturer un seul log. On attend l'ID au lieu de partir en
    # vrille (le service est de toute façon lancé par zomboid.service).
    local iid start_time timestamp waited=0
    while (( waited < 60 )); do
        iid="$(systemctl --user show -p InvocationID --value "${PZ_SERVICE_NAME}" 2>/dev/null || true)"
        [[ -n "$iid" ]] && break
        sleep 2
        waited=$(( waited + 2 ))
    done
    [[ -n "$iid" ]] || die "InvocationID de ${PZ_SERVICE_NAME} indisponible après ${waited}s (service non démarré ?)"

    start_time="$(systemctl --user show -p ActiveEnterTimestamp --value "${PZ_SERVICE_NAME}" 2>/dev/null || true)"
    # date -d "" renverrait la date du jour à 00:00 et écraserait le log de la
    # veille : on retombe sur l'instant présent, qui est la vraie approximation.
    timestamp="$(date -d "$start_time" +"%Y-%m-%d_%Hh%Mm%S" 2>/dev/null || date +"%Y-%m-%d_%Hh%Mm%S")"

    journalctl -n all -f "INVOCATION_ID=${iid}" + "_SYSTEMD_INVOCATION_ID=${iid}" \
        > "${LOG_ZOMBOID_DIR}/zomboid_${timestamp}.log"
}

ensure_directory "${LOG_ZOMBOID_DIR}"
cleanup_old_logs
capture_logs
