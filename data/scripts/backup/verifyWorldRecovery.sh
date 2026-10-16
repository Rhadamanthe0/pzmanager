#!/bin/bash
# Verify an explicitly recovered world and close only its matching durable intent.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
[[ $# == 2 && "$1" =~ ^[0-9a-f]{32}$ && ( "$2" == --restored || "$2" == --reverted ) ]] \
    || die "Usage: pzm backup verify-recovery <id> --restored|--reverted"
acquire_world_lock --required || exit 1
trap release_world_lock EXIT
assert_server_stopped_proven "Vérification d'une récupération explicite"
state=complete
[[ "$2" != --reverted ]] || state=reverted
python3 "${SCRIPT_DIR}/../lib/world_transaction.py" finish --world "$PZ_SOURCE_DIR" --token "$1" --state "$state"
echo "État récupéré vérifié ; aucune donnée du monde n'a été réécrite."
