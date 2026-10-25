#!/usr/bin/env bash
# Chaîne manager réelle (verrous, FS, JSON, templates) ; Steam/bus seuls simulés.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?copie jetable requise}"
# Bash lancé via SSH lirait le .bashrc créé par la vraie installation et
# remplacerait le runtime privé par /run/user/UID dans les sous-scénarios.
unset SSH_CLIENT SSH_CONNECTION SSH2_CLIENT
if (( EUID == 0 )); then echo 'SKIP chaîne manager non privilégiée : exécutée séparément sous UID manager.'; exit; fi
SANDBOX="$(mktemp -d)"
[[ ! -f "$ROOT/.env" ]] || cp -p "$ROOT/.env" "$SANDBOX/env.original"
cleanup() {
    [[ ! -f "$SANDBOX/release" ]] || :
    touch "$SANDBOX/release"
    [[ -z "${holder:-}" ]] || wait "$holder" 2>/dev/null || true
    if [[ -f "$SANDBOX/env.original" ]]; then cp -p "$SANDBOX/env.original" "$ROOT/.env"; else rm -f "$ROOT/.env"; fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT
export HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/runtime" INSTALL_CALLS="$SANDBOX/calls"
manager="$HOME/pzmanager"
mkdir -p "$manager/data" "$SANDBOX/bin" "$XDG_RUNTIME_DIR"
cp -a "$ROOT/data/scripts" "$ROOT/data/setupTemplates" "$manager/data/"
user="$(id -un)"
printf 'export PZ_USER=%q\nexport PZ_MANAGER_DIR=%q\nexport PZ_HOME=%q\nexport STEAMCMD_PATH=%q\n' "$user" "$manager" "$HOME" "$SANDBOX/bin/steamcmd" > "$ROOT/.env"
printf 'export JAVA_VERSION=25\nexport JAVA_PACKAGE=openjdk-25-jre-headless\nexport JAVA_PATH=/usr/lib/jvm/java-25-openjdk-amd64\n' >> "$ROOT/.env"
cp "$ROOT/.env" "$manager/.env"
cat > "$SANDBOX/bin/systemctl" <<'SYSTEMCTL'
#!/bin/bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$INSTALL_CALLS"
[[ "${INSTALL_STATE:-inactive}" != error ]] || exit 1
if [[ " $* " == *" show "* ]]; then
    if [[ " $* " == *" -p Version "* ]]; then echo Version=fixture; exit; fi
    load=not-found; file=zomboid.service
    [[ " $* " != *" pz.slice "* ]] || file=pz.slice
    [[ ! -f "$HOME/.config/systemd/user/$file" ]] || load=loaded
    if [[ " $* " == *" --value "* ]]; then echo "$load"; exit; fi
    printf 'LoadState=%s\nActiveState=%s\nSubState=dead\nMainPID=0\nControlPID=0\n' "$load" "${INSTALL_STATE:-inactive}"
fi
if [[ " $* " == *" enable zomboid.service "* ]]; then
    for directory in "$PZ_INSTALL_DIR" "$PZ_SOURCE_DIR" "$PZ_MANAGER_DIR/logs" "$PZ_MANAGER_DIR/logs/zomboid" "$BACKUP_DIR"; do
        [[ -d "$directory" && -O "$directory" && "$(stat -c %a "$directory")" == 700 ]]
    done
    echo readiness-paths-private >> "$INSTALL_CALLS"
fi
SYSTEMCTL
cat > "$SANDBOX/bin/steamcmd" <<'STEAM'
#!/bin/bash
set -euo pipefail
[[ "$1" == +runscript && -f "$2" ]]
grep -q 'app_update .*validate' "$2"
[[ ! -L "$PZ_INSTALL_DIR/jre64" ]]
# Le descendant doit garder les deux OFD verrouillés, et pouvoir les reprendre.
bash -eu -c 'source "$1"; acquire_world_lock --required; acquire_serverctl_lock_or_die; grep -q "FLOCK.*WRITE" "/proc/self/fdinfo/$PZ_WORLD_LOCK_FD"; grep -q "FLOCK.*WRITE" "/proc/self/fdinfo/$SERVERCTL_LOCK_FD"' _ "$PZ_MANAGER_DIR/data/scripts/lib/common.sh"
printf 'steam uid=%s fd-world=%s fd-server=%s java=%s/%s\n' "$(id -u)" "$PZ_WORLD_LOCK_FD" "$SERVERCTL_LOCK_FD" "$JAVA_VERSION" "$JAVA_PACKAGE" >> "$INSTALL_CALLS"
[[ "${INSTALL_PAYLOAD:-complete}" != missing ]] || exit 0
mkdir -p "$PZ_INSTALL_DIR/jre64/bin"
for file in ProjectZomboid64 start-server.sh jre64/bin/java; do
    printf '#!/bin/sh\nexit 91 # fixture executable, never launched\n' > "$PZ_INSTALL_DIR/$file"
    chmod 0700 "$PZ_INSTALL_DIR/$file"
done
printf '{"mainClass":"zombie/network/GameServer","classpath":["java/."],"vmArgs": []}\n' > "$PZ_INSTALL_DIR/ProjectZomboid64.json"
case "${INSTALL_PAYLOAD:-complete}" in
    incomplete) rm "$PZ_INSTALL_DIR/start-server.sh" ;;
    nonexec) chmod 0600 "$PZ_INSTALL_DIR/ProjectZomboid64" ;;
    malformed) printf '{broken' > "$PZ_INSTALL_DIR/ProjectZomboid64.json" ;;
    schema) printf '{"vmArgs":"wrong"}' > "$PZ_INSTALL_DIR/ProjectZomboid64.json" ;;
