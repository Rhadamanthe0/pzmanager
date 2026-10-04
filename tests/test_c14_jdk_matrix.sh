#!/usr/bin/env bash
# test_c14_jdk_matrix.sh - Matrice OS/JDK coherente (C14).
#
# Couvre (data/scripts/lib/jdk_matrix.sh, vrai code source) :
#   (1) Debian 12 sans 25 -> repli loggue vers 21 (puis 17 si 21 absent) + install OK
#   (2) Ubuntu 24.04 avec 25 -> 25 conserve (pas de repli speculatif)
#   (3) `java -version` incoherent -> die (exit != 0, message explicite)
#   (4) binaire EFFECTIF du service : JAVA_PATH/bin/java prime sur `java` du PATH
#   (5) PZ_JDK_SOURCE=temurin -> nommage temurin ; whitelist C15 etendue
#   (0) statique : cablage install (resolve avant apt, verify apres),
#       defauts PZ_JDK_SOURCE, section doc.
#
# Preuves reelles : vraies fonctions sourcees ; mocks seulement aux frontieres
# inaccessibles (os-release via PZ_OS_RELEASE, apt-cache + java via PATH/sandbox).
# Isolé : sandbox sous TMPDIR, aucun impact prod.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
JDK_LIB="${ROOT}/data/scripts/lib/jdk_matrix.sh"
ENV_PARSE="${ROOT}/data/scripts/lib/env_parse.sh"
CONF_INIT="${ROOT}/data/scripts/install/configurationInitiale.sh"
COMMON="${ROOT}/data/scripts/lib/common.sh"
ENV_EXAMPLE="${ROOT}/data/setupTemplates/.env.example"
DOC="${ROOT}/docs/WHAT_IS_INSTALLED.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/c14-jdk-XXXXXX")"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() {
    [[ "${C14_KEEP:-0}" == "1" ]] || rm -rf "$SANDBOX"
}
trap cleanup EXIT

[[ -f "$JDK_LIB" ]] || { echo "[FAIL] cible introuvable : $JDK_LIB" >&2; exit 1; }
# shellcheck disable=SC1090
source "$JDK_LIB"
declare -F resolve_java_package >/dev/null || { ko "resolve_java_package absente"; exit 1; }
declare -F verify_java_version >/dev/null || { ko "verify_java_version absente"; exit 1; }
ok "sourcing reel de jdk_matrix.sh (aucun effet de bord)"

# --- Sandbox : mocks apt-cache + java ------------------------------------------
S="${SANDBOX}/case"
BIN="${S}/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# APT_CACHE_AVAILABLE="pkg1 pkg2" : paquets pour lesquels apt-cache annonce un candidat.
cat > "$BIN/apt-cache" <<'MOCKEOF'
#!/usr/bin/env bash
pkg="${2:-}"
if [[ " ${APT_CACHE_AVAILABLE:-} " == *" ${pkg} "* ]]; then
    printf '%s:\n  Installed: (none)\n  Candidate: 9.9.9-1\n' "$pkg"
else
    printf '%s:\n  Installed: (none)\n  Candidate: (none)\n' "$pkg"
fi
MOCKEOF
chmod +x "$BIN/apt-cache"

# make_java <chemin> <version-affichee> : faux binaire `java -version` sur stderr.
make_java() {
    mkdir -p "$(dirname "$1")"
    printf '#!/usr/bin/env bash\necho \x27openjdk version "%s"\x27 1>&2\n' "$2" > "$1"
    chmod +x "$1"
}

# Faux os-release.
cat > "$S/os-debian12" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
cat > "$S/os-ubuntu2404" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF

# --- (0) statique : cablage -----------------------------------------------------
echo "== (0) statique =="
grep -q 'resolve_java_package' "$CONF_INIT" \
    && ok "configurationInitiale.sh appelle resolve_java_package" \
    || ko "resolve_java_package non cable dans configurationInitiale.sh"
grep -q 'verify_java_version "${JAVA_VERSION}"' "$CONF_INIT" \
    && ok "configurationInitiale.sh verifie le binaire apres install" \
    || ko "verify_java_version non cable dans configurationInitiale.sh"
grep -q 'PZ_JDK_SOURCE' "$ENV_PARSE" \
    && ok "env_parse.sh whiteliste PZ_JDK_SOURCE" \
    || ko "PZ_JDK_SOURCE absent de env_parse.sh"
grep -q 'PZ_JDK_SOURCE' "$COMMON" \
    && ok "common.sh porte le defaut PZ_JDK_SOURCE" \
    || ko "PZ_JDK_SOURCE absent de common.sh"
