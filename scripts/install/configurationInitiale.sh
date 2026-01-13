#!/bin/bash
# ------------------------------------------------------------------------------
# configurationInitiale.sh - Installation et restauration serveur PZ
# ------------------------------------------------------------------------------
# Usage: ./configurationInitiale.sh <restore|zomboid>
#
# Commandes:
#   restore PATH   - Restaurer depuis une sauvegarde
#   zomboid        - Installer le serveur Project Zomboid via SteamCMD
#
# Nécessite: root
# Note: Pour setup système, utilisez setupSystem.sh
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

readonly BACKUPS_PATH="/home/pzuser/pzmanager/data/fullBackups"
readonly PZ_USER="pzuser"
readonly PZ_HOME="/home/$PZ_USER"
readonly INSTALL_DIR="/home/pzuser/pzmanager/data/pzserver"

restore_directory() {
    local src="$1" dest="$2" owner="${3:-}"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dest"
    rsync -a "$src/" "$dest/"
    [[ -n "$owner" ]] && chown -R "$owner:$owner" "$dest"
}

restore_scripts() {
    local src="$1" dest="$2" owner="${3:-}"
    restore_directory "$src" "$dest" "$owner"
    chmod +x "$dest"/*.sh 2>/dev/null || true
}

restore_sudoers() {
    local backup_path="$1"

    if [[ -d "$backup_path/etc/sudoers.d" ]]; then
        for sudoers_file in "$backup_path"/etc/sudoers.d/*; do
            [[ -f "$sudoers_file" ]] || continue
            local filename=$(basename "$sudoers_file")
            cp "$sudoers_file" "/etc/sudoers.d/$filename"
            chmod 440 "/etc/sudoers.d/$filename"
            chown root:root "/etc/sudoers.d/$filename"
            visudo -cf "/etc/sudoers.d/$filename" || die "Fichier sudoers invalide: $filename"
        done
    fi

    if [[ -f "$backup_path$PZ_HOME/sudoers-pzuser" ]]; then
        cp "$backup_path$PZ_HOME/sudoers-pzuser" "$PZ_HOME/sudoers-pzuser"
        chown "$PZ_USER:$PZ_USER" "$PZ_HOME/sudoers-pzuser"
    fi
}

restore_crontab() {
    local backup_path="$1"

    if [[ -f "$backup_path$PZ_HOME/pzmanager/data/setupTemplates/pzuser-crontab" ]]; then
        crontab -u "$PZ_USER" "$backup_path$PZ_HOME/pzmanager/data/setupTemplates/pzuser-crontab"
        echo "Crontab de $PZ_USER restauré"
    fi
}

restore_zomboid_data() {
    local backup_path="$1"

    [[ -f "$backup_path$PZ_HOME/Zomboid_Latest_Full.zip" ]] || return 0

    echo "Restauration des données Zomboid..."
    mkdir -p "$PZ_HOME/pzmanager/data/dataBackups"
    unzip -o -q "$backup_path$PZ_HOME/Zomboid_Latest_Full.zip" -d "$PZ_HOME/pzmanager/data/dataBackups/"

    if [[ -d "$PZ_HOME/pzmanager/data/dataBackups/latest" ]]; then
        mkdir -p "$PZ_HOME/pzmanager/Zomboid"
        rsync -a "$PZ_HOME/pzmanager/data/dataBackups/latest/" "$PZ_HOME/pzmanager/Zomboid/"
        echo "Données Zomboid restaurées vers $PZ_HOME/pzmanager/Zomboid"
    fi

    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/pzmanager/data/dataBackups"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/pzmanager/Zomboid"
}

restore_backup() {
    local backup_path="${1:-}"

    if [[ ! -d "$backup_path" ]]; then
        echo "Usage: $0 restore ${BACKUPS_PATH}/YYYY-MM-DD_HH-MM"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$BACKUPS_PATH" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    echo "=== Restauration : $backup_path ==="

    restore_crontab "$backup_path"
    restore_directory "$backup_path$PZ_HOME/.ssh" "$PZ_HOME/.ssh" "$PZ_USER"

    if [[ -d "$PZ_HOME/.ssh" ]]; then
        chmod 700 "$PZ_HOME/.ssh"
        chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
    fi

    restore_directory "$backup_path$PZ_HOME/.config/systemd/user" "$PZ_HOME/.config/systemd/user" "$PZ_USER"
    restore_scripts "$backup_path$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    restore_sudoers "$backup_path"
    restore_zomboid_data "$backup_path"

    systemctl restart cron
    su - "$PZ_USER" -c "systemctl --user daemon-reload" || true

    echo "=== Restauration terminée ==="
}

install_zomboid_dependencies() {
    dpkg --add-architecture i386
    apt-get update -qq
    apt-get install -yqq lib32gcc-s1 libsdl2-2.0-0:i386 steamcmd
}

download_zomboid_server() {
    mkdir -p "$INSTALL_DIR"
    chown "$PZ_USER:$PZ_USER" "$INSTALL_DIR"
    sudo -u "$PZ_USER" /usr/games/steamcmd +force_install_dir "$INSTALL_DIR" +login anonymous +app_update 380870 validate +quit
}

configure_zomboid_jvm() {
    [[ -f "$INSTALL_DIR/ProjectZomboid64.json" ]] || return 0
    grep -q "UseZGC" "$INSTALL_DIR/ProjectZomboid64.json" && return 0
    sed -i 's/"-XX:-OmitStackTraceInFastThrow"/"-XX:+UseZGC",\n\t\t"-XX:-OmitStackTraceInFastThrow"/' "$INSTALL_DIR/ProjectZomboid64.json"
}

configure_user_environment() {
    grep -q "XDG_RUNTIME_DIR" "$PZ_HOME/.bashrc" || \
        echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "$PZ_HOME/.bashrc"
}

install_systemd_services() {
    local systemd_dir="$PZ_HOME/.config/systemd/user"
    local templates_dir="$PZ_HOME/pzmanager/data/setupTemplates"

    echo "Installation des services systemd..."
    mkdir -p "$systemd_dir"

    for service_file in zomboid.service zomboid.socket zomboid_logger.service; do
        if [[ -f "$templates_dir/$service_file" ]]; then
            cp "$templates_dir/$service_file" "$systemd_dir/$service_file"
            chown "$PZ_USER:$PZ_USER" "$systemd_dir/$service_file"
            echo "  - $service_file installé"
        else
            echo "  [WARN] Template introuvable: $service_file"
        fi
    done
}

enable_zomboid_service() {
    local uid=$(id -u "$PZ_USER")
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable zomboid.service
}

install_zomboid() {
    echo "=== Installation serveur Project Zomboid ==="
    loginctl enable-linger "$PZ_USER"
    install_zomboid_dependencies
    download_zomboid_server
    configure_zomboid_jvm
    configure_user_environment
    install_systemd_services
    enable_zomboid_service
    echo "=== Installation terminée ==="
}

show_help() {
    cat <<HELPEOF
Usage: $0 <commande>

Commandes :
  restore PATH  Restaurer depuis une sauvegarde (inclut sudoers)
  zomboid       Installer le serveur Project Zomboid

Pour configuration système initiale, utilisez: ./setupSystem.sh
HELPEOF
}

[[ $EUID -eq 0 ]] || die "Exécution root requise"

case "${1:-}" in
    restore)   restore_backup "${2:-}" ;;
    zomboid)   install_zomboid ;;
    setup)     echo "Utilisez maintenant ./setupSystem.sh pour la configuration système" ;;
    *)         show_help ;;
esac