esac
STEAM
cat > "$SANDBOX/bin/apt-cache" <<'APT'
#!/bin/bash
if [[ "$2" == openjdk-17-jre-headless ]]; then echo 'Candidate: 17.0-fixture'; else echo 'Candidate: (none)'; fi
APT
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"
# Exporter les variables réelles comme l'enfant manager du helper privilégié.
run_phase() {
    bash -eu -c 'source "$1" --manager-root "$2"; source_env; source "${1%/*}/../lib/jdk_matrix.sh"; resolve_java_package; source_env; install_zomboid_manager true' _ "$ROOT/data/scripts/install/configurationInitiale.sh" "$manager"
}
for state in active activating error; do
    : > "$INSTALL_CALLS"
    if INSTALL_STATE="$state" run_phase > "$SANDBOX/refusal.log" 2>&1; then echo "État $state accepté" >&2; exit 1; fi
    grep -qE 'non prouvé arrêté|lecture du bus refusée' "$SANDBOX/refusal.log"
    ! grep -q '^steam ' "$INSTALL_CALLS"
    [[ ! -e "$manager/Zomboid" && ! -e "$manager/.config" && ! -e "$HOME/.config/systemd/user/zomboid.service" ]]
done
echo 'OK état actif/transitoire/bus : aucun Steam, monde ou unité.'
for payload in missing incomplete nonexec malformed schema; do
    rm -rf "$manager/data/pzserver"
    : > "$INSTALL_CALLS"
    if INSTALL_PAYLOAD="$payload" run_phase > "$SANDBOX/payload-$payload.log" 2>&1; then
        echo "Payload Steam $payload accepté" >&2; exit 1
    fi
    grep -q 'Payload Steam incomplet ou invalide' "$SANDBOX/payload-$payload.log"
    ! grep -q 'enable zomboid.service' "$INSTALL_CALLS"
    [[ ! -e "$manager/.admin_password" && ! -e "$manager/data/pzserver/ProjectZomboid64.json.bak" ]]
