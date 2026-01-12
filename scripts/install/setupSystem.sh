#!/usr/bin/env bash
# setupSystem.sh - Configuration système initiale
# Crée l'utilisateur pzuser, installe les paquets requis et configure le pare-feu.
# Usage: sudo ./setupSystem.sh

set -euo pipefail
trap 'on_error $LINENO' ERR

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PZ_USER="pzuser"

on_error() {
    local lineno=${1:-?}
    echo "[ERROR] Échec lors de l'exécution (ligne: ${lineno})" >&2
    exit 1
}

require_command() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] la commande '$cmd' est requise mais introuvable" >&2; exit 1; }
}

load_common() {
    local common="${SCRIPT_DIR}/../lib/common.sh"
    if [[ -r "$common" ]]; then
        # shellcheck source=/dev/null
        source "$common"
    else
        echo "[WARN] Fichier common.sh introuvable, utilisation de fonctions minimales" >&2
        die() { echo "[FATAL] $*" >&2; exit 1; }
    fi
}

create_user() {
    require_command id
    require_command useradd
    if id -u "$PZ_USER" >/dev/null 2>&1; then
        echo "[INFO] L'utilisateur $PZ_USER existe déjà"
        return
    fi
    useradd -m -s /bin/bash "$PZ_USER"
    echo "[INFO] Utilisateur $PZ_USER créé"
}

install_packages() {
    require_command apt-get
    local -a needed=(rsync unzip ufw)
    local -a to_install=()
    for pkg in "${needed[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        echo "[INFO] Tous les paquets requis sont présents"
        return
    fi
    echo "[INFO] Installation des paquets: ${to_install[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${to_install[@]}"
}

configure_firewall() {
    require_command ufw
    if ufw status verbose 2>/dev/null | grep -q "Status: active"; then
        echo "[INFO] UFW est déjà actif"
        return
    fi
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    local -a rules=("OpenSSH" "16261/udp" "16262/udp" "8766/udp" "27015/tcp")
    for r in "${rules[@]}"; do
        ufw allow "$r"
    done
    ufw --force enable
    echo "[INFO] Pare-feu configuré et activé"
}

configure_path() {
    local bashrc="/home/${PZ_USER}/.bashrc"
    if [[ ! -f "$bashrc" ]]; then
        echo "[WARN] Fichier .bashrc introuvable pour $PZ_USER"
        return
    fi

    if grep -q "PATH.*pzmanager" "$bashrc"; then
        echo "[INFO] PATH déjà configuré pour pzmanager"
        return
    fi

    cat >> "$bashrc" << 'PATHEOF'

# pzmanager PATH
export PATH="/home/pzuser/pzmanager:${PATH}"
PATHEOF

    chown "${PZ_USER}:${PZ_USER}" "$bashrc"
    echo "[INFO] PATH configuré pour inclure pzmanager"
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "[FATAL] Ce script doit être exécuté en root" >&2
        exit 1
    fi

    load_common
    create_user
    install_packages
    configure_firewall
    configure_path

    echo "=== Configuration système terminée ==="
    echo "Note: vérifier et installer le sudoers si nécessaire :"
    echo "  sudo visudo -cf data/setup/pzuser-sudoers && sudo cp data/setup/pzuser-sudoers /etc/sudoers.d/pzuser"
}

main
