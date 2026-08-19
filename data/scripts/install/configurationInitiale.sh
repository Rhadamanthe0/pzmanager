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
# Note: PZ_USER et tous les chemins sont lus depuis .env
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# Toutes ces variables viennent de .env (source_env)
# PZ_USER, PZ_HOME, PZ_MANAGER_DIR, PZ_INSTALL_DIR, PZ_SOURCE_DIR,
# STEAM_BETA_BRANCH, JAVA_PACKAGE, BACKUP_DIR, SYNC_BACKUPS_DIR

FORCE_MODE=false
SKIPPED_STEPS=()

# === Utilities ===

# Timers d'automatisation, activés à l'identique à l'installation et à la
# restauration. Liste unique : deux listes séparées avaient divergé (la
# restauration oubliait pz-creation-date-init.timer, sur lequel repose la purge
# des inactifs).
readonly AUTOMATION_TIMERS=(
    pz-backup.timer
    pz-modcheck.timer
    pz-maintenance.timer
    pz-creation-date-init.timer
    pz-heapcheck.timer
    pz-stallwatch.timer
)

# Le service tourne en --user : sans session ouverte, XDG_RUNTIME_DIR n'existe
# pas et systemctl --user échoue. Renvoie le chemin sur stdout.
ensure_runtime_dir() {
    local uid runtime_dir
    uid=$(id -u "$PZ_USER")
    runtime_dir="/run/user/$uid"

    if [[ ! -d "$runtime_dir" ]]; then
        mkdir -p "$runtime_dir"
        chown "$PZ_USER:$PZ_USER" "$runtime_dir"
        chmod 700 "$runtime_dir"
    fi

    echo "$runtime_dir"
}

# systemctl --user pour PZ_USER, tolérant à l'échec (|| true) comme les appels
# qu'elle remplace : l'install ne doit pas s'arrêter sur un timer récalcitrant.
user_systemctl() {
    local runtime_dir="$1"; shift
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@" || true
}

enable_automation_timers() {
    local runtime_dir="$1" timer
    for timer in "${AUTOMATION_TIMERS[@]}"; do
        user_systemctl "$runtime_dir" enable --now "$timer"
    done
}

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
            local filename; filename="$(basename "$sudoers_file")"
            # Valider AVANT d'installer. L'ordre inverse mettait le fichier en
            # place puis mourait dessus : un sudoers invalide restait dans
            # /etc/sudoers.d/ et cassait sudo pour toute la machine.
            visudo -cf "$sudoers_file" || die "Fichier sudoers invalide: $filename"
            install -o root -g root -m 440 "$sudoers_file" "/etc/sudoers.d/$filename"
        done
    fi

    if [[ -f "$backup_path$PZ_HOME/sudoers-${PZ_USER}" ]]; then
        cp "$backup_path$PZ_HOME/sudoers-${PZ_USER}" "$PZ_HOME/sudoers-${PZ_USER}"
        chown "$PZ_USER:$PZ_USER" "$PZ_HOME/sudoers-${PZ_USER}"
    fi
}

restore_zomboid_data() {
    # $1 = racine de config du backup ; $2 (optionnel) = dossier des données de jeu
    # déjà extraites (nouveau format ZIP : zomboid/ = Saves/db/Server). Si $2 est
    # vide, on retombe sur l'ancien format (zip interne Zomboid_Latest_Full.zip).
    local cfg_root="$1" game_root="${2:-}"
    local src=""

    if [[ -n "$game_root" && -d "$game_root" ]]; then
        src="$game_root"
    else
        local zip_file="$cfg_root$PZ_HOME/Zomboid_Latest_Full.zip"
        [[ -f "$zip_file" ]] || return 0
        mkdir -p "$BACKUP_DIR"
        unzip -o -q "$zip_file" -d "$BACKUP_DIR/"
        [[ -d "$BACKUP_DIR/latest" ]] && src="$BACKUP_DIR/latest"
        chown -R "$PZ_USER:$PZ_USER" "$BACKUP_DIR"
    fi

    [[ -n "$src" && -d "$src" ]] || return 0

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
    mkdir -p "$PZ_SOURCE_DIR"
    rsync -a "$src/" "$PZ_SOURCE_DIR/"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_SOURCE_DIR"
    echo "Données Zomboid restaurées vers $PZ_SOURCE_DIR"
}

