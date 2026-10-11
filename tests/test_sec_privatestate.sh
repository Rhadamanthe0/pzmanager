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
# Tous les chemins sont créés atomiquement : aucun nom de compte réel ni
# répertoire antérieur ne peut être repris par ce test.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pz-secps-sandbox.XXXXXX")"
readonly SANDBOX
SANDBOX_RUN="$(mktemp -d "${TMPDIR:-/tmp}/pz-secps-runtime.XXXXXX")"
readonly SANDBOX_RUN
FALLBACK_DIR="$(mktemp -d /tmp/pzmanager-pz-secps.XXXXXX)"
readonly FALLBACK_DIR
PRIVATE_STATE_TEST_USER="${FALLBACK_DIR#/tmp/pzmanager-}"
readonly PRIVATE_STATE_TEST_USER
SANDBOX_INODE="$(stat -c '%d:%i' "$SANDBOX")"
readonly SANDBOX_INODE
RUNTIME_INODE="$(stat -c '%d:%i' "$SANDBOX_RUN")"
readonly RUNTIME_INODE
FALLBACK_INODE="$(stat -c '%d:%i' "$FALLBACK_DIR")"
readonly FALLBACK_INODE
id() {
    if [[ "$*" == "-un" ]]; then printf '%s\n' "$PRIVATE_STATE_TEST_USER"
    else command id "$@"; fi
}

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1)); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1)); echo "[FAIL] $*" >&2; }

same_directory() {
    [[ -d "$1" && ! -L "$1" ]] && [[ "$(stat -c '%d:%i' "$1")" == "$2" ]]
}
remove_owned_directory() {
    if same_directory "$1" "$2" && [[ -O "$1" ]]; then
        rm -rf -- "$1"
    else
        echo "[FAIL] cleanup refusé : inode/propriétaire inattendu ($1)" >&2
        return 1
    fi
}
cleanup() {
    remove_owned_directory "$SANDBOX" "$SANDBOX_INODE"
    remove_owned_directory "$SANDBOX_RUN" "$RUNTIME_INODE"
    remove_owned_directory "$FALLBACK_DIR" "$FALLBACK_INODE"
}
trap cleanup EXIT

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
# Runtime déjà réservé par mktemp, privé comme celui de pam_systemd.
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

# --- (3) repli /tmp 0700 réservé exclusivement au test ---------------------------
unset XDG_RUNTIME_DIR
p2="$(XDG_RUNTIME_DIR=/nonexistent-xyz private_state_path "heapcheck.trigger")" \
    || { ko "repli : private_state_path en échec"; exit 1; }
[[ "$p2" == "$FALLBACK_DIR/heapcheck.trigger" ]] \
    && same_directory "$FALLBACK_DIR" "$FALLBACK_INODE" && [[ -O "$FALLBACK_DIR" ]] \
    || { ko "repli : identité inattendue"; exit 1; }
ok "repli : chemin sous /tmp/pzmanager-<identité synthétique>"
[[ "$(stat -c %a "$FALLBACK_DIR")" == "700" ]] \
    && ok "repli : dossier réservé en 0700" || ko "repli : mode non privé"

# --- (4) repli possédé par un tiers -> refus ------------------------------------
# Ne remplacer ni supprimer le répertoire : garder le même inode réservé.
same_directory "$FALLBACK_DIR" "$FALLBACK_INODE" && [[ -O "$FALLBACK_DIR" ]] \
    || { ko "repli : inode remplacé avant simulation"; exit 1; }
chown --no-dereference 65534:65534 "$FALLBACK_DIR"
if XDG_RUNTIME_DIR=/nonexistent-xyz private_state_path "heapcheck.trigger" >/dev/null 2>&1; then
    ko "repli hostile : accepté (un tiers y écrirait)"
else
    ok "repli hostile : refusé (fail-closed)"
fi
# Le refus ne doit pas permettre un chown suivant un lien placé entre-temps.
same_directory "$FALLBACK_DIR" "$FALLBACK_INODE" \
    || { ko "repli : inode remplacé, restauration refusée"; exit 1; }
chown --no-dereference "$(id -u):$(id -g)" "$FALLBACK_DIR"
same_directory "$FALLBACK_DIR" "$FALLBACK_INODE" && [[ -O "$FALLBACK_DIR" ]] \
    || { ko "repli : restauration de propriétaire non vérifiée"; exit 1; }

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
