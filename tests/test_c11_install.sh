#!/usr/bin/env bash
# test_c11_install.sh - Installation C11 : secret admin, erreurs propagées, idempotence.
#
# Couvre (data/scripts/install/configurationInitiale.sh uniquement) :
#   (0) statique : owner = compte du service + mode 0600, skip si existant sauf
#       --force, fail_on_error + strict pour daemon-reload/enable zomboid.service,
#       user_systemctl tolérant conservé (timers, documenté).
#   (A) generate_admin_password : chown vers PZ_MANAGER_USER + chmod 600 émis,
#       mode réel 600 (si le FS le porte), contenu non vide.
#   (B) idempotence : 2e run sans --force ne régénère pas (contenu identique,
#       generate_password non rappelé) ; --force régénère.
#   (C) échec daemon-reload mocké : enable_zomboid_service meurt (exit != 0),
#       ERREUR tracée, zomboid.service et timers jamais tentés (pas de succès
#       partiel) ; témoin positif : sans panne, exit 0 + daemon-reload, enable
#       zomboid.service et les 6 timers demandés.
#
# Preuves réelles : vraies fonctions sourcées (garde BASH_SOURCE du script),
# mocks seulement aux frontières inaccessibles : chown/chmod journalisés,
# sudo/systemctl via PATH sandbox, generate_password déterministe.
# Isolé : PZ_MANAGER_DIR + stubs redirigés vers un sandbox (aucun impact prod).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONF_INIT="${ROOT}/data/scripts/install/configurationInitiale.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/c11-install-XXXXXX")"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    [[ "${C11_KEEP:-0}" == "1" ]] || rm -rf "$SANDBOX"
}
trap cleanup EXIT

[[ -f "$CONF_INIT" ]] || { echo "[FAIL] cible introuvable : $CONF_INIT" >&2; exit 1; }

# Capacité du FS local : sur NTFS (checkout Windows), chmod est sans effet.
# On prouve alors la COMMANDE émise (journal) ; sur Linux le mode réel en plus.
probe_fs_modes() {
    local f m
    f="$(mktemp)"
    chmod 600 "$f" 2>/dev/null || true
    m="$(stat -c %a "$f" 2>/dev/null || echo ?)"
    rm -f "$f"
    [[ "$m" == "600" ]] && echo 1 || echo 0
}
FS_MODES="$(probe_fs_modes)"

# --- (0) statique ---------------------------------------------------------------
echo "== (0) statique =="
grep -q 'PZ_MANAGER_USER' "$CONF_INIT" \
    && ok "compte du service (PZ_MANAGER_USER) référencé" \
    || ko "PZ_MANAGER_USER absent"
grep -q 'chown "\$owner:\$owner" "\$password_file"' "$CONF_INIT" \
    && ok "chown owner:owner du .admin_password présent" \
    || ko "chown du .admin_password absent"
grep -q 'chmod 600 "\$password_file"' "$CONF_INIT" \
    && ok "chmod 600 du .admin_password présent" \
    || ko "chmod 600 du .admin_password absent"
grep -q '\-s "\$password_file"' "$CONF_INIT" \
    && ok "skip si mot de passe existant (-s password_file)" \
    || ko "garde idempotence (-s) absente"
grep -q 'FORCE_MODE' "$CONF_INIT" \
    && ok "régénération conditionnée à --force (FORCE_MODE)" \
    || ko "FORCE_MODE absent de generate_admin_password"
grep -q 'fail_on_error' "$CONF_INIT" \
    && ok "fail_on_error défini" \
    || ko "fail_on_error absent"
grep -q 'user_systemctl_strict "\$runtime_dir" daemon-reload' "$CONF_INIT" \
    && ok "daemon-reload strict (plus masqué)" \
    || ko "daemon-reload strict absent"
grep -q 'user_systemctl_strict "\$runtime_dir" enable zomboid.service' "$CONF_INIT" \
    && ok "enable zomboid.service strict (plus masqué)" \
    || ko "enable zomboid.service strict absent"
grep -q 'fail_on_error \$? "daemon-reload' "$CONF_INIT" \
    && ok "fail_on_error après daemon-reload" \
    || ko "fail_on_error après daemon-reload absent"
grep -q 'fail_on_error \$? "activation zomboid.service"' "$CONF_INIT" \
    && ok "fail_on_error après enable zomboid.service" \
    || ko "fail_on_error après enable absent"
grep -A3 '^user_systemctl() {' "$CONF_INIT" | grep -q '|| true' \
    && ok "user_systemctl tolérant conservé (timers, documenté)" \
    || ko "user_systemctl tolérant perdu"
grep -A3 '^user_systemctl_strict() {' "$CONF_INIT" | grep -q '|| true' \
    && ko "user_systemctl_strict masque encore (|| true)" \
    || ok "user_systemctl_strict ne masque rien"

