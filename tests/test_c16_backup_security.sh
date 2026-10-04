#!/usr/bin/env bash
# test_c16_backup_security.sh - Securisation full backups et restauration (C16).
#
# Couvre (fullBackup.sh + configurationInitiale.sh uniquement) :
#   (0) cablage statique : chiffrement age (.age, die si age absent, WARNING si
#       vide), sudoers jamais restaure (refuse + regenere depuis template),
#       .ssh opt-in (--restore-ssh, validation authorized_keys/config/privees),
#       validation archive avant extraction (whitelist config+zomboid, absolus,
#       `..`, symlinks, unzip -t/-l), perms 0700/0600, staging tmp.
#   (1) sudoers modifie mais valide dans l'archive -> NON installe (dest
#       systeme inchangee, regeneree depuis le template) + log.
#   (2) .ssh sans flag -> non restaure (skip + log) ; avec flag + contenu
#       propre -> restaure et valide (perms 0700/0600).
#   (3) authorized_keys malicieux (command="...") + flag -> refuse (die, .ssh
#       non installe). Idem config avec ProxyCommand, cle privee sans
#       PZ_RESTORE_PRIVATE_KEYS=1 (acceptee si =1).
#   (4) ZIP avec `../../etc/cron.d/pwn`, chemin absolu, symlink /etc/passwd,
#       top-level inconnu -> refuses AVANT extraction (die, aucun artefact).
#   (5) age : RECIPIENT defini + age present -> .age 0600 cree, ZIP clair
#       supprime (non publie hors-site) ; age absent + RECIPIENT -> die, rien
#       publie ; RECIPIENT vide -> WARNING + ZIP clair seul, pas de .age ;
#       AGE_RECIPIENTS multiples (virgule) -> un -r par destinataire.
#   (6) cle privee age (PZ_AGE_IDENTITY) jamais dans l'archive (noms+contenu).
#
# Preuves : vrai fullBackup.sh (end-to-end, mocks zip/unzip/sudo/age via PATH,
# flock/rsync/chmod/stat reels), vraies fonctions de configurationInitiale.sh
# sourcees (garde BASH_SOURCE), ZIP d'attaque reels construits en python
# zipfile. Isoles : XDG_RUNTIME_DIR + TMPDIR + PZ_HOME + BACKUP_DIR +
# SYNC_BACKUPS_DIR sous sandbox, stub .env (sauvegarde + restauration via
# trap EXIT). Ne touche a aucun backup ni sudoers reel (PZ_SUDOERS_DEST
# redirige, visudo/install/chown/systemctl mockes).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FULLBACKUP="${ROOT}/data/scripts/backup/fullBackup.sh"
CONF_INIT="${ROOT}/data/scripts/install/configurationInitiale.sh"
SANDBOX="${TMPDIR:-/tmp}/pzmanager-c16-$$"
BIN="${SANDBOX}/bin"
AGE_BIN="${SANDBOX}/agebin"
MOCK_DIR="${SANDBOX}/mock"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

REPO_ENV="${ROOT}/.env"
ENV_BACKUP="${SANDBOX}/env.orig"

cleanup() {
    if [[ -f "$ENV_BACKUP" ]]; then
        cp -p "$ENV_BACKUP" "$REPO_ENV"
    else
        rm -f "$REPO_ENV"
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# --- Prerequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible — test C16 a executer sous Linux/WSL." >&2
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP-local] python3 indisponible — test C16 a executer avec python3." >&2
    exit 0
fi
if ! command -v rsync >/dev/null 2>&1; then
    echo "[SKIP-local] rsync absent — test C16 a executer sous Linux/WSL." >&2
    exit 0
fi
if [[ ! -f "$FULLBACKUP" ]]; then
    echo "[FAIL] script introuvable : $FULLBACKUP" >&2
    exit 1
fi
if [[ ! -f "$CONF_INIT" ]]; then
    echo "[FAIL] script introuvable : $CONF_INIT" >&2
    exit 1
fi

# --- Isolation ---------------------------------------------------------------
rm -rf "$SANDBOX"
mkdir -p "${SANDBOX}/rt" "${SANDBOX}/tmp" "$BIN" "$AGE_BIN" "$MOCK_DIR"
probe="$(mktemp "${SANDBOX}/.probe.XXXXXX")"
chmod 600 "$probe" 2>/dev/null || true
if [[ "$(stat -c %a "$probe" 2>/dev/null || echo ?)" != "600" ]]; then
    echo "[SKIP-local] FS sans chmod (DrvFs/NTFS) — test C16 a executer sous Linux/WSL." >&2
    exit 0
fi
rm -f "$probe"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
export TMPDIR="${SANDBOX}/tmp"
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
    PZ_WORLD_LOCK_DEPTH=0; PZ_WORLD_LOCK_FD=""
    export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
