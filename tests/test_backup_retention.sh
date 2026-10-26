#!/usr/bin/env bash
# Run in a disposable Linux checkout. Test real GFS pruning at fixed UTC ages.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR=$(mktemp -d "${ROOT}/tests/.tmp-retention-XXXXXX")
trap 'rm -rf "$CASE_DIR"' EXIT
export TZ=UTC
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/backups"
export MOCK_NOW=$(/bin/date -d '2026-10-14 00:00:00 UTC' +%s)
cat > "$CASE_DIR/bin/date" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == '+%s' ]]; then printf '%s\n' "$MOCK_NOW"; else exec /bin/date "$@"; fi
MOCK
chmod +x "$CASE_DIR/bin/date"
export PATH="$CASE_DIR/bin:$PATH"
BACKUP_DIR="$CASE_DIR/backups"
SCRIPT_DIR="$ROOT/data/scripts/backup"
PZ_SOURCE_DIR="$CASE_DIR/world"
mkdir -m 0700 "$PZ_SOURCE_DIR"
BACKUP_GFS_HOURLY_HOURS=12
BACKUP_GFS_SIXHOURLY_DAYS=3
BACKUP_GFS_DAILY_DAYS=14
BACKUP_PRUNE_MAX_DELETE=0
BACKUP_PRUNE_DRY_RUN=0
snapshot_name() { /bin/date -d "@$(( MOCK_NOW - $1 * 3600 ))" +'backup_%Y-%m-%d_%Hh%Mm%Ss'; }
for age in 1 11 13 15 19 25 55 61 71 73 80 95 120 312 335 337; do
    mkdir -p "$BACKUP_DIR/$(snapshot_name "$age")/Saves"
done
# Load the owning function only, without launching a backup.
eval "$(sed -n '/^prune_gfs()/,/^}/p' "$ROOT/data/scripts/backup/dataBackup.sh")"
prune_gfs
for age in 1 11 13 19 25 55 61 71 73 120 312 335; do
    [[ -d "$BACKUP_DIR/$(snapshot_name "$age")" ]] || { echo "FAIL: removed age ${age}h"; exit 1; }
done
for age in 15 80 95 337; do
    [[ ! -e "$BACKUP_DIR/$(snapshot_name "$age")" ]] || { echo "FAIL: retained age ${age}h"; exit 1; }
done
echo 'BACKUP RETENTION: OK (hourly, six-hourly, daily, expiry and newest-per-bucket)'

# Une première suppression lente doit épuiser le budget, sans couper rm et
# sans commencer la deuxième. Avancer l'horloge Bash évite un sleep de 10 min.
for age in 337 338 339; do
    mkdir -p "$BACKUP_DIR/$(snapshot_name "$age")/Saves"
done
BACKUP_PRUNE_MAX_SECONDS=10
rm() {
    command rm "$@"
    SECONDS=$(( SECONDS + 11 ))
}
prune_gfs
[[ ! -e "$BACKUP_DIR/$(snapshot_name 337)" ]]
[[ -d "$BACKUP_DIR/$(snapshot_name 338)" && -d "$BACKUP_DIR/$(snapshot_name 339)" ]]
unset -f rm
BACKUP_PRUNE_DRY_RUN=1
prune_gfs > "$CASE_DIR/dry-run.log"
grep -q "DRY-RUN prune: $(snapshot_name 338)" "$CASE_DIR/dry-run.log"
grep -q "DRY-RUN prune: $(snapshot_name 339)" "$CASE_DIR/dry-run.log"
echo 'BACKUP PRUNE BUDGET: OK (complete current deletion, defer remaining, dry-run unchanged)'
