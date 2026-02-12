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
# Note: Crée automatiquement un utilisateur 'admin' avec mot de passe aléatoire
# Note: PZ_USER et tous les chemins sont lus depuis scripts/.env
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# Toutes ces variables viennent de .env (source_env)
# PZ_USER, PZ_HOME, PZ_MANAGER_DIR, PZ_INSTALL_DIR, PZ_SOURCE_DIR,
# STEAM_BETA_BRANCH, JAVA_PACKAGE, BACKUP_DIR, SYNC_BACKUPS_DIR

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

    if [[ -f "$backup_path$PZ_HOME/sudoers-${PZ_USER}" ]]; then
        cp "$backup_path$PZ_HOME/sudoers-${PZ_USER}" "$PZ_HOME/sudoers-${PZ_USER}"
        chown "$PZ_USER:$PZ_USER" "$PZ_HOME/sudoers-${PZ_USER}"
    fi
}

restore_zomboid_data() {
    local backup_path="$1"
    local zip_file="$backup_path$PZ_HOME/Zomboid_Latest_Full.zip"

    [[ -f "$zip_file" ]] || return 0

    if [[ -d "$PZ_SOURCE_DIR" ]]; then
        echo ""
        echo "⚠️  ATTENTION: Le dossier de données Zomboid existe déjà"
        echo "   Chemin: $PZ_SOURCE_DIR"
        if ! confirm_action "Voulez-vous le remplacer ?"; then
            skip_step "Restauration données Zomboid"
            return 0
        fi
    fi

    echo "Restauration des données Zomboid..."
    mkdir -p "$BACKUP_DIR"
    unzip -o -q "$zip_file" -d "$BACKUP_DIR/"

    if [[ -d "$BACKUP_DIR/latest" ]]; then
        mkdir -p "$PZ_SOURCE_DIR"
        rsync -a "$BACKUP_DIR/latest/" "$PZ_SOURCE_DIR/"
        echo "Données Zomboid restaurées vers $PZ_SOURCE_DIR"
    fi

    chown -R "$PZ_USER:$PZ_USER" "$BACKUP_DIR"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_SOURCE_DIR"
}

restore_backup() {
    local backup_path="${1:-}"

    if [[ ! -d "$backup_path" ]]; then
        echo "Usage: $0 restore ${SYNC_BACKUPS_DIR}/YYYY-MM-DD_HH-MM [--force]"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$SYNC_BACKUPS_DIR" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    echo "=== Restauration : $backup_path ==="

    restore_directory "$backup_path$PZ_HOME/.ssh" "$PZ_HOME/.ssh" "$PZ_USER"

    if [[ -d "$PZ_HOME/.ssh" ]]; then
        chmod 700 "$PZ_HOME/.ssh"
        chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
    fi

    restore_directory "$backup_path$PZ_HOME/.config/systemd/user" "$PZ_HOME/.config/systemd/user" "$PZ_USER"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/.config"
    restore_scripts "$backup_path$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    restore_sudoers "$backup_path"
    restore_zomboid_data "$backup_path"

    local uid=$(id -u "$PZ_USER")
    local runtime_dir="/run/user/$uid"

    # Create runtime directory if it doesn't exist
    if [[ ! -d "$runtime_dir" ]]; then
        mkdir -p "$runtime_dir"
        chown "$PZ_USER:$PZ_USER" "$runtime_dir"
        chmod 700 "$runtime_dir"
    fi

    echo "Rechargement des services systemd..."
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user daemon-reload || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-backup.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-modcheck.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-maintenance.timer || true

    echo "=== Restauration terminée ==="
    show_summary
}

# === Install Functions ===

install_zomboid_dependencies() {
    echo "Installation des dépendances..."
    dpkg --add-architecture i386
    apt-get update -qq

    # Accept Steam license automatically
    echo steam steam/question select "I AGREE" | debconf-set-selections
    echo steam steam/license note '' | debconf-set-selections

    apt-get install -yqq lib32gcc-s1 libsdl2-2.0-0:i386 steamcmd "${JAVA_PACKAGE}"
}

download_zomboid_server() {
    echo "Téléchargement du serveur via SteamCMD..."
    mkdir -p "$PZ_INSTALL_DIR"
    chown "$PZ_USER:$PZ_USER" "$PZ_INSTALL_DIR"

    local beta_args=""
    if [[ -n "${STEAM_BETA_BRANCH:-}" ]]; then
        echo "  → Branche beta: $STEAM_BETA_BRANCH"
        beta_args="-beta $STEAM_BETA_BRANCH"
    fi

    sudo -u "$PZ_USER" /usr/games/steamcmd +force_install_dir "$PZ_INSTALL_DIR" +login anonymous +app_update 380870 $beta_args validate +quit
}

