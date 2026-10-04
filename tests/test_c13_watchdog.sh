#!/usr/bin/env bash
# test_c13_watchdog.sh - Watchdog lié à l'invocation diagnostiquée (C13).
#
# Couvre (data/scripts/internal/watchServerStall.sh uniquement) :
#   (0) câblage statique : capture InvocationID/MainPID/ActiveEnter dans le
#       STATE_FILE, verrou monde --try avant SIGKILL, abandon si invocation
#       changée, repli PID+ActiveEnter si InvocationID indisponible.
#   (A) nominal, même invocation -> SIGKILL (systemctl kill appelé) + restart.
#   (A0) ancien STATE_FILE à 4 champs toujours relu (pas de crash, réécrit à
#       7 champs).
#   (B) race : restart simulé PENDANT la capture (InvocationID basculé par un
#       flipper dès le début du dump) -> kill ANNULÉ, pas de restart, reset.
#   (C) InvocationID indisponible (vide) -> repli PID+ActiveEnter : MainPID
#       basculé pendant la capture -> kill ANNULÉ.
#
# Preuves réelles : vrai script rejoué (bash), vrais awk/grep/timeout,
# mocks seulement aux frontières inaccessibles : systemd (systemctl),
# JVM (pgrep/jcmd/top), journal (journalctl), Prometheus (curl), restart
# (pzm). `sleep 10` de capture raccourci (0,2 s) via mock, sans changer la
# séquence. Isolé : XDG_RUNTIME_DIR + PZ_MANAGER_DIR redirigés vers un sandbox
# par cas (aucun impact prod). Aucun systemd réel requis (sous Linux/WSL).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET="${ROOT}/data/scripts/internal/watchServerStall.sh"
# Sandbox sur fs POSIX (TMPDIR, /tmp sous WSL) et NON sous tests/ : le script
# exige un XDG_RUNTIME_DIR en 0700 réel (stat), ce que NTFS (checkout Windows)
# ne porte pas — chmod sans effet -> refus silencieux (exit 1).
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/c13-watchdog-XXXXXX")"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    # C13_KEEP=1 : conserve le sandbox pour diagnostic (stdout.log par cas).
    [[ "${C13_KEEP:-0}" == "1" ]] || rm -rf "$SANDBOX"
}
trap cleanup EXIT

[[ -f "$TARGET" ]] || { echo "[FAIL] cible introuvable : $TARGET" >&2; exit 1; }

# --- (0) câblage statique -------------------------------------------------------
echo "== (0) câblage =="
grep -q 'InvocationID' "$TARGET" \
    && ok "capture de l'InvocationID présente" \
    || ko "InvocationID absent du script"
grep -q 'acquire_world_lock --try' "$TARGET" \
    && ok "verrou monde --try avant SIGKILL" \
    || ko "acquire_world_lock --try absent"
grep -q 'abandon du SIGKILL' "$TARGET" \
    && ok "abandon du SIGKILL tracé" \
    || ko "abandon du SIGKILL absent"
grep -q 'ActiveEnter' "$TARGET" \
    && ok "repli ActiveEnter présent" \
    || ko "repli ActiveEnter absent"
grep -q 'write_state' "$TARGET" \
    && ok "écriture d'état centralisée (write_state)" \
    || ko "write_state absent"

