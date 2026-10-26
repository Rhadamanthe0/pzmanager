#!/usr/bin/env bash
# Aucun pip/venv réel : seuls l'adaptateur d'installation et systemctl sont
# remplacés ; le lecteur de budget utilise les preuves privées du runner.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?copie Linux jetable requise}"
SETUP="$ROOT/data/scripts/install/setupDiscordBot.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
if (( EUID == 0 )); then
    if bash "$SETUP" > "$SANDBOX/out" 2>&1; then exit 1; fi
    grep -q 'compte manager' "$SANDBOX/out"
    echo 'OK installation Discord refusée sous root avant venv/pip.'
    exit
fi
if [[ -f "$ROOT/.env" ]]; then cp -p "$ROOT/.env" "$SANDBOX/env.original"; fi
cleanup() {
    if [[ -f "$SANDBOX/env.original" ]]; then cp -p "$SANDBOX/env.original" "$ROOT/.env"; else rm -f "$ROOT/.env"; fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT
export SETUP_CALLS="$SANDBOX/calls" MOCK_EXPECTED_VENV="$SANDBOX/discord/.venv"
export HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/runtime"
mkdir -p "$SANDBOX/bin" "$SANDBOX/discord" "$HOME/.config/systemd/user" "$XDG_RUNTIME_DIR"
cp "$ROOT/data/setupTemplates/pz.slice" "$HOME/.config/systemd/user/pz.slice"
cp "$ROOT/data/scripts/discord/requirements.txt" "$SANDBOX/discord/requirements.txt"
printf 'export PZ_USER=%q\nexport PZ_HOME=%q\nexport PZ_MANAGER_DIR=%q\nexport PZ_SCRIPTS_DIR=%q\nexport PZ_DATA_DIR=%q\n' \
    "$(id -un)" "$HOME" "$ROOT" "$SANDBOX" "$ROOT/data" > "$ROOT/.env"
export REAL_SETUP_PYTHON="$(command -v python3)"
cat > "$SANDBOX/bin/python3" <<'PYTHON'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    */shared_memory_budget.py)
        printf 'budget %s\n' "${2:-}" >> "$SETUP_CALLS"
        exec "$REAL_SETUP_PYTHON" "$@" ;;
    -c) [[ "$2" == 'import ensurepip' ]]; exit ;;
    -m)
        [[ "$2" == venv && "$3" == "$MOCK_EXPECTED_VENV" ]]
        printf 'venv uid=%s %s\n' "$(id -u)" "$3" >> "$SETUP_CALLS"
        mkdir -p "$3/bin"
        cat > "$3/bin/python" <<'PIP'
#!/bin/bash
set -euo pipefail
[[ "$1" == -m && "$2" == pip && "$3" == install ]]
if [[ " $* " == *" --upgrade "* ]]; then
    [[ "${@: -1}" == 'pip>=26.2' ]]
    printf 'upgrade uid=%s %s\n' "$(id -u)" "$*" >> "$SETUP_CALLS"
    [[ "${MOCK_UPGRADE_FAIL:-0}" != 1 ]] || exit 23
else
    [[ " $* " == *" -r "* && "${@: -1}" == "${MOCK_EXPECTED_VENV%/.venv}/requirements.txt" ]]
    printf 'requirements uid=%s %s\n' "$(id -u)" "$*" >> "$SETUP_CALLS"
fi
PIP
        # Compatibilité du double avec l'ancien appel direct bin/pip, pour
        # que la régression échoue sur l'upgrade absent, pas sur un outil absent.
        printf '#!/bin/bash\nexec "$(dirname "$0")/python" -m pip "$@"\n' > "$3/bin/pip"
        chmod +x "$3/bin/python" "$3/bin/pip"
        ;;
    *) exec "$REAL_SETUP_PYTHON" "$@" ;;
esac
PYTHON
cat > "$SANDBOX/bin/systemctl" <<'SYSTEMCTL'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$SETUP_CALLS"
SYSTEMCTL
chmod +x "$SANDBOX/bin/python3" "$SANDBOX/bin/systemctl"
export PATH="$SANDBOX/bin:$PATH"
: > "$SETUP_CALLS"
bash "$SETUP" > "$SANDBOX/success.log" 2>&1
python3 - "$SETUP_CALLS" "$(id -u)" <<'ORDER'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text().splitlines()
find=lambda prefix: next(i for i,line in enumerate(lines) if line.startswith(prefix))
assert any(line.startswith('upgrade ') for line in lines), 'Mise à jour pip absente avant requirements'
assert find('budget check') < find('venv ') < find('upgrade ') < find('requirements ') < find('systemctl --user enable --now pz-discord-bot.service')
assert all('uid='+sys.argv[2]+' ' in line for line in lines if line.startswith(('venv ', 'upgrade ', 'requirements ')))
ORDER
[[ -f "$HOME/.config/systemd/user/pz-discord-bot.service" ]]
grep -qx 'aiohttp>=3.14.4,<4' "$SANDBOX/discord/requirements.txt"
echo 'OK budget vérifié, pip du venv manager mis à jour avant requirements.'
rm "$HOME/.config/systemd/user/pz-discord-bot.service"
: > "$SETUP_CALLS"
if MOCK_UPGRADE_FAIL=1 bash "$SETUP" > "$SANDBOX/failure.log" 2>&1; then exit 1; else status=$?; fi
[[ "$status" == 23 ]]
grep -q '^upgrade ' "$SETUP_CALLS"
! grep -qE '^requirements |^systemctl ' "$SETUP_CALLS"
[[ ! -e "$HOME/.config/systemd/user/pz-discord-bot.service" ]]
echo 'OK échec upgrade bloquant avant requirements, unité et activation.'
