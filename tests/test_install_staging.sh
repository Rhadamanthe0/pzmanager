#!/usr/bin/env bash
# Contrat libexec réel. Exécution privilégiée réservée au rootfs UID mappé
# jetable ; la suite ordinaire vérifie le contexte déclaratif sans privilège.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?copie Linux jetable requise}"
if (( EUID != 0 )); then
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    user="$(id -un)"
    home="$(getent passwd "$(id -u)" | cut -d: -f6)"
    printf 'PZ_USER=%s\nPZ_PORT_GAME=17261\nMALICIOUS="$(touch %s/pwned)"\n' "$user" "$fixture" > "$fixture/.env"
    bash -c 'source "$1/data/scripts/install/configurationInitiale.sh" --manager-root "$2"; load_root_env_declarative; [[ "$PZ_MANAGER_ROOT" == "$2" && "$PZ_MANAGER_DIR" == "$2" && "$PZ_USER" == "$3" && "$PZ_HOME" == "$4" && "$PZ_PORT_GAME" == 17261 && ! -e "$2/pwned" ]]' _ "$ROOT" "$fixture" "$user" "$home"
    echo 'OK contexte explicite et .env déclaratif ; staging root réservé au rootfs UID mappé.'
    exit
fi
# Ne jamais créer /usr/local ou /etc dans le namespace hôte.
if ! awk '$1 == 0 && $2 != 0 { mapped=1 } END { exit !mapped }' /proc/self/uid_map \
    || [[ "$(stat -f -c %T /)" != tmpfs ]]; then
    echo 'SKIP staging privilégié : rootfs jetable avec UID mappé requis ; aucune mutation système.'
    bash -n "$ROOT/data/scripts/install.sh" "$ROOT/data/scripts/install/setupSystem.sh" "$ROOT/data/scripts/install/configurationInitiale.sh"
    exit 0
fi
chmod 0755 / /etc
chmod 0644 /etc/passwd /etc/group /etc/nsswitch.conf
# /usr est un bind readonly de l'hôte : monter une destination privée dessus.
mount -t tmpfs -o mode=0755 tmpfs /usr/local
printf 'pzfixture:x:65533:65533::/home/pzfixture:/bin/bash\n' >> /etc/passwd
printf 'pzfixture:x:65533:\n' >> /etc/group
mkdir -p /usr/local/libexec /etc/sudoers.d /home/pzfixture /run/user
chmod 0755 /home /run /run/user
chmod 0755 /usr/local /usr/local/libexec
# The firewall boundary below is IPv4-only. Remap only the product reader's
# physical policy path inside this disposable copy, never the host /etc file.
cp -p "$ROOT/data/scripts/lib/ufw_access.py" /tmp/pz-fixture-ufw-reader.orig
trap 'cp -p /tmp/pz-fixture-ufw-reader.orig "$ROOT/data/scripts/lib/ufw_access.py"; rm -f /tmp/pz-fixture-ufw-reader.orig /tmp/pz-fixture-ufw-defaults /tmp/pz-fixture-ufw.conf' EXIT
printf 'IPV6=no\n' > /tmp/pz-fixture-ufw-defaults
printf 'ENABLED=no\n' > /tmp/pz-fixture-ufw.conf
chmod 0644 /tmp/pz-fixture-ufw.conf
chmod 0644 /tmp/pz-fixture-ufw-defaults
python3 - "$ROOT/data/scripts/lib/ufw_access.py" <<'UFWDEFAULTS'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.write_text(p.read_text().replace('Path("/etc/default/ufw")', 'Path("/tmp/pz-fixture-ufw-defaults")').replace('Path("/etc/ufw/ufw.conf")', 'Path("/tmp/pz-fixture-ufw.conf")'))
UFWDEFAULTS
PZ_USER=pzfixture bash -c 'source "$1/data/scripts/install.sh"; stage_root_helpers "$1"' _ "$ROOT"
helper=/usr/local/libexec/pzmanager/install
[[ -f "$helper/../../setupTemplates/pzuser-sudoers" && -f "$helper/../internal/configureJvm.sh" ]]
[[ -f /usr/local/libexec/pzmanager/data/scripts/backup/restoreZomboidData.sh ]]
[[ -z "$(find /usr/local/libexec/pzmanager/data \( ! -uid 0 -o -perm /0022 \) -print -quit)" ]]
# Exécuter l'alias public, pas son chemin physique.
if bash "$helper/setupSystem.sh" INVALID > /tmp/setup-invalid.log 2>&1; then exit 1; fi
grep -q 'Invalid PZ_USER' /tmp/setup-invalid.log
manager_home="$(getent passwd pzfixture | cut -d: -f6)"
mkdir -p "$manager_home/pzmanager"
chmod 0755 "$manager_home"
chown pzfixture:pzfixture "$manager_home"
printf 'PZ_USER=pzfixture\nPZ_PORT_GAME=17261\nMALICIOUS="$(touch /tmp/install-pwned)"\n' > "$manager_home/pzmanager/.env"
chown -R pzfixture:pzfixture "$manager_home/pzmanager"
bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" help > /tmp/config-help.log
[[ ! -e /tmp/install-pwned ]]
grep -q -- '--manager-root' /tmp/config-help.log
# Le vrai templating sudoers passe par l'alias ; visudo est la seule frontière
# remplacée dans ce rootfs sans paquets (install/stat/chown restent natifs).
mkdir -p /test-bin
chmod 0755 /test-bin
printf '#!/bin/sh\nexit 0\n' > /test-bin/visudo
chmod +x /test-bin/visudo
PATH="/test-bin:$PATH" bash -c 'source "$1/setupSystem.sh" pzfixture "$2"; load_ports_from_env "$2"; [[ "$PZ_PORT_GAME" == 17261 ]]; install_sudoers' _ "$helper" "$manager_home/pzmanager/.env"
[[ "$(stat -c '%u:%a' /etc/sudoers.d/pzfixture)" == 0:440 ]]
grep -q 'pzfixture.*NOPASSWD.*apt-get' /etc/sudoers.d/pzfixture
echo 'OK stage complet root-owned, alias public, contexte custom, sudoers natif.'
# Bascule réelle d'UID ; seuls sudo et le bus sont des frontières simulées.
cat > /test-bin/sudo <<'SUDO'
#!/bin/bash
set -euo pipefail
if [[ "$1" != -u ]]; then
    printf 'root-helper %s\n' "$*" >> /tmp/pzm-sudo.log
    exec "$@"