grep -q 'PZ_JDK_SOURCE' "$ENV_EXAMPLE" \
    && ok ".env.example documente PZ_JDK_SOURCE" \
    || ko "PZ_JDK_SOURCE absent de .env.example"
grep -q 'OS / JDK support matrix' "$DOC" \
    && ok "matrice OS/JDK documentee dans WHAT_IS_INSTALLED.md" \
    || ko "matrice absente de WHAT_IS_INSTALLED.md"
grep -q 'apt-cache policy' "$JDK_LIB" \
    && ok "disponibilite verifiee via apt-cache (pas d'hypothese en dur)" \
    || ko "apt-cache policy absent de jdk_matrix.sh"

# --- (1) Debian 12 sans 25 -> repli 21 ------------------------------------------
echo "== (1) Debian 12 sans 25 =="
export PZ_OS_RELEASE="$S/os-debian12" PZ_JDK_SOURCE="debian"
export APT_CACHE_AVAILABLE="openjdk-21-jre-headless openjdk-17-jre-headless"
export JAVA_VERSION="25" JAVA_PACKAGE="" JAVA_PATH=""
resolve_java_package >"$S/resolve1.log" 2>&1 || { ko "resolve a echoue alors que 21/17 dispo"; }
LOG1="$(cat "$S/resolve1.log")"
[[ "${JAVA_VERSION:-}" == "21" ]] \
    && ok "Debian 12 sans 25 : repli vers 21 (JAVA_VERSION=${JAVA_VERSION})" \
    || ko "Debian 12 sans 25 : JAVA_VERSION=${JAVA_VERSION:-?} (attendu 21)"
[[ "${JAVA_PACKAGE:-}" == "openjdk-21-jre-headless" ]] \
    && ok "paquet effectif openjdk-21-jre-headless" \
    || ko "JAVA_PACKAGE=${JAVA_PACKAGE:-?} (attendu openjdk-21-jre-headless)"
[[ "${JAVA_PATH:-}" == "/usr/lib/jvm/java-21-openjdk-amd64" ]] \
    && ok "chemin effectif java-21-openjdk-amd64" \
    || ko "JAVA_PATH=${JAVA_PATH:-?} (attendu java-21-openjdk-amd64)"
grep -q 'repli' <<<"$LOG1" \
    && ok "repli journalise (pas de downgrade silencieux)" \
    || ko "repli non journalise -- $LOG1"

# (1b) Debian 12 avec 21 absent aussi -> 17.
export APT_CACHE_AVAILABLE="openjdk-17-jre-headless"
export JAVA_VERSION="25" JAVA_PACKAGE="" JAVA_PATH=""
resolve_java_package >/dev/null 2>&1 \
    && ok "repli 17 : install OK (exit 0)" \
    || ko "repli 17 : resolve en echec"
[[ "${JAVA_VERSION:-}" == "17" ]] \
    && ok "Debian 12 sans 25/21 : repli vers 17" \
    || ko "JAVA_VERSION=${JAVA_VERSION:-?} (attendu 17)"

# (1c) rien de dispo -> die explicite.
export APT_CACHE_AVAILABLE=""
export JAVA_VERSION="25" JAVA_PACKAGE="" JAVA_PATH=""
set +e
( resolve_java_package >"$S/die-none.log" 2>&1 )
RC=$?
set -e
[[ "$RC" != "0" ]] \
    && ok "aucun candidat : die (exit $RC)" \
    || ko "aucun candidat : exit 0 (aurait du mourir)"
grep -qi 'aucun jre compatible' "$S/die-none.log" \
    && ok "aucun candidat : message explicite" \
    || ko "aucun candidat : message absent -- $(tail -1 "$S/die-none.log")"

# --- (2) Ubuntu 24.04 avec 25 -> 25 ---------------------------------------------
echo "== (2) Ubuntu 24.04 avec 25 =="
export PZ_OS_RELEASE="$S/os-ubuntu2404"
export APT_CACHE_AVAILABLE="openjdk-25-jre-headless openjdk-21-jre-headless openjdk-17-jre-headless"
export JAVA_VERSION="25" JAVA_PACKAGE="" JAVA_PATH=""
resolve_java_package >"$S/resolve2.log" 2>&1 || { ko "resolve Ubuntu en echec"; }
LOG2="$(cat "$S/resolve2.log")"
[[ "${JAVA_VERSION:-}" == "25" && "${JAVA_PACKAGE:-}" == "openjdk-25-jre-headless" ]] \
    && ok "Ubuntu 24.04 avec 25 : 25 conserve (${JAVA_PACKAGE})" \
    || ko "Ubuntu : ${JAVA_VERSION:-?}/${JAVA_PACKAGE:-?} (attendu 25/openjdk-25)"