# --- Fabrique d'un cas isolé ----------------------------------------------------
# setup_case <nom> : prépare $S/{rt,logs,scripts,bin,pzmroot,mock} et exporte
# l'env ; imprime le chemin $S sur stdout.
setup_case() {
    local s="${SANDBOX}/$1"
    rm -rf "$s"
    mkdir -p "$s/rt" "$s/logs" "$s/scripts/internal" "$s/scripts/lib" "$s/bin" "$s/pzmroot" "$s/mock"
    chmod 700 "$s/rt"
    cp "$TARGET" "$s/scripts/internal/watchServerStall.sh"
    chmod +x "$s/scripts/internal/watchServerStall.sh"

    # Stub common.sh : source_env/log/notify + server_is_active + world lock.
    # server_is_active devient faux dès le kill (systemd qui constate la mort),
    # ce qui termine la boucle d'attente de 30 s sans la subir.
    cat > "$s/scripts/lib/common.sh" <<'MOCKEOF'
source_env() { :; }
server_is_active() { [[ ! -f "${MOCK_DIR:-/nonexistent}/kill_called" ]]; }
log() { printf '%s\n' "$*"; }
notify() { return 0; }
acquire_world_lock() {
    if [[ "${1:-}" == "--try" && "${WORLD_LOCK_BUSY:-0}" == "1" ]]; then return 1; fi
    return 0
}
release_world_lock() { return 0; }
MOCKEOF

    # Mock systemctl : show MainPID/InvocationID/ActiveEnter, kill enregistreur.
    cat > "$s/bin/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ " $* " == *" show "* ]]; then
    prop=""
    prev=""
    for a in "$@"; do
        if [[ "$prev" == "-p" ]]; then prop="$a"; fi
        prev="$a"
    done
    case "$prop" in
        InvocationID) cat "${MOCK_DIR}/mock_invocation" 2>/dev/null || true ;;
        MainPID) cat "${MOCK_DIR}/mock_mainpid" 2>/dev/null || true ;;
        ActiveEnterTimestampMonotonic) cat "${MOCK_DIR}/mock_enter" 2>/dev/null || true ;;
        ActiveEnterTimestamp) cat "${MOCK_DIR}/mock_enter_ts" 2>/dev/null || true ;;
        *) printf '' ;;
    esac
    exit 0
fi
if [[ " $* " == *" is-active "* ]]; then exit 0; fi
if [[ " $* " == *" kill "* ]]; then
    : > "${MOCK_DIR}/kill_called"
    echo "killed: $*" >> "${MOCK_DIR}/kill_log"
    exit 0
fi
echo "mock-systemctl: args inattendus: $*" >&2
exit 99
MOCKEOF
    cat > "$s/bin/pgrep" <<'MOCKEOF'
#!/usr/bin/env bash
cat "${MOCK_DIR}/mock_pid"
MOCKEOF
    cat > "$s/bin/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s.000 host prog: f:%s st:ready\n' "${MOCK_STAMP:-2000}" "${MOCK_FRAME:-42}"
MOCKEOF
    cat > "$s/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo 'game{parameter="players"} 1'
MOCKEOF
    cat > "$s/bin/top" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock-top"
MOCKEOF
    # jcmd : main RUNNABLE avec cpu/elapsed croissants -> burn ~100 % (>= 60).
    cat > "$s/bin/jcmd" <<'MOCKEOF'
#!/usr/bin/env bash
n="$(cat "${MOCK_DIR}/jcmd_count" 2>/dev/null || echo 0)"
n=$(( n + 1 )); printf '%s' "$n" > "${MOCK_DIR}/jcmd_count"
cpu=$(( 100000 + n * 10000 )); el=$(( 100 + n * 10 ))
printf '"main" #1 prio=5 os_prio=0 cpu=%d.00ms elapsed=%d.00s tid=0x2 nid=0x2 runnable [0x0]\n' "$cpu" "$el"
MOCKEOF
    # sleep : capture `sleep 10` raccourcie, le reste au réel.
    cat > "$s/bin/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "10" ]]; then exec /bin/sleep 0.2; fi
exec /bin/sleep "$@"
MOCKEOF
    # pzm : enregistre le restart demandé.
    cat > "$s/pzmroot/pzm" <<'MOCKEOF'
#!/usr/bin/env bash
echo "pzm $*" >> "${MOCK_DIR}/restart_log"
exit 0
MOCKEOF
    chmod +x "$s/bin/"* "$s/pzmroot/pzm"
    printf '%s' "$s"
}