restore_backup() {
    local backup_path="${1:-}"
    local cfg_root game_root="" tmp_extract=""

    if [[ -f "$backup_path" && "$backup_path" == *.zip ]]; then
        # Nouveau format : UN seul ZIP (config/ + zomboid/). On l'extrait dans un
        # temp, puis on rejoue la restauration sur cette arborescence.
        command -v unzip &>/dev/null || die "unzip non installé (nécessaire pour restaurer un ZIP)."
        tmp_extract="$(mktemp -d)"
        trap 'rm -rf "$tmp_extract" 2>/dev/null || true' RETURN
        echo "Extraction de l'archive : $backup_path ..."
        unzip -o -q "$backup_path" -d "$tmp_extract"
        cfg_root="$tmp_extract/config"
        [[ -d "$tmp_extract/zomboid" ]] && game_root="$tmp_extract/zomboid"
    elif [[ -d "$backup_path" ]]; then
        # Ancien format : dossier fullBackups/<ts>/ (config en vrac + zip interne).
        cfg_root="$backup_path"
    else
        echo "Usage: $0 restore ${SYNC_BACKUPS_DIR}/YYYY-MM-DD_HH-MM.zip [--force]"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$SYNC_BACKUPS_DIR" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    echo "=== Restauration : $backup_path ==="

    restore_directory "$cfg_root$PZ_HOME/.ssh" "$PZ_HOME/.ssh" "$PZ_USER"

    if [[ -d "$PZ_HOME/.ssh" ]]; then
        chmod 700 "$PZ_HOME/.ssh"
        chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
    fi

    restore_directory "$cfg_root$PZ_HOME/.config/systemd/user" "$PZ_HOME/.config/systemd/user" "$PZ_USER"
    chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME/.config"
    restore_scripts "$cfg_root$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    restore_sudoers "$cfg_root"
    restore_zomboid_data "$cfg_root" "$game_root"

    local runtime_dir
    runtime_dir="$(ensure_runtime_dir)"

    echo "Rechargement des services systemd..."
    user_systemctl "$runtime_dir" daemon-reload
    enable_automation_timers "$runtime_dir"

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

    # -beta TOUJOURS explicite, y compris "public" : omettre l'option laisse la
    # BetaKey précédente figée dans le manifeste, ce qui avait provoqué la boucle
    # de mises à jour du 05/08/2026. performFullMaintenance.sh le documente et le
    # fait déjà ; l'installation faisait l'inverse et rejouait donc le bug sur une
    # machine neuve. Tableau plutôt que chaîne : plus de word-splitting implicite.
    local -a beta_args=(-beta "${STEAM_BETA_BRANCH:-public}")
    echo "  → Branche Steam: ${STEAM_BETA_BRANCH:-public}"

    # STEAMCMD_PATH / STEAM_APP_ID viennent du .env comme partout ailleurs, au
    # lieu d'être écrits en dur ici seulement.
    sudo -u "$PZ_USER" "${STEAMCMD_PATH:-/usr/games/steamcmd}" +force_install_dir "$PZ_INSTALL_DIR" \
        +login "${STEAM_LOGIN:-anonymous}" +app_update "${STEAM_APP_ID:-380870}" "${beta_args[@]}" validate +quit
}

configure_zomboid_jvm() {
    # Tuning JVM partagé avec la maintenance (steamcmd validate restaure le
    # JSON vanilla à chaque update, le script est donc réappliqué chaque nuit)
    sudo -u "$PZ_USER" "${SCRIPT_DIR}/../internal/configureJvm.sh"
}

configure_user_environment() {
    local bashrc="$PZ_HOME/.bashrc"
    grep -q "XDG_RUNTIME_DIR" "$bashrc" 2>/dev/null && return 0

    echo "Configuration environnement utilisateur..."
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "$bashrc"
    # On tourne en root : sans ce chown, un .bashrc créé par cette redirection
    # appartient à root et l'utilisateur ne peut plus le modifier.
    chown "$PZ_USER:$PZ_USER" "$bashrc"
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

    # Automation timers and services — dérivés de AUTOMATION_TIMERS plutôt que
    # réénumérés à la main : cette liste-ci et celle des timers activés avaient
    # divergé, et pz-stallwatch (le détecteur de gel, pourtant actif sur la
    # machine) n'apparaissait dans aucune des deux ni dans setupTemplates/. Une
    # réinstallation ou une restauration revenait donc sans lui, en silence.
    local -a automation_units=()
    local t
    for t in "${AUTOMATION_TIMERS[@]}"; do
        automation_units+=("${t%.timer}.service" "$t")
    done
    for unit_file in "${automation_units[@]}"; do
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
    local runtime_dir
    runtime_dir="$(ensure_runtime_dir)"

    echo "Activation des services et timers..."
    user_systemctl "$runtime_dir" daemon-reload
    user_systemctl "$runtime_dir" enable zomboid.service
    enable_automation_timers "$runtime_dir"
}

generate_admin_password() {
    local password_file="$PZ_MANAGER_DIR/.admin_password"

    # Générer un mot de passe admin pour le premier démarrage
    local password; password="$(generate_password)"
    # Créer le fichier DÉJÀ en 600 : un `echo >` suivi d'un chmod le laisse
    # lisible par tous (umask 022) le temps de l'écriture.
    install -m 600 /dev/null "$password_file"
    echo "$password" > "$password_file"

    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  Mot de passe admin généré pour le premier démarrage   ║"
    echo "  ║  Mot de passe: $password  ║"
    echo "  ║  NOTEZ-LE, il ne sera plus affiché !                   ║"
    echo "  ║  Fichier: $password_file          ║"
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
    generate_admin_password

    echo ""
    echo "=== Installation terminée ==="
    show_summary

    echo ""
    echo "Prochaines étapes :"
    echo "  1. Démarrer le serveur : sudo -u $PZ_USER pzm server start"
    echo "  2. Configurer le serveur : ${PZ_INI_PATH}"
}

show_help() {
    cat <<HELPEOF
Usage: $0 <commande> [--force]

Commandes :
  restore PATH  Restaurer depuis une sauvegarde (inclut sudoers)
  zomboid       Installer le serveur Project Zomboid

Options :
  --force       Ne pas demander de confirmation avant écrasement

Note: PZ_USER et chemins lus depuis .env
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
