#!/bin/bash
# Applique le mode texte de ProjectWriting avant chaque démarrage.
# Le garde est injecté dans la configuration serveur après les checksums Lua,
# sans modifier les fichiers Workshop ni les scripts des clients.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

mode="${PZ_WRITING_TEXT_ONLY:-1}"
[[ "$mode" == 0 || "$mode" == 1 ]] \
    || die "PZ_WRITING_TEXT_ONLY doit valoir 0 ou 1."

python3 "${SCRIPT_DIR}/configureWritingTextOnly.py" \
    --install-dir "$PZ_INSTALL_DIR" \
    --ini-file "$PZ_INI_PATH" \
    --sandbox-file "${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}_SandboxVars.lua" \
    --guard-source "${SCRIPT_DIR}/PZManagerWritingTextOnly.lua" \
    --mode "$mode"
