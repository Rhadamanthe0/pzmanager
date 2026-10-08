#!/usr/bin/env bash
# test_sec_privatestate.sh - Marqueurs/verrous hors /tmp partagé (failles /tmp prévisibles).
#
# Couvre :
#   (1) câblage statique : checkHeapAndRestart.sh ne référence plus /tmp pour son
#       marqueur de cooldown ; il passe par private_state_path (lib/common.sh).
#   (2) private_state_path sous XDG_RUNTIME_DIR : chemin dedans, dossier 0700.
#   (3) repli sans runtime : dossier /tmp/pzmanager-<user> créé en 0700.
#   (4) repli pré-créé par un tiers (autre owner) -> refus (retour 1, fail-closed),
#       jamais d'écriture dedans.
#   (5) nom avec '/' -> refus (pas d'échappée du dossier privé).
#
# Preuves réelles : vraie fonction private_state_path (lib/common.sh sourcée),
# vrais mkdir/chmod/stat, possession simulée via chown (nobody). Isolé : sandbox
# sous tests/, XDG_RUNTIME_DIR sandbox, repli /tmp nettoyé via trap.
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SANDBOX="${ROOT}/tests/.tmp-secps-$$"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

FALLBACK_DIR="/tmp/pzmanager-$(id -un)"
FALLBACK_PREEXISTED=false
[[ -e "$FALLBACK_DIR" ]] && FALLBACK_PREEXISTED=true
# Runtime sandbox sous /tmp (vrai FS Linux : chmod probants ; sous /mnt/c les
# bits DrvFs ne sont pas significatifs).
SANDBOX_RUN="/tmp/.pztest-run-$$"

cleanup() {
    rm -rf "$SANDBOX" "$SANDBOX_RUN"
    # Ne retire le repli que si le test l'a créé.
    if [[ "$FALLBACK_PREEXISTED" == false ]]; then
        rm -rf "$FALLBACK_DIR"
    fi
}
trap cleanup EXIT
mkdir -p "$SANDBOX"

# --- (1) câblage statique ------------------------------------------------------
if grep -q 'pzmanager-heapcheck.*\.trigger' "${ROOT}/data/scripts/internal/checkHeapAndRestart.sh"; then
    ko "heapcheck : marqueur /tmp prévisible encore présent"
else
    ok "heapcheck : plus de marqueur /tmp prévisible"
fi
if grep -q 'private_state_path' "${ROOT}/data/scripts/internal/checkHeapAndRestart.sh"; then
    ok "heapcheck : passe par private_state_path"
else
    ko "heapcheck : n'utilise pas private_state_path"
fi

# La suite exige la fonction réelle.
# shellcheck disable=SC1090
source "${ROOT}/data/scripts/lib/common.sh"

# --- (2) runtime privé ----------------------------------------------------------
export XDG_RUNTIME_DIR="$SANDBOX_RUN"
mkdir -p "$XDG_RUNTIME_DIR"   # en prod, créé par pam_systemd (possédé par l'utilisateur)
p="$(private_state_path "heapcheck.trigger")" || { ko "runtime : private_state_path en échec"; p=""; }
if [[ -n "${p:-}" && "$p" == "${XDG_RUNTIME_DIR}/pzmanager/heapcheck.trigger" ]]; then
    ok "runtime : chemin sous XDG_RUNTIME_DIR/pzmanager"
else
    ko "runtime : chemin inattendu ('${p:-<vide>}')"
fi
if [[ "$(stat -c %a "${XDG_RUNTIME_DIR}/pzmanager" 2>/dev/null)" == "700" ]]; then
    ok "runtime : dossier en 0700"
else
    ko "runtime : dossier absent ou non-0700"
fi

# --- (3) repli /tmp 0700 ---------------------------------------------------------
unset XDG_RUNTIME_DIR
rm -rf "$FALLBACK_DIR"
p2="$(XDG_RUNTIME_DIR=/nonexistent-xyz private_state_path "heapcheck.trigger")" \
    || { ko "repli : private_state_path en échec"; p2=""; }
if [[ "${p2:-}" == "${FALLBACK_DIR}/heapcheck.trigger" ]]; then
    ok "repli : chemin sous /tmp/pzmanager-<user>"
else
    ko "repli : chemin inattendu ('${p2:-<vide>}')"
fi
if [[ "$(stat -c %a "$FALLBACK_DIR" 2>/dev/null)" == "700" ]]; then
    ok "repli : dossier créé en 0700"
else
    ko "repli : dossier absent ou non-0700"
fi

# --- (4) repli pré-créé par un tiers -> refus ------------------------------------
rm -rf "$FALLBACK_DIR"
mkdir -p "$FALLBACK_DIR"
chown 65534:65534 "$FALLBACK_DIR"
chmod 755 "$FALLBACK_DIR"
if XDG_RUNTIME_DIR=/nonexistent-xyz private_state_path "heapcheck.trigger" >/dev/null 2>&1; then
    ko "repli hostile : accepté (un tiers y écrirait)"
else
    ok "repli hostile : refusé (fail-closed)"
fi
# Remise en état pour le cleanup (retiré car créé par le test).
chown root:root "$FALLBACK_DIR" 2>/dev/null || true
rm -rf "$FALLBACK_DIR"

# --- (5) nom avec '/' -> refus -----------------------------------------------------
export XDG_RUNTIME_DIR="$SANDBOX_RUN"
if private_state_path "../echappe" >/dev/null 2>&1; then
    ko "nom '../echappe' : accepté (échappée du dossier privé)"
else
    ok "nom '../echappe' : refusé"
fi

echo ""
if (( FAIL > 0 )); then
    echo "SEC PRIVATESTATE: ÉCHEC (${FAIL} échec(s), ${PASS} ok)"
    exit 1
fi
echo "SEC PRIVATESTATE: OK (${PASS} contrôles)"