fi
user="$2"; shift 2
uid="$(id -u "$user")"; gid="$(id -g "$user")"
exec setpriv --reuid "$uid" --regid "$gid" --clear-groups env "$@"
SUDO
cat > /test-bin/systemctl <<'SYSTEMCTL'
#!/bin/bash
[[ -z "${MOCK_DIR:-}" ]] || printf 'systemctl %s\n' "$*" >> "$MOCK_DIR/calls.log"
if [[ " $* " == *" show "* ]]; then
    [[ "${MOCK_RESTORE_STATE:-inactive}" != error ]] || exit 1
    if [[ " $* " == *" -p Version "* ]]; then printf 'Version=fixture\n'; exit; fi
    load=loaded
    if [[ "${MOCK_FRESH_RESTORE:-0}" == 1 ]]; then
        file=zomboid.service
        [[ " $* " != *" pz.slice "* ]] || file=pz.slice
        [[ -f "$PZ_HOME/.config/systemd/user/$file" ]] || load=not-found
    fi
    if [[ " $* " == *" pz.slice "* && " $* " == *" --value "* ]]; then
        printf '%s\n' "$load"; exit
    fi
    if [[ "${MOCK_FRESH_RESTORE:-0}" == 1 && " $* " == *" -p ActiveState,SubState,Result "* ]]; then
        [[ -f "$PZ_HOME/.config/systemd/user/zomboid.service" && -f "$PZ_HOME/.config/systemd/user/pz.slice" ]] || exit 1
        printf 'metadata-ready-before-world\n' >> "$MOCK_DIR/calls.log"
    fi
    if [[ " $* " == *LoadState* ]]; then
        printf 'LoadState=%s\nActiveState=%s\nSubState=dead\nMainPID=%s\nControlPID=%s\n' "$load" "${MOCK_RESTORE_STATE:-inactive}" "${MOCK_MAIN_PID:-0}" "${MOCK_CONTROL_PID:-0}"
    else
        printf 'ActiveState=%s\nSubState=dead\nResult=success\n' "${MOCK_RESTORE_STATE:-inactive}"
    fi
