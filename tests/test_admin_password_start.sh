#!/usr/bin/env bash
# Lanceur ExecStart réel et vrai parent RO/leaf RW, dans rootfs jetable seulement.
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
cp -a "$ROOT/data/scripts" "$manager/data/scripts"
[[ -x "$manager/data/scripts/internal/startServer.sh" ]]
runtime="$base/runtime"
mkdir -m 0700 "$runtime"
python3 - "$manager" "$home" <<'CONFIG'
from pathlib import Path
import shlex,sys
manager,home=map(Path,sys.argv[1:])
values=dict(PZ_USER='pzpwd',PZ_HOME=str(home),PZ_MANAGER_DIR=str(manager),
            PZ_SERVER_NAME='pwd-fixture')
(manager/'.env').write_text(''.join('export '+key+'='+shlex.quote(value)+'\n' for key,value in values.items()))
CONFIG
chmod 0640 "$manager/.env"
printf 'fixture-secret\n' > "$manager/.admin_password"
mkfifo -m 0600 "$game/zomboid.control"
printf '{"vmArgs":["-Xmx8g"]}\n' > "$game/ProjectZomboid64.json"
cat > "$game/start-server.sh" <<'GAME'
#!/bin/sh
printf 'RUN' >> "$PZ_PWD_LOG"
printf '<%s>' "$@" >> "$PZ_PWD_LOG"
printf '\n' >> "$PZ_PWD_LOG"
printf 'FD-preserved\n' >&9
grep -Eq 'FLOCK.*WRITE' /proc/self/fdinfo/9
GAME
chmod 0755 "$game/start-server.sh"
chmod 0600 "$manager/.admin_password"
touch "$base/start.log" "$base/bus-called"
chown -R pzpwd:pzpwd "$home" "$runtime" "$base/start.log" "$base/bus-called"
# Les vrais lecteurs de cgroup gardent leurs contrôles, seuls les fichiers
# physiques de preuve de cette copie sont remplacés.
python3 - "$manager" "$base" <<'BUDGET'
from pathlib import Path
import re,sys
manager,base=map(Path,sys.argv[1:])
proc=base/'proc-cgroup';cg=base/'cgroups'
group=cg/'user.slice/user-65532.slice/user@65532.service/pz.slice/fixture.scope'
group.mkdir(parents=True)
proc.write_text('0::/'+str(group.relative_to(cg))+'\n')
for directory in [group,*group.parents]:
    if directory==cg:break
    (directory/'memory.max').write_text(str(20*1024**3))
(group.parent/'memory.swap.max').write_text('0')
(group.parent/'memory.current').write_text('0')
for name in ('shared_memory_budget.py','jvm_memory_budget.py'):
    file=manager/'data/scripts/lib'/name
    text,count=re.subn(r'proc_cgroup=Path\([^\n]*?\)',lambda _: 'proc_cgroup=Path('+repr(str(proc))+')',file.read_text())
    assert count>=1,name
    text,count=re.subn(r'cgroup_root=Path\([^\n]*?\)',lambda _: 'cgroup_root=Path('+repr(str(cg))+')',text)
    assert count>=1,name
    file.write_text(text)
for file in [proc,*cg.rglob('*')]:
    file.chmod(0o755 if file.is_dir() else 0o644)
cg.chmod(0o755)
BUDGET
# Extraire les deux commandes réellement installées, sans les reconstituer.
python3 - "$ROOT/data/setupTemplates/zomboid.service" "$home" "$base" <<'FRAGMENT'
import shlex,sys
from pathlib import Path
unit=Path(sys.argv[1]).read_text().splitlines()
home,base=map(Path,sys.argv[2:])
start=shlex.split(next(line for line in unit if line.startswith('ExecStart=')).split('=',1)[1].replace('%h',str(home)))
check=shlex.split(next(line for line in unit if line.startswith('ExecStartPre=') and 'startServer.sh --check' in line).split('=',1)[1].replace('%h',str(home)))
assert start==[str(home/'pzmanager/data/scripts/internal/startServer.sh')]
assert check==start+['--check']
assert 'ProtectSystem=strict' in unit
assert '%h/pzmanager' not in [token.lstrip('-') for line in unit if line.startswith('ReadWritePaths=') for token in line.split('=',1)[1].split()]
for name,args in [('start-unit',start),('check-unit',check)]:
    file=base/name
    file.write_text('#!/bin/bash\nexec '+shlex.join(args)+'\n')
    file.chmod(0o755)
