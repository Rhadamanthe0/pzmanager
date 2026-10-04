#!/usr/bin/env bash
# test_c6_full_backup.sh - Fiabilisation full backup off-site (C6).
#
# Couvre (fullBackup.sh uniquement) :
#   (0) câblage statique : umask 077, chmod 600 + vérif, nom unique
#       secondes+pid, latest épinglé (readlink -f + re-lecture stable),
#       acquire_world_lock, validation unzip -t avant publish, rotation
#       après publish seule, purge dossiers legacy opt-in (PZ_PURGE_LEGACY).
#   (1) monde absent (pas de latest) -> die, aucun ZIP.
#   (2) latest invalide (répertoire réel / cible vide sans Saves-db-Server /
#       lien cassé) -> die, aucun ZIP.
#   (3) succès : ZIP 0600, contient config + zomboid (Saves).
#   (4) deux backups même minute -> noms distincts, deux ZIP.
#   (5) latest change pendant zip (mock) -> die, rien publié.
#   (6) ZIP corrompu (mock zip) -> unzip -t échoue -> pas de publish,
#       pas de rotation, pas de .partial résiduel.
#   (7) rotation après échec : anciens ZIP intacts (aucun bon backup
#       supprimé par un run en échec).
#   (8) dossiers legacy : conservés par défaut, purgés seulement si
#       PZ_PURGE_LEGACY=1.
#
# Preuves : vrai script fullBackup.sh, vrais flock/mv/chmod/stat, zip/unzip
# émulés par PATH via python zipfile (format ZIP réel, validation réelle ;
# les hôtes sans zip/unzip natifs restent couverts) avec injection de fautes
# pilotée (MOCK_ZIP_CORRUPT / MOCK_ZIP_CHANGE_LATEST). Isolé : XDG_RUNTIME_DIR
# + PZ_HOME + BACKUP_DIR + SYNC_BACKUPS_DIR sous sandbox. source_env lit
# ${ROOT}/.env (qui écrase l'environnement exporté) : le test y pose un stub
# (sauvegarde + restauration du .env préexistant via trap EXIT). Ne touche à
# aucun backup réel.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${ROOT}/data/scripts/backup/fullBackup.sh"
# C6 : sandbox sous /tmp (FS Linux, chmod/stat réels). Sous WSL/Git-Bash le
# dépôt vit sur /mnt/c (DrvFs sans modes) : un sandbox sous tests/ y lirait
# toujours 777 malgré chmod 600 et fausserait le contrôle des permissions.
SANDBOX="${TMPDIR:-/tmp}/pzmanager-c6-$$"
BIN="${SANDBOX}/bin"

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

# --- Prérequis ---------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    echo "[SKIP-local] flock indisponible — test C6 à exécuter sous Linux/WSL." >&2
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP-local] python3 indisponible (mocks zip/unzip) — test C6 à exécuter avec python3." >&2
    exit 0
fi
if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] script introuvable : $SCRIPT" >&2
    exit 1
fi

# --- Isolation ---------------------------------------------------------------
rm -rf "$SANDBOX"
mkdir -p "${SANDBOX}/rt" "$BIN"
# FS sans modes (DrvFs/NTFS sous Git-Bash) : chmod 600 illisible -> SKIP propre
# (le contrôle 0600, cœur du C6, exige un FS Linux ; voir WSL).
probe="$(mktemp "${SANDBOX}/.probe.XXXXXX")"
chmod 600 "$probe" 2>/dev/null || true
if [[ "$(stat -c %a "$probe" 2>/dev/null || echo ?)" != "600" ]]; then
    echo "[SKIP-local] FS sans chmod (DrvFs/NTFS) — test C6 à exécuter sous Linux/WSL." >&2
    exit 0