# --- Sandbox + sourcing réel ----------------------------------------------------
echo "== sandbox =="
S="${SANDBOX}/case"
MOCK_DIR="${S}/mock"
BIN="${S}/bin"
MGR="${S}/home/pzmgr"
mkdir -p "$MOCK_DIR" "$BIN" "$MGR/pzmanager" "$S/rt"
chmod 700 "$S/rt"
export MOCK_DIR

# chown : journalisé puis succès simulé (non-root ne peut pas chown).
cat > "$BIN/chown" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exit 0
MOCKEOF
# chmod : journalisé PUIS délégué au vrai binaire (prouve la commande émise,
# applique le mode réel quand le FS le porte).
cat > "$BIN/chmod" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'chmod %s\n' "$*" >> "${MOCK_DIR}/calls.log"
exec /bin/chmod "$@"
MOCKEOF
# sudo : dépile `-u <user>` et les `VAR=val`, exécute le reste (mock systemctl).
cat > "$BIN/sudo" <<'MOCKEOF'
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
# systemctl : enregistreur ; daemon-reload échoue si MOCK_FAIL_DAEMON_RELOAD=1.
cat > "$BIN/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${MOCK_DIR}/calls.log"
if [[ " $* " == *" daemon-reload "* && "${MOCK_FAIL_DAEMON_RELOAD:-0}" == "1" ]]; then
    echo "mock-systemctl: daemon-reload simulé en échec" >&2
    exit 1
fi
exit 0
MOCKEOF
chmod +x "$BIN/"*

export PATH="$BIN:$PATH"

# Sourcing réel du script (garde BASH_SOURCE : le dispatch principal ne tourne
# pas). Contexte non-root : le chargement déclaratif root est sauté, on pose
# donc les variables directement comme le ferait le .env parsé.
# shellcheck disable=SC1090
source "$CONF_INIT"
export PZ_USER="pzmgr" PZ_MANAGER_USER="pzmgr" PZ_GAME_USER="pzmgr"
export PZ_HOME="$S/home/pzmgr" PZ_MANAGER_DIR="$MGR/pzmanager"
FORCE_MODE=false
: > "$MOCK_DIR/calls.log"

# generate_password déterministe à compteur : prouve (non-)régénération.
generate_password() {
    local n=0
    [[ -f "$MOCK_DIR/pwcount" ]] && n="$(cat "$MOCK_DIR/pwcount")"
    n=$(( n + 1 )); printf '%s' "$n" > "$MOCK_DIR/pwcount"
    printf 'test-admin-pw-%03d-abcdefgh' "$n"
}
ok "sourcing réel de configurationInitiale.sh (dispatch non exécuté)"

PW_FILE="$MGR/pzmanager/.admin_password"

# --- (A) création : owner + mode --------------------------------------------------
echo "== (A) création =="
generate_admin_password >"$S/run1.log" 2>&1 \
    && ok "run 1 : exit 0" \
    || ko "run 1 : exit $? (attendu 0)"
[[ -s "$PW_FILE" ]] \
    && ok "run 1 : .admin_password créé non vide" \
    || ko "run 1 : .admin_password absent ou vide"
grep -qF "chown pzmgr:pzmgr $PW_FILE" "$MOCK_DIR/calls.log" \
    && ok "run 1 : chown pzmgr:pzmgr émis (compte du service)" \
    || ko "run 1 : chown vers le compte du service non émis -- $(cat "$MOCK_DIR/calls.log")"
grep -qF "chmod 600 $PW_FILE" "$MOCK_DIR/calls.log" \
    && ok "run 1 : chmod 600 émis" \
    || ko "run 1 : chmod 600 non émis"
if (( FS_MODES )); then
    [[ "$(stat -c %a "$PW_FILE")" == "600" ]] \
        && ok "run 1 : mode réel 600" \
        || ko "run 1 : mode réel $(stat -c %a "$PW_FILE") (attendu 600)"
else
    echo "[SKIP-local] chmod inopérant sur ce FS — commande prouvée via journal"
    ok "run 1 : commande chmod 600 prouvée via journal (FS sans modes)"
fi
[[ "$(cat "$MOCK_DIR/pwcount")" == "1" ]] \
    && ok "run 1 : un seul mot de passe généré" \
    || ko "run 1 : compteur inattendu ($(cat "$MOCK_DIR/pwcount" 2>/dev/null || echo ?))"
PW1="$(cat "$PW_FILE")"

# --- (B) idempotence ---------------------------------------------------------------
echo "== (B) idempotence =="
generate_admin_password >"$S/run2.log" 2>&1 \
    && ok "run 2 : exit 0 (skip, pas d'erreur)" \
    || ko "run 2 : exit $? (attendu 0)"
[[ "$(cat "$PW_FILE")" == "$PW1" ]] \
    && ok "run 2 : contenu inchangé (pas de régénération)" \
    || ko "run 2 : contenu modifié (aurait dû être conservé)"
