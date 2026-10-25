#!/usr/bin/env bash
# test_c12_ufw.sh - Pare-feu C12 : jamais de reset, SSH réel, delta affiché.
#
# Couvre (data/scripts/install/setupSystem.sh uniquement) :
#   (0) statique : aucun `ufw --force reset`, détection port SSH, ajout des
#       seuls manquants, delta avant/après, DRY-RUN PZ_UFW_DRY_RUN.
#   (A) UFW inactif, SSH 22 : défauts + 22/tcp + jeu 16261-16262/udp
#       + deny prometheus 9110/tcp, puis enable ; pas de reset.
#   (B) SSH non standard 2222 (ss + sshd_config) : 2222/tcp autorisé, accès
#       admin conservé (+22) ; pas de reset.
#   (C) UFW déjà actif + règles préexistantes : conservées (dont une règle
#       custom 8080/tcp), aucun doublon (16261/udp x1), seul le manquant
#       (16262/udp) ajouté, pas de reset.
#   (D) DRY-RUN=1 : rien modifié (règles + état inchangés), commandes
#       journalisées [DRY-RUN].
#   (E) SSH : ss prioritaire, sinon sshd -T (Include), erreurs bloquantes ;
#       accès local admis seulement sans binaire ni configuration SSH.
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
#!/usr/bin/python3
import os,re,sys
from pathlib import Path
root=Path(os.environ['MOCK_DIR']); args=sys.argv[1:]
rulesfile=root/'ufw.rules'; activefile=root/'ufw.active'
if not rulesfile.exists(): rulesfile.write_text('')
if not activefile.exists(): activefile.write_text('no')
with (root/'ufw.log').open('a') as log: log.write('ufw '+' '.join(args)+'\n')
rules=rulesfile.read_text().splitlines(); active=activefile.read_text().strip()=='yes'
# Le profil n'est pas livré par UFW : représenter une installation sans OpenSSH.
if args==['allow','OpenSSH']: sys.exit(23)
if os.environ.get('MOCK_UFW_FAIL')==(args[1] if args[0]=='--force' else args[0]): sys.exit(23)
family=lambda row: 6 if '(v6)' in row or '2001:' in row else 4
rules.sort(key=family)
def save(): rulesfile.write_text(''.join(row+'\n' for row in rules))
def key(row):
    row=row.split('#',1)[0].strip()
    row=re.sub(r' \(log(?:-all)?\)$','',row)
    return re.sub(r' (ALLOW|DENY|REJECT|LIMIT) (IN|OUT|FWD) ',r' \2 ',row)
if args[0]=='status':
    french=os.environ.get('MOCK_UFW_FRENCH')=='1' and (os.environ.get('LC_ALL')!='C' or os.environ.get('LANGUAGE')!='C')
    print(('État : actif' if french else 'Status: active') if active else ('État : inactif' if french else 'Status: inactive'))
    if active:
        for index,row in enumerate(rules,1): print('[ %d] %s' % (index,row))
elif args[:2]==['--force','delete']:
    del rules[int(args[2])-1]; save()
elif args[:2]==['--force','enable']:
    activefile.write_text('yes')
elif args[:2]==['--force','reset']:
    raise RuntimeError('RESET_CALLED')
elif args[0]=='default': pass
elif args[0] in ('allow','deny','prepend'):
    prepend=args[0]=='prepend'
    action='DENY' if prepend else args[0].upper()
    target=args[-1]+'/tcp' if prepend else args[1]
    ipv6=(root/'ufw.ipv6').exists()
    for version in ([4,6] if ipv6 else [4]):
        row=target+(' (v6)' if version==6 else '')+' '+action+' IN Anywhere'+(' (v6)' if version==6 else '')
        # Le vrai backend UFW ignore action/log/comment dans les doublons
        # d'une insertion, donc prepend ne déplace pas une key existante.
        matches=[i for i,old in enumerate(rules) if key(old)==key(row)]
        if prepend and matches: continue
        if matches:
            rules[matches[0]]=row
        elif prepend:
            index=next((i for i,old in enumerate(rules) if family(old)==version),len(rules))
            rules.insert(index,row)
        else: rules.append(row)
    rules.sort(key=family); save()