fi
if [[ " $* " == *" enable zomboid.service "* ]]; then
    for directory in "$PZ_INSTALL_DIR" "$PZ_SOURCE_DIR" "$PZ_MANAGER_DIR/logs" "$PZ_MANAGER_DIR/logs/zomboid" "$BACKUP_DIR"; do
        [[ -d "$directory" && -O "$directory" && "$(stat -c %a "$directory")" == 700 ]] || {
            echo "ReadWritePaths absent/non privé avant enable : $directory" >&2; exit 1;
        }
    done
    grep -q 'FLOCK.*WRITE' "/proc/self/fdinfo/$PZ_WORLD_LOCK_FD"
    grep -q 'FLOCK.*WRITE' "/proc/self/fdinfo/$SERVERCTL_LOCK_FD"
    echo private-paths-and-locks-ready-before-enable >> "$MOCK_DIR/calls.log"
fi
SYSTEMCTL
chmod 0755 /test-bin/sudo /test-bin/systemctl
# Le runner a injecté des chemins cgroup privés ; seul leur contenu de preuve
# est partagé avec l'UID manager, sans modifier les validations du produit.
fixture_base="$(dirname "$ROOT")"
chmod 0755 "$fixture_base"
chmod 0644 "$fixture_base/proc-cgroup"
find "$fixture_base/cgroups" -type d -exec chmod 0755 {} +
find "$fixture_base/cgroups" -type f -exec chmod 0644 {} +
cp -a /usr/local/libexec/pzmanager/data "$manager_home/pzmanager/"
chown -R pzfixture:pzfixture "$manager_home/pzmanager"
python3 - <<'ARCHIVE'
import sqlite3, zipfile
connection=sqlite3.connect(':memory:')
connection.execute('CREATE TABLE whitelist(username TEXT)')
with zipfile.ZipFile('/tmp/restore-native.zip','w') as archive:
    archive.writestr('zomboid/Saves/Multiplayer/native/player.bin',b'native')
    archive.writestr('zomboid/db/servertest.db',connection.serialize())
    archive.writestr('zomboid/Server/servertest.ini',b'ini')
ARCHIVE
mkdir -p /tmp/root-call-fixture
chown pzfixture:pzfixture /tmp/root-call-fixture
export MOCK_DIR=/tmp/root-call-fixture MOCK_FRESH_RESTORE=1
PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/restore-native.zip --force
[[ "$(stat -c %u "$manager_home/pzmanager/Zomboid/Saves/Multiplayer/native/player.bin")" == "$(id -u pzfixture)" ]]
[[ "$(cat "$manager_home/pzmanager/Zomboid/Saves/Multiplayer/native/player.bin")" == native ]]
PATH="/test-bin:$PATH" /test-bin/sudo -u pzfixture python3 "$manager_home/pzmanager/data/scripts/lib/world_transaction.py" check --world "$manager_home/pzmanager/Zomboid"
grep -q metadata-ready-before-world "$MOCK_DIR/calls.log"
! grep -qE 'systemctl --user (start|restart) zomboid' "$MOCK_DIR/calls.log"
echo 'OK restauration bootstrap native fichiers/SQLite/flock/journal sous UID manager, sans lancement serveur/socket.' 

python3 - <<'ARCHIVE'
import zipfile
with zipfile.ZipFile('/tmp/restore-native.zip', 'w') as archive:
    archive.writestr('zomboid/Saves/Multiplayer/native/player.bin', b'changed')
    archive.writestr('config/home/pzfixture/pzmanager/refusal-marker', b'changed')
ARCHIVE
for state in active activating error; do
    if MOCK_RESTORE_STATE="$state" PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/restore-native.zip --force > "/tmp/refusal-$state.log" 2>&1; then
        echo "Restauration $state acceptée à tort." >&2; exit 1
    fi
    grep -qE 'serveur est actif|non prouvé arrêté' "/tmp/refusal-$state.log"
    [[ "$(cat "$manager_home/pzmanager/Zomboid/Saves/Multiplayer/native/player.bin")" == native ]]
    [[ ! -e "$manager_home/pzmanager/refusal-marker" ]]
