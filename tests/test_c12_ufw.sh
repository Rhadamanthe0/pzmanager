#!/usr/bin/env bash
# test_c12_ufw.sh - Pare-feu C12 : jamais de reset, SSH réel, delta affiché.
#
# Couvre (data/scripts/install/setupSystem.sh uniquement) :
#   (0) statique : aucun `ufw --force reset`, détection port SSH, ajout des
#       seuls manquants, delta avant/après, DRY-RUN PZ_UFW_DRY_RUN.
#   (A) UFW inactif, SSH 22 : défauts + OpenSSH + 22/tcp + jeu 16261-16262/udp
#       + deny prometheus 9110/tcp, puis enable ; pas de reset.
#   (B) SSH non standard 2222 (ss + sshd_config) : 2222/tcp autorisé, accès
#       admin conservé (OpenSSH + 22) ; pas de reset.
#   (C) UFW déjà actif + règles préexistantes : conservées (dont une règle
#       custom 8080/tcp), aucun doublon (16261/udp x1), seul le manquant
#       (16262/udp) ajouté, pas de reset.
#   (D) DRY-RUN=1 : rien modifié (règles + état inchangés), commandes
#       journalisées [DRY-RUN].
#   (E) detect_ssh_port : 2222 via ss ou config (+22 garde-fou) ; défaut 22
#       sans indice.
#
# Preuves réelles : vraies fonctions sourcées (garde BASH_SOURCE du script),
# mock ufw D'ÉTAT (status/allow/deny/enable, reset piégé), ss et sshd_config
# via sandbox. Isolé : rien du pare-feu réel n'est touché.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SETUP_SYS="${ROOT}/data/scripts/install/setupSystem.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/c12-ufw-XXXXXX")"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    [[ "${C12_KEEP:-0}" == "1" ]] || rm -rf "$SANDBOX"
}
trap cleanup EXIT

[[ -f "$SETUP_SYS" ]] || { echo "[FAIL] cible introuvable : $SETUP_SYS" >&2; exit 1; }

# --- (0) statique ---------------------------------------------------------------
echo "== (0) statique =="
grep -vE '^[[:space:]]*#' "$SETUP_SYS" | grep -q 'ufw --force reset' \
    && ko "setupSystem.sh contient encore 'ufw --force reset' (hors commentaires)" \
    || ok "aucun 'ufw --force reset' dans setupSystem.sh"
grep -q '^detect_ssh_port() {' "$SETUP_SYS" \
    && ok "detect_ssh_port défini" \
    || ko "detect_ssh_port absent"
grep -q 'PZ_SSHD_CONFIG' "$SETUP_SYS" \
    && ok "sshd_config surchargeable (PZ_SSHD_CONFIG)" \
    || ko "PZ_SSHD_CONFIG absent"
grep -q 'ufw_has_rule' "$SETUP_SYS" \
    && ok "ajout conditionné aux règles manquantes (ufw_has_rule)" \
    || ko "ufw_has_rule absent"
grep -q 'PZ_UFW_DRY_RUN' "$SETUP_SYS" \
    && ok "DRY-RUN PZ_UFW_DRY_RUN supporté" \
    || ko "PZ_UFW_DRY_RUN absent"
grep -q 'UFW avant' "$SETUP_SYS" \
    && ok "delta affiché (UFW avant)" \
    || ko "delta 'UFW avant' absent"
grep -q 'UFW après' "$SETUP_SYS" \
    && ok "delta affiché (UFW après)" \
    || ko "delta 'UFW après' absent"
grep -q 'Règles ajoutées' "$SETUP_SYS" \
    && ok "règles ajoutées journalisées" \
    || ko "'Règles ajoutées' absent"
grep -q 'déjà actif' "$SETUP_SYS" \
    && ok "cas UFW-déjà-actif tracé (préservation)" \
    || ko "cas UFW-déjà-actif absent"

# --- Sandbox : mocks ufw (état) + ss (canned) ------------------------------------
echo "== sandbox =="
S="${SANDBOX}/case"
MOCK_DIR="${S}/mock"
BIN="${S}/bin"
mkdir -p "$MOCK_DIR" "$BIN"
export MOCK_DIR