else: raise RuntimeError('unexpected ufw '+repr(args))
MOCKEOF
# Mock ss : rejoue le contenu canned de $MOCK_DIR/ss_output (ignore les args).
cat > "$BIN/ss" <<'MOCKEOF'
#!/usr/bin/env bash
cat "${MOCK_DIR}/ss_output" 2>/dev/null || true
MOCKEOF
# sshd boundary for ordinary cases; native Include case below bypasses it.
cat > "$BIN/sshd" <<'MOCKEOF'
#!/usr/bin/env bash
[[ "${MOCK_SSHD_FAIL:-0}" == 0 ]] || exit 23
[[ "$1" == -T && "$2" == -f ]] || exit 24
awk 'tolower($1)=="port" { print "port",$2; found=1 } END { if (!found) print "port 22" }' "$3"
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
    unset PZ_SSHD_CONFIG MOCK_SSHD_FAIL MOCK_UFW_FAIL MOCK_UFW_FRENCH PZ_PROMETHEUS_PORT 2>/dev/null || true
    rm -f "$MOCK_DIR/ufw.ipv6"
    printf 'Port 22\n' > "$S/sshd_config"
    export PZ_SSHD_CONFIG="$S/sshd_config"
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
for r in "22/tcp" "16261/udp" "16262/udp"; do
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
grep -qF "22/tcp" "$MOCK_DIR/ufw.rules" \
    && ok "B : garde-fou22 conservé sans profil OpenSSH" \
    || ko "B : garde-fou22 absent"
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
reset_case
export PZ_SSHD_CONFIG="$S/sshd_config_absent"
if (configure_firewall) > "$S/missing-config.log" 2>&1; then ko 'config SSH absente acceptée avec sshd installé'; else ok 'config SSH absente : refus explicite'; fi
[[ ! -s "$MOCK_DIR/ufw.log" ]] && ok 'config SSH absente : aucune commande UFW' || ko 'UFW invoqué malgré config absente'
reset_case
export MOCK_SSHD_FAIL=1
if (configure_firewall) > "$S/failed-config.log" 2>&1; then ko 'échec sshd accepté'; else ok 'échec sshd : refus explicite'; fi
[[ ! -s "$MOCK_DIR/ufw.log" ]] && ok 'échec sshd : aucune commande UFW' || ko 'UFW invoqué malgré échec sshd'
unset MOCK_SSHD_FAIL

# Absence prouvée de sshd (résolution seule doublée), installation locale.
reset_case
export PZ_SSHD_CONFIG="$S/sshd_config_absent"
(
    command() {
        if [[ "$*" == '-v sshd' || "$*" == '-v /usr/sbin/sshd' ]]; then return 1; fi
        builtin command "$@"
    }
    configure_firewall > "$S/local.log" 2>&1
) && ok 'sans binaire ni config SSH : installation locale admise' || ko 'installation locale sans SSH refusée'
grep -q '^ufw allow 22/tcp$' "$MOCK_DIR/ufw.log" && ok 'installation locale : garde-fou22 conservé' || ko 'garde-fou22 perdu'
reset_case
(
    command() {
        if [[ "$*" == '-v sshd' || "$*" == '-v /usr/sbin/sshd' ]]; then return 1; fi
        builtin command "$@"
    }
    configure_firewall > "$S/missing-binary.log" 2>&1
) && ko 'config présente sans binaire SSH acceptée' || ok 'config présente sans binaire SSH refusée'
[[ ! -s "$MOCK_DIR/ufw.log" ]] && ok 'binaire absent avec config : aucune commande UFW' || ko 'UFW invoqué malgré binaire absent'
reset_case
export MOCK_SSHD_FAIL=1
printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=222,fd=3))\n' > "$MOCK_DIR/ss_output"
[[ "$(detect_ssh_port)" == $'22\n2222' ]] && ok 'ss observé prioritaire même si configuration invalide' || ko 'configuration invalide écrase ss'
unset MOCK_SSHD_FAIL

