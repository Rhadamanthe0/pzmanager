#!/usr/bin/env bash
# test_sec_steamlogin.sh - Login Steam hors argv, logs expurgés, journal 600.
#
# Couvre :
#   (1) câblage statique : plus aucun `+login` en argv dans
#       performFullMaintenance.sh ni configurationInitiale.sh.
#   (2) aucune ligne `log` n'interpole le login (ni journal ni tee).
#   (3) le journal de maintenance est créé en 600 avant le tee.
#   (4) les IDs WorkshopItems interpolés dans le runscript sont validés numériques.
#   (5) steamcmd_runscript : login absent de l'argv (runscript +runscript),
#       fichier 0600, contenu exact, effacé après usage, code retour propagé.
#   (6) login avec saut de ligne ou guillemet -> refus (fail-closed).
#   (7) chemin sudo (STEAMCMD_AS_USER) : login absent de l'argv de sudo aussi.
#
# Preuves réelles : vraie fonction steamcmd_runscript (lib/common.sh sourcée),
# vrai mktemp/chmod/stat/rm, faux binaires steamcmd/sudo (PATH sandbox).
set -euo pipefail

ROOT="${PZ_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SANDBOX="${ROOT}/tests/.tmp-secslogin-$$"
MOCKBIN="${SANDBOX}/bin"
# Tmp sur vrai FS Linux (/tmp) : sous /mnt/c les bits DrvFs rendent stat/chmod
# non probants (même remarque que test_sec_privatestate.sh).
MOCKTMP="/tmp/.pztest-login-$$"

PASS=0
FAIL=0
ok() { PASS=$(( PASS + 1 )); echo "[OK] $*"; }
ko() { FAIL=$(( FAIL + 1 )); echo "[FAIL] $*" >&2; }

cleanup() { rm -rf "$SANDBOX" "$MOCKTMP"; }
trap cleanup EXIT
mkdir -p "$MOCKBIN" "$MOCKTMP"

MAINT="${ROOT}/data/scripts/admin/performFullMaintenance.sh"
INST="${ROOT}/data/scripts/install/configurationInitiale.sh"

# --- (1) plus de +login en argv -------------------------------------------------
if grep -q '+login' "$MAINT" "$INST"; then
    ko "un '+login' reste en argv (ps visible)"
else
    ok "plus aucun '+login' en argv"
fi

# --- (2) logs sans login --------------------------------------------------------
if grep -qE '^[[:space:]]*log .*[$]\{login\}' "$MAINT"; then
    ko "une ligne log expose encore le login"
else
    ok "aucune ligne log n'expose le login"
fi

# --- (3) journal maintenance en 600 ----------------------------------------------
if grep -qF 'install -m 600 /dev/null "${MAINT_LOG}"' "$MAINT"; then
    ok "journal maintenance créé en 600"
else
    ko "journal maintenance non restreint en 600"
fi

# --- (4) WorkshopItems validés numériques -----------------------------------------
if grep -q '\[.*"\$id" =~' "$MAINT"; then
    ok "IDs WorkshopItems validés avant interpolation runscript"
else
    ko "IDs WorkshopItems non validés (injection runscript possible)"
fi

# --- Faux binaires ----------------------------------------------------------------
cat > "${MOCKBIN}/steamcmd" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${PZ_MOCK_ARGV}"
i=1
for a in "$@"; do
    if [[ "$a" == "+runscript" ]]; then
        j=$(( i + 1 ))
        f="${!j}"
        cat "$f" > "${PZ_MOCK_SCRIPT}"
        stat -c %a "$f" > "${PZ_MOCK_MODE}"
    fi
    i=$(( i + 1 ))
done
exit "${PZ_MOCK_EXIT:-0}"
MOCKEOF
chmod +x "${MOCKBIN}/steamcmd"
cat > "${MOCKBIN}/sudo" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${PZ_MOCK_SUDO_ARGV}"
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
exec "$@"
MOCKEOF
chmod +x "${MOCKBIN}/sudo"

# shellcheck disable=SC1090
source "${ROOT}/data/scripts/lib/common.sh"

