#!/usr/bin/env bash
# Vrais flock et fichiers jetables : aucun appel au serveur ni aux bases joueurs.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB="${ROOT}/data/scripts/lib/common.sh"
SANDBOX="$(mktemp -d /tmp/pz-serverctl-test.XXXXXX)"
HOLDER=""
cleanup() {
    if [[ -n "$HOLDER" ]]; then kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; fi
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT
PASS=0
check() { if "$@"; then PASS=$((PASS + 1)); else echo "[FAIL] $*" >&2; exit 1; fi; }
run() { bash -eu -c 'source "$1"; shift; eval "$1"' bash "$LIB" "$1"; }
export TEST_SANDBOX="$SANDBOX"
mkdir "$SANDBOX/runtime"

# La bibliothèque doit rester utilisable même quand aucun verrou ne peut être créé.
check run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/absent"; true'
if ! run 'declare -F serverctl_lock_path >/dev/null'; then
    echo '[FAIL] serverctl utilise encore le verrou partagé prévisible sous /tmp.' >&2
    exit 1
fi

# La configuration XDG peut être posée après le sourçage. Umask ouvert sans fuite.
check run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; umask 000; acquire_serverctl_lock_or_die; [[ "$SERVERCTL_LOCK_FILE" == "$XDG_RUNTIME_DIR/pzmanager/serverctl.lock" && -n "$SERVERCTL_LOCK_FD" ]]; [[ "$(stat -c %a "$XDG_RUNTIME_DIR/pzmanager")" == 700 ]]'

# Deux processus distincts doivent réellement se disputer le même inode.
bash -eu -c 'source "$1"; export XDG_RUNTIME_DIR="$2/runtime"; acquire_serverctl_lock_or_die; echo ready > "$2/ready"; while [[ ! -f "$2/release" ]]; do sleep 0.05; done' bash "$LIB" "$SANDBOX" &
HOLDER=$!
for ((i=0; i<100; i++)); do
    [[ -f "$SANDBOX/ready" ]] && break
    sleep 0.05
done
check test -f "$SANDBOX/ready"
if run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; acquire_serverctl_lock_or_die' >/dev/null 2>&1; then
    echo '[FAIL] acquisition concurrente acceptée' >&2; exit 1
fi
PASS=$((PASS + 1))
touch "$SANDBOX/release"
wait "$HOLDER"; HOLDER=""
check run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; acquire_serverctl_lock_or_die'

# Aucun suivi de lien ni attente sur un FIFO, même après un ancien état permissif.
LOCK="$SANDBOX/runtime/pzmanager/serverctl.lock"
rm "$LOCK"
printf 'intact\n' > "$SANDBOX/cible"
ln -s "$SANDBOX/cible" "$LOCK"
if run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; acquire_serverctl_lock_or_die' >/dev/null 2>&1; then exit 1; fi
check test "$(cat "$SANDBOX/cible")" = intact
rm "$LOCK"; mkfifo "$LOCK"
set +e
timeout 2 bash -eu -c 'source "$1"; export XDG_RUNTIME_DIR="$2/runtime"; acquire_serverctl_lock_or_die' bash "$LIB" "$SANDBOX" >/dev/null 2>&1
rc=$?
set -e
check test "$rc" -eq 1
rm "$LOCK"; ln "$SANDBOX/cible" "$LOCK"
if run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; acquire_serverctl_lock_or_die' >/dev/null 2>&1; then exit 1; fi
check test "$(cat "$SANDBOX/cible")" = intact
rm "$LOCK"

# Un parent remplaçable par un autre utilisateur n'est pas un abri privé.
mkdir -p "$SANDBOX/partage/runtime"
chmod 0777 "$SANDBOX/partage"
if run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/partage/runtime"; acquire_serverctl_lock_or_die' >/dev/null 2>&1; then exit 1; fi
check test ! -e "$SANDBOX/partage/runtime/pzmanager"

# Échec de chmod : ne jamais accepter un répertoire resté accessible aux tiers.
chmod 0755 "$SANDBOX/runtime/pzmanager"
if run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; chmod() { return 1; }; acquire_serverctl_lock_or_die' >/dev/null 2>&1; then exit 1; fi
check test "$(stat -c %a "$SANDBOX/runtime/pzmanager")" = 755
chmod 0700 "$SANDBOX/runtime/pzmanager"
check run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/runtime"; acquire_serverctl_lock_or_die'

# Un XDG relatif doit être refusé, sans boucle infinie sur dirname '.'.
set +e
timeout 2 bash -eu -c 'cd "$2"; source "$1"; export XDG_RUNTIME_DIR=runtime; acquire_serverctl_lock_or_die' bash "$LIB" "$SANDBOX" >/dev/null 2>&1
rc=$?
set -e
check test "$rc" -eq 1

# La résolution du repli ne doit pas être rejouée par le helper générique.
# Simuler l'apparition hostile du runtime dans cette ancienne fenêtre.
check run 'export XDG_RUNTIME_DIR="$TEST_SANDBOX/partage/nouveau"; private_state_path() { mkdir -p "$XDG_RUNTIME_DIR/pzmanager"; printf "%s\n" "$XDG_RUNTIME_DIR/pzmanager/serverctl.lock"; }; acquire_serverctl_lock_or_die; [[ "$SERVERCTL_LOCK_FILE" != "$XDG_RUNTIME_DIR/pzmanager/serverctl.lock" ]]'
echo "SEC SERVERCTL: OK ($PASS contrôles)"
