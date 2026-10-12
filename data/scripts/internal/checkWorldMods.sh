#!/bin/bash
# Read-only preflight against the current or a proposed Mods= list.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
[[ $# -le 1 ]] || { echo 'Usage: pzm mods check [candidate.ini or V[N].txt]' >&2; exit 2; }
exec python3 "${SCRIPT_DIR}/checkWorldMods.py" \
    --dictionary "${PZ_SOURCE_DIR}/Saves/Multiplayer/${PZ_SERVER_NAME}/WorldDictionaryReadable.lua" \
    --ini "${1:-$PZ_INI_PATH}"