done
echo 'OK refus actif/bus sous UID manager : monde et scripts intacts.'
# The same declared profile must reach root preflight and manager transaction.
cp "$manager_home/pzmanager/.env" /tmp/profile-env-original
printf 'export PZ_SOURCE_DIR="${PZ_MANAGER_DIR}/custom-world"\nexport PZ_DATA_DIR="${PZ_MANAGER_DIR}/custom-data"\nexport PZ_INSTALL_DIR="${PZ_DATA_DIR}/custom-game"\nexport PZ_SERVICE_NAME=custom-select.service\n' >> "$manager_home/pzmanager/.env"
# Only the selected custom unit is inactive; selecting the default must fail.
python3 - <<'PROFILEBUS'
from pathlib import Path
p=Path('/test-bin/systemctl')
s=p.read_text().replace('if [[ " $* " == *" show "* ]]; then', 'if [[ " $* " == *" custom-select.service "* ]]; then\n    printf \'LoadState=loaded\\nActiveState=%s\\nSubState=dead\\nMainPID=0\\nControlPID=0\\n\' "${CUSTOM_STATE:-inactive}"\n    exit 0\nfi\nif [[ " $* " == *" show "* ]]; then')
p.write_text(s)
PROFILEBUS
python3 - <<'PROFILEARCHIVE'
import sqlite3,zipfile
connection=sqlite3.connect(':memory:')
connection.execute('CREATE TABLE whitelist(username TEXT)')
with zipfile.ZipFile('/tmp/profile-restore.zip','w') as archive:
    archive.writestr('zomboid/Saves/Multiplayer/native/player.bin', b'custom-restored')
    archive.writestr('zomboid/db/servertest.db', connection.serialize())
    archive.writestr('zomboid/Server/servertest.ini', b'ini')
PROFILEARCHIVE
mkdir -p "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native"
printf custom-before > "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native/player.bin"
chown -R pzfixture:pzfixture "$manager_home/pzmanager/custom-world"
MOCK_FRESH_RESTORE=0 MOCK_RESTORE_STATE=active PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/profile-restore.zip --force
[[ "$(cat "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native/player.bin")" == custom-restored ]]
[[ "$(stat -c %u "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native/player.bin")" == "$(id -u pzfixture)" ]]
[[ "$(cat "$manager_home/pzmanager/Zomboid/Saves/Multiplayer/native/player.bin")" == native ]]
# Custom unit active: prove the refusal cause and preserve both worlds.
if CUSTOM_STATE=active MOCK_FRESH_RESTORE=0 PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/profile-restore.zip --force > /tmp/custom-active.log 2>&1; then exit 1; fi
grep -qE 'actif|non prouvé arrêté' /tmp/custom-active.log
[[ "$(cat "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native/player.bin")" == custom-restored && "$(cat "$manager_home/pzmanager/Zomboid/Saves/Multiplayer/native/player.bin")" == native ]]
# Legacy overrides and unresolved profile must fail before any world mutation.
for setting in 'PZ_DB_PATH=/tmp/wrong.db' 'PZ_INI_PATH=/tmp/wrong.ini' 'PZ_SOURCE_DIR=${UNKNOWN}/world' 'PZ_SOURCE_DIR="/tmp/custom"#suffix' 'PZ_SOURCE_DIR="/tmp/custom\\world"' 'PZ_SOURCE_DIR=/tmp/custom|true'; do
    cp "$manager_home/pzmanager/.env" /tmp/profile-env-case
    printf '%s\n' "$setting" >> "$manager_home/pzmanager/.env"
    if PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/profile-restore.zip --force > /tmp/profile-invalid.log 2>&1; then exit 1; fi
    grep -qE 'contradictoires|non résolu|déclaratif invalide' /tmp/profile-invalid.log
    [[ "$(cat "$manager_home/pzmanager/custom-world/Saves/Multiplayer/native/player.bin")" == custom-restored ]]
    mv /tmp/profile-env-case "$manager_home/pzmanager/.env"
