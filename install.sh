#!/bin/bash
# ------------------------------------------------------------------------------
# pzmanager - One-line installer
# ------------------------------------------------------------------------------
# Usage: curl -fsSL https://raw.githubusercontent.com/Rhadamanthe0/pzmanager/main/install.sh | sudo bash
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
    log "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
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

run_setup() {
    log "Running system setup for user: ${PZ_USER}..."
    bash "${TMP_DIR}/scripts/install/setupSystem.sh" "${PZ_USER}"
}

configure_env() {
    log "Configuring .env for user: ${PZ_USER}..."
    local env_file="${TMP_DIR}/scripts/.env"
    local env_example="${TMP_DIR}/data/setupTemplates/.env.example"

    if [[ -f "$env_example" ]]; then
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
    bash "${INSTALL_DIR}/scripts/install/configurationInitiale.sh" zomboid --force
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
    run_setup
    configure_env
    move_to_home
    run_initial_config
    print_success
}

main "$@"