FRAGMENT
mkdir "$base/bin"
chmod 0755 "$base/bin"
for command in systemctl systemd-run; do
    printf '#!/bin/sh\nprintf "called\\n" >> "$PZ_PWD_BUS"\nexit 97\n' > "$base/bin/$command"
    chmod 0755 "$base/bin/$command"
done
mount --bind "$manager" "$manager"
mount --bind "$game" "$game"
leaf=false
if grep -qx 'ReadWritePaths=-%h/pzmanager/.admin_password' "$ROOT/data/setupTemplates/zomboid.service"; then
    mount --bind "$manager/.admin_password" "$manager/.admin_password"
    leaf=true
fi
mount -o remount,bind,ro "$manager"
cleanup() {
    exec 8>&- 9>&-
    mount -o remount,bind,rw "$manager" 2>/dev/null || true
    [[ "$leaf" != true ]] || umount "$manager/.admin_password" 2>/dev/null || true
    umount "$game" 2>/dev/null || true
    umount "$manager" 2>/dev/null || true
    rm -rf "$base"
}
trap cleanup EXIT
as_user() { setpriv --reuid 65532 --regid 65532 --clear-groups "$@"; }
if as_user touch "$manager/forbidden" 2>/dev/null; then echo 'Parent pas RO.' >&2; exit 1; fi
exec 9>"$base/inherited-fd"
flock -x 9
exec 8<>"$game/zomboid.control"
run_unit() { as_user env PATH="$base/bin:$PATH" XDG_RUNTIME_DIR="$runtime" PZ_PWD_LOG="$base/start.log" PZ_PWD_BUS="$base/bus-called" "$base/$1"; }
run_start() { run_unit start-unit; }
# Le préflight lit la même configuration et le vrai JSON choisi, sans réparer
# le .env, consommer le secret, ouvrir/drainer la FIFO ni acquérir un verrou.
config_hash="$(sha256sum "$manager/.env")"
printf 'preflight-pending\n' >&8
run_unit check-unit
IFS= read -r -t 1 -u 8 pending
[[ "$pending" == preflight-pending && "$(sha256sum "$manager/.env")" == "$config_hash" ]]
[[ "$(stat -c %a "$manager/.env")" == 640 && "$(cat "$manager/.admin_password")" == fixture-secret ]]
[[ ! -s "$base/start.log" && ! -s "$base/bus-called" && ! -e "$runtime/pzmanager" ]]
printf '{"vmArgs":["-Xmx20g"]}\n' > "$game/ProjectZomboid64.json"
if run_unit check-unit > "$base/bad-heap.log" 2>&1; then echo 'Mauvais heap accepté.' >&2; exit 1; fi
if run_start >> "$base/bad-heap.log" 2>&1; then echo 'Lancement malgré mauvais heap.' >&2; exit 1; fi
grep -q 'Heap incompatible' "$base/bad-heap.log"
[[ ! -s "$base/start.log" && "$(cat "$manager/.admin_password")" == fixture-secret ]]
printf '{"vmArgs":["-Xmx8g"]}\n' > "$game/ProjectZomboid64.json"
run_start
[[ ! -s "$manager/.admin_password" ]] || { echo 'FAIL secret non consommé sous parent RO.' >&2; exit 1; }
[[ "$(stat -c '%u:%a' "$manager/.admin_password")" == 65532:600 ]]
grep -q '<-adminpassword><fixture-secret>' "$base/start.log"
run_start
[[ "$(grep -c adminpassword "$base/start.log")" == 1 && "$(wc -l < "$base/start.log")" == 2 ]]
[[ "$(grep -c FD-preserved "$base/inherited-fd")" == 2 && ! -s "$base/bus-called" ]]
echo 'OK secret consommé une fois ; second boot sans adminpassword ; leaf vide 0600, parent RO.'
# La consommation qui échoue doit empêcher l'exec du serveur.
as_user sh -c 'printf retry-secret > "$1"' _ "$manager/.admin_password"
mount -o remount,bind,ro "$manager/.admin_password"
if run_start > "$base/blocked.log" 2>&1; then echo 'Troncature refusée non bloquante.' >&2; exit 1; fi
[[ "$(wc -l < "$base/start.log")" == 2 && "$(cat "$manager/.admin_password")" == retry-secret ]]
echo 'OK leaf RO : échec de consommation bloquant avant exec serveur.'
