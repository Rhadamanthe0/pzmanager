#!/usr/bin/env bash
# Route AVANT secrets/verrous ; une scope hérite stdin/stdout et les FD ouverts.
# La session SSH reste à son emplacement, seul le travail PZ est lancé dedans.
set -euo pipefail
PZ_BUDGET_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if python3 "${PZ_BUDGET_LIB}/shared_memory_budget.py" inside; then
    python3 "${PZ_BUDGET_LIB}/shared_memory_budget.py" check
    exec "$@"
fi
if [[ "$(id -u)" == 0 ]]; then
    echo 'Opération PZ hors budget : utiliser le compte manager, pas root.' >&2
    exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Unité absente/bus refusé : pas de fallback qui annoncerait un faux plafond.
systemctl --user start pz.slice
exec systemd-run --user --scope --slice=pz.slice --quiet --collect \
    --expand-environment=no --unit="pz-command-$$.scope" /bin/bash "${BASH_SOURCE[0]}" "$@"