fi
rm -f "$probe"
export XDG_RUNTIME_DIR="${SANDBOX}/rt"
if ! [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || [[ -z "${PZ_WORLD_LOCK_FD:-}" ]] \
    || ! { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
    PZ_WORLD_LOCK_DEPTH=0; PZ_WORLD_LOCK_FD=""
    export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
fi
if [[ -f "$REPO_ENV" ]]; then
    cp -p "$REPO_ENV" "$ENV_BACKUP"
fi
printf '# stub test C6 (restauré en fin de test)\n' > "$REPO_ENV"

# --- Mocks -------------------------------------------------------------------
# sudo : toujours en échec (branche "Ignoré" du script, sans prompt).
cat > "${BIN}/sudo" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
chmod +x "${BIN}/sudo"
# zip émulé via python zipfile (format réel). Comprend `zip -r -q DEST membres...`.
# Fautes : MOCK_ZIP_CORRUPT=1 -> fichier non-ZIP (exit 0, la validation doit
# rejeter) ; MOCK_ZIP_CHANGE_LATEST=1 -> rebascule latest vers
# MOCK_ZIP_CHANGE_TARGET pendant la création (le contrôle de stabilité doit
# rejeter).
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
if [[ "${MOCK_ZIP_CORRUPT:-0}" == "1" ]]; then
    printf 'CORRUPT-NOT-A-ZIP\n' > "$dest"
    exit 0
fi
if [[ "${MOCK_ZIP_CHANGE_LATEST:-0}" == "1" && -n "${MOCK_ZIP_CHANGE_TARGET:-}" ]]; then
    ln -sfnT "${MOCK_ZIP_CHANGE_TARGET}" "${BACKUP_LATEST_LINK}"
fi
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
chmod +x "${BIN}/zip"
# unzip émulé : ne sert qu'à `unzip -t ARCHIVE` (validation réelle du format).
cat > "${BIN}/unzip" <<'MOCKEOF'
#!/usr/bin/env bash
arch=""
for a in "$@"; do
    [[ "$a" == -* ]] && continue
    arch="$a"
done
[[ -n "$arch" ]] || { echo "mock unzip: pas d'archive" >&2; exit 2; }
python3 - "$arch" <<'PYEOF'
import sys, zipfile
arch = sys.argv[1]
try:
    with zipfile.ZipFile(arch) as z:
        bad = z.testzip()
        if bad is not None:
            print("mock unzip: entrée corrompue: %s" % bad, file=sys.stderr)
            sys.exit(1)
except Exception as e:
    print("mock unzip: archive invalide: %s" % e, file=sys.stderr)
    sys.exit(1)
PYEOF
MOCKEOF
chmod +x "${BIN}/unzip"
export PATH="${BIN}:$PATH"

# --- Helpers -----------------------------------------------------------------
# fresh_case <nom> : sandbox config + monde + latest valides, env exporté dans
# CE shell (appel direct). Réinitialise les MOCK_* (pas de fuite entre cas).
SYNC=""
BKP=""
fresh_case() {
    local name="$1"
    local home="${SANDBOX}/home-${name}"
    local mgr="${SANDBOX}/mgr-${name}"
    local datadir="${SANDBOX}/data-${name}"
    local scripts="${SANDBOX}/scripts-${name}"
    BKP="${SANDBOX}/bkp-${name}"
    SYNC="${SANDBOX}/sync-${name}"
    rm -rf "$home" "$mgr" "$datadir" "$scripts" "$BKP" "$SYNC"
    mkdir -p "$home/.ssh" "$home/.config/systemd/user" "$datadir/setupTemplates" \
        "$scripts" "$mgr/versionning" "$BKP" "$SYNC"
    mkdir -p "$BKP/snap1/Saves" "$BKP/snap1/db" "$BKP/snap1/Server"
    echo key > "$home/.ssh/id_ed25519.pub"
    echo unit > "$home/.config/systemd/user/svc.service"
    echo tpl > "$datadir/setupTemplates/tpl.txt"
    echo dummy > "$scripts/dummy.sh"
    printf 'export FOO=bar\n' > "$mgr/.env"
    echo v1 > "$mgr/versionning/V1.txt"
    echo "world" > "$BKP/snap1/Saves/player.bin"
    echo "db" > "$BKP/snap1/db/servertest.db"
    echo "ini" > "$BKP/snap1/Server/servertest.ini"
    ln -sfnT "$BKP/snap1" "$BKP/latest"
    # Cible de rebascule pour le cas "latest change pendant zip".
    mkdir -p "$BKP/snap2/Saves"
    echo "other" > "$BKP/snap2/Saves/other.bin"
    export PZ_HOME="$home" PZ_MANAGER_DIR="$mgr" PZ_DATA_DIR="$datadir" \
        PZ_SCRIPTS_DIR="$scripts" PZ_MANAGER_HOME="$home" PZ_GAME_HOME="$home"
    export WHITELIST_LEDGER="${datadir}/whitelistLedger.csv"
    echo "u;1;2026-01-01 00:00:00" > "$WHITELIST_LEDGER"
    export BACKUP_DIR="$BKP" BACKUP_LATEST_LINK="$BKP/latest" SYNC_BACKUPS_DIR="$SYNC"
    export PZ_USER="pzuser" OFFSITE_BACKUP_COUNT=7 PZ_PURGE_LEGACY=0
    unset MOCK_ZIP_CORRUPT MOCK_ZIP_CHANGE_LATEST MOCK_ZIP_CHANGE_TARGET
}
zip_count() { find "$1" -maxdepth 1 -type f -name '*.zip' 2>/dev/null | wc -l | tr -d ' '; }
partial_left() { find "$1" -maxdepth 1 -name '*.partial' 2>/dev/null | wc -l | tr -d ' '; }
run_backup() { bash "$SCRIPT" >"${SANDBOX}/out.log" 2>&1; }
show_out() { sed 's/^/  [out] /' "${SANDBOX}/out.log" 2>/dev/null || true; }

# --- (0) câblage statique ------------------------------------------------------
echo "== (0) câblage =="
grep -q 'umask 077' "$SCRIPT" \
    && ok "umask 077 (secrets .env)" \
    || ko "umask 077 absent"
grep -q 'chmod 600' "$SCRIPT" && grep -q 'stat -c %a' "$SCRIPT" \
    && ok "chmod 600 + vérification des permissions" \
    || ko "chmod 600 / vérification absents"
grep -q 'unzip -t' "$SCRIPT" \
    && ok "validation unzip -t avant publication" \
    || ko "validation unzip -t absente"
if grep -q 'ZIP produit sans données de jeu' "$SCRIPT"; then
    ko "ancien warning ZIP sans données encore présent"
else
    ok "plus de ZIP sans données de jeu (die exigé)"
fi
grep -q 'PINNED_GAME_DIR' "$SCRIPT" && grep -q 'readlink -f' "$SCRIPT" \
    && ok "source latest épinglée (readlink -f + re-lecture)" \
    || ko "épinglage latest absent"
grep -q 'acquire_world_lock' "$SCRIPT" \
    && ok "verrou monde acquis (lecture stable)" \
    || ko "acquire_world_lock absent"
grep -q '%Y-%m-%d_%H-%M-%S' "$SCRIPT" && grep -q '\-\$\$' "$SCRIPT" \
    && ok "nom unique secondes+pid" \
    || ko "nom unique secondes+pid absent"
grep -q 'PZ_PURGE_LEGACY' "$SCRIPT" \
    && ok "purge dossiers legacy opt-in (PZ_PURGE_LEGACY)" \
    || ko "PZ_PURGE_LEGACY absent"
if grep -A6 'PZ_PURGE_LEGACY' "$SCRIPT" | grep -q 'return 0'; then
    ok "legacy conservé par défaut (retour avant purge)"
else
    ko "garde legacy par défaut absente"
fi

# --- (1) monde absent -----------------------------------------------------------
echo "== (1) monde absent =="
fresh_case absent
rm -f "$BKP/latest"
if run_backup; then
    ko "latest absent : succès à tort"; show_out
else
    ok "latest absent : die (non-zéro)"
fi
(( $(zip_count "$SYNC") == 0 )) && ok "latest absent : aucun ZIP publié" || { ko "latest absent : ZIP publié à tort"; show_out; }
(( $(partial_left "$SYNC") == 0 )) && ok "latest absent : pas de .partial" || ko "latest absent : .partial résiduel"

# --- (2) latest invalide ----------------------------------------------------------
echo "== (2) latest invalide =="
fresh_case realdir
rm -f "$BKP/latest"
mkdir -p "$BKP/latest"
echo sentinel > "$BKP/latest/sentinel.txt"
if run_backup; then
    ko "latest répertoire réel : succès à tort"; show_out
else
    ok "latest répertoire réel : die"
fi
(( $(zip_count "$SYNC") == 0 )) && ok "latest répertoire réel : aucun ZIP" || ko "latest répertoire réel : ZIP à tort"
if [[ -f "$BKP/latest/sentinel.txt" ]]; then
    ok "latest répertoire réel : contenu intact (pas de suppression)"
else
    ko "latest répertoire réel : contenu altéré"
fi

fresh_case emptytarget
rm -f "$BKP/latest"
mkdir -p "$BKP/empty"
ln -sfnT "$BKP/empty" "$BKP/latest"
if run_backup; then
    ko "latest cible vide : succès à tort"; show_out
else
    ok "latest cible vide (sans Saves/db/Server) : die"
fi
(( $(zip_count "$SYNC") == 0 )) && ok "latest cible vide : aucun ZIP" || ko "latest cible vide : ZIP à tort"

fresh_case broken
rm -f "$BKP/latest"
ln -sfnT "$BKP/inexistant" "$BKP/latest"
if run_backup; then
    ko "latest lien cassé : succès à tort"; show_out
else
    ok "latest lien cassé : die"
fi
(( $(zip_count "$SYNC") == 0 )) && ok "latest lien cassé : aucun ZIP" || ko "latest lien cassé : ZIP à tort"

# --- (3) succès : perms + contenu ---------------------------------------------------
echo "== (3) succès =="
fresh_case happy
if run_backup; then
    ok "cas nominal : succès"
else
    ko "cas nominal : échec à tort"; show_out
fi
(( $(zip_count "$SYNC") == 1 )) && ok "cas nominal : un ZIP publié" || { ko "cas nominal : zip_count=$(zip_count "$SYNC") (attendu 1)"; show_out; }
zipfile="$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' | head -1)"
if [[ -n "${zipfile:-}" && "$(stat -c %a "$zipfile")" == "600" ]]; then
    ok "cas nominal : ZIP en 0600"
else
    ko "cas nominal : permissions $(stat -c %a "$zipfile" 2>/dev/null || echo ?) (attendu 600)"
fi
if python3 - "$zipfile" <<'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert any(n.startswith('config/') for n in names), "pas de config/"
assert any(n.startswith('zomboid/') for n in names), "pas de zomboid/"
assert any('player.bin' in n for n in names), "pas de données monde"
PYEOF
then
    ok "cas nominal : ZIP contient config + zomboid (Saves)"
else
    ko "cas nominal : contenu ZIP incomplet"; show_out
fi
(( $(partial_left "$SYNC") == 0 )) && ok "cas nominal : pas de .partial" || ko "cas nominal : .partial résiduel"

# --- (4) deux backups même minute ----------------------------------------------------
echo "== (4) unicité =="
fresh_case uniq
export OFFSITE_BACKUP_COUNT=7
run_backup || { ko "unicité run1 : échec"; show_out; }
run_backup || { ko "unicité run2 : échec"; show_out; }
if (( $(zip_count "$SYNC") == 2 )); then
    ok "deux runs : deux ZIP"
else
    ko "deux runs : zip_count=$(zip_count "$SYNC") (attendu 2)"; show_out
fi
if [[ "$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' -printf '%f\n' | sort -u | wc -l | tr -d ' ')" == "2" ]]; then
    ok "deux runs : noms distincts"
else
    ko "deux runs : collision de noms"; show_out
fi

# --- (5) latest change pendant zip ------------------------------------------------------
echo "== (5) latest instable =="
fresh_case unstable
run_backup || { ko "instable setup run : échec"; show_out; }
before="$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' | sort)"
export MOCK_ZIP_CORRUPT= MOCK_ZIP_CHANGE_LATEST=1 MOCK_ZIP_CHANGE_TARGET="$BKP/snap2"
if run_backup; then
    ko "latest instable : succès à tort"; show_out
else
    ok "latest instable : die"
fi
(( $(zip_count "$SYNC") == 1 )) && ok "latest instable : rien publié" || { ko "latest instable : ZIP publié à tort"; show_out; }
(( $(partial_left "$SYNC") == 0 )) && ok "latest instable : pas de .partial" || ko "latest instable : .partial résiduel"
after="$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' | sort)"
[[ "$before" == "$after" ]] && ok "latest instable : ancien ZIP intact" || ko "latest instable : ancien ZIP altéré"
unset MOCK_ZIP_CHANGE_LATEST MOCK_ZIP_CHANGE_TARGET

# --- (6)(7) ZIP corrompu : pas de publish/rotation -----------------------------------------
echo "== (6)(7) corrompu =="
fresh_case corrupt
export OFFSITE_BACKUP_COUNT=7
run_backup || { ko "corrompu setup run1 : échec"; show_out; }
sleep 1.1
run_backup || { ko "corrompu setup run2 : échec"; show_out; }
good_list="$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' | sort)"
good_count="$(echo "$good_list" | wc -l | tr -d ' ')"
export MOCK_ZIP_CORRUPT=1
if run_backup; then
    ko "ZIP corrompu : succès à tort"; show_out
else
    ok "ZIP corrompu : die (unzip -t)"
fi
unset MOCK_ZIP_CORRUPT
(( $(zip_count "$SYNC") == "$good_count" )) && ok "ZIP corrompu : aucun nouveau ZIP (rotation non avancée)" || { ko "ZIP corrompu : rotation modifiée"; show_out; }
(( $(partial_left "$SYNC") == 0 )) && ok "ZIP corrompu : pas de .partial" || ko "ZIP corrompu : .partial résiduel"
now_list="$(find "$SYNC" -maxdepth 1 -type f -name '*.zip' | sort)"
[[ "$good_list" == "$now_list" ]] && ok "ZIP corrompu : anciens ZIP intacts" || { ko "ZIP corrompu : anciens ZIP altérés"; show_out; }

# --- (8) dossiers legacy ----------------------------------------------------------------------
echo "== (8) legacy =="
fresh_case legacy
mkdir -p "$SYNC/2026-01-01_00-00"
echo legacy > "$SYNC/2026-01-01_00-00/keep.txt"
export PZ_PURGE_LEGACY=0 OFFSITE_BACKUP_COUNT=7
if run_backup; then
    ok "legacy défaut : run OK"
else
    ko "legacy défaut : échec"; show_out
fi
if [[ -f "$SYNC/2026-01-01_00-00/keep.txt" ]]; then
    ok "legacy défaut : dossier conservé"
else
    ko "legacy défaut : dossier supprimé à tort"
fi
export PZ_PURGE_LEGACY=1
if run_backup; then
    ok "legacy opt-in : run OK"
else
    ko "legacy opt-in : échec"; show_out
fi
if [[ ! -e "$SYNC/2026-01-01_00-00" ]]; then
    ok "legacy opt-in : dossier purgé"
else
    ko "legacy opt-in : dossier conservé à tort"
fi

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C6 FULL BACKUP: OK (${PASS} contrôles)"
else
    echo "C6 FULL BACKUP: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