done
echo 'OK Steam exit0 sans payload valide : refus avant JVM/secret/activation.'
rm -rf "$manager/data/pzserver"
: > "$INSTALL_CALLS"
run_phase > "$SANDBOX/fresh.log" 2>&1 || { cat "$SANDBOX/fresh.log"; exit 1; }
grep -q '^steam .*java=17/openjdk-17-jre-headless$' "$INSTALL_CALLS"
grep -q '^export JAVA_VERSION=25$' "$manager/.env"
grep -q readiness-paths-private "$INSTALL_CALLS"
[[ -s "$manager/.admin_password" && "$(stat -c %a "$manager/.admin_password")" == 600 ]]
python3 - "$manager/data/pzserver/ProjectZomboid64.json" <<'JSON'
import json,sys
assert any(arg.startswith('-Xmx') for arg in json.load(open(sys.argv[1]))['vmArgs'])
JSON
echo 'OK fresh : JRE/Steam/JVM, chemins privés avant enable, FD exclusifs hérités/repris.'
# Réinstallation : un lien externe doit être retiré et le stock restauré d'abord.
external="$SANDBOX/external-jre"; mkdir "$external"
echo untouched > "$external/victim"
mv "$manager/data/pzserver/jre64" "$manager/data/pzserver/jre64.stock"
ln -s "$external" "$manager/data/pzserver/jre64"
run_phase > "$SANDBOX/reinstall.log" 2>&1
[[ ! -L "$manager/data/pzserver/jre64" && "$(cat "$external/victim")" == untouched ]]
echo 'OK reinstall : stock restauré avant validate, JRE externe intact.'
# Sans stock, aucun validate ne doit être tenté.
rm -rf "$manager/data/pzserver/jre64"
ln -s "$external" "$manager/data/pzserver/jre64"
: > "$INSTALL_CALLS"
if run_phase > "$SANDBOX/no-stock.log" 2>&1; then exit 1; fi
! grep -q '^steam ' "$INSTALL_CALLS"
[[ -L "$manager/data/pzserver/jre64" && "$(cat "$external/victim")" == untouched ]]
echo 'OK stock absent : refus avant Steam.'
# Réparer la fixture stock avant les tests de concurrence : leur refus doit
# provenir du verrou, pas du scénario stock absent qui précède.
rm "$manager/data/pzserver/jre64"; mkdir "$manager/data/pzserver/jre64"
# Un WORLD concurrent bloque l'installation avant inspection/mutation du jeu.
bash -eu -c 'source "$1"; acquire_world_lock --required; touch "$2/ready"; while [[ ! -e "$2/release" ]]; do sleep .02; done' _ "$ROOT/data/scripts/lib/common.sh" "$SANDBOX" & holder=$!
for (( i=0; i<100; i++ )); do [[ ! -e "$SANDBOX/ready" ]] || break; sleep .02; done
[[ -f "$SANDBOX/ready" ]]
: > "$INSTALL_CALLS"
if run_phase > "$SANDBOX/concurrent.log" 2>&1; then exit 1; fi
grep -q 'verrou monde indisponible' "$SANDBOX/concurrent.log"
! grep -q '^steam ' "$INSTALL_CALLS"
touch "$SANDBOX/release"; wait "$holder"; holder=""
echo 'OK WORLD concurrent : refus avant Steam.'

rm "$SANDBOX/ready" "$SANDBOX/release"
bash -eu -c 'source "$1"; acquire_serverctl_lock_or_die; touch "$2/ready"; while [[ ! -e "$2/release" ]]; do sleep .02; done' _ "$ROOT/data/scripts/lib/common.sh" "$SANDBOX" & holder=$!
for (( i=0; i<100; i++ )); do [[ ! -e "$SANDBOX/ready" ]] || break; sleep .02; done
[[ -f "$SANDBOX/ready" ]]
: > "$INSTALL_CALLS"
if run_phase > "$SANDBOX/serverctl-concurrent.log" 2>&1; then exit 1; fi
grep -q 'déjà en cours' "$SANDBOX/serverctl-concurrent.log"
! grep -q '^steam ' "$INSTALL_CALLS"
touch "$SANDBOX/release"; wait "$holder"; holder=""
echo 'OK SERVERCTL concurrent : refus avant Steam.'
# Un FD ouvert sur le bon inode, sans flock, ne donne aucune réentrance.
for lock in WORLD SERVERCTL; do
    : > "$INSTALL_CALLS"
    if bash -eu -c '
        source "$1/data/scripts/lib/common.sh"
        if [[ "$3" == WORLD ]]; then
            path="$(world_lock_path)"; exec {fd}>"$path"
            export PZ_WORLD_LOCK_DEPTH=1 PZ_WORLD_LOCK_FD="$fd"
        else
            path="$(serverctl_lock_path)"; exec {fd}>"$path"
            export SERVERCTL_LOCK_FILE="$path" SERVERCTL_LOCK_FD="$fd"
        fi
        exec bash -eu -c "$4" _ "$1/data/scripts/install/configurationInitiale.sh" "$2"
    ' _ "$ROOT" "$manager" "$lock" 'source "$1" --manager-root "$2"; source_env; source "${1%/*}/../lib/jdk_matrix.sh"; resolve_java_package; source_env; install_zomboid_manager true' > "$SANDBOX/forged.log" 2>&1; then exit 1; fi
    grep -qi 'réentrance.*non prouvée' "$SANDBOX/forged.log"
    ! grep -q '^steam ' "$INSTALL_CALLS"
done
echo 'OK FD hérités non verrouillés : WORLD et SERVERCTL refusés.'
