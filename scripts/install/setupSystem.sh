#!/usr/bin/env bash
# setupSystem.sh - Configuration système initiale
# Crée l'utilisateur, installe les paquets requis et configure le pare-feu.
# Usage: sudo ./setupSystem.sh [nom_utilisateur]
# Par défaut, l'utilisateur est "pzuser"

set -euo pipefail
trap 'on_error $LINENO' ERR

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PZ_USER="${1:-pzuser}"
readonly PZ_HOME="/home/${PZ_USER}"

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
    local -a needed=(sudo rsync unzip zip ufw curl sqlite3)
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

    # Activer UFW si pas encore actif
    if ! ufw status verbose 2>/dev/null | grep -q "Status: active"; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow OpenSSH
        ufw --force enable
        echo "[INFO] UFW activé avec règles par défaut"
    fi

    # Charger les ports depuis .env si disponible, sinon utiliser les défauts
    local port_game="${PZ_PORT_GAME:-16261}"
    local port_game2="${PZ_PORT_GAME2:-16262}"
    local port_rcon="${PZ_PORT_RCON:-8766}"
    local port_steam="${PZ_PORT_STEAM:-27015}"

    local -a rules=("${port_game}/udp" "${port_game2}/udp" "${port_rcon}/udp" "${port_steam}/tcp")
    for r in "${rules[@]}"; do
        ufw allow "$r"
    done
    echo "[INFO] Ports ouverts: ${rules[*]}"
}

configure_path() {
    local bashrc="${PZ_HOME}/.bashrc"
    if [[ ! -f "$bashrc" ]]; then
        echo "[WARN] Fichier .bashrc introuvable pour $PZ_USER"
        return
    fi

    if grep -q "PATH.*pzmanager" "$bashrc"; then
        echo "[INFO] PATH déjà configuré pour pzmanager"
        return
    fi

    cat >> "$bashrc" << PATHEOF

# pzmanager PATH
export PATH="${PZ_HOME}/pzmanager:\${PATH}"
PATHEOF

    chown "${PZ_USER}:${PZ_USER}" "$bashrc"
    echo "[INFO] PATH configuré pour inclure pzmanager"
}

install_sudoers() {
    local templates_dir="${SCRIPT_DIR}/../../data/setupTemplates"
    local template="${templates_dir}/pzuser-sudoers"
    local dest="/etc/sudoers.d/${PZ_USER}"

    if [[ ! -f "$template" ]]; then
        echo "[WARN] Template sudoers introuvable: $template"
        return
    fi

    # Générer le sudoers avec les bonnes valeurs
    sed -e "s|__PZ_USER__|${PZ_USER}|g" -e "s|__PZ_HOME__|${PZ_HOME}|g" "$template" > "/tmp/${PZ_USER}-sudoers"

    if visudo -cf "/tmp/${PZ_USER}-sudoers"; then
        cp "/tmp/${PZ_USER}-sudoers" "$dest"
        chmod 440 "$dest"
        chown root:root "$dest"
        rm -f "/tmp/${PZ_USER}-sudoers"
        echo "[INFO] Sudoers installé: $dest"
    else
        rm -f "/tmp/${PZ_USER}-sudoers"
        echo "[ERROR] Fichier sudoers invalide, installation annulée" >&2
    fi
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "[FATAL] Ce script doit être exécuté en root" >&2
        exit 1
    fi

    echo "[INFO] Configuration pour l'utilisateur: $PZ_USER"

    load_common

    # Charger les ports depuis .env si disponible
    local env_file="${PZ_HOME}/pzmanager/scripts/.env"
    if [[ -f "$env_file" ]]; then
        eval "$(grep -E '^export PZ_PORT_' "$env_file")" 2>/dev/null || true
        echo "[INFO] Ports chargés depuis $env_file"
    fi

    create_user
    install_packages
    configure_firewall
    configure_path
    install_sudoers

    echo "=== Configuration système terminée pour $PZ_USER ==="
}

main