[[ "$(cat "$MOCK_DIR/pwcount")" == "1" ]] \
    && ok "run 2 : generate_password non rappelé" \
    || ko "run 2 : régénération furtive (compteur=$(cat "$MOCK_DIR/pwcount"))"
grep -q 'déjà présent' "$S/run2.log" \
    && ok "run 2 : conservation journalisée" \
    || ko "run 2 : conservation non journalisée"
FORCE_MODE=true
generate_admin_password >"$S/run3.log" 2>&1 \
    && ok "run 3 (--force) : exit 0" \
    || ko "run 3 (--force) : exit $? (attendu 0)"
[[ "$(cat "$PW_FILE")" != "$PW1" ]] \
    && ok "run 3 (--force) : mot de passe régénéré" \
    || ko "run 3 (--force) : contenu identique (aurait dû régénérer)"
FORCE_MODE=false

# --- (C) échec daemon-reload : pas de succès partiel --------------------------------
echo "== (C) daemon-reload en échec =="
RT="$S/rt"
ensure_runtime_dir() { printf '%s' "$RT"; }
export -f ensure_runtime_dir 2>/dev/null || true

: > "$MOCK_DIR/calls.log"
set +e
( MOCK_FAIL_DAEMON_RELOAD=1 PATH="$BIN:$PATH" enable_zomboid_service >"$S/fail.log" 2>&1 )
RC=$?
set -e
[[ "$RC" != "0" ]] \
    && ok "daemon-reload en échec : exit $RC (!= 0)" \
    || ko "daemon-reload en échec : exit 0 (succès partiel annoncé à tort)"
grep -q 'ERREUR' "$S/fail.log" \
    && ok "daemon-reload en échec : ERREUR tracée" \
    || ko "daemon-reload en échec : aucune ERREUR -- $(tail -3 "$S/fail.log")"
grep -q 'daemon-reload' "$MOCK_DIR/calls.log" \
    && ok "daemon-reload bien tenté (preuve causale)" \
    || ko "daemon-reload non tenté"
grep -q 'enable zomboid.service' "$MOCK_DIR/calls.log" \
    && ko "zomboid.service tenté malgré l'échec (aurait dû mourir avant)" \
    || ok "zomboid.service jamais tenté (mort sur l'échec)"
grep -q 'enable --now' "$MOCK_DIR/calls.log" \
    && ko "timers tentés malgré l'échec (succès partiel)" \
    || ok "timers jamais tentés (aucun succès partiel)"

echo "== (C+) témoin positif =="
: > "$MOCK_DIR/calls.log"
set +e
( MOCK_FAIL_DAEMON_RELOAD=0 PATH="$BIN:$PATH" enable_zomboid_service >"$S/ok.log" 2>&1 )
RC=$?
set -e
[[ "$RC" == "0" ]] \
    && ok "témoin : exit 0 sans panne" \
    || ko "témoin : exit $RC (attendu 0) -- $(tail -3 "$S/ok.log")"
grep -q 'daemon-reload' "$MOCK_DIR/calls.log" \
    && ok "témoin : daemon-reload demandé" \
    || ko "témoin : daemon-reload absent"
grep -q 'enable zomboid.service' "$MOCK_DIR/calls.log" \
    && ok "témoin : enable zomboid.service demandé" \
    || ko "témoin : enable zomboid.service absent"
NTIMERS="$(grep -c 'enable --now' "$MOCK_DIR/calls.log" || true)"
[[ "$NTIMERS" == "6" ]] \
    && ok "témoin : 6 timers demandés" \
    || ko "témoin : $NTIMERS timers (attendu 6)"

echo "== (C2) daemon-reload en échec sous set -e (prod) =="
: > "$MOCK_DIR/calls.log"
# set -e ACTIF ici (hérité) : prouve que `|| fail_on_error` meurt avec message
# même sous errexit (un `cmd; fail_on_error $?` serait inatteignable en prod).
( MOCK_FAIL_DAEMON_RELOAD=1 PATH="$BIN:$PATH" enable_zomboid_service >"$S/fail-errexit.log" 2>&1 ) || RC=$?
[[ "$RC" != "0" ]] \
    && ok "errexit : exit $RC (!= 0)" \
    || ko "errexit : exit 0 (échec masqué sous set -e)"
grep -q 'ERREUR.*daemon-reload' "$S/fail-errexit.log" \
    && ok "errexit : ERREUR daemon-reload tracée" \
    || ko "errexit : ERREUR absente -- $(tail -3 "$S/fail-errexit.log")"
grep -q 'enable zomboid.service' "$MOCK_DIR/calls.log" \
    && ko "errexit : zomboid.service tenté malgré l'échec" \
    || ok "errexit : mort avant zomboid.service (aucun succès partiel)"

# --- bash -n -------------------------------------------------------------------------
for f in "$CONF_INIT" "$0"; do
    bash -n "$f" || { ko "bash -n : $f"; }
done
ok "bash -n : scripts OK"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C11 INSTALL: OK (${PASS} contrôles)"
else
    echo "C11 INSTALL: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
