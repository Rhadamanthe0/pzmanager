#!/usr/bin/env bash
# Vrai wrapper + faux bus/cgroup : preuve FD/propagation, aucun service hôte.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/pz-route-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/lib"
cp "$ROOT/data/scripts/lib/run_in_pz_slice.sh" "$FIXTURE/lib/"
cp "$ROOT/data/scripts/lib/systemd_scope.sh" "$FIXTURE/lib/"
cat > "$FIXTURE/bin/python3" <<'MOCK'
#!/usr/bin/env bash
case "${2:-}" in
    inside) [[ "${MOCK_PHASE:-outside}" == inside ]] ;;
    check) [[ "${MOCK_BAD_CAP:-0}" == 0 ]] ;;
    *) exit 99 ;;
esac
MOCK
cat > "$FIXTURE/bin/id" <<'MOCK'
#!/usr/bin/env bash
echo 1005
MOCK
cat > "$FIXTURE/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$MOCK_CALLS"
[[ "${MOCK_BUS_FAILURE:-0}" == 0 ]]
MOCK
cat > "$FIXTURE/bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then printf '%s\n' --scope --expand-environment=BOOL; exit; fi
printf '%s\n' "$@" >> "$MOCK_CALLS"
[[ " $* " == *" --slice=pz.slice "* ]] || exit 99
while [[ "${1:-}" != /bin/bash ]]; do shift; done
MOCK_PHASE=inside exec "$@"
MOCK
cat > "$FIXTURE/task.sh" <<'TASK'
#!/usr/bin/env bash
printf 'world-lock-FD-preserved\n' >&9
printf '%s\n' "$@" > "$MOCK_TASK_RESULT"
exit "${MOCK_TASK_STATUS:-0}"
TASK
chmod +x "$FIXTURE/bin/"*
export PATH="$FIXTURE/bin:$PATH" MOCK_CALLS="$FIXTURE/calls" MOCK_TASK_RESULT="$FIXTURE/task-result"
exec 9>"$FIXTURE/lock-fd"
bash "$FIXTURE/lib/run_in_pz_slice.sh" bash "$FIXTURE/task.sh" 'arg with spaces'
grep -qx 'world-lock-FD-preserved' "$FIXTURE/lock-fd"
grep -qx 'arg with spaces' "$MOCK_TASK_RESULT"
grep -qx -- '--slice=pz.slice' "$MOCK_CALLS"
# Une scope créée sur une mauvaise limite ne lance jamais le travail.
rm -f "$MOCK_TASK_RESULT"
if MOCK_BAD_CAP=1 bash "$FIXTURE/lib/run_in_pz_slice.sh" bash "$FIXTURE/task.sh"; then
    echo 'Mauvais plafond accepté' >&2; exit 1
fi
[[ ! -e "$MOCK_TASK_RESULT" ]]
# Bus refusé : aucun fallback hors budget.
if MOCK_BUS_FAILURE=1 bash "$FIXTURE/lib/run_in_pz_slice.sh" bash "$FIXTURE/task.sh"; then
    echo 'Bus refusé masqué' >&2; exit 1
fi
[[ ! -e "$MOCK_TASK_RESULT" ]]
status=0
MOCK_TASK_STATUS=7 bash "$FIXTURE/lib/run_in_pz_slice.sh" bash "$FIXTURE/task.sh" || status=$?
[[ "$status" == 7 ]]
# Une variable affirmant un placement ne contourne pas le routage kernel.
: > "$MOCK_CALLS"
PZ_BUDGET_SCOPED=1 bash "$FIXTURE/lib/run_in_pz_slice.sh" bash "$FIXTURE/task.sh"
grep -qx -- '--slice=pz.slice' "$MOCK_CALLS"
# Vrai common.sh : appels absolus, relatifs et par alias doivent tous router.
mkdir -p "$FIXTURE/project/data/scripts/core" "$FIXTURE/project/data/scripts/lib"
cp "$ROOT/data/scripts/lib/common.sh" "$FIXTURE/project/data/scripts/lib/"
cp "$ROOT/data/scripts/lib/run_in_pz_slice.sh" "$FIXTURE/project/data/scripts/lib/"
cp "$ROOT/data/scripts/lib/systemd_scope.sh" "$FIXTURE/project/data/scripts/lib/"
cat > "$FIXTURE/project/data/scripts/core/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
[[ "${MOCK_PHASE:-outside}" == inside ]] || { echo 'travail hors slice' >&2; exit 99; }
printf 'checked before work\n' > "$MOCK_TASK_RESULT"
PROBE
ln -s probe.sh "$FIXTURE/project/data/scripts/core/alias.sh"
for entry in "$FIXTURE/project/data/scripts/core/probe.sh" data/scripts/core/probe.sh data/scripts/core/alias.sh; do
    rm -f "$MOCK_TASK_RESULT"
    (cd "$FIXTURE/project" && bash "$entry")
    grep -qx 'checked before work' "$MOCK_TASK_RESULT"
done
# L'aide seule ne nécessite ni bus ni installation.
bash "$ROOT/pzm" help > "$FIXTURE/help"
grep -q 'pzmanager' "$FIXTURE/help"
echo 'Shared routing: FD, argv, refus et code retour OK'
