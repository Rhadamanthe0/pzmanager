#!/usr/bin/env bash
# Arrêt inchangé : quit puis attente systemd120s ; diagnostic avant expiration.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
exec python3 "${SCRIPT_DIR}/../lib/stop_diagnostics.py" stop \
    --unit "$PZ_SERVICE_NAME" --pipe "$PZ_CONTROL_PIPE" \
    --logs "$LOG_ZOMBOID_DIR" --jcmd "${PZ_GRAALVM_HOME:-}/bin/jcmd"