# Mock ufw D'ÉTAT : $MOCK_DIR/ufw.rules (une règle/ligne), ufw.active (yes/no),
# ufw.log (toutes les invocations). `reset` est piégé : il log RESET_CALLED et
# vide les règles — le test échoue si le code l'appelle un jour.
cat > "$BIN/ufw" <<'MOCKEOF'
#!/usr/bin/env bash
RULES="${MOCK_DIR}/ufw.rules"
ACTIVE="${MOCK_DIR}/ufw.active"
[[ -f "$RULES" ]] || : > "$RULES"
[[ -f "$ACTIVE" ]] || echo "no" > "$ACTIVE"
printf 'ufw %s\n' "$*" >> "${MOCK_DIR}/ufw.log"
case "${1:-}" in
    status)
        if [[ "$(cat "$ACTIVE")" == "yes" ]]; then echo "Status: active"; else echo "Status: inactive"; fi
        [[ "${2:-}" == "verbose" ]] && exit 0
        echo ""
        echo "     To                         Action      From"
        echo "     --                         ------      ----"
        i=0
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            i=$(( i + 1 )); printf '[ %d] %s\n' "$i" "$line"
        done < "$RULES"
        exit 0
        ;;
    allow|deny)
        verb="$1"; rule="${2:-}"
        if ! grep -qF "$rule" "$RULES" 2>/dev/null; then
            if [[ "$verb" == "allow" ]]; then echo "$rule ALLOW IN Anywhere" >> "$RULES"
            else echo "$rule DENY IN Anywhere" >> "$RULES"; fi
        fi
        echo "Rule added"
        exit 0
        ;;
    default|--force)
        if [[ "$1" == "--force" && "${2:-}" == "reset" ]]; then
            echo "RESET_CALLED" >> "${MOCK_DIR}/ufw.log"
            : > "$RULES"
            echo "Reset done"
            exit 0
        fi
        if [[ "$1" == "--force" && "${2:-}" == "enable" ]]; then
            echo "yes" > "$ACTIVE"
        fi
        echo "OK ($*)"
        exit 0
        ;;
    *)
        echo "mock-ufw: args inattendus: $*" >&2
        exit 99
        ;;
esac
MOCKEOF
# Mock ss : rejoue le contenu canned de $MOCK_DIR/ss_output (ignore les args).
cat > "$BIN/ss" <<'MOCKEOF'
#!/usr/bin/env bash
cat "${MOCK_DIR}/ss_output" 2>/dev/null || true
MOCKEOF
chmod +x "$BIN/"*
export PATH="$BIN:$PATH"

# Sourcing réel (garde BASH_SOURCE : main ne tourne pas). Le `trap ERR`
# posé par le script est retiré aussitôt (il appartient au run root, pas au test).
# shellcheck disable=SC1090
source "$SETUP_SYS"
trap - ERR
ok "sourcing réel de setupSystem.sh (main non exécuté)"

unset PZ_PORT_GAME PZ_PORT_GAME2 PZ_PROMETHEUS_PORT 2>/dev/null || true
export PZ_UFW_DRY_RUN=0

reset_case() {
    : > "$MOCK_DIR/ufw.rules"
    echo "no" > "$MOCK_DIR/ufw.active"
    : > "$MOCK_DIR/ufw.log"
    : > "$MOCK_DIR/ss_output"
    unset PZ_SSHD_CONFIG 2>/dev/null || true
}
rules_count() { grep -cF "$1" "$MOCK_DIR/ufw.rules" || true; }

# --- (A) inactif, SSH 22 ------------------------------------------------------------
echo "== (A) inactif, SSH 22 =="
reset_case
cat > "$MOCK_DIR/ss_output" <<'SSHEOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128    0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=111,fd=3))
SSHEOF
printf 'Port 22\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
configure_firewall >"$S/a.log" 2>&1 \
    && ok "A : exit 0" \
    || ko "A : exit $? (attendu 0)"
grep -q 'RESET_CALLED\|--force reset' "$MOCK_DIR/ufw.log" \
    && ko "A : reset exécuté (interdit)" \
    || ok "A : aucun reset exécuté"
[[ "$(cat "$MOCK_DIR/ufw.active")" == "yes" ]] \
    && ok "A : UFW activé (enable sans reset)" \
    || ko "A : UFW non activé"
for r in "OpenSSH" "22/tcp" "16261/udp" "16262/udp"; do
    grep -qF "$r" "$MOCK_DIR/ufw.rules" \
        && ok "A : règle $r présente" \
        || ko "A : règle $r absente -- $(cat "$MOCK_DIR/ufw.rules")"
done
grep -qF "9110/tcp DENY" "$MOCK_DIR/ufw.rules" \
    && ok "A : prometheus 9110/tcp refusé" \
    || ko "A : deny prometheus absent"
grep -q 'UFW avant' "$S/a.log" \
    && ok "A : delta avant affiché" \
    || ko "A : delta avant absent"
grep -q 'UFW après' "$S/a.log" \
    && ok "A : delta après affiché" \
    || ko "A : delta après absent"
grep -q 'Règles ajoutées' "$S/a.log" \
    && ok "A : règles ajoutées journalisées" \
    || ko "A : journal des ajouts absent"

# --- (B) SSH non standard 2222 ---------------------------------------------------------
echo "== (B) SSH 2222 =="
reset_case
cat > "$MOCK_DIR/ss_output" <<'SSHEOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128    0.0.0.0:2222       0.0.0.0:*          users:(("sshd",pid=222,fd=3))
SSHEOF
printf 'Port 2222\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
configure_firewall >"$S/b.log" 2>&1 \
    && ok "B : exit 0" \
    || ko "B : exit $? (attendu 0)"
grep -q 'RESET_CALLED' "$MOCK_DIR/ufw.log" \
    && ko "B : reset exécuté (interdit)" \
    || ok "B : aucun reset exécuté"
