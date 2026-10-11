#!/usr/bin/env bash
# Rejoue le vrai moniteur ; doubles limités au bus et à la commande restart.
# À exécuter uniquement dans une copie Linux jetable (AGENTS.md).
set -euo pipefail
ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pz-memory-test.XXXXXX")"
SANDBOX_INODE="$(stat -c '%d:%i' "$SANDBOX")"
cleanup() {
    if [[ -d "$SANDBOX" && ! -L "$SANDBOX" && -O "$SANDBOX" ]] \
        && [[ "$(stat -c '%d:%i' "$SANDBOX")" == "$SANDBOX_INODE" ]]; then
        rm -rf -- "$SANDBOX"
    else
        echo "[WARN] fixture remplacée : nettoyage refusé" >&2
    fi
}
trap cleanup EXIT
mkdir -p "$SANDBOX/scripts/internal" "$SANDBOX/scripts/lib" "$SANDBOX/bin"
cp "$ROOT/data/scripts/internal/checkHeapAndRestart.sh" "$SANDBOX/scripts/internal/"
# Double du lecteur RSS, vérifié avec des fixtures /proc dans la suite Python.
cat > "$SANDBOX/scripts/lib/service_memory.py" <<'MOCK'
import os, sys
if sys.argv[1] != '/server' or os.environ.get('MOCK_MEMORY_RC', '0') != '0':
    sys.exit(1)
print(os.environ.get('MOCK_MEMORY', '[not set]'))
MOCK
# Réutilise les vrais chemins privés, les vrais défauts et la vraie mesure d'âge.
printf 'source %q\nsource_env() { :; }\n' "$ROOT/data/scripts/lib/common.sh" > "$SANDBOX/scripts/lib/common.sh"
cat > "$SANDBOX/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
    *" is-active "*) exit "${MOCK_ACTIVE_RC:-0}" ;;
    *" show "*" -p ControlGroup "*)
        [[ "${MOCK_MEMORY_RC:-0}" == 0 ]] || exit "$MOCK_MEMORY_RC"
        printf '/server\n' ;;
    *) echo "systemctl inattendu: $*" >&2; exit 99 ;;
esac
MOCK
cat > "$SANDBOX/pzm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$MOCK_CASE/restart"
exit "${MOCK_RESTART_RC:-0}"
MOCK
chmod +x "$SANDBOX/bin/systemctl" "$SANDBOX/pzm"
export PATH="$SANDBOX/bin:$PATH" PZ_MANAGER_DIR="$SANDBOX" PZ_SERVICE_NAME=zomboid.service
export HEAP_RESTART_PERCENT=95 HEAP_RESTART_DELAY=5m PZ_RAM_RESTART_GB=18
PASS=0
check() { if "$@"; then PASS=$((PASS + 1)); else echo "[FAIL] $*" >&2; exit 1; fi; }
setup_case() {
    export MOCK_CASE="$SANDBOX/$1" LOG_ZOMBOID_DIR="$SANDBOX/$1/logs" XDG_RUNTIME_DIR="$SANDBOX/$1/rt"
    mkdir -p "$LOG_ZOMBOID_DIR" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    # Chaque cas repart sans panne de bus, cooldown, restart ni mesure antérieure.
    unset MOCK_ACTIVE_RC MOCK_MEMORY_RC MOCK_RESTART_RC
    export MOCK_MEMORY=$((18 * 1073741824 - 1)) PZ_RAM_RESTART_GB=18
}
run() { bash "$SANDBOX/scripts/internal/checkHeapAndRestart.sh" > "$MOCK_CASE/output" 2>&1; }
gc() { printf 'Major Collection (Timer) 20000M(98%%)->18000M(%s%%) 0.1s\n' "$1" > "$LOG_ZOMBOID_DIR/gc.log"; }

setup_case below
check run
check test ! -e "$MOCK_CASE/restart"
setup_case equality_without_gc
export MOCK_MEMORY=$((18 * 1073741824))
check run
check grep -q 'RAM totale PZ (jeu et gestion) à 18.0 Go' "$MOCK_CASE/restart"
check grep -qx 5m "$MOCK_CASE/restart"
check test "$(stat -c %a "$XDG_RUNTIME_DIR/pzmanager")" = 700
# Même état : un seul préavis, même si le timer est lancé une seconde fois.
check run
check test "$(grep -cx restart "$MOCK_CASE/restart")" = 1
setup_case high_ram_low_heap
gc 17
export MOCK_MEMORY=$((19 * 1073741824))
check run
check grep -q 'RAM totale PZ (jeu et gestion)' "$MOCK_CASE/restart"
setup_case heap_guard
gc 95
check run
check grep -q 'Heap Java post-GC à 95%' "$MOCK_CASE/restart"
setup_case missing_memory
export MOCK_MEMORY='[not set]'
check run
check test ! -e "$MOCK_CASE/restart"
setup_case bus_error_heap_guard
export MOCK_MEMORY_RC=1
gc 95
check run
check grep -q 'Heap Java post-GC' "$MOCK_CASE/restart"
setup_case stopped
export MOCK_ACTIVE_RC=3 MOCK_MEMORY=$((20 * 1073741824))
check run
check test ! -e "$MOCK_CASE/restart"
setup_case failed_restart
export MOCK_MEMORY=$((18 * 1073741824)) MOCK_RESTART_RC=1
if run; then echo '[FAIL] échec restart masqué'; exit 1; fi
check test ! -e "$XDG_RUNTIME_DIR/pzmanager/heapcheck.trigger"
unset MOCK_RESTART_RC
check run
check test "$(grep -cx restart "$MOCK_CASE/restart")" = 2
setup_case invalid_threshold
export PZ_RAM_RESTART_GB=20
if run; then echo '[FAIL] seuil >= plafond accepté'; exit 1; fi
check test ! -e "$MOCK_CASE/restart"
echo "MEMORY BUDGET: OK ($PASS contrôles)"