# run_watch <dir-cas> <fichier-stdout> : rejoue le vrai script, imprime son rc.
run_watch() {
    local s="$1" out="$2"
    env PATH="$s/bin:$PATH" \
        XDG_RUNTIME_DIR="$s/rt" \
        PZ_SERVICE_NAME="zomboid.service" \
        PZ_PROMETHEUS_PORT="1" \
        LOG_ZOMBOID_DIR="$s/logs" \
        LOG_RETENTION_DAYS="7" \
        PZ_MANAGER_DIR="$s/pzmroot" \
        PZ_GRAALVM_HOME="" \
        STALL_WATCH_SAMPLES="1" \
        STALL_AUTO_RESTART="1" \
        STALL_BURN_MIN_PCT="60" \
        DISCORD_ADMIN_WEBHOOK="" \
        MOCK_DIR="$s/mock" \
        MOCK_STAMP="${MOCK_STAMP:-2000}" \
        MOCK_FRAME="${MOCK_FRAME:-42}" \
        WORLD_LOCK_BUSY="${WORLD_LOCK_BUSY:-0}" \
        timeout 120 bash "$s/scripts/internal/watchServerStall.sh" >"$out" 2>&1
    echo $?
}

export MOCK_FRAME=42 MOCK_STAMP=2000 WORLD_LOCK_BUSY=0

# --- (A) nominal : même invocation -> kill + restart -----------------------------
echo "== (A) nominal =="
SA="$(setup_case nominal)"
INV_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf '%s' "$INV_A" > "$SA/mock/mock_invocation"
printf '123' > "$SA/mock/mock_mainpid"
printf '1000000' > "$SA/mock/mock_enter"
printf '' > "$SA/mock/mock_enter_ts"
printf '123' > "$SA/mock/mock_pid"
mkdir -p "$SA/rt/pzmanager"
printf '123 42 1999 0 %s 123 1000000\n' "$INV_A" > "$SA/rt/pzmanager/stallwatch.state"
RC="$(run_watch "$SA" "$SA/stdout.log")"
[[ "$RC" == "0" ]] \
    && ok "nominal : exit 0 (rc=$RC)" \
    || ko "nominal : exit $RC (attendu 0) -- $(tail -3 "$SA/stdout.log")"
[[ -f "$SA/mock/kill_called" ]] \
    && ok "nominal : systemctl kill appelé (même invocation)" \
    || ko "nominal : kill NON appelé (aurait dû tuer)"
[[ -s "$SA/mock/restart_log" ]] \
    && ok "nominal : restart demandé ($(cat "$SA/mock/restart_log"))" \
    || ko "nominal : restart NON demandé"
grep -q 'SIGKILL' "$SA/stdout.log" \
    && ok "nominal : SIGKILL tracé" \
    || ko "nominal : SIGKILL absent du log"
STATE_A="$(cat "$SA/rt/pzmanager/stallwatch.state" 2>/dev/null || true)"
RE7='^[0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9a-fA-F-]+ [0-9]+ [0-9]+$'
if [[ "$STATE_A" =~ $RE7 ]]; then
    ok "nominal : STATE_FILE au format 7 champs"
else
    ko "nominal : STATE_FILE inattendu : '$STATE_A'"
fi

# --- (A0) compat : ancien STATE_FILE à 4 champs -----------------------------------
echo "== (A0) compat ancien format =="
SB="$(setup_case compat)"
printf '%s' "$INV_A" > "$SB/mock/mock_invocation"
printf '123' > "$SB/mock/mock_mainpid"
printf '1000000' > "$SB/mock/mock_enter"
printf '' > "$SB/mock/mock_enter_ts"
printf '123' > "$SB/mock/mock_pid"
mkdir -p "$SB/rt/pzmanager"
printf '123 42 1999 08\n' > "$SB/rt/pzmanager/stallwatch.state"
RC="$(run_watch "$SB" "$SB/stdout.log")"
[[ "$RC" == "0" ]] \
    && ok "compat : exit 0 sans crash sur 4 champs (rc=$RC)" \
    || ko "compat : exit $RC -- $(tail -3 "$SB/stdout.log")"
STATE_B="$(cat "$SB/rt/pzmanager/stallwatch.state" 2>/dev/null || true)"
RE7B='^123 42 [0-9]+ [0-9]+ [0-9a-fA-F-]+ [0-9]+ [0-9]+$'
if [[ "$STATE_B" =~ $RE7B ]]; then
    ok "compat : état réécrit à 7 champs ('$STATE_B')"
else
    ko "compat : état inattendu : '$STATE_B'"
fi