export TMPDIR="$MOCKTMP"
export STEAMCMD_PATH="${MOCKBIN}/steamcmd"
export PZ_MOCK_ARGV="${SANDBOX}/argv.txt"
export PZ_MOCK_SCRIPT="${SANDBOX}/script.txt"
export PZ_MOCK_MODE="${SANDBOX}/mode.txt"
export PZ_MOCK_SUDO_ARGV="${SANDBOX}/sudo-argv.txt"
unset STEAMCMD_AS_USER

LOGIN="compte_test_dedie"

# --- (5) appel nominal --------------------------------------------------------------
export PZ_MOCK_EXIT=0
rc=0
steamcmd_runscript "$LOGIN" 'force_install_dir "/srv/pz"' "login \"${LOGIN}\"" 'app_update "380870" -beta "public" validate' || rc=$?
(( rc == 0 )) || ko "appel nominal en échec (rc=${rc})"
if grep -qF "$LOGIN" "$PZ_MOCK_ARGV"; then
    ko "login présent dans l'argv steamcmd"
else
    ok "login absent de l'argv steamcmd"
fi
grep -q '^+runscript$' "$PZ_MOCK_ARGV" && ok "invocation via +runscript" || ko "pas via +runscript"
[[ "$(cat "$PZ_MOCK_MODE")" == "600" ]] && ok "runscript en 0600" || ko "runscript non-0600"
grep -qF "login \"${LOGIN}\"" "$PZ_MOCK_SCRIPT" && ok "runscript contient le login" || ko "runscript sans login"
[[ "$(tail -1 "$PZ_MOCK_SCRIPT")" == "quit" ]] && ok "runscript terminé par quit" || ko "runscript sans quit final"
if compgen -G "${MOCKTMP}/pz-steamcmd-*" > /dev/null; then
    ko "runscript non effacé après usage"
else
    ok "runscript effacé après usage"
fi

# Propagation du code retour (échec steamcmd -> échec helper, sans masquage).
export PZ_MOCK_EXIT=3
rc=0
steamcmd_runscript "$LOGIN" 'force_install_dir "/srv/pz"' "login \"${LOGIN}\"" || rc=$?
(( rc == 3 )) && ok "code retour steamcmd propagé (3)" || ko "code retour non propagé (rc=${rc})"
export PZ_MOCK_EXIT=0

# --- (6) logins hostiles refusés -------------------------------------------------------
if ( steamcmd_runscript $'méchant\nlogin "x"' 'x' >/dev/null 2>&1 ); then
    ko "login avec saut de ligne accepté"
else
    ok "login avec saut de ligne refusé"
fi
if ( steamcmd_runscript 'méchant"login' 'x' >/dev/null 2>&1 ); then
    ko 'login avec guillemet accepté'
else
    ok 'login avec guillemet refusé'
fi
if compgen -G "${MOCKTMP}/pz-steamcmd-*" > /dev/null; then
    ko "runscript hostile non nettoyé"
else
    ok "aucun runscript hostile résiduel"
fi

# --- (7) chemin sudo --------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[SKIP] chemin sudo (non-root : chown impossible)"
else
    export PATH="${MOCKBIN}:$PATH"
    export STEAMCMD_AS_USER="$(id -un)"
    rc=0
    steamcmd_runscript "$LOGIN" 'force_install_dir "/srv/pz"' "login \"${LOGIN}\"" || rc=$?
    (( rc == 0 )) || ko "appel sudo en échec (rc=${rc})"
    if grep -qF "$LOGIN" "$PZ_MOCK_SUDO_ARGV"; then
        ko "login présent dans l'argv de sudo"
    else
        ok "login absent de l'argv de sudo"
    fi
    grep -qF "$LOGIN" "$PZ_MOCK_ARGV" && ko "login présent dans l'argv steamcmd (sudo)" || ok "login absent de l'argv steamcmd (sudo)"
    compgen -G "${MOCKTMP}/pz-steamcmd-*" > /dev/null && ko "runscript sudo non effacé" || ok "runscript sudo effacé"
    unset STEAMCMD_AS_USER
fi

echo ""
if (( FAIL > 0 )); then
    echo "SEC STEAMLOGIN: ÉCHEC (${FAIL} échec(s), ${PASS} ok)"
    exit 1
fi
echo "SEC STEAMLOGIN: OK (${PASS} contrôles)"
