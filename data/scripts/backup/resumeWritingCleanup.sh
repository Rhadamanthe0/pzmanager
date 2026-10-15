#!/bin/bash
# Explicit recovery only; the startup path never calls this command.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
[[ $# == 1 ]] || die "Usage: pzm backup resume-writing <répertoire-de-récupération>"
acquire_world_lock --required || exit 1
trap release_world_lock EXIT
assert_server_stopped_proven "Reprise explicite du nettoyage Writing"
export PZ_WORLD_LOCK_FILE="$(world_lock_path)"
compiler_args=()
if [[ -n "${PZ_WRITING_CLEANUP_JAVAC:-}" ]]; then compiler_args=(--javac "$PZ_WRITING_CLEANUP_JAVAC")
elif [[ -x "${JAVA_PATH}/bin/javac" ]]; then compiler_args=(--javac "${JAVA_PATH}/bin/javac"); fi
python3 "${SCRIPT_DIR}/../internal/cleanWritingDrawings.py" \
    --world-dir "${PZ_SOURCE_DIR}/Saves/Multiplayer/${PZ_SERVER_NAME}" \
    --backup-dir "${BACKUP_DIR}/projectwriting-cleanups" --resume-from "$1" \
    --jar "${PZ_INSTALL_DIR}/java/projectzomboid.jar" \
    --java "${PZ_WRITING_CLEANUP_JAVA:-${PZ_INSTALL_DIR}/jre64/bin/java}" "${compiler_args[@]}"
