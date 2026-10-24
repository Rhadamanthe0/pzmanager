#!/usr/bin/env bash
# C8: vraie fonction PID exact ; chaîne reset couverte dans test_reset_wipe_safety.py.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/admin/resetServer.sh"
SANDBOX="$(mktemp -d "${ROOT}/tests/.tmp-c8-XXXXXX")"
GENERATOR_PID=""; HOMOPID=""; SUFFIXPID=""
cleanup() {
    for pid in "$GENERATOR_PID" "$HOMOPID" "$SUFFIXPID"; do
        [[ -z "$pid" ]] || kill -KILL "$pid" 2>/dev/null || true
        [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT
extract_func() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SCRIPT"; }
{
    extract_func generator_cmdline_matches
    extract_func kill_generator_exact
} > "$SANDBOX/functions.sh"
source "$SANDBOX/functions.sh"
# Le stub garde son argv et son PID jusqu'au signal, comme le générateur.
cat > "$SANDBOX/generator.py" <<'PY'
import time
time.sleep(60)
PY
STAGING_DIR="$SANDBOX/Zomboid.new.fixture"
export STAGING_CACHEDIR="$STAGING_DIR"
bash -c 'exec -a ProjectZomboid64 sleep 60' &
HOMOPID=$!
python3 "$SANDBOX/generator.py" "-cachedir=${STAGING_DIR}.suffix" &
SUFFIXPID=$!
python3 "$SANDBOX/generator.py" "-cachedir=${STAGING_DIR}" &
GENERATOR_PID=$!
generator_pid="$GENERATOR_PID"
sleep .2
if generator_cmdline_matches "$SUFFIXPID" "$STAGING_DIR"; then
    echo '[FAIL] cachedir suffix accepté comme exact' >&2
    exit 1
fi
kill_generator_exact
kill -0 "$HOMOPID"
kill -0 "$SUFFIXPID"
if kill -0 "$generator_pid" 2>/dev/null; then
    echo '[FAIL] générateur exact toujours vivant' >&2
    exit 1
fi
[[ -z "$GENERATOR_PID" ]]
echo 'C8 PID exact: OK (homonyme et cachedir suffix préservés ; générateur exact arrêté)'