# Vraie configuration effective OpenSSH : Include, plusieurs ports et décimal.
reset_case
if [[ -x /usr/sbin/sshd ]] && command -v ssh-keygen >/dev/null; then
    ssh-keygen -q -t ed25519 -N '' -f "$S/hostkey"
    printf 'Port 02222\nPort 2223\n' > "$S/sshd-included.conf"
    printf 'HostKey %s\nInclude %s\n' "$S/hostkey" "$S/sshd-included.conf" > "$S/sshd_config"
    # Le binaire de production est retrouvé par PATH, sans changer son interface.
    mv "$BIN/sshd" "$BIN/sshd.mock"
    ln -s /usr/sbin/sshd "$BIN/sshd"
    if /usr/sbin/sshd -T -f "$S/sshd_config" > "$S/effective.log" 2> "$S/effective.err"; then
        (
            command() { [[ "$*" != '-v ss' ]] && builtin command "$@"; }
            configure_firewall
        ) > "$S/include.log" 2>&1 || ko 'Include natif : refus inattendu'
        grep -qx 'ufw allow 2222/tcp' "$MOCK_DIR/ufw.log" && grep -qx 'ufw allow 2223/tcp' "$MOCK_DIR/ufw.log" \
            && ok 'Include natif : tous ports effectifs autorisés avant enable' || ko 'Include natif : port perdu'
        if python3 - "$MOCK_DIR/ufw.log" <<'ORDER'
import sys
rows=open(sys.argv[1]).read().splitlines()
assert rows.index('ufw allow 2222/tcp') < rows.index('ufw --force enable')
assert rows.index('ufw allow 2223/tcp') < rows.index('ufw --force enable')
ORDER
        then ok 'Include natif : ordre autorisations avant activation'; else ko 'Include natif : activation prématurée'; fi
        : > "$MOCK_DIR/ufw.log"
        export PZ_PROMETHEUS_PORT=2222
        if (configure_firewall) > "$S/include-collision.log" 2>&1; then ko 'Include natif : collision acceptée'; fi
        [[ ! -s "$MOCK_DIR/ufw.log" ]] && ok 'Include natif : collision refusée avant UFW' || ko 'Include natif : mutation malgré collision'
    else
        echo "[SKIP] sshd -T natif indisponible dans ce banc : $(cat "$S/effective.err")"
    fi
    rm "$BIN/sshd"
    mv "$BIN/sshd.mock" "$BIN/sshd"
else
    echo "[SKIP] Include natif : sshd ou ssh-keygen absent du banc."
fi

# Priorité vraie avec règles persistées masquées quand UFW est inactif.
for initial in yes no; do
    reset_case
    echo "$initial" > "$MOCK_DIR/ufw.active"
    touch "$MOCK_DIR/ufw.ipv6"
    export MOCK_UFW_FRENCH=1 LANGUAGE=fr
    cat > "$MOCK_DIR/ufw.rules" <<'RULES'
9000:9200/tcp ALLOW IN Anywhere
9110/tcp ALLOW IN Anywhere # old global allow
9110/tcp DENY IN 10.0.0.0/8
9110/tcp on eth1 DENY IN Anywhere
9110/udp ALLOW IN Anywhere
9110/tcp ALLOW OUT Anywhere
9110/tcp DENY IN Anywhere (log-all) # duplicate global
9000:9200/tcp (v6) ALLOW IN Anywhere (v6)
9110/tcp (v6) REJECT IN Anywhere (v6) (log) # old exact
9110/tcp (v6) DENY IN 2001:db8::/32
RULES
    configure_firewall > "$S/priority.log" 2>&1 || { ko "priority $initial : refus"; cat "$S/priority.log"; continue; }
    python3 - "$MOCK_DIR/ufw.rules" <<'PRIORITY'
