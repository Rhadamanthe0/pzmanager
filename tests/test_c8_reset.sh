#!/usr/bin/env bash
# C8: dedicated generator session, exact cachedir, unrelated processes preserved.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?runner jetable requis}"
SCRIPT="${ROOT}/data/scripts/admin/resetServer.sh"
SCRIPT_DIR="${ROOT}/data/scripts/admin"
HELPER="${ROOT}/data/scripts/lib/reset_generator.py"
SANDBOX="$(mktemp -d "${ROOT}/tests/.tmp-c8-XXXXXX")"
GENERATOR_PID=""; HOMOPID=""; SUFFIXPID=""; CHILD_PID=""
cleanup() {
    for pid in "$GENERATOR_PID" "$HOMOPID" "$SUFFIXPID" "$CHILD_PID"; do
        [[ -z "$pid" ]] || kill -KILL "$pid" 2>/dev/null || true
        [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT
extract_func() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SCRIPT"; }
{
    extract_func kill_generator_exact
} > "$SANDBOX/functions.sh"
source "$SANDBOX/functions.sh"
cat > "$SANDBOX/generator.py" <<'PY'
import os,signal,sys,time
from pathlib import Path
signal.signal(signal.SIGTERM,signal.SIG_IGN)
if len(sys.argv)>2:Path(sys.argv[2]).write_text(str(os.getpid()))
time.sleep(60)
PY
STAGING_DIR="$SANDBOX/Zomboid.new.fixture"
STAGING_CACHEDIR="$STAGING_DIR"
mkdir -p "$STAGING_DIR"
printf evidence > "$STAGING_DIR/evidence"
GENERATOR_METADATA="$STAGING_DIR/.pzm-generator.json"
bash -c 'exec -a ProjectZomboid64 sleep 60' &
HOMOPID=$!
python3 "$SANDBOX/generator.py" "-cachedir=${STAGING_DIR}.suffix" &
SUFFIXPID=$!
set +m
python3 "$HELPER" launch --metadata "$GENERATOR_METADATA" -cachedir="$STAGING_DIR" -- \
    python3 "$SANDBOX/generator.py" "-cachedir=${STAGING_DIR}" "$SANDBOX/child.ready" &
GENERATOR_PID=$!
for ((attempt=0;attempt<250;attempt++)); do
    [[ ! -s "$SANDBOX/child.ready" ]] || break
    kill -0 "$GENERATOR_PID"
    sleep .02
done
[[ -s "$SANDBOX/child.ready" ]] || { echo '[FAIL] generator child never became ready' >&2; exit 1; }
CHILD_PID="$(cat "$SANDBOX/child.ready")"
python3 "$HELPER" ready --metadata "$GENERATOR_METADATA" -cachedir="$STAGING_DIR" --pid "$GENERATOR_PID"
if python3 "$HELPER" stop --metadata "$GENERATOR_METADATA" -cachedir="${STAGING_DIR}.suffix" --pid "$GENERATOR_PID"; then
    echo '[FAIL] wrong cachedir accepted by real stop helper' >&2
    exit 1
fi
kill -0 "$GENERATOR_PID"
kill -0 "$CHILD_PID"
kill -0 "$HOMOPID"
kill -0 "$SUFFIXPID"
[[ -f "$STAGING_DIR/evidence" && -f "$GENERATOR_METADATA" ]]
kill_generator_exact
kill -0 "$HOMOPID"
kill -0 "$SUFFIXPID"
python3 - "$CHILD_PID" <<'PY'
from pathlib import Path
import sys
try:state=Path('/proc/'+sys.argv[1]+'/stat').read_text().rsplit(')',1)[1].split()[0]
except FileNotFoundError:state='X'
assert state in {'Z','X'}, 'generator child survived stop: '+state
PY
[[ -z "$GENERATOR_PID" ]]
echo 'C8 session group: OK (unrelated name/suffix preserved; TERM-resistant child stopped)'