grep -qF "2222/tcp" "$MOCK_DIR/ufw.rules" \
    && ok "B : port SSH détecté 2222/tcp autorisé" \
    || ko "B : 2222/tcp absent (lock-out admin !)"
grep -qF "OpenSSH" "$MOCK_DIR/ufw.rules" \
    && ok "B : OpenSSH conservé (accès admin)" \
    || ko "B : OpenSSH absent"
for r in "16261/udp" "16262/udp"; do
    grep -qF "$r" "$MOCK_DIR/ufw.rules" \
        && ok "B : règle jeu $r présente" \
        || ko "B : règle jeu $r absente"
done

# --- (C) déjà actif + préexistantes ------------------------------------------------------
echo "== (C) déjà actif, préexistantes =="
reset_case
cat > "$MOCK_DIR/ufw.rules" <<'RULESEOF'
OpenSSH ALLOW IN Anywhere
22/tcp ALLOW IN Anywhere
16261/udp ALLOW IN Anywhere
8080/tcp ALLOW IN Anywhere
9110/tcp DENY IN Anywhere
RULESEOF
echo "yes" > "$MOCK_DIR/ufw.active"
cat > "$MOCK_DIR/ss_output" <<'SSHEOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128    0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=111,fd=3))
SSHEOF
printf 'Port 22\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
configure_firewall >"$S/c.log" 2>&1 \
    && ok "C : exit 0" \
    || ko "C : exit $? (attendu 0)"
grep -q 'RESET_CALLED' "$MOCK_DIR/ufw.log" \
    && ko "C : reset exécuté (interdit, règles détruites)" \
    || ok "C : aucun reset (règles préservées)"
grep -qF "8080/tcp" "$MOCK_DIR/ufw.rules" \
    && ok "C : règle custom 8080/tcp conservée" \
    || ko "C : règle custom 8080/tcp perdue"
[[ "$(rules_count '16261/udp')" == "1" ]] \
    && ok "C : 16261/udp sans doublon (x1)" \
    || ko "C : 16261/udp dupliqué (x$(rules_count '16261/udp'))"
grep -qF "16262/udp" "$MOCK_DIR/ufw.rules" \
    && ok "C : seul le manquant 16262/udp ajouté" \
    || ko "C : 16262/udp non ajouté"
grep -q 'déjà actif' "$S/c.log" \
    && ok "C : préservation tracée (déjà actif)" \
    || ko "C : préservation non tracée"
grep -q '16262/udp' "$S/c.log" \
    && ok "C : delta mentionne 16262/udp" \
    || ko "C : delta muet sur l'ajout"

# --- (D) DRY-RUN ----------------------------------------------------------------------------
echo "== (D) dry-run =="
reset_case
export PZ_UFW_DRY_RUN=1
cat > "$MOCK_DIR/ss_output" <<'SSHEOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128    0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=111,fd=3))
SSHEOF
printf 'Port 22\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
configure_firewall >"$S/d.log" 2>&1 \
    && ok "D : exit 0" \
    || ko "D : exit $? (attendu 0)"
[[ ! -s "$MOCK_DIR/ufw.rules" ]] \
    && ok "D : aucune règle écrite" \
    || ko "D : règles écrites malgré DRY-RUN"
[[ "$(cat "$MOCK_DIR/ufw.active")" == "no" ]] \
    && ok "D : UFW non activé (simulé)" \
    || ko "D : UFW activé malgré DRY-RUN"
grep -q 'DRY-RUN' "$S/d.log" \
    && ok "D : commandes journalisées [DRY-RUN]" \
    || ko "D : aucune trace DRY-RUN"
export PZ_UFW_DRY_RUN=0

# --- (E) detect_ssh_port ----------------------------------------------------------------------
echo "== (E) detect_ssh_port =="
cat > "$MOCK_DIR/ss_output" <<'SSHEOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128    0.0.0.0:2222       0.0.0.0:*          users:(("sshd",pid=222,fd=3))
SSHEOF
printf '# commentaire\nPort 2222\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
E1="$(detect_ssh_port)"
grep -qx '2222' <<< "$E1" \
    && ok "E1 : 2222 détecté (ss/config)" \
    || ko "E1 : 2222 non détecté (got: $E1)"
grep -qx '22' <<< "$E1" \
    && ok "E1 : 22 garde-fou inclus" \
    || ko "E1 : 22 absent (got: $E1)"
: > "$MOCK_DIR/ss_output"
export PZ_SSHD_CONFIG="$S/sshd_config_absent"
E2="$(detect_ssh_port)"
[[ "$E2" == "22" ]] \
    && ok "E2 : défaut 22 sans indice" \
    || ko "E2 : inattendu (got: $E2)"

# --- bash -n -------------------------------------------------------------------------
for f in "$SETUP_SYS" "$0"; do
    bash -n "$f" || { ko "bash -n : $f"; }
done
ok "bash -n : scripts OK"

# --- Bilan -------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C12 UFW: OK (${PASS} contrôles)"
else
    echo "C12 UFW: ÉCHEC (${FAIL} échec(s), ${PASS} OK)" >&2
    exit 1
fi
