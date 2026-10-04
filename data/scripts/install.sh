#!/bin/bash
# ------------------------------------------------------------------------------
# pzmanager - One-line installer
# ------------------------------------------------------------------------------
# Usage: curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/data/scripts/install.sh | sudo bash
# Usage: curl -fsSL ... | sudo PZ_USER=pzuser42 bash
#
# Requirements: Debian/Ubuntu, root access, git, curl
# ------------------------------------------------------------------------------

set -euo pipefail

readonly REPO_URL="https://github.com/Rhadamanthe0/pzmanager.git"
readonly PZ_USER="${PZ_USER:-pzuser}"
readonly PZ_HOME="/home/${PZ_USER}"
readonly INSTALL_DIR="${PZ_HOME}/pzmanager"
readonly TMP_DIR="/tmp/pzmanager-install"
# C15 : helpers root exécutés depuis un arbre root-owned (plus depuis
# INSTALL_DIR chown PZ_USER). Renseigné par stage_root_helpers.
readonly LIBEXEC_DIR="/usr/local/libexec/pzmanager"
STAGED_ROOT_HELPERS=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[pzmanager]${NC} $*"; }
warn()  { echo -e "${YELLOW}[pzmanager]${NC} $*"; }
error() { echo -e "${RED}[pzmanager]${NC} $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)"
}

check_os() {
    if [[ ! -f /etc/debian_version ]]; then
        error "This script only supports Debian/Ubuntu"
    fi
    log "OS: $(. /etc/os-release && echo "${PRETTY_NAME}")"
}

check_dependencies() {
    for cmd in git curl; do
        if ! command -v "$cmd" &>/dev/null; then
            log "Installing $cmd..."
            apt-get update -qq && apt-get install -y -qq "$cmd"
        fi
    done
}

clone_repo() {
    log "Cloning pzmanager..."
    rm -rf "${TMP_DIR}"
    git clone --depth 1 "${REPO_URL}" "${TMP_DIR}"
}

# C15 : copie les helpers root (scripts install + libs) depuis une source
# pristine (clone root, avant tout chown PZ_USER) vers LIBEXEC_DIR root-owned,
# puis exécution depuis là. Les copies stagées sont root:root 0755/0644 :
# PZ_USER ne peut plus les réécrire entre l'install et leur exécution en root.
# Les libs stagées (common/env_parse/jdk_matrix) sont la copie pristine
# root-owned du clone, pas l'arbre PZ_USER : le relatif install/../lib reste
# valide et sûr. Échec (pas de droit, test) -> warning + fallback historique ;
# configurationInitiale.sh refuse alors lui-même tout helper non root-owned
# quand EUID==0 (fail-closed).
stage_root_helpers() {
    local src_root="$1"
    local dst_install="${LIBEXEC_DIR}/install" dst_lib="${LIBEXEC_DIR}/lib"
    if ! mkdir -p "$dst_install" "$dst_lib" 2>/dev/null; then
        warn "libexec indisponible (${LIBEXEC_DIR}) : exécution depuis l'arbre d'installation (fallback)."
        return 1
    fi
    cp -p "${src_root}/data/scripts/install/setupSystem.sh" "${src_root}/data/scripts/install/configurationInitiale.sh" "$dst_install/" 2>/dev/null \
        || { warn "stage helpers install impossible : fallback sur l'arbre d'installation."; return 1; }
    cp -p "${src_root}/data/scripts/lib/common.sh" "${src_root}/data/scripts/lib/env_parse.sh" "${src_root}/data/scripts/lib/jdk_matrix.sh" "$dst_lib/" 2>/dev/null \
        || { warn "stage libs impossible : fallback sur l'arbre d'installation."; return 1; }
    chown -R root:root "${LIBEXEC_DIR}" 2>/dev/null || warn "chown root ${LIBEXEC_DIR} impossible (poursuite en fallback partiel)."
    chmod 0755 "${LIBEXEC_DIR}" "$dst_install" "$dst_lib" 2>/dev/null || true
    chmod 0755 "$dst_install/setupSystem.sh" "$dst_install/configurationInitiale.sh" 2>/dev/null || true
    chmod 0644 "$dst_lib/common.sh" "$dst_lib/env_parse.sh" "$dst_lib/jdk_matrix.sh" 2>/dev/null || true
    STAGED_ROOT_HELPERS=1
}

