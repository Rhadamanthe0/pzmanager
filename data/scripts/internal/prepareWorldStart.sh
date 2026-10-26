#!/bin/bash
# One WORLD handoff covers all startup world mutations. Each worker re-proves it.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

if [[ "${1:-}" != --admitted-worker ]]; then
    lock_path="$(python3 "${SCRIPT_DIR}/writing_start_admission.py" path)" || exit 1
    exec python3 "${SCRIPT_DIR}/writing_start_admission.py" run \
        --lock-path "$lock_path" --unit "$PZ_SERVICE_NAME" -- bash "$0" --admitted-worker
fi
python3 "${SCRIPT_DIR}/../lib/account_safety.py" verify-worker || exit 1
bash "${SCRIPT_DIR}/enforceClosedServer.sh" --admitted-worker
bash "${SCRIPT_DIR}/configureWritingTextOnly.sh" --admitted-worker
# Access cleanup remains optional; closing the server and Writing are blocking.
bash "${SCRIPT_DIR}/../admin/purgeInactivePlayers.sh" --admitted-worker \
    || log "AVERTISSEMENT: purge des accès non effectuée avant démarrage."