done
mv /tmp/profile-env-original "$manager_home/pzmanager/.env"
chown pzfixture:pzfixture "$manager_home/pzmanager/.env"
echo 'OK profil root/manager : monde custom restauré seul, service custom contrôlé, contradictions refusées avant mutation.'
# A hash inside an assignment word is literal, unlike a separated comment.
# Compare the real manager shell's own .env with the root restore target.
for syntax in unquoted quoted-comment unquoted-comment; do
    cp "$manager_home/pzmanager/.env" /tmp/hash-env-original
    case "$syntax" in
        unquoted) printf 'PZ_SOURCE_DIR=%s/pzmanager/hash#world\n' "$manager_home" ;;
        quoted-comment) printf 'PZ_SOURCE_DIR="%s/pzmanager/hash#world" # separated comment\n' "$manager_home" ;;
        unquoted-comment) printf 'PZ_SOURCE_DIR=%s/pzmanager/hash#world # separated comment\n' "$manager_home" ;;
    esac >> "$manager_home/pzmanager/.env"
    chmod 0600 "$manager_home/pzmanager/.env"
    chown pzfixture:pzfixture "$manager_home/pzmanager/.env"
    manager_source="$(PATH="/test-bin:$PATH" /test-bin/sudo -u pzfixture /bin/bash -eu -c 'source "$1"; printf "%s" "$PZ_SOURCE_DIR"' _ "$manager_home/pzmanager/.env")"
    [[ "$manager_source" == "$manager_home/pzmanager/hash#world" ]]
    for world in hash 'hash#world'; do
        mkdir -p "$manager_home/pzmanager/$world/Saves/Multiplayer/native"
        printf '%s-before' "$world" > "$manager_home/pzmanager/$world/Saves/Multiplayer/native/player.bin"
    done
    chown -R pzfixture:pzfixture "$manager_home/pzmanager/hash" "$manager_home/pzmanager/hash#world"
    MOCK_FRESH_RESTORE=0 PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" restore /tmp/profile-restore.zip --force
    printf 'HASH_SYNTAX=%s MANAGER_SOURCE=%s EXPECTED_AFTER=%s NEIGHBOR_AFTER=%s\n' "$syntax" "$manager_source" "$(cat "$manager_source/Saves/Multiplayer/native/player.bin")" "$(cat "$manager_home/pzmanager/hash/Saves/Multiplayer/native/player.bin")"
    [[ "$(cat "$manager_source/Saves/Multiplayer/native/player.bin")" == custom-restored ]]
    [[ "$(stat -c %u "$manager_source/Saves/Multiplayer/native/player.bin")" == "$(id -u pzfixture)" ]]
    [[ "$(cat "$manager_home/pzmanager/hash/Saves/Multiplayer/native/player.bin")" == hash-before ]]
    mv /tmp/hash-env-original "$manager_home/pzmanager/.env"
    chown pzfixture:pzfixture "$manager_home/pzmanager/.env"
done
echo 'OK # littéral : .env manager UID réel concordant, trois syntaxes restaurent seulement hash#world.'
# Parcours CLI réel vers helpers privilégiés ; frontières paquets/UFW/session
# remplacées, aucune installation ou action sur un service système réel.
cp "$ROOT/pzm" "$manager_home/pzmanager/pzm"
chmod 0755 "$manager_home/pzmanager/pzm"
chown pzfixture:pzfixture "$manager_home/pzmanager/pzm"
for cmd in dpkg apt-get ufw loginctl; do
    cat > "/test-bin/$cmd" <<'BOUNDARY'
#!/bin/bash
printf 'boundary %s %s\n' "${0##*/}" "$*" >> /tmp/pzm-boundaries.log
[[ "${0##*/}" != apt-get ]] || { echo 'Installation paquet interdite.' >&2; exit 99; }
[[ "${0##*/}" != ufw || "${1:-}" != status ]] || printf 'Status: active\n[ 1] 9110/tcp DENY IN Anywhere\n'
exit 0
BOUNDARY
    chmod 0755 "/test-bin/$cmd"
