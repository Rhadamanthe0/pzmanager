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
    find "${LOG_ZOMBOID_DIR}" -maxdepth 1 -name 'stop-stall-*.txt' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete
    # Dumps heap OOM (java_pid<PID>.hprof, ~Xmx chacun) : politique du
    # propriétaire (10/2026) — 3 dumps max, 2 semaines max (constat de
    # sécurité : rétention illimitée remplissant le disque).
    find "${LOG_ZOMBOID_DIR}" -maxdepth 1 -name 'java_pid*.hprof' -type f -mtime +14 -delete
    local kept=0 dump
    while IFS= read -r dump; do
        kept=$(( kept + 1 ))
        if (( kept > 3 )); then rm -f -- "$dump"; fi
    done < <(find "${LOG_ZOMBOID_DIR}" -maxdepth 1 -name 'java_pid*.hprof' -type f -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2-)
}

capture_logs() {
    # Le logger peut précéder l'activation : attendre l'identité du boot pour
    # ne jamais suivre un filtre d'invocation vide.
    local iid start_time timestamp="" log_file waited=0
    while (( waited < 60 )); do
        iid="$(systemctl --user show -p InvocationID --value "${PZ_SERVICE_NAME}" 2>/dev/null || true)"
        [[ -n "$iid" ]] && break
        sleep 2
        waited=$(( waited + 2 ))
    done
    [[ -n "$iid" ]] || die "InvocationID de ${PZ_SERVICE_NAME} indisponible après ${waited}s (service non démarré ?)"
    [[ "$iid" =~ ^[0-9a-fA-F]{32}$ ]] || die "InvocationID de ${PZ_SERVICE_NAME} invalide"

    start_time="$(systemctl --user show -p ActiveEnterTimestamp --value "${PZ_SERVICE_NAME}" 2>/dev/null || true)"
    # Avant activation, l'horodatage peut manquer : ne pas interpréter le vide
    # comme minuit. L'instant présent est alors une approximation explicite.
    if [[ -n "$start_time" ]]; then
        timestamp="$(date -d "$start_time" +"%Y-%m-%d_%Hh%Mm%S" 2>/dev/null || true)"
    fi
    [[ -n "$timestamp" ]] || timestamp="$(date +"%Y-%m-%d_%Hh%Mm%S")"
    # Deux boots rapprochés ou le redémarrage du logger ne doivent jamais
    # tronquer une capture existante. mktemp crée la nouvelle capture en 0600.
    log_file="$(mktemp "${LOG_ZOMBOID_DIR}/zomboid_${timestamp}_${iid}_XXXXXX.log")"

    journalctl -n all -f "INVOCATION_ID=${iid}" + "_SYSTEMD_INVOCATION_ID=${iid}" \
        > "$log_file"
}

ensure_directory "${LOG_ZOMBOID_DIR}"
cleanup_old_logs
capture_logs
