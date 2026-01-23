#!/bin/bash
# ------------------------------------------------------------------------------
# configurationInitiale.sh - Installation et restauration serveur PZ
# ------------------------------------------------------------------------------
# Usage: ./configurationInitiale.sh <restore|zomboid> [--force]
#
# Commandes:
#   restore PATH   - Restaurer depuis une sauvegarde
#   zomboid        - Installer le serveur Project Zomboid via SteamCMD
#
# Options:
#   --force        - Ne pas demander de confirmation
#
# Nécessite: root
# Note: Pour setup système, utilisez setupSystem.sh
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}"

readonly BACKUPS_PATH="/home/pzuser/pzmanager/data/fullBackups"
readonly PZ_USER="pzuser"
readonly PZ_HOME="/home/$PZ_USER"
readonly INSTALL_DIR="/home/pzuser/pzmanager/data/pzserver"
readonly ZOMBOID_DIR="$PZ_HOME/pzmanager/Zomboid"

FORCE_MODE=false
SKIPPED_STEPS=()

# === Utilities ===

confirm_action() {
    local message="$1"
    [[ "$FORCE_MODE" == true ]] && return 0

    echo -n "$message [o/N] "
    read -r response
    [[ "$response" =~ ^[oOyY]$ ]]
}

skip_step() {
    local step_name="$1"
    echo "  → Étape ignorée: $step_name"
    SKIPPED_STEPS+=("$step_name")
}