done
# Sonde SSH simulée : aucun daemon dans le rootfs privé.
cat > /test-bin/ss <<'BOUNDARY'
#!/bin/bash
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'
BOUNDARY
chmod 0755 /test-bin/ss
mkdir -p "$manager_home/pzmanager/data/pzserver"
touch "$manager_home/pzmanager/data/pzserver/ProjectZomboid64"
chown -R pzfixture:pzfixture "$manager_home/pzmanager/data/pzserver"
# Victimes root indépendantes : aucune écriture/chown root via liens du home.
mkdir -p /root/install-victims
for file in env key bashrc; do printf 'root-%s-original\n' "$file" > "/root/install-victims/$file"; chmod 0640 "/root/install-victims/$file"; done
victims_before="$(stat -c '%u:%g:%a:%s' /root/install-victims/*; sha256sum /root/install-victims/*)"
mv "$manager_home/pzmanager/.env" /tmp/install-env-original
ln -s /root/install-victims/env "$manager_home/pzmanager/.env"
if PATH="/test-bin:$PATH" bash -eu -c 'source "$1" --manager-root "$2"; harden_manager_secrets' _ "$helper/setupSystem.sh" "$manager_home/pzmanager" > /tmp/secret-link.log 2>&1; then echo "FAIL lien .env accepté ; victime $(stat -c '%u:%a' /root/install-victims/env)" >&2; exit 1; fi
rm "$manager_home/pzmanager/.env"; mv /tmp/install-env-original "$manager_home/pzmanager/.env"
ln -s /root/install-victims "$manager_home/.ssh"
if PATH="/test-bin:$PATH" bash -eu -c 'source "$1" --manager-root "$2"; harden_manager_secrets' _ "$helper/setupSystem.sh" "$manager_home/pzmanager" > /tmp/ssh-link.log 2>&1; then exit 1; fi
rm "$manager_home/.ssh"
ln -s /root/install-victims/bashrc "$manager_home/.bashrc"
if PATH="/test-bin:$PATH" bash -eu -c 'source "$1" --manager-root "$2"; configure_path' _ "$helper/setupSystem.sh" "$manager_home/pzmanager" > /tmp/bashrc-link.log 2>&1; then exit 1; fi
rm "$manager_home/.bashrc"
[[ "$(stat -c '%u:%g:%a:%s' /root/install-victims/*; sha256sum /root/install-victims/*)" == "$victims_before" ]]
mkdir "$manager_home/.ssh"
printf key > "$manager_home/.ssh/id_ed25519"
printf '# manager shell\n' > "$manager_home/.bashrc"
chown -R pzfixture:pzfixture "$manager_home/.ssh" "$manager_home/.bashrc"
PATH="/test-bin:$PATH" bash -eu -c 'source "$1" --manager-root "$2"; harden_manager_secrets; configure_path' _ "$helper/setupSystem.sh" "$manager_home/pzmanager"
[[ "$(stat -c '%u:%a' "$manager_home")" == "$(id -u pzfixture):750" && "$(stat -c %a "$manager_home/pzmanager/.env")" == 600 && "$(stat -c '%u:%a' "$manager_home/.ssh")" == "$(id -u pzfixture):700" && "$(stat -c %a "$manager_home/.ssh/id_ed25519")" == 600 && "$(stat -c %u "$manager_home/.bashrc")" == "$(id -u pzfixture)" ]]
echo 'OK home normal privé sous UID manager ; liens refusés, victimes root owner/mode/contenu intacts.'

route_failures=0
for route in system zomboid; do
    if printf 'n\nn\n' | PATH="/test-bin:$PATH" bash "$manager_home/pzmanager/pzm" install "$route" > "/tmp/route-$route.log" 2>&1; then
        echo "OK pzm install $route : helper privilégié et contexte custom."
    else
        cat "/tmp/route-$route.log"; route_failures=$((route_failures + 1))
    fi
done
[[ "$route_failures" == 0 ]]
grep -q "root-helper $helper/setupSystem.sh --manager-root $manager_home/pzmanager" /tmp/pzm-sudo.log
grep -q "root-helper $helper/configurationInitiale.sh --manager-root $manager_home/pzmanager zomboid" /tmp/pzm-sudo.log
grep -q '17261' /tmp/pzm-boundaries.log
[[ ! -e /tmp/install-pwned || "$(stat -c %u /tmp/install-pwned)" == "$(id -u pzfixture)" ]]
for route in system zomboid; do
    name=setupSystem.sh
    [[ "$route" == system ]] || name=configurationInitiale.sh
    mv "$helper/$name" "$helper/$name.unavailable"
    before="$(wc -l < /tmp/pzm-sudo.log)"
    if PATH="/test-bin:$PATH" bash "$manager_home/pzmanager/pzm" install "$route" > /tmp/helper-absent.log 2>&1; then exit 1; fi
    grep -q 'Helper privilégié absent' /tmp/helper-absent.log
    [[ "$(wc -l < /tmp/pzm-sudo.log)" == "$before" ]]
    mv "$helper/$name.unavailable" "$helper/$name"
done
echo 'OK pzm install : absence helper refusée avant sudo, sans repli.'

# Une dépendance manquante ne doit jamais charger une ancienne copie plate.
printf 'touch /tmp/flat-parser-executed\n' > /usr/local/libexec/pzmanager/env_parse.sh
mv /usr/local/libexec/pzmanager/data/scripts/lib/env_parse.sh /tmp/trusted-env-parse
if PATH="/test-bin:$PATH" bash "$helper/configurationInitiale.sh" --manager-root "$manager_home/pzmanager" help > /tmp/missing-parser.log 2>&1; then
    echo 'Parser absent accepté.' >&2; exit 1
fi
[[ ! -e /tmp/flat-parser-executed ]]
grep -q 'env_parse.sh.*No such file' /tmp/missing-parser.log
mv /tmp/trusted-env-parse /usr/local/libexec/pzmanager/data/scripts/lib/env_parse.sh
echo 'OK parser manquant refusé sans chargement de copie plate.'
