#!/bin/bash
# Remove the old live guard and clean saved drawings before JVM startup.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
mode="${PZ_WRITING_TEXT_ONLY:-1}"
[[ "$mode" == 0 || "$mode" == 1 ]] || die "PZ_WRITING_TEXT_ONLY doit valoir 0 ou 1."
world_lock="$(world_lock_path)"
# Use the JVM actually launched by PZ; JAVA_PATH may refer to an older JDK.
cleanup_java="${PZ_WRITING_CLEANUP_JAVA:-$(realpath -m "${PZ_INSTALL_DIR}/jre64/bin/java")}"
cleanup_javac="${PZ_WRITING_CLEANUP_JAVAC:-$(dirname "$cleanup_java")/javac}"
python3 "${SCRIPT_DIR}/writing_start_admission.py" run \
    --unit "$PZ_SERVICE_NAME" --lock-path "$world_lock" -- \
    python3 "${SCRIPT_DIR}/configureWritingTextOnly.py" \
    --install-dir "$PZ_INSTALL_DIR" --ini-file "$PZ_INI_PATH" \
    --sandbox-file "${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}_SandboxVars.lua" \
    --cleanup-world "${PZ_SOURCE_DIR}/Saves/Multiplayer/${PZ_SERVER_NAME}" \
    --cleanup-backups "${BACKUP_DIR}/projectwriting-cleanups" \
    --jar "${PZ_INSTALL_DIR}/java/projectzomboid.jar" \
    --java "$cleanup_java" --javac "$cleanup_javac" --mode "$mode"