# --- (B) race : restart PENDANT la capture -> abandon -----------------------------
echo "== (B) race restart pendant capture =="
SC="$(setup_case race)"
INV_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf '%s' "$INV_A" > "$SC/mock/mock_invocation"
printf '123' > "$SC/mock/mock_mainpid"
printf '1000000' > "$SC/mock/mock_enter"
printf '' > "$SC/mock/mock_enter_ts"
printf '123' > "$SC/mock/mock_pid"
mkdir -p "$SC/rt/pzmanager"
printf '123 42 1999 0 %s 123 1000000\n' "$INV_A" > "$SC/rt/pzmanager/stallwatch.state"
# Flipper déterministe : bascule l'InvocationID dès que la capture commence
# (création de stall_*.txt), donc avant la revérification pré-SIGKILL.
(
    for _ in $(seq 1 200); do
        if ls "$SC/logs"/stall_*.txt >/dev/null 2>&1; then
            printf '%s' "$INV_B" > "$SC/mock/mock_invocation"
            exit 0
        fi
        /bin/sleep 0.05
    done
    echo "flipper: capture jamais commencée" >&2
) &
FLIP_PID=$!
RC="$(run_watch "$SC" "$SC/stdout.log")"
wait "$FLIP_PID" 2>/dev/null || true
[[ "$RC" == "0" ]] \
    && ok "race : exit 0 (rc=$RC)" \
    || ko "race : exit $RC (attendu 0) -- $(tail -3 "$SC/stdout.log")"
[[ ! -f "$SC/mock/kill_called" ]] \
    && ok "race : systemctl kill NON appelé (restart entre-temps)" \
    || ko "race : kill appelé malgré le restart (aurait dû abandonner)"
[[ ! -s "$SC/mock/restart_log" ]] \
    && ok "race : aucun restart demandé" \
    || ko "race : restart demandé à tort"
grep -q 'abandon du SIGKILL' "$SC/stdout.log" \
    && ok "race : abandon tracé" \
    || ko "race : abandon absent du log -- $(tail -5 "$SC/stdout.log")"
STATE_C="$(cat "$SC/rt/pzmanager/stallwatch.state" 2>/dev/null || true)"
REC='^123 42 [0-9]+ 0 '
if [[ "$STATE_C" =~ $REC ]]; then
    ok "race : état réinitialisé (strikes 0)"
else
    ko "race : état non réinitialisé : '$STATE_C'"
fi

# --- (C) repli : InvocationID vide, PID changé -> abandon --------------------------
echo "== (C) repli sans InvocationID =="
SD="$(setup_case fallback)"
printf '' > "$SD/mock/mock_invocation"
printf '123' > "$SD/mock/mock_mainpid"
printf '' > "$SD/mock/mock_enter"
printf '' > "$SD/mock/mock_enter_ts"
printf '123' > "$SD/mock/mock_pid"
mkdir -p "$SD/rt/pzmanager"
printf '123 42 1999 0 - 123 0\n' > "$SD/rt/pzmanager/stallwatch.state"
# Même flipper : le MainPID change pendant la capture (123 -> 456),
# InvocationID restant indisponible des deux côtés -> repli PID+ActiveEnter.
(
    for _ in $(seq 1 200); do
        if ls "$SD/logs"/stall_*.txt >/dev/null 2>&1; then
            printf '456' > "$SD/mock/mock_mainpid"
            exit 0
        fi
        /bin/sleep 0.05
    done
    echo "flipper: capture jamais commencée" >&2
) &
FLIP_PID=$!
RC="$(run_watch "$SD" "$SD/stdout.log")"
wait "$FLIP_PID" 2>/dev/null || true
[[ "$RC" == "0" ]] \
    && ok "repli : exit 0 (rc=$RC)" \
    || ko "repli : exit $RC (attendu 0) -- $(tail -3 "$SD/stdout.log")"
[[ ! -f "$SD/mock/kill_called" ]] \
    && ok "repli : systemctl kill NON appelé (PID changé, sans InvocationID)" \
    || ko "repli : kill appelé malgré le PID changé (aurait dû abandonner)"
grep -q 'abandon du SIGKILL' "$SD/stdout.log" \
    && ok "repli : abandon tracé" \
    || ko "repli : abandon absent du log -- $(tail -5 "$SD/stdout.log")"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C13 WATCHDOG: OK (${PASS} contrôles)"
else
    echo "C13 WATCHDOG: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