configure_zomboid_jvm() {
    [[ -f "$PZ_INSTALL_DIR/ProjectZomboid64.json" ]] || return 0
    grep -q "UseZGC" "$PZ_INSTALL_DIR/ProjectZomboid64.json" && return 0

    echo "Configuration JVM (UseZGC)..."
    sed -i 's/"-XX:-OmitStackTraceInFastThrow"/"-XX:+UseZGC",\n\t\t"-XX:-OmitStackTraceInFastThrow"/' "$PZ_INSTALL_DIR/ProjectZomboid64.json"
}

configure_user_environment() {
    grep -q "XDG_RUNTIME_DIR" "$PZ_HOME/.bashrc" && return 0

    echo "Configuration environnement utilisateur..."
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "$PZ_HOME/.bashrc"
}

install_systemd_services() {
    local systemd_dir="$PZ_HOME/.config/systemd/user"
    local templates_dir="$PZ_MANAGER_DIR/data/setupTemplates"

    echo "Installation des services systemd..."
    mkdir -p "$systemd_dir"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/.config"

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
    for unit_file in pz-backup.service pz-backup.timer pz-modcheck.service pz-modcheck.timer pz-maintenance.service pz-maintenance.timer pz-creation-date-init.service pz-creation-date-init.timer; do
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
    local runtime_dir="/run/user/$uid"

    # Create runtime directory if it doesn't exist (no active session)
    if [[ ! -d "$runtime_dir" ]]; then
        mkdir -p "$runtime_dir"
        chown "$PZ_USER:$PZ_USER" "$runtime_dir"
        chmod 700 "$runtime_dir"
    fi

    echo "Activation des services et timers..."
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user daemon-reload || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable zomboid.service || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-backup.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-modcheck.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-maintenance.timer || true
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user enable --now pz-creation-date-init.timer || true
}

create_admin_user() {
    local db_path="$PZ_SOURCE_DIR/db/servertest.db"

    # Attendre que la DB existe (créée au premier démarrage du serveur)
    if [[ ! -f "$db_path" ]]; then
        echo "  [SKIP] Base de données non trouvée (créée au premier démarrage)"
        return 0
    fi

    # Vérifier si admin existe déjà
    local exists=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM whitelist WHERE username = 'admin'" 2>/dev/null || echo "0")
    if [[ "$exists" -gt 0 ]]; then
        echo "  [SKIP] Utilisateur 'admin' existe déjà"
        return 0
    fi

    # Générer mot de passe et hash bcrypt
    local password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    local hash=$(mkpasswd -m bcrypt-a -R 12 "$password")

    # Créer l'utilisateur admin
    sqlite3 "$db_path" "INSERT INTO whitelist (username, password, accesslevel, encryptedPwd, pwdEncryptType, created_at) VALUES ('admin', '$hash', 'admin', 1, 1, datetime('now'));"

    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  Utilisateur admin créé                                ║"
    echo "  ║  Mot de passe: $password  ║"
    echo "  ║  NOTEZ-LE, il ne sera plus affiché !                   ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
}

install_zomboid() {
    echo "=== Installation serveur Project Zomboid (utilisateur: $PZ_USER) ==="

    local do_server_install=true
    local do_zomboid_init=true

    # Check existing server installation
    if [[ -d "$PZ_INSTALL_DIR" ]] && [[ -f "$PZ_INSTALL_DIR/ProjectZomboid64" ]]; then
        echo ""
        echo "ℹ️  Serveur déjà installé dans $PZ_INSTALL_DIR"
        if ! confirm_action "Voulez-vous réinstaller/mettre à jour ?"; then
            skip_step "Installation serveur PZ"
            do_server_install=false
        fi
    fi

    # Check existing Zomboid data
    if [[ -d "$PZ_SOURCE_DIR" ]]; then
        echo ""
        echo "⚠️  ATTENTION: Le dossier de données Zomboid existe déjà"
        echo "   Chemin: $PZ_SOURCE_DIR"
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
    create_admin_user

    echo ""
    echo "=== Installation terminée ==="
    show_summary

    echo ""
    echo "Prochaines étapes :"
    echo "  1. Démarrer le serveur : sudo -u $PZ_USER pzm server start"
    echo "  2. Configurer le serveur : $PZ_SOURCE_DIR/Server/servertest.ini"
}

show_help() {
    cat <<HELPEOF
Usage: $0 <commande> [--force]

Commandes :
  restore PATH  Restaurer depuis une sauvegarde (inclut sudoers)
  zomboid       Installer le serveur Project Zomboid

Options :
  --force       Ne pas demander de confirmation avant écrasement

Note: PZ_USER et chemins lus depuis scripts/.env
Pour configuration système initiale, utilisez: ./setupSystem.sh [nom_utilisateur]
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