from pathlib import Path
import sys
rows=Path(sys.argv[1]).read_text().splitlines()
assert next(r for r in rows if '(v6)' not in r)=='9110/tcp DENY IN Anywhere', 'Refus Prometheus absent en première position IPv4'
assert next(r for r in rows if '(v6)' in r)=='9110/tcp (v6) DENY IN Anywhere (v6)', 'Refus Prometheus absent en première position IPv6'
for keep in ['9000:9200/tcp ALLOW IN Anywhere','9110/tcp DENY IN 10.0.0.0/8','9110/tcp on eth1 DENY IN Anywhere','9110/udp ALLOW IN Anywhere','9110/tcp ALLOW OUT Anywhere','9110/tcp (v6) DENY IN 2001:db8::/32']:
    assert keep in rows,keep
PRIORITY
    before="$(cat "$MOCK_DIR/ufw.rules")"
    configure_firewall > "$S/idempotent.log" 2>&1 || ko "priority $initial : second run refusé"
    [[ "$(cat "$MOCK_DIR/ufw.rules")" == "$before" ]] \
        && ok "priority $initial : IPv4/IPv6, règles partielles/ranges/iface/UDP conservées et idempotence" || ko 'idempotence perdue'
done
for ssh in 22 2222 02222 00002222; do
    reset_case
    export PZ_PROMETHEUS_PORT="$((10#$ssh))"
    printf 'Port %s\n' "$ssh" > "$S/sshd_config"
    export PZ_SSHD_CONFIG="$S/sshd_config"
    if (configure_firewall) > "$S/collision.log" 2>&1; then ko 'collision SSH acceptée'; fi
    ! grep -qE '^ufw (allow|default|prepend|--force)' "$MOCK_DIR/ufw.log" \
        && ok "collision SSH $ssh : refus avant mutation" || ko 'mutation malgré collision SSH'
done
reset_case
printf 'Port 00002222\n' > "$S/sshd_config"
export PZ_SSHD_CONFIG="$S/sshd_config"
configure_firewall > "$S/canonical-ssh.log" 2>&1 || ko 'SSH décimal canonique refusé'
grep -q '^ufw allow 2222/tcp$' "$MOCK_DIR/ufw.log" \
    && ! grep -q '^ufw allow 0' "$MOCK_DIR/ufw.log" \
    && ok 'SSH zéros initiaux non conflictuel : ALLOW2222 canonique' || ko 'ALLOW SSH non canonique'
for port in 0 65536; do
    reset_case
    printf 'Port %s\n' "$port" > "$S/sshd_config"
    export PZ_SSHD_CONFIG="$S/sshd_config"
    if (configure_firewall) > "$S/invalid-ssh.log" 2>&1; then ko "SSH invalide $port accepté"; fi
    ! grep -qE '^ufw (allow|default|prepend|--force)' "$MOCK_DIR/ufw.log" \
        && ok "SSH hors plage $port refusé avant mutation" || ko 'mutation malgré SSH invalide'
done
for failure in status prepend delete enable; do
    reset_case
    echo yes > "$MOCK_DIR/ufw.active"
    echo '9110/tcp ALLOW IN Anywhere' > "$MOCK_DIR/ufw.rules"
    [[ "$failure" != enable ]] || echo no > "$MOCK_DIR/ufw.active"
    export MOCK_UFW_FAIL="$failure"
    if (configure_firewall) > "$S/command-failure.log" 2>&1; then ko "erreur $failure ignorée"; else ok "erreur $failure bloquante"; fi
    ! grep -q 'restreint à localhost' "$S/command-failure.log" || ko "faux succès après $failure"
done
unset MOCK_UFW_FAIL MOCK_UFW_FRENCH PZ_PROMETHEUS_PORT

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