fi
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C16 (restaure en fin de test)\n' > "$REPO_ENV"

# --- Mocks -------------------------------------------------------------------
# sudo : depile -u/VAR= puis execute (style C11). `sudo /bin/cat /etc/sudoers.d`
# echoue naturellement (fichier absent) -> branche "Ignore" du backup.
cat > "${BIN}/sudo" <<'MOCKEOF'
#!/usr/bin/env bash
while (( $# > 0 )); do
    case "$1" in
        -u) shift 2 ;;
        *=*) shift ;;
        *) break ;;
    esac
done
exec "$@"
MOCKEOF
# zip emule via python zipfile (format reel), derive le symlink zomboid/.
cat > "${BIN}/zip" <<'MOCKEOF'
#!/usr/bin/env bash
dest=""
members=()
for a in "$@"; do
    case "$a" in
        -*) continue ;;
        *) if [[ -z "$dest" ]]; then dest="$a"; else members+=("$a"); fi ;;
    esac
done
[[ -n "$dest" ]] || { echo "mock zip: pas de destination" >&2; exit 2; }
python3 - "$dest" "${members[@]}" <<'PYEOF'
import sys, os, zipfile
dest = sys.argv[1]
members = sys.argv[2:]
with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
    for m in members:
        if os.path.islink(m):
            target = os.path.realpath(m)
            for root, _dirs, files in os.walk(target):
                for f in files:
                    full = os.path.join(root, f)
                    arc = os.path.join(m.rstrip('/'), os.path.relpath(full, target))
                    z.write(full, arc)
        elif os.path.isdir(m):
            for root, _dirs, files in os.walk(m):
                for f in files:
                    full = os.path.join(root, f)
                    z.write(full, os.path.relpath(full, '.'))
        elif os.path.isfile(m):
            z.write(m, m)
        else:
            print("mock zip: membre introuvable: %s" % m, file=sys.stderr)
            sys.exit(1)
PYEOF
MOCKEOF
# unzip mock : -t (validation reelle), -l (format Info-ZIP), extraction reelle.
cat > "${BIN}/unzip" <<'MOCKEOF'
#!/usr/bin/env bash
mode="extract" arch="" dest=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-d" ]]; then dest="$a"; prev=""; continue; fi
    case "$a" in
        -t) mode="test" ;;
        -l) mode="list" ;;
        -d) prev="-d" ;;
        -*) ;;
        *) arch="$a" ;;
    esac
    [[ "$a" != "-d" ]] && prev="$a"
done
# Re-derivation robuste : l'archive est le premier non-flag existant en fichier.
if [[ ! -f "${arch:-}" ]]; then
    for a in "$@"; do
        [[ "$a" == -* ]] && continue
        if [[ -f "$a" ]]; then arch="$a"; break; fi
    done
fi
[[ -n "$arch" ]] || { echo "mock unzip: pas d'archive" >&2; exit 2; }
case "$mode" in
    test)
        python3 - "$arch" <<'PYEOF'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        bad = z.testzip()
        if bad is not None:
            print("mock unzip: entree corrompue: %s" % bad, file=sys.stderr)
            sys.exit(1)
except Exception as e:
    print("mock unzip: archive invalide: %s" % e, file=sys.stderr)
    sys.exit(1)
PYEOF
        ;;
    list)
        python3 - "$arch" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print("Archive:  %s" % sys.argv[1])
    print("  Length      Date    Time    Name")
    print("---------  ---------- -----   ----")
    total = 0
    for i in z.infolist():
        print("%9d  2026-01-01 00:00   %s" % (i.file_size, i.filename))
        total += i.file_size
    print("---------                     -------")
    print("%9d                     %d files" % (total, len(z.infolist())))
PYEOF
        ;;
    *)
        [[ -n "$dest" ]] || { echo "mock unzip: pas de destination (-d)" >&2; exit 2; }
        python3 - "$arch" "$dest" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PYEOF
        ;;
esac
MOCKEOF
# age mock (AGE_BIN, ajoute au PATH seulement pour les cas chiffres) : simule
# le chiffrement par copie + journalise chaque destinataire -r.
cat > "${AGE_BIN}/age" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${MOCK_AGE_FAIL:-0}" == "1" ]]; then
    echo "mock age: chiffrement simule en echec" >&2
    exit 1
fi
out=""; in=""
while (( $# > 0 )); do
    case "$1" in
        -r) printf 'recip %s\n' "$2" >> "${MOCK_DIR}/age.log"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -*) echo "mock age: flag inconnue $1" >&2; exit 2 ;;
        *) in="$1"; shift ;;
    esac