run_setup() {
    log "Running system setup for user: ${PZ_USER}..."
    # Le .env est encore dans TMP_DIR à ce stade (move_to_home n'a pas eu lieu) :
    # on le passe explicitement, sinon setupSystem.sh cherche dans un home pas
    # encore peuplé, ne trouve rien, et pose les règles UFW sur les ports codés en
    # dur en ignorant silencieusement PZ_PORT_* / PZ_PROMETHEUS_PORT.
    if [[ -n "${STAGED_ROOT_HELPERS}" && -f "${LIBEXEC_DIR}/install/setupSystem.sh" ]]; then
        bash "${LIBEXEC_DIR}/install/setupSystem.sh" "${PZ_USER}" "${TMP_DIR}/.env"
    else
        bash "${TMP_DIR}/data/scripts/install/setupSystem.sh" "${PZ_USER}" "${TMP_DIR}/.env"
    fi
}

configure_env() {
    # PZ_USER vient de l'environnement (sudo PZ_USER=...) et alimente un sed
    # sans échappement : refuse toute valeur hors regex avant usage.
    [[ "${PZ_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || error "Invalid PZ_USER '${PZ_USER}' (attendu ^[a-z_][a-z0-9_-]{0,31}$)"
    log "Configuring .env for user: ${PZ_USER}..."
    local env_file="${TMP_DIR}/.env"
    local env_example="${TMP_DIR}/data/setupTemplates/.env.example"

    if [[ -f "$env_example" ]]; then
        # Créé en 600 AVANT d'écrire : le .env reçoit ensuite webhook, token de bot
        # et clé de compte de service, qu'une redirection sous umask 022 exposerait
        # en lecture à toute la machine.
        install -m 600 /dev/null "$env_file"
        sed "s|pzuser|${PZ_USER}|g" "$env_example" > "$env_file"
    fi
}

move_to_home() {
    log "Installing to ${INSTALL_DIR}..."

    if [[ -d "${INSTALL_DIR}" ]]; then
        warn "Existing installation found, backing up..."
        mv "${INSTALL_DIR}" "${INSTALL_DIR}.backup.$(date +%s)"
    fi

    mv "${TMP_DIR}" "${INSTALL_DIR}"
    chown -R "${PZ_USER}:${PZ_USER}" "${INSTALL_DIR}"
}

run_initial_config() {
    log "Running initial configuration (this may take a while)..."
    # C15 : jamais depuis INSTALL_DIR (chown PZ_USER par move_to_home) si le
    # stage a réussi : exécute la copie root-owned de LIBEXEC_DIR.
    if [[ -n "${STAGED_ROOT_HELPERS}" && -f "${LIBEXEC_DIR}/install/configurationInitiale.sh" ]]; then
        bash "${LIBEXEC_DIR}/install/configurationInitiale.sh" zomboid --force
    else
        warn "helpers root non stagés : exécution depuis l'arbre PZ_USER (fallback)."
        bash "${INSTALL_DIR}/data/scripts/install/configurationInitiale.sh" zomboid --force
    fi
}

print_success() {
    echo ""
    log "=========================================="
    log "  pzmanager installed successfully!"
    log "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Switch to ${PZ_USER}:  su - ${PZ_USER}"
    echo "  2. Go to pzmanager:   cd ${INSTALL_DIR}"
    echo "  3. Start server:      pzm server start"
    echo ""
    echo "Documentation: ${INSTALL_DIR}/docs/"
    echo ""
}

main() {
    echo ""
    echo "  ____  _____                                         "
    echo " |  _ \|__  /_ __ ___   __ _ _ __   __ _  __ _  ___ _ __ "
    echo " | |_) | / /| '_ \` _ \ / _\` | '_ \ / _\` |/ _\` |/ _ \ '__|"
    echo " |  __/ / /_| | | | | | (_| | | | | (_| | (_| |  __/ |   "
    echo " |_|   /____|_| |_| |_|\__,_|_| |_|\__,_|\__, |\___|_|   "
    echo "                                         |___/           "
    echo ""
    echo " Project Zomboid Server Manager - Installer (user: ${PZ_USER})"
    echo ""

    check_root
    check_os
    check_dependencies
    clone_repo
    # configure_env AVANT run_setup (qui lit les ports du .env), et run_setup
    # avant move_to_home (dont le chown a besoin de l'utilisateur créé par
    # create_user).
    configure_env
    # Stage AVANT run_setup depuis TMP_DIR pristine (avant tout chown) ; échec
    # -> warning + fallback historique (voir stage_root_helpers).
    stage_root_helpers "${TMP_DIR}" || true
    run_setup
    move_to_home
    run_initial_config
    print_success
}

main "$@"
