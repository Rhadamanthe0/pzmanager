#!/bin/bash
# ------------------------------------------------------------------------------
# creationDateInit.sh - Initialiser les dates de creation manquantes
# ------------------------------------------------------------------------------
# Execute quotidiennement pour assigner une date de creation aux comptes
# whitelist qui n'en ont pas (date du jour - 1).
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly DB_PATH="${PZ_SOURCE_DIR}/db/servertest.db"

main() {
    [[ -f "$DB_PATH" ]] || { log "Base de donnees introuvable: $DB_PATH"; exit 0; }

    # B42 n'a pas de colonne created_at, rien à faire
    local columns
    columns=$(sqlite3 "$DB_PATH" "PRAGMA table_info(whitelist)" 2>/dev/null)
    if ! echo "$columns" | grep -q '|created_at|'; then
        exit 0
    fi

    # Compter les comptes sans date de creation
    local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM whitelist WHERE created_at IS NULL" 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        log "Aucun compte sans date de creation"
        exit 0
    fi

    # Assigner la date d'hier aux comptes sans date
    sqlite3 "$DB_PATH" "UPDATE whitelist SET created_at = date('now', '-1 day') WHERE created_at IS NULL"

    log "Date de creation assignee a $count compte(s)"
}

main "$@"