grep -q 'repli' <<<"$LOG2" \
    && ko "repli annonce a tort alors que 25 dispo" \
    || ok "aucun repli annonce (25 vraiment dispo)"

# --- (3) mismatch java -version -> die ------------------------------------------
echo "== (3) mismatch =="
make_java "$S/jvm17/bin/java" "17.0.13"
export JAVA_PATH="$S/jvm17"
set +e
( verify_java_version "25" >"$S/mismatch.log" 2>&1 )
RC=$?
set -e
[[ "$RC" != "0" ]] \
    && ok "mismatch 17 vs 25 : die (exit $RC)" \
    || ko "mismatch : exit 0 (aurait du mourir)"
grep -q 'annonce 17' "$S/mismatch.log" \
    && ok "mismatch : binaire et versions cites ($(tail -1 "$S/mismatch.log"))" \
    || ko "mismatch : message inexploitable -- $(tail -1 "$S/mismatch.log")"

# Témoin positif : version coherente -> exit 0.
make_java "$S/jvm25/bin/java" "25.0.1"
export JAVA_PATH="$S/jvm25"
verify_java_version "25" >/dev/null 2>&1 \
    && ok "temoin : 25 vs 25 -> exit 0" \
    || ko "temoin : 25 vs 25 en echec"

# --- (4) binaire effectif : JAVA_PATH prime sur PATH -----------------------------
echo "== (4) binaire effectif =="
make_java "$S/svc/bin/java" "21.0.5"
make_java "$BIN/java" "25.0.1"   # `java` du PATH, volontairement divergent
export JAVA_PATH="$S/svc"
verify_java_version "21" >/dev/null 2>&1 \
    && ok "JAVA_PATH/bin/java (21) utilise, pas le java du PATH (25)" \
    || ko "le binaire du PATH a pris le pas sur JAVA_PATH"
set +e
( verify_java_version "25" >/dev/null 2>&1 )
RC=$?
set -e
[[ "$RC" != "0" ]] \
    && ok "preuve inverse : attendu 25 mais service en 21 -> die" \
    || ko "preuve inverse : exit 0 (le java 25 du PATH a masque le service)"
rm -f "$BIN/java"

# --- (5) temurin + whitelist C15 --------------------------------------------------
echo "== (5) temurin / whitelist =="
export PZ_OS_RELEASE="$S/os-debian12" PZ_JDK_SOURCE="temurin"
export APT_CACHE_AVAILABLE="openjdk-17-jre-headless"
export JAVA_VERSION="25" JAVA_PACKAGE="" JAVA_PATH=""
resolve_java_package >/dev/null 2>&1 \
    && ok "temurin : resolve OK sans candidat debian" \
    || ko "temurin : resolve en echec"
[[ "${JAVA_PACKAGE:-}" == "temurin-25-jre" ]] \
    && ok "temurin : paquet temurin-25-jre" \
    || ko "temurin : JAVA_PACKAGE=${JAVA_PACKAGE:-?}"
# shellcheck disable=SC1090
source "$ENV_PARSE"
TMP_ENV="$(mktemp)"
printf 'PZ_JDK_SOURCE=temurin\n' > "$TMP_ENV"
unset PZ_JDK_SOURCE || true
parse_env_declarative "$TMP_ENV" \
    && [[ "${PZ_JDK_SOURCE:-}" == "temurin" ]] \
    && ok "whitelist C15 : PZ_JDK_SOURCE=temurin importe" \
    || ko "whitelist C15 : PZ_JDK_SOURCE=temurin non importe"
printf 'PZ_JDK_SOURCE=evil;touch\n' > "$TMP_ENV"
unset PZ_JDK_SOURCE || true
parse_env_declarative "$TMP_ENV" \
    && [[ -z "${PZ_JDK_SOURCE:-}" ]] \
    && ok "whitelist C15 : valeur hostile ignoree" \
    || ko "whitelist C15 : valeur hostile acceptee (${PZ_JDK_SOURCE:-?})"
rm -f "$TMP_ENV"
export PZ_JDK_SOURCE="debian"

# --- bash -n ----------------------------------------------------------------------
for f in "$JDK_LIB" "$CONF_INIT" "$COMMON" "$ENV_PARSE" "$0"; do
    bash -n "$f" || { ko "bash -n : $f"; }
done
ok "bash -n : scripts OK"

# --- Bilan ------------------------------------------------------------------------
echo ""
if (( FAIL == 0 )); then
    echo "C14 JDK MATRIX: OK (${PASS} controles)"
else
    echo "C14 JDK MATRIX: ECHEC (${FAIL} echec(s), ${PASS} OK)" >&2
    exit 1
fi
