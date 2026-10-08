#!/usr/bin/env bash
# test_heapdump_retention.sh - Rétention des dumps heap OOM (991da29).
#
# Politique du propriétaire (10/2026) : 3 dumps max, 2 semaines max.
# Sans elle, chaque OOM écrivait un java_pid<PID>.hprof ~Xmx jamais nettoyé.
#
# Preuves réelles : vraie fonction cleanup_old_logs (extraite de
# data/scripts/internal/captureLogs.sh, jamais exécutée pour elle-même),
# vrais fichiers avec mtimes pilotes. Sans flock/sqlite : exécutable partout.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SANDBOX="${ROOT}/tests/.tmp-heapdump-$$"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/logs"

# Extraire seulement la fonction (motif C16) : le bas du script capturerait
# journalctl, jamais exécuté ici. awk (pas sed …,/^}/) car l'appel nu
# « cleanup_old_logs » en bas de fichier rouvrirait une plage sed.
awk '/^cleanup_old_logs\(\)/{f=1} f{print} f && /^\}/{exit}' \
    "${ROOT}/data/scripts/internal/captureLogs.sh" > "${SANDBOX}/cleanup.sh"
export LOG_ZOMBOID_DIR="${SANDBOX}/logs" LOG_RETENTION_DAYS=9999
# shellcheck disable=SC1091
source "${SANDBOX}/cleanup.sh"

touch -d '20 days ago' "${SANDBOX}/logs/java_pid101.hprof"
touch -d '15 days ago' "${SANDBOX}/logs/java_pid102.hprof"
touch -d '10 days ago' "${SANDBOX}/logs/java_pid103.hprof"
touch -d '3 days ago' "${SANDBOX}/logs/java_pid104.hprof"
touch -d '2 days ago' "${SANDBOX}/logs/java_pid105.hprof"
touch -d '1 day ago' "${SANDBOX}/logs/java_pid106.hprof"
echo "notes" > "${SANDBOX}/logs/notes.txt"

cleanup_old_logs
cleanup_old_logs

restants="$(find "${SANDBOX}/logs" -maxdepth 1 -name 'java_pid*.hprof' -printf '%f\n' | sort)"
attendus="$(printf 'java_pid104.hprof\njava_pid105.hprof\njava_pid106.hprof')"
if [[ "$restants" == "$attendus" ]]; then
    ok "3 dumps récents conservés (104/105/106), vieux supprimés"
else
    ko "rétention inattendue : [${restants//$'\n'/, }] (attendu 104/105/106)"
fi
[[ -f "${SANDBOX}/logs/notes.txt" ]] && ok "fichiers non-dump intacts" || ko "notes.txt supprimé à tort"

echo ""
if (( FAIL == 0 )); then
    echo "HEAPDUMP RETENTION: OK (${PASS} contrôles)"
else
    echo "HEAPDUMP RETENTION: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
