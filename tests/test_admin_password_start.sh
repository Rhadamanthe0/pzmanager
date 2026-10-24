#!/usr/bin/env bash
# Fragment ExecStart réel et vrai parent RO/leaf RW, dans rootfs jetable seulement.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?copie Linux jetable requise}"
if (( EUID != 0 )) || ! awk '$1 == 0 && $2 != 0 { mapped=1 } END { exit !mapped }' /proc/self/uid_map \
    || [[ "$(stat -f -c %T /)" != tmpfs ]]; then
    echo 'SKIP fragment privilégié : rootfs tmpfs avec UID mappé requis.'
    exit
fi
chmod 0755 / /etc /home /run
chmod 0644 /etc/passwd /etc/group /etc/nsswitch.conf
printf 'pzpwd:x:65532:65532::/home/pzpwd:/bin/sh\n' >> /etc/passwd
printf 'pzpwd:x:65532:\n' >> /etc/group
base="$(mktemp -d /tmp/pz-admin-secret-XXXXXXXX)"
chmod 0755 "$base"
home="$base/home"; manager="$home/pzmanager"; game="$manager/data/pzserver"
mkdir -p "$game"
printf 'export PZ_SERVER_NAME=pwd-fixture\n' > "$manager/.env"
printf 'fixture-secret\n' > "$manager/.admin_password"
: > "$game/zomboid.control"
cat > "$game/start-server.sh" <<'GAME'
#!/bin/sh
printf 'RUN' >> "$PZ_PWD_LOG"
printf '<%s>' "$@" >> "$PZ_PWD_LOG"
printf '\n' >> "$PZ_PWD_LOG"
GAME
chmod 0755 "$game/start-server.sh"
chmod 0600 "$manager/.admin_password"
touch "$base/start.log"
chown -R pzpwd:pzpwd "$home" "$base/start.log"
# shlex enlève uniquement le quoting de l'argument /bin/sh -c, sans exécuter.
python3 - "$ROOT/data/setupTemplates/zomboid.service" "$home" "$base/fragment" <<'FRAGMENT'
import shlex,sys
from pathlib import Path
unit=Path(sys.argv[1]).read_text().splitlines()
line=next(line for line in unit if line.startswith('ExecStart='))
args=shlex.split(line.split('=',1)[1])
assert args[:2]==['/bin/sh','-c'] and len(args)==3
assert '%h/pzmanager' not in [token.lstrip('-') for line in unit if line.startswith('ReadWritePaths=') for token in line.split('=',1)[1].split()]
Path(sys.argv[3]).write_text(args[2].replace('%h',sys.argv[2]))
FRAGMENT
chmod 0644 "$base/fragment"
mount --bind "$manager" "$manager"
mount --bind "$game" "$game"
leaf=false
if grep -qx 'ReadWritePaths=-%h/pzmanager/.admin_password' "$ROOT/data/setupTemplates/zomboid.service"; then
    mount --bind "$manager/.admin_password" "$manager/.admin_password"
    leaf=true
fi
mount -o remount,bind,ro "$manager"
cleanup() {
    mount -o remount,bind,rw "$manager" 2>/dev/null || true
    [[ "$leaf" != true ]] || umount "$manager/.admin_password" 2>/dev/null || true
    umount "$game" 2>/dev/null || true
    umount "$manager" 2>/dev/null || true
    rm -rf "$base"
}
trap cleanup EXIT
as_user() { setpriv --reuid 65532 --regid 65532 --clear-groups "$@"; }
if as_user touch "$manager/forbidden" 2>/dev/null; then echo 'Parent pas RO.' >&2; exit 1; fi
run_start() { as_user env PZ_PWD_LOG="$base/start.log" /bin/sh -c "$(cat "$base/fragment")"; }
run_start
[[ ! -s "$manager/.admin_password" ]] || { echo 'FAIL secret non consommé sous parent RO.' >&2; exit 1; }
[[ "$(stat -c '%u:%a' "$manager/.admin_password")" == 65532:600 ]]
grep -q '<-adminpassword><fixture-secret>' "$base/start.log"
run_start
[[ "$(grep -c adminpassword "$base/start.log")" == 1 && "$(wc -l < "$base/start.log")" == 2 ]]
echo 'OK secret consommé une fois ; second boot sans adminpassword ; leaf vide 0600, parent RO.'
# La consommation qui échoue doit empêcher l'exec du serveur.
as_user sh -c 'printf retry-secret > "$1"' _ "$manager/.admin_password"
mount -o remount,bind,ro "$manager/.admin_password"
if run_start > "$base/blocked.log" 2>&1; then echo 'Troncature refusée non bloquante.' >&2; exit 1; fi
[[ "$(wc -l < "$base/start.log")" == 2 && "$(cat "$manager/.admin_password")" == retry-secret ]]
echo 'OK leaf RO : échec de consommation bloquant avant exec serveur.'