done
[[ -n "$out" && -n "$in" ]] || { echo "mock age: usage: age -r R -o OUT IN" >&2; exit 2; }
cp -p "$in" "$out"
MOCKEOF
# visudo mock : validation simulee OK + journal.
cat > "${BIN}/visudo" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'visudo %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
MOCKEOF
# install mock : install -o root -g root -m 440 SRC DST -> cp + journal.
cat > "${BIN}/install" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "${MOCK_DIR}/calls.log"
args=()
for a in "$@"; do
    case "$a" in
        -*) ;;
        *) args+=("$a") ;;
    esac
done
n=${#args[@]}
(( n >= 2 )) || { echo "mock install: usage" >&2; exit 2; }
cp -p "${args[n-2]}" "${args[n-1]}"
MOCKEOF
# chown mock : journalise, succes simule (non-root ne peut pas chown).
cat > "${BIN}/chown" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
MOCKEOF
# chmod mock : journalise PUIS delegue au vrai (prouve la commande + mode reel).
cat > "${BIN}/chmod" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'chmod %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exec /bin/chmod "$@"
MOCKEOF
# systemctl mock : enregistreur, toujours OK.
cat > "${BIN}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
MOCKEOF
chmod +x "${BIN}/"* "${AGE_BIN}/"*
export PATH="${BIN}:$PATH"
export MOCK_DIR
# PATH de base (mocks sans age) : les cas age le recomposent explicitement.
BASE_PATH="${BIN}:$(command -p getconf PATH 2>/dev/null || echo /usr/bin:/bin):$PATH"
# Retire toute occurrence d'AGE_BIN (pollution inter-cas) pour un PATH sain.
BASE_PATH="$(printf '%s' "$BASE_PATH" | tr ':' '\n' | grep -v "^${AGE_BIN}$" | paste -sd: -)"
export BASE_PATH

# --- Helpers -----------------------------------------------------------------
# fresh_backup_case <nom> : sandbox config + monde + latest valides pour
# fullBackup.sh (exports shell ; le stub .env quasi-vide les preserve).
BK_SYNC=""
fresh_backup_case() {
    local name="$1"
    local home="${SANDBOX}/b-home-${name}"
    local mgr="${SANDBOX}/b-mgr-${name}"
    local datadir="${SANDBOX}/b-data-${name}"
    local scripts="${SANDBOX}/b-scripts-${name}"
    local bkp="${SANDBOX}/b-bkp-${name}"
    BK_SYNC="${SANDBOX}/b-sync-${name}"
    rm -rf "$home" "$mgr" "$datadir" "$scripts" "$bkp" "$BK_SYNC"
    mkdir -p "$home/.ssh" "$home/.config/systemd/user" "$datadir/setupTemplates" \
        "$scripts" "$mgr/versionning" "$bkp" "$BK_SYNC"
    mkdir -p "$bkp/snap1/Saves" "$bkp/snap1/db" "$bkp/snap1/Server"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h" > "$home/.ssh/id_ed25519.pub"
    echo unit > "$home/.config/systemd/user/svc.service"
    echo tpl > "$datadir/setupTemplates/tpl.txt"
    echo dummy > "$scripts/dummy.sh"
    printf 'export FOO=bar\n' > "$mgr/.env"
    echo v1 > "$mgr/versionning/V1.txt"
    echo "world" > "$bkp/snap1/Saves/player.bin"
    echo "db" > "$bkp/snap1/db/servertest.db"
    echo "ini" > "$bkp/snap1/Server/servertest.ini"
    ln -sfnT "$bkp/snap1" "$bkp/latest"
    export PZ_HOME="$home" PZ_MANAGER_DIR="$mgr" PZ_DATA_DIR="$datadir" \
        PZ_SCRIPTS_DIR="$scripts" PZ_MANAGER_HOME="$home" PZ_GAME_HOME="$home"
    export WHITELIST_LEDGER="${datadir}/whitelistLedger.csv"
    echo "u;1;2026-01-01 00:00:00" > "$WHITELIST_LEDGER"
    export BACKUP_DIR="$bkp" BACKUP_LATEST_LINK="$bkp/latest" SYNC_BACKUPS_DIR="$BK_SYNC"
    export PZ_USER="pzuser" OFFSITE_BACKUP_COUNT=7 PZ_PURGE_LEGACY=0
    unset AGE_RECIPIENT AGE_RECIPIENTS PZ_AGE_IDENTITY MOCK_AGE_FAIL
    : > "${MOCK_DIR}/age.log"
}
run_backup() { bash "$FULLBACKUP" >"${SANDBOX}/out.log" 2>&1; }
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }
count_ext() { find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

# --- (0) cablage statique ------------------------------------------------------
echo "== (0) cablage =="
grep -q 'command -v age' "$FULLBACKUP" \
    && ok "fullBackup : age exige si RECIPIENT (command -v age)" \
    || ko "fullBackup : garde age absente"
grep -q 'AGE_RECIPIENT' "$FULLBACKUP" \
    && ok "fullBackup : AGE_RECIPIENT(S) lu" \
    || ko "fullBackup : AGE_RECIPIENT absent"
grep -q '\.age' "$FULLBACKUP" \
    && ok "fullBackup : artefact .age produit" \
    || ko "fullBackup : artefact .age absent"
grep -qiE 'WARNING.*AGE_RECIPIENT|AGE_RECIPIENT.*WARNING|RECIPIENT.*vide' "$FULLBACKUP" \
    && ok "fullBackup : WARNING si RECIPIENT vide (ZIP clair local seul)" \
    || ko "fullBackup : WARNING RECIPIENT vide absent"
grep -q 'restore-ssh' "$CONF_INIT" \
    && ok "restore : flag --restore-ssh" \
    || ko "restore : --restore-ssh absent"
grep -q 'PZ_RESTORE_PRIVATE_KEYS' "$CONF_INIT" \
    && ok "restore : PZ_RESTORE_PRIVATE_KEYS (cles privees opt-in)" \
    || ko "restore : PZ_RESTORE_PRIVATE_KEYS absent"
grep -q 'sudoers non restauré, régénéré' "$CONF_INIT" \
    && ok "restore : sudoers refuse + regenere (log)" \
    || ko "restore : log 'sudoers non restauré, régénéré' absent"
grep -q 'install_sudoers' "$CONF_INIT" \
    && ok "restore : install_sudoers (template root-owned)" \
    || ko "restore : install_sudoers absent"
if grep -q 'restore_sudoers' "$CONF_INIT"; then
    ko "restore : restore_sudoers depuis archive encore present"
else
    ok "restore : plus d'install sudoers depuis l'archive"
fi
grep -q 'ProxyCommand' "$CONF_INIT" && grep -q 'PermitLocalCommand' "$CONF_INIT" \
    && ok "restore : config SSH refuse ProxyCommand/PermitLocalCommand" \
    || ko "restore : garde ProxyCommand/PermitLocalCommand absente"
grep -q 'command=' "$CONF_INIT" && grep -qi 'permitopen' "$CONF_INIT" \
    && ok "restore : authorized_keys refuse command=/permitopen" \
    || ko "restore : garde command=/permitopen absente"
grep -q 'unzip -t' "$CONF_INIT" && grep -q 'unzip -l' "$CONF_INIT" \
    && ok "restore : validation unzip -t + listing unzip -l avant extraction" \
    || ko "restore : validation unzip -t/-l absente"
grep -qE 'S_ISLNK|external_attr|symlink' "$CONF_INIT" \
    && ok "restore : detection symlinks dangereux" \
    || ko "restore : detection symlinks absente"
grep -q '"config"' "$CONF_INIT" && grep -q '"zomboid"' "$CONF_INIT" \
    && ok "restore : whitelist config/ + zomboid/" \
    || ko "restore : whitelist config/zomboid absente"
grep -q 'chmod 700' "$CONF_INIT" \
    && ok "restore : perms 0700/0600 .ssh" \
    || ko "restore : chmod 700 absent"

# --- Sourcing reel configurationInitiale.sh -----------------------------------
# shellcheck disable=SC1090
source "$CONF_INIT"
ok "sourcing reel de configurationInitiale.sh (dispatch non execute)"

R_HOME="${SANDBOX}/r-home"
R_MGR="${SANDBOX}/r-mgr"
R_WORLD="${SANDBOX}/r-world"
R_SUDOERS="${SANDBOX}/sudoers-dest"
reset_restore_env() {
    rm -rf "$R_HOME" "$R_MGR" "$R_WORLD" "$R_SUDOERS"
    mkdir -p "$R_HOME" "$R_MGR" "$R_SUDOERS" "${SANDBOX}/rt2"
    export PZ_USER="pzuser" PZ_HOME="$R_HOME" PZ_MANAGER_DIR="$R_MGR"
    export PZ_MANAGER_HOME="$R_HOME" PZ_GAME_HOME="$R_HOME"
    export PZ_SOURCE_DIR="$R_WORLD" PZ_SUDOERS_DEST="${R_SUDOERS}/pzuser"
    export BACKUP_DIR="${SANDBOX}/r-bkp" SYNC_BACKUPS_DIR="${SANDBOX}/r-sync"
    export RESTORE_SSH=false FORCE_MODE=true PZ_RESTORE_PRIVATE_KEYS=0
    echo "SYSTEM-SENTINEL" > "$PZ_SUDOERS_DEST"
    : > "${MOCK_DIR}/calls.log"
    : > "${MOCK_DIR}/age.log"
}
# Staging runtime user sans privilege (evite /run/user + chown reel).
ensure_runtime_dir() { printf '%s' "${SANDBOX}/rt2"; }

# make_zip <out> <spec.py> : construit une archive de test via python.
# La spec est un script python recevant OUT et PHOME (PZ_HOME sans / initial).
make_zip() {
    local out="$1" phome="${R_HOME#/}"
    PHOME="$phome" OUT="$out" python3 - "$2" <<'PYEOF'
import os, sys, zipfile
out = os.environ['OUT']
phome = os.environ['PHOME']
spec = sys.argv[1]
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
def w(name, data="x"):
    z.writestr(name, data)
def sym(name, target):
    zi = zipfile.ZipInfo(name)
    zi.create_system = 3
    zi.external_attr = (0o120755 << 16)
    z.writestr(zi, target)
ctx = {'w': w, 'sym': sym, 'phome': phome, 'z': z}
exec(compile(spec, '<spec>', 'exec'), ctx)
z.close()
PYEOF
}
GOOD_SPEC='
w("config/" + phome + "/.ssh/authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h\n")
w("config/" + phome + "/.config/systemd/user/svc.service", "unit\n")
w("config/" + phome + "/pzmanager/dummy.sh", "#!/bin/bash\n")
w("config/etc/sudoers.d/pzuser", "pzuser ALL=(ALL) NOPASSWD: ALL\n")
w("zomboid/Saves/player.bin", "world\n")
w("zomboid/db/servertest.db", "db\n")
w("zomboid/Server/servertest.ini", "ini\n")
'
run_restore() { ( restore_backup "$@" >"${SANDBOX}/r-out.log" 2>&1 ); }

# --- (1) sudoers modifie valide -> non installe, regenere -----------------------
echo "== (1) sudoers =="
if declare -F refuse_sudoers_from_backup >/dev/null 2>&1 && declare -F install_sudoers >/dev/null 2>&1; then
    reset_restore_env
    A1="${SANDBOX}/a1-good.zip"
    make_zip "$A1" "$GOOD_SPEC"
    if run_restore "$A1" --restore-ssh; then
        ok "sudoers : restore nominal exit 0"
    else
        ko "sudoers : restore nominal exit != 0"; sed 's/^/  [out] /' "${SANDBOX}/r-out.log" || true
    fi
    grep -q 'sudoers non restauré, régénéré' "${SANDBOX}/r-out.log" \
        && ok "sudoers : refus journalise (sudoers non restauré, régénéré)" \
        || ko "sudoers : refus non journalise"
    if grep -q 'NOPASSWD: ALL' "$PZ_SUDOERS_DEST"; then
        ko "sudoers : sudoers malicieux de l'archive INSTALLE"
    else
        ok "sudoers : sudoers de l'archive non installe"
    fi
    if grep -q 'SYSTEM-SENTINEL' "$PZ_SUDOERS_DEST"; then
        ko "sudoers : dest non regeneree (sentinelle intacte)"
    else
        ok "sudoers : dest regeneree depuis le template"
    fi
    grep -q "pzuser.*NOPASSWD.*apt-get" "$PZ_SUDOERS_DEST" \
        && ok "sudoers : contenu regenere == template (lignes apt-get)" \
        || ko "sudoers : contenu regenere inattendu -- $(cat "$PZ_SUDOERS_DEST")"
else
    ko "sudoers : fonctions refuse_sudoers_from_backup/install_sudoers absentes"
fi

# --- (2) .ssh opt-in -------------------------------------------------------------
echo "== (2) ssh opt-in =="
if declare -F restore_backup >/dev/null 2>&1; then
    reset_restore_env
    A1="${SANDBOX}/a1-good.zip"
    make_zip "$A1" "$GOOD_SPEC"
    if run_restore "$A1"; then
        ok "ssh sans flag : exit 0"
    else
        ko "ssh sans flag : exit != 0"
    fi
    [[ ! -e "$R_HOME/.ssh" ]] \
        && ok "ssh sans flag : .ssh non restaure" \
        || ko "ssh sans flag : .ssh restaure a tort"
    grep -qi 'ssh non restaur' "${SANDBOX}/r-out.log" \
        && ok "ssh sans flag : skip journalise" \
        || ko "ssh sans flag : skip non journalise"
    [[ -f "$R_WORLD/Saves/player.bin" ]] \
        && ok "ssh sans flag : reste (monde) restaure quand meme" \
        || ko "ssh sans flag : monde non restaure"

    reset_restore_env
    make_zip "$A1" "$GOOD_SPEC"
    if run_restore "$A1" --restore-ssh; then
        ok "ssh avec flag : exit 0"
    else
        ko "ssh avec flag : exit != 0"; sed 's/^/  [out] /' "${SANDBOX}/r-out.log" || true
    fi
    [[ -f "$R_HOME/.ssh/authorized_keys" ]] \
        && ok "ssh avec flag : authorized_keys restaure et valide" \
        || ko "ssh avec flag : authorized_keys absent"
    if [[ -d "$R_HOME/.ssh" && "$(stat -c %a "$R_HOME/.ssh")" == "700" ]]; then
        ok "ssh avec flag : dir 0700"
    else
        ko "ssh avec flag : dir perms $(stat -c %a "$R_HOME/.ssh" 2>/dev/null || echo ?) (attendu 700)"
    fi
    if [[ -f "$R_HOME/.ssh/authorized_keys" && "$(stat -c %a "$R_HOME/.ssh/authorized_keys")" == "600" ]]; then
        ok "ssh avec flag : fichier 0600"
    else
        ko "ssh avec flag : fichier perms $(stat -c %a "$R_HOME/.ssh/authorized_keys" 2>/dev/null || echo ?) (attendu 600)"
    fi
else
    ko "ssh opt-in : restore_backup absente"
fi

# --- (3) .ssh malicieux refuse ----------------------------------------------------
echo "== (3) ssh refuse =="
if declare -F validate_ssh_tree >/dev/null 2>&1 || declare -F restore_backup >/dev/null 2>&1; then
    reset_restore_env
    A_CMD="${SANDBOX}/a-cmd.zip"
    make_zip "$A_CMD" '
w("config/" + phome + "/.ssh/authorized_keys", "command=\"rm -rf /\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== evil@h\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_CMD" --restore-ssh; then
        ko "authorized_keys command= : restaure a tort"
    else
        ok "authorized_keys command= : refuse (die)"
    fi
    [[ ! -e "$R_HOME/.ssh/authorized_keys" ]] \
        && ok "authorized_keys command= : .ssh non installe" \
        || ko "authorized_keys command= : .ssh installe malgre le refus"

    reset_restore_env
    A_PO="${SANDBOX}/a-permitopen.zip"
    make_zip "$A_PO" '
w("config/" + phome + "/.ssh/authorized_keys", "permitopen=\"host:22\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== evil@h\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_PO" --restore-ssh; then
        ko "authorized_keys permitopen : restaure a tort"
    else
        ok "authorized_keys permitopen : refuse (die)"
    fi

    reset_restore_env
    A_PX="${SANDBOX}/a-proxy.zip"
    make_zip "$A_PX" '
w("config/" + phome + "/.ssh/authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h\n")
w("config/" + phome + "/.ssh/config", "Host *\n    ProxyCommand /bin/sh\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_PX" --restore-ssh; then
        ko "ssh config ProxyCommand : restaure a tort"
    else
        ok "ssh config ProxyCommand : refuse (die)"
    fi
    [[ ! -e "$R_HOME/.ssh/config" ]] \
        && ok "ssh config ProxyCommand : config non installe" \
        || ko "ssh config ProxyCommand : config installee malgre le refus"

    reset_restore_env
    A_PRIV="${SANDBOX}/a-priv.zip"
    make_zip "$A_PRIV" '
w("config/" + phome + "/.ssh/authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h\n")
w("config/" + phome + "/.ssh/id_ed25519", "PRIVATE-KEY-SENTINEL\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_PRIV" --restore-ssh; then
        ko "cle privee (defaut) : restauree a tort"
    else
        ok "cle privee (defaut) : refusee"
    fi
    [[ ! -e "$R_HOME/.ssh/id_ed25519" ]] \
        && ok "cle privee (defaut) : non installee" \
        || ko "cle privee (defaut) : installee malgre le refus"
    reset_restore_env
    export PZ_RESTORE_PRIVATE_KEYS=1
    make_zip "$A_PRIV" '
w("config/" + phome + "/.ssh/authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h\n")
w("config/" + phome + "/.ssh/id_ed25519", "PRIVATE-KEY-SENTINEL\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_PRIV" --restore-ssh; then
        ok "cle privee (PZ_RESTORE_PRIVATE_KEYS=1) : acceptee"
    else
        ko "cle privee (PZ_RESTORE_PRIVATE_KEYS=1) : refusee a tort"
    fi
    export PZ_RESTORE_PRIVATE_KEYS=0
else
    ko "ssh refuse : fonctions absentes"
fi

# --- (4) archives piegees refusees avant extraction -------------------------------
echo "== (4) traversal/symlink =="
if declare -F validate_restore_archive >/dev/null 2>&1; then
    reset_restore_env
    A_TRAV="${SANDBOX}/a-trav.zip"
    make_zip "$A_TRAV" '
w("../../etc/cron.d/pwn", "* * * * * root pwn\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_TRAV" --restore-ssh; then
        ko "traversal ../../etc/cron.d/pwn : restaure a tort"
    else
        ok "traversal ../../etc/cron.d/pwn : refuse avant extraction"
    fi
    [[ ! -e "$R_HOME/.ssh/authorized_keys" ]] \
        && ok "traversal : rien installe (.ssh absent)" \
        || ko "traversal : .ssh installe malgre le refus"
    if find "$SANDBOX" -name pwn -print -quit 2>/dev/null | grep -q pwn; then
        ko "traversal : fichier pwn ecrit quelque part"
    else
        ok "traversal : aucun fichier pwn ecrit"
    fi

    reset_restore_env
    A_ABS="${SANDBOX}/a-abs.zip"
    make_zip "$A_ABS" '
w("/etc/cron.d/pwn", "* * * * * root pwn\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_ABS"; then
        ko "chemin absolu : restaure a tort"
    else
        ok "chemin absolu : refuse"
    fi

    reset_restore_env
    A_SYM="${SANDBOX}/a-sym.zip"
    make_zip "$A_SYM" '
w("config/" + phome + "/.ssh/authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3QgdGVzdA== u@h\n")
sym("config/" + phome + "/.ssh/link", "/etc/passwd")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_SYM" --restore-ssh; then
        ko "symlink /etc/passwd : restaure a tort"
    else
        ok "symlink /etc/passwd : refuse"
    fi
    [[ ! -e "$R_HOME/.ssh/link" ]] \
        && ok "symlink : non installe" \
        || ko "symlink : installe malgre le refus"

    reset_restore_env
    A_EVIL="${SANDBOX}/a-evil.zip"
    make_zip "$A_EVIL" '
w("evil.sh", "#!/bin/sh\nevil\n")
w("zomboid/Saves/player.bin", "world\n")
'
    if run_restore "$A_EVIL"; then
        ko "top-level inconnu : restaure a tort"
    else
        ok "top-level inconnu : refuse (whitelist)"
    fi
else
    ko "traversal : validate_restore_archive absente"
fi

# --- (5) chiffrement age (fullBackup end-to-end) ------------------------------------
echo "== (5) age =="
fresh_backup_case age-ok
export AGE_RECIPIENT="age1ql5ksft0rjx2vtestrecipient"
export PATH="${AGE_BIN}:${BASE_PATH}"
if run_backup; then
    ok "age : run OK avec RECIPIENT"
else
    ko "age : run en echec a tort"; show_out
fi
if (( $(count_ext "$BK_SYNC" '*.age') == 1 )); then
    ok "age : .age publie"
else
    ko "age : .age absent (sync=$(ls "$BK_SYNC" 2>/dev/null))"
fi
if (( $(count_ext "$BK_SYNC" '*.zip') == 0 )); then
    ok "age : ZIP clair supprime (non publie hors-site)"
else
    ko "age : ZIP clair publie malgre le chiffrement"
fi
agefile="$(find "$BK_SYNC" -maxdepth 1 -type f -name '*.age' | head -1)"
if [[ -n "${agefile:-}" && "$(stat -c %a "$agefile")" == "600" ]]; then
    ok "age : .age en 0600"
else
    ko "age : perms .age $(stat -c %a "$agefile" 2>/dev/null || echo ?) (attendu 600)"
fi
if grep -q '^recip age1ql5ksft0rjx2v' "${MOCK_DIR}/age.log"; then
    ok "age : destinataire transmis (age -r)"
else
    ko "age : destinataire non transmis"
fi

fresh_backup_case age-multi
export AGE_RECIPIENTS="age1aaaa,age1bbbb"
export PATH="${AGE_BIN}:${BASE_PATH}"
if run_backup; then
    ok "age multi : run OK"
else
    ko "age multi : run en echec a tort"; show_out
fi
if [[ "$(grep -c '^recip ' "${MOCK_DIR}/age.log")" == "2" ]]; then
    ok "age multi : 2 destinataires (-r x2, rotation)"
else
    ko "age multi : $(grep -c '^recip ' "${MOCK_DIR}/age.log") destinataire(s) (attendu 2)"
fi

fresh_backup_case age-missing
export AGE_RECIPIENT="age1ql5ksft0rjx2vtest"
# Mocks presents mais 'age' absent (ni mock ni systeme) -> doit mourir.
export PATH="${BASE_PATH}"
command -v age >/dev/null 2>&1 && { ko "age-missing : 'age' resolu dans BASE_PATH, cas non isole"; }
if run_backup; then
    ko "age absent : succes a tort (backup clair hors-site silencieux)"
else
    ok "age absent + RECIPIENT : die"
fi
(( $(count_ext "$BK_SYNC" '*.age') == 0 )) \
    && ok "age absent : aucun .age" \
    || ko "age absent : .age publie a tort"
(( $(count_ext "$BK_SYNC" '*.zip') == 0 )) \
    && ok "age absent : aucun ZIP clair publie" \
    || ko "age absent : ZIP clair publie malgre tout"
(( $(find "$BK_SYNC" -maxdepth 1 -name '*.partial*' 2>/dev/null | wc -l | tr -d ' ') == 0 )) \
    && ok "age absent : pas de .partial residuel" \
    || ko "age absent : .partial residuel"

fresh_backup_case age-empty
unset AGE_RECIPIENT AGE_RECIPIENTS
export PATH="${BASE_PATH}"
if run_backup; then
    ok "sans RECIPIENT : run OK (ZIP clair historique)"
else
    ko "sans RECIPIENT : run en echec a tort"; show_out
fi
(( $(count_ext "$BK_SYNC" '*.zip') == 1 )) \
    && ok "sans RECIPIENT : ZIP clair local seul" \
    || ko "sans RECIPIENT : zip_count=$(count_ext "$BK_SYNC" '*.zip') (attendu 1)"
(( $(count_ext "$BK_SYNC" '*.age') == 0 )) \
    && ok "sans RECIPIENT : pas de .age" \
    || ko "sans RECIPIENT : .age present a tort"
grep -qi 'WARNING' "${SANDBOX}/out.log" \
    && ok "sans RECIPIENT : WARNING journalise" \
    || ko "sans RECIPIENT : WARNING absent"

fresh_backup_case age-fail
export AGE_RECIPIENT="age1ql5ksft0rjx2vtest"
export MOCK_AGE_FAIL=1
export PATH="${AGE_BIN}:${BASE_PATH}"
if run_backup; then
    ko "age en echec : succes a tort"
else
    ok "age en echec : die"
fi
unset MOCK_AGE_FAIL
(( $(count_ext "$BK_SYNC" '*.age') == 0 )) \
    && ok "age en echec : aucun .age publie" \
    || ko "age en echec : .age publie a tort"
(( $(count_ext "$BK_SYNC" '*.zip') == 0 )) \
    && ok "age en echec : aucun ZIP clair publie" \
    || ko "age en echec : ZIP clair publie malgre tout"
(( $(find "$BK_SYNC" -maxdepth 1 -name '*.partial*' 2>/dev/null | wc -l | tr -d ' ') == 0 )) \
    && ok "age en echec : pas de .partial residuel" \
    || ko "age en echec : .partial residuel"

# --- (6) cle privee age jamais dans l'archive ---------------------------------------
echo "== (6) identite age =="
fresh_backup_case age-ident
export AGE_RECIPIENT="age1ql5ksft0rjx2vtest"
export PZ_AGE_IDENTITY="${SANDBOX}/age-key.txt"
printf 'AGE-SECRET-KEY-SENTINEL-IDENTITY\n' > "$PZ_AGE_IDENTITY"
chmod 600 "$PZ_AGE_IDENTITY"
export PATH="${AGE_BIN}:${BASE_PATH}"
if run_backup; then
    ok "identite : run OK"
else
    ko "identite : run en echec a tort"; show_out
fi
agefile="$(find "$BK_SYNC" -maxdepth 1 -type f -name '*.age' | head -1)"
if python3 - "$agefile" <<'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert not any('identity' in n.lower() or 'age-key' in n.lower() for n in names), "entree identite: %s" % names
blob = "\n".join(names)
for i in z.infolist():
    blob += z.read(i.filename).decode('utf-8', 'replace')
assert 'AGE-SECRET-KEY-SENTINEL-IDENTITY' not in blob, "contenu cle privee dans l'archive"
assert 'PZ_AGE_IDENTITY' not in blob, "reference identite dans l'archive"
PYEOF
then
    ok "identite : cle privee absente de l'archive (noms + contenu)"
else
    ko "identite : cle privee ou reference dans l'archive"
fi
if grep -n 'PZ_AGE_IDENTITY' "$FULLBACKUP" | grep -vqE '^[0-9]+:[[:space:]]*#'; then
    ko "identite : PZ_AGE_IDENTITY utilise en code (devrait n'etre que documente)"
else
    ok "identite : PZ_AGE_IDENTITY seulement documente (jamais embarquee)"
fi

# --- bash -n -----------------------------------------------------------------------
for f in "$FULLBACKUP" "$CONF_INIT" "$0"; do
    bash -n "$f" || { ko "bash -n : $f"; }
done
ok "bash -n : scripts OK"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C16 BACKUP SECURITY: OK (${PASS} controles)"
else
    echo "C16 BACKUP SECURITY: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