show_summary() {
    echo ""
    if [[ ${#SKIPPED_STEPS[@]} -gt 0 ]]; then
        echo "⚠️  Étapes ignorées:"
        for step in "${SKIPPED_STEPS[@]}"; do
            echo "   - $step"
        done
    else
        echo "✅ Toutes les étapes exécutées"
    fi
}

# === Restore Functions ===

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

restore_zomboid_data() {
    local backup_path="$1"
    local zip_file="$backup_path$PZ_HOME/Zomboid_Latest_Full.zip"

    [[ -f "$zip_file" ]] || return 0

    if [[ -d "$ZOMBOID_DIR" ]]; then
        echo ""
        echo "⚠️  ATTENTION: Le dossier de données Zomboid existe déjà"
        echo "   Chemin: $ZOMBOID_DIR"
        if ! confirm_action "Voulez-vous le remplacer ?"; then
            skip_step "Restauration données Zomboid"
            return 0
        fi
    fi

    echo "Restauration des données Zomboid..."
    mkdir -p "$PZ_HOME/pzmanager/data/dataBackups"
    unzip -o -q "$zip_file" -d "$PZ_HOME/pzmanager/data/dataBackups/"

    if [[ -d "$PZ_HOME/pzmanager/data/dataBackups/latest" ]]; then
        mkdir -p "$ZOMBOID_DIR"
        rsync -a "$PZ_HOME/pzmanager/data/dataBackups/latest/" "$ZOMBOID_DIR/"
        echo "Données Zomboid restaurées vers $ZOMBOID_DIR"
    fi

    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/pzmanager/data/dataBackups"
    chown -R "$PZ_USER:$PZ_USER" "$ZOMBOID_DIR"
}

restore_backup() {
    local backup_path="${1:-}"

    if [[ ! -d "$backup_path" ]]; then
        echo "Usage: $0 restore ${BACKUPS_PATH}/YYYY-MM-DD_HH-MM [--force]"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$BACKUPS_PATH" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    echo "=== Restauration : $backup_path ==="

    restore_directory "$backup_path$PZ_HOME/.ssh" "$PZ_HOME/.ssh" "$PZ_USER"

    if [[ -d "$PZ_HOME/.ssh" ]]; then
        chmod 700 "$PZ_HOME/.ssh"
        chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
    fi

    restore_directory "$backup_path$PZ_HOME/.config/systemd/user" "$PZ_HOME/.config/systemd/user" "$PZ_USER"
    restore_scripts "$backup_path$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    restore_sudoers "$backup_path"
    restore_zomboid_data "$backup_path"

    local uid=$(id -u "$PZ_USER")
    echo "Rechargement des services systemd..."
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-backup.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-modcheck.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-maintenance.timer || true

    echo "=== Restauration terminée ==="
    show_summary
}

# === Install Functions ===

install_zomboid_dependencies() {
    echo "Installation des dépendances..."
    dpkg --add-architecture i386
    apt-get update -qq
    apt-get install -yqq lib32gcc-s1 libsdl2-2.0-0:i386 steamcmd "${JAVA_PACKAGE}"
}

download_zomboid_server() {
    echo "Téléchargement du serveur via SteamCMD..."
    mkdir -p "$INSTALL_DIR"
    chown "$PZ_USER:$PZ_USER" "$INSTALL_DIR"
    sudo -u "$PZ_USER" /usr/games/steamcmd +force_install_dir "$INSTALL_DIR" +login anonymous +app_update 380870 validate +quit
}

configure_zomboid_jvm() {
    [[ -f "$INSTALL_DIR/ProjectZomboid64.json" ]] || return 0
    grep -q "UseZGC" "$INSTALL_DIR/ProjectZomboid64.json" && return 0

    echo "Configuration JVM (UseZGC)..."
    sed -i 's/"-XX:-OmitStackTraceInFastThrow"/"-XX:+UseZGC",\n\t\t"-XX:-OmitStackTraceInFastThrow"/' "$INSTALL_DIR/ProjectZomboid64.json"
}

configure_user_environment() {
    grep -q "XDG_RUNTIME_DIR" "$PZ_HOME/.bashrc" && return 0

    echo "Configuration environnement utilisateur..."
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "$PZ_HOME/.bashrc"
}

install_systemd_services() {
    local systemd_dir="$PZ_HOME/.config/systemd/user"
    local templates_dir="$PZ_HOME/pzmanager/data/setupTemplates"

    echo "Installation des services systemd..."
    mkdir -p "$systemd_dir"

    # Server services
    for service_file in zomboid.service zomboid.socket zomboid_logger.service; do
        if [[ -f "$templates_dir/$service_file" ]]; then
            cp "$templates_dir/$service_file" "$systemd_dir/$service_file"
            chown "$PZ_USER:$PZ_USER" "$systemd_dir/$service_file"
            echo "  - $service_file installé"
        else
            echo "  [WARN] Template introuvable: $service_file"
        fi
    done

    # Automation timers and services
    for unit_file in pz-backup.service pz-backup.timer pz-modcheck.service pz-modcheck.timer pz-maintenance.service pz-maintenance.timer; do
        if [[ -f "$templates_dir/$unit_file" ]]; then
            cp "$templates_dir/$unit_file" "$systemd_dir/$unit_file"
            chown "$PZ_USER:$PZ_USER" "$systemd_dir/$unit_file"
            echo "  - $unit_file installé"
        else
            echo "  [WARN] Template introuvable: $unit_file"
        fi
    done
}

enable_zomboid_service() {
    local uid=$(id -u "$PZ_USER")

    echo "Activation des services et timers..."
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable zomboid.service
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-backup.timer
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-modcheck.timer
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now pz-maintenance.timer
}

install_zomboid() {
    echo "=== Installation serveur Project Zomboid ==="

    local do_server_install=true
    local do_zomboid_init=true

    # Check existing server installation
    if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/ProjectZomboid64" ]]; then
        echo ""
        echo "ℹ️  Serveur déjà installé dans $INSTALL_DIR"
        if ! confirm_action "Voulez-vous réinstaller/mettre à jour ?"; then
            skip_step "Installation serveur PZ"
            do_server_install=false
        fi
    fi

    # Check existing Zomboid data
    if [[ -d "$ZOMBOID_DIR" ]]; then
        echo ""
        echo "⚠️  ATTENTION: Le dossier de données Zomboid existe déjà"
        echo "   Chemin: $ZOMBOID_DIR"
        if ! confirm_action "Voulez-vous l'écraser ?"; then
            skip_step "Initialisation données Zomboid"
            do_zomboid_init=false
        fi
    fi

    # Execute steps based on user choices
    loginctl enable-linger "$PZ_USER"

    if [[ "$do_server_install" == true ]]; then
        install_zomboid_dependencies
        download_zomboid_server
        configure_zomboid_jvm
    fi

    configure_user_environment
    install_systemd_services
    enable_zomboid_service

    echo ""
    echo "=== Installation terminée ==="
    show_summary

    echo ""
    echo "Prochaines étapes :"
    echo "  1. Démarrer le serveur : sudo -u $PZ_USER pzm server start"
    echo "  2. Configurer le serveur : $ZOMBOID_DIR/Server/servertest.ini"
}

show_help() {
    cat <<HELPEOF
Usage: $0 <commande> [--force]

Commandes :
  restore PATH  Restaurer depuis une sauvegarde (inclut sudoers)
  zomboid       Installer le serveur Project Zomboid

Options :
  --force       Ne pas demander de confirmation avant écrasement

Pour configuration système initiale, utilisez: ./setupSystem.sh
HELPEOF
}

# === Main ===

[[ $EUID -eq 0 ]] || die "Exécution root requise"

# Parse --force flag
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE_MODE=true
done

case "${1:-}" in
    restore)   restore_backup "${2:-}" ;;
    zomboid)   install_zomboid ;;
    setup)     echo "Utilisez maintenant ./setupSystem.sh pour la configuration système" ;;
    *)         show_help ;;
esac
