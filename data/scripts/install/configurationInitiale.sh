#!/bin/bash
# ------------------------------------------------------------------------------
# configurationInitiale.sh - Installation et restauration serveur PZ
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# (Lance depuis le clone en dev : avertissement non bloquant ci-dessous.)
# Helper root : ne jamais charger le .env modifiable par PZ_USER par execution
# shell en root ; parsing declaratif via lib/env_parse.sh + defauts surs. Les
# sous-commandes en sudo -u PZ_USER peuvent ensuite charger le .env normalement.
# ------------------------------------------------------------------------------
# Usage: ./configurationInitiale.sh --manager-root /home/USER/pzmanager <restore|zomboid> [--force] [--restore-ssh]
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
# Note: Prépare le secret admin utilisé au premier démarrage du jeu
# Note: identité/home du propriétaire NSS ; configuration .env déclarative.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
INSTALL_MANAGER_ROOT=""
if [[ "${1:-}" == --manager-root ]]; then
    [[ "${2:-}" == /* && "${2:-}" != *$'\n'* && "${2:-}" != *..* ]] \
        || { echo "Racine manager absolue requise." >&2; exit 1; }
    INSTALL_MANAGER_ROOT="$2"
    shift 2
fi

# Chaque composant du chemin et chaque bibliothèque doit être protégé :
# un fichier root-owned dans un répertoire remplaçable n'est pas fiable.
if [[ "${EUID:-0}" -eq 0 ]]; then
    for _trusted in "$SCRIPT_DIR" "${SCRIPT_DIR}/../lib"; do
        _trusted="$(realpath -e "$_trusted")"
        while [[ "$_trusted" != / ]]; do
            [[ "$(stat -c %u "$_trusted")" == 0 && $(( 8#$(stat -c %a "$_trusted") & 0022 )) == 0 ]] \
                || { echo "ERREUR: chemin helper root non fiable : $_trusted" >&2; exit 1; }
            _trusted="$(dirname "$_trusted")"
        done
    done
    [[ -z "$(find "$SCRIPT_DIR" "${SCRIPT_DIR}/../lib" "${SCRIPT_DIR}/../../setupTemplates" \( -type l -o ! -uid 0 -o -perm /0022 \) -print -quit)" ]] \
        || { echo "ERREUR: helpers root modifiables par un tiers." >&2; exit 1; }
    unset _trusted
fi
source "${SCRIPT_DIR}/../lib/common.sh"
# common déduit la racine du CODE ; ce helper administre une installation
# distincte, explicitement désignée (jamais déduite de /usr/local).
if [[ -n "$INSTALL_MANAGER_ROOT" ]]; then
    PZ_MANAGER_ROOT="$INSTALL_MANAGER_ROOT"
fi

# Refus fail-closed en root (C15) : un helper non owned root exécuté en root
# meurt au lieu d'avertir. Hors root (dev/test), simple avertissement.
warn_if_not_root_owned() {
    local target="${1:-$0}" owner=""
    owner="$(stat -c %U "$target" 2>/dev/null || echo unknown)"
    if [[ "$owner" != "root" ]]; then
        if [[ "${EUID:-0}" -eq 0 ]]; then
            die "Helper root $target non owned root (owner=$owner) ; attendu /usr/local/libexec/pzmanager/ root:root 0755."
        fi
        echo "[WARN] Helper root $target non owned root (owner=$owner) ; attendu /usr/local/libexec/pzmanager/ root:root 0755." >&2
    fi
    return 0
}

# Contexte root : NE PAS executer le .env modifiable. Parsing declaratif
# uniquement, puis defauts surs (n'ecrasent jamais une valeur validee).
load_root_env_declarative() {
    local env_file="${PZ_MANAGER_ROOT:-}/.env"
    [[ -n "${PZ_MANAGER_ROOT:-}" ]] || env_file="/home/pzuser/pzmanager/.env"
    # Seed declarative path references from NSS, then validate declarations
    # against the same identity below. Never derive a manager home from root.
    local manager_uid manager_name manager_home
    if [[ -n "$INSTALL_MANAGER_ROOT" ]]; then
        manager_uid="$(stat -c %u "$INSTALL_MANAGER_ROOT")" || die "Installation absente."
        [[ "$manager_uid" != 0 ]] || die "L'installation doit appartenir au manager non root."
        manager_name="$(getent passwd "$manager_uid" | cut -d: -f1)"
        manager_home="$(getent passwd "$manager_uid" | cut -d: -f6)"
        [[ "$manager_name" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$manager_home" == /* ]] \
            || die "Identité manager introuvable."
        : "${PZ_USER:=$manager_name}" "${PZ_HOME:=$manager_home}"
    fi
    if [[ -f "$env_file" ]]; then
        if grep -qE '\$\(|`|;' "$env_file" 2>/dev/null; then
            echo "[WARN] $env_file contient '\$()' / backtick / ';' : contenu non execute, valeurs validees uniquement." >&2
        fi
    fi
    local lib1="${SCRIPT_DIR}/../lib/env_parse.sh"
    # shellcheck disable=SC1090
    . "$lib1"
    if declare -F parse_env_declarative >/dev/null 2>&1; then
        if [[ -f "$env_file" ]]; then
            parse_env_declarative "$env_file" || die "Profil déclaratif invalide : restauration/installation refusée."
        fi
    fi
    if [[ -n "$INSTALL_MANAGER_ROOT" ]]; then
        [[ "${PZ_USER:-$manager_name}" == "$manager_name" && "${PZ_HOME:-$manager_home}" == "$manager_home" ]] \
            || die "Identité/home déclarés incompatibles avec le propriétaire de l'installation."
        [[ "${PZ_MANAGER_USER:-$manager_name}" == "$manager_name" && "${PZ_GAME_USER:-$manager_name}" == "$manager_name" ]] \
            || die "Les identités jeu/manager doivent correspondre au propriétaire de l'installation."
        PZ_USER="$manager_name"
        PZ_HOME="$manager_home"
        PZ_MANAGER_DIR="$INSTALL_MANAGER_ROOT"
    fi
    : "${PZ_USER:=pzuser}"
    : "${PZ_HOME:=/home/${PZ_USER}}"
    # C17 (split-users) : défaut = PZ_USER pour les deux (mono-user inchangé).
    : "${PZ_GAME_USER:=${PZ_USER}}"
    : "${PZ_MANAGER_USER:=${PZ_USER}}"
    : "${PZ_GAME_HOME:=/home/${PZ_GAME_USER}}"
    : "${PZ_MANAGER_HOME:=/home/${PZ_MANAGER_USER}}"
    : "${PZ_MANAGER_DIR:=${INSTALL_MANAGER_ROOT:-${PZ_HOME}/pzmanager}}"
    : "${PZ_DATA_DIR:=${PZ_MANAGER_DIR}/data}"
    : "${PZ_INSTALL_DIR:=${PZ_DATA_DIR}/pzserver}"
    : "${PZ_SOURCE_DIR:=${PZ_MANAGER_DIR}/Zomboid}"
    : "${PZ_SERVER_NAME:=servertest}"
    : "${PZ_SERVICE_NAME:=zomboid.service}"
    local profile_path
    for profile_path in PZ_DATA_DIR PZ_INSTALL_DIR PZ_SOURCE_DIR; do
        [[ "${!profile_path}" == /* && "${!profile_path}" != *'..'* && "${!profile_path}" != *$'\n'* ]] \
            || die "Chemin métier absolu requis : $profile_path."
    done
    [[ "$PZ_SERVICE_NAME" =~ ^[A-Za-z0-9_.@:-]+\.service$ && "$PZ_SERVICE_NAME" != -* \
       && "$PZ_SERVER_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "Unité ou nom de monde invalide."
    local expected_db="${PZ_SOURCE_DIR}/db/${PZ_SERVER_NAME}.db"
    local expected_ini="${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}.ini"
    [[ "${PZ_DB_PATH:-$expected_db}" == "$expected_db" && "${PZ_INI_PATH:-$expected_ini}" == "$expected_ini" ]] \
        || die "PZ_DB_PATH/PZ_INI_PATH contradictoires avec le monde configuré : supprimer ces anciennes surcharges."
    PZ_DB_PATH="$expected_db"
    PZ_INI_PATH="$expected_ini"
    : "${STEAMCMD_PATH:=/usr/games/steamcmd}"
    : "${STEAM_APP_ID:=380870}"
    : "${STEAM_BETA_BRANCH:=}"
    : "${STEAM_LOGIN:=}"
    : "${JAVA_VERSION:=25}"
    : "${JAVA_PACKAGE:=openjdk-${JAVA_VERSION}-jre-headless}"
    : "${JAVA_PATH:=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64}"
    : "${PZ_JDK_SOURCE:=debian}"
    : "${BACKUP_DIR:=${PZ_DATA_DIR}/dataBackups}"
    : "${SYNC_BACKUPS_DIR:=${PZ_DATA_DIR}/fullBackups}"
    export PZ_USER PZ_GAME_USER PZ_MANAGER_USER PZ_GAME_HOME PZ_MANAGER_HOME PZ_HOME PZ_MANAGER_DIR PZ_DATA_DIR PZ_INSTALL_DIR PZ_SOURCE_DIR \
        PZ_SERVER_NAME PZ_SERVICE_NAME PZ_DB_PATH PZ_INI_PATH \
        STEAMCMD_PATH STEAM_APP_ID STEAM_BETA_BRANCH STEAM_LOGIN \
        JAVA_VERSION JAVA_PACKAGE JAVA_PATH PZ_JDK_SOURCE \
        BACKUP_DIR SYNC_BACKUPS_DIR
}

if [[ "${EUID:-0}" -eq 0 ]]; then
    load_root_env_declarative
    warn_if_not_root_owned || true
fi

# Toutes ces variables viennent du .env via parsing declaratif (contexte root)
# PZ_USER, PZ_HOME, PZ_MANAGER_DIR, PZ_INSTALL_DIR, PZ_SOURCE_DIR,
# STEAM_BETA_BRANCH, JAVA_PACKAGE, BACKUP_DIR, SYNC_BACKUPS_DIR

FORCE_MODE=false
# C16 : restauration du .ssh EXPLICITE (opt-in --restore-ssh, défaut NON).
RESTORE_SSH=false
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

# Après le premier changement d'UID, exécuter directement : sudo fermerait
# les descripteurs WORLD/SERVERCTL hérités par les helpers et leurs descendants.
as_manager() {
    if [[ "$(id -un)" == "$PZ_USER" ]]; then "$@"; else sudo -u "$PZ_USER" "$@"; fi
}

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
# Réservée AUX TIMERS (enable_automation_timers) : les étapes critiques
# (daemon-reload, enable zomboid.service) passent par user_systemctl_strict +
# fail_on_error ci-dessous et MEURENT sur échec (C11).
user_systemctl() {
    local runtime_dir="$1"; shift
    as_manager env XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@" || true
}

# Variante stricte pour les étapes critiques : ne masque rien, le code retour
# réel est renvoyé à l'appelant qui le vérifie via fail_on_error (C11).
user_systemctl_strict() {
    local runtime_dir="$1"; shift
    as_manager env XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@"
}

# Meurt si l'étape critique précédente a échoué : une installation partielle
# n'est jamais annoncée réussie (C11). Usage SOUS `set -e` :
#   etape || fail_on_error $? "message"
# (un simple `etape; fail_on_error $?` serait inatteignable : errexit tue le
# shell avant la vérification). Le `||` ci n'est PAS un masquage : il mène à
# die, contrairement au `|| true` réservé aux timers (voir user_systemctl).
fail_on_error() {
    local rc="$1"; shift
    (( rc == 0 )) || die "$* (code ${rc})"
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
    if [[ -n "$owner" ]]; then
        sudo -u "$owner" mkdir -p "$dest"
        sudo -u "$owner" rsync -a "$src/" "$dest/"
    else
        mkdir -p "$dest"
        rsync -a "$src/" "$dest/"
    fi
}

restore_scripts() {
    local src="$1" dest="$2" owner="${3:-}"
    restore_directory "$src" "$dest" "$owner"
    sudo -u "${owner:-$PZ_USER}" chmod +x "$dest"/*.sh 2>/dev/null || true
}

# C16 : le sudoers de l'archive n'est JAMAIS installé (même syntaxiquement
# valide : il peut être modifié/élargi). On le refuse et on régénère depuis le
# template root-owned via install_sudoers().
refuse_sudoers_from_backup() {
    local backup_path="$1"

    if [[ -d "$backup_path/etc/sudoers.d" ]] || [[ -f "$backup_path$PZ_HOME/sudoers-${PZ_USER}" ]]; then
        echo "sudoers non restauré, régénéré depuis le template (install_sudoers)." >&2
    fi
}

# C16 : régénération du sudoers depuis le template (reprise d'install_sudoers
# de setupSystem.sh, qui reste la référence à l'installation). Dest
# surchargeable (PZ_SUDOERS_DEST) pour les tests.
install_sudoers() {
    local templates_dir="${SCRIPT_DIR}/../../setupTemplates"
    local template="${templates_dir}/pzuser-sudoers"
    local dest="${PZ_SUDOERS_DEST:-/etc/sudoers.d/${PZ_USER}}"

    if [[ ! -f "$template" ]]; then
        echo "[ERROR] Template sudoers introuvable: $template" >&2
        return 1
    fi

    # Temporaire privé sur le même FS : validation et permissions précèdent la
    # publication atomique, sans altérer le sudoers précédent en cas d'échec.
    local staged
    staged="$(mktemp "$(dirname "$dest")/.${PZ_USER}-sudoers.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -f '${staged}'" RETURN
    sed -e "s|__PZ_USER__|${PZ_USER}|g" -e "s|__PZ_HOME__|${PZ_HOME}|g" "$template" > "$staged" || return 1

    if visudo -cf "$staged"; then
        chown root:root -- "$staged" || return 1
        chmod 440 -- "$staged" || return 1
        mv -fT -- "$staged" "$dest" || return 1
        echo "[INFO] Sudoers installé: $dest"
    else
        echo "[ERROR] Fichier sudoers invalide, installation annulée" >&2
        return 1
    fi
}

# C16 : les unités systemd de l'archive ne sont JAMAIS restaurées (un ExecStart
# depuis une archive = exécution de code au prochain daemon-reload). On les
# ignore et on régénère depuis les templates via install_systemd_services(),
# comme le sudoers (refuse + régénère).
refuse_systemd_units_from_backup() {
    local backup_path="$1"

    if [[ -d "$backup_path$PZ_HOME/.config/systemd/user" ]]; then
        echo "unités systemd non restaurées depuis l'archive, régénérées depuis les templates (install_systemd_services)." >&2
    fi
}

# C16 : validation d'un arbre .ssh avant installation. Meurt au premier refus
# (fail-closed) : les formes à options (from=, ...) sont refusées avec le
# reste — seul le nu `ssh-*/sk-* <clé> [commentaire]` passe, les besoins
# spéciaux repassent par un appel conscient en --restore-ssh.
validate_ssh_tree() {
    local src="$1" f base line
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        case "$base" in
            authorized_keys|known_hosts|config|*.pub) ;;
            id_*|*_ed25519|*_rsa|*_ecdsa|*_dsa|identity|identity_*)
                [[ "${PZ_RESTORE_PRIVATE_KEYS:-0}" == "1" ]] \
                    || die "Clé privée SSH refusée ($base) : PZ_RESTORE_PRIVATE_KEYS=1 pour l'autoriser."
                ;;
        esac
    done < <(find "$src" -type f -print0)

    if [[ -f "$src/authorized_keys" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^(ssh-[A-Za-z0-9-]+|sk-[A-Za-z0-9-]+|ecdsa-sha2-[A-Za-z0-9-]+)[[:space:]] ]] \
                || die "Ligne authorized_keys refusée (forme à options ou type inconnu) : ${line:0:60}..."
            # Options dangereuses : exécution forcée ou ouverture réseau.
            if [[ "$line" =~ [Cc][Oo][Mm][Mm][Aa][Nn][Dd]= ]] || [[ "$line" =~ [Pp][Ee][Rr][Mm][Ii][Tt][Oo][Pp][Ee][Nn] ]]; then
                die "Ligne authorized_keys refusée (command=/permitopen) : ${line:0:60}..."
            fi
        done < "$src/authorized_keys"
    fi

    if [[ -f "$src/config" ]]; then
        grep -qiE '^[[:space:]]*(ProxyCommand|PermitLocalCommand)' "$src/config" \
            && die "Directive SSH refusée dans config (ProxyCommand/PermitLocalCommand)."
    fi
}

# C16 : restauration du .ssh EXPLICITE (opt-in --restore-ssh, défaut NON).
restore_ssh_opt_in() {
    local cfg_root="$1"
    if [[ "${RESTORE_SSH:-false}" != true ]]; then
        echo "[INFO] .ssh non restauré (opt-in --restore-ssh absent)."
        return 0
    fi
    local src="$cfg_root$PZ_HOME/.ssh"
    if [[ ! -d "$src" ]]; then
        echo "[INFO] .ssh absent du backup, rien à restaurer."
        return 0
    fi
    validate_ssh_tree "$src"
    restore_directory "$src" "$PZ_HOME/.ssh" "$PZ_USER"
    if [[ -d "$PZ_HOME/.ssh" ]]; then
        as_manager chmod 700 "$PZ_HOME/.ssh"
        as_manager chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
    fi
    echo "[INFO] .ssh restauré et validé."
}

# C16 : validation d'une archive de restauration AVANT extraction
# (fail-closed). Refuse : archive invalide, chemins absolus, `..` traversal,
# top-level hors whitelist (config/, zomboid/ seuls), symlinks. En cas de
# doute -> die. L'extraction reste vers un staging tmp (jamais vers /, /home,
# /etc directement), suivi d'une install contrôlée (ssh opt-in, sudoers
# régénéré, rsync validé).
validate_restore_archive() {
    local archive="$1"
    command -v unzip &>/dev/null || die "unzip non installé (nécessaire pour restaurer un ZIP)."
    unzip -t "$archive" >/dev/null 2>&1 \
        || die "Archive invalide (${archive}, unzip -t en échec) : rien n'est restauré."
    local listing name top part
    local -a parts
    listing="$(unzip -l "$archive")" \
        || die "Lecture de l'archive impossible (${archive}) : rien n'est restauré."
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == /* ]] && die "Chemin absolu refusé dans l'archive ($name) : rien n'est restauré."
        IFS='/' read -ra parts <<< "$name"
        for part in "${parts[@]}"; do
            [[ "$part" == ".." ]] && die "Traversal '..' refusé dans l'archive ($name) : rien n'est restauré."
        done
        top="${name%%/*}"
        [[ "$top" == "config" || "$top" == "zomboid" ]] \
            || die "Entrée hors whitelist refusée dans l'archive ($name, attendu config/ ou zomboid/) : rien n'est restauré."
    done < <(printf '%s\n' "$listing" | awk '/^ *[0-9]+ +[0-9-]+ +[0-9:]+ / { $1=""; $2=""; $3=""; sub(/^ +/, ""); print }')
    # Symlinks : unzip -l ne les signale pas, contrôle via zipinfo python si
    # présent ; sans python3, doute -> die (le contrôle noms seul ne suffit pas).
    if command -v python3 &>/dev/null; then
        python3 - "$archive" <<'PYEOF' \
            || die "Symlink dangereux dans l'archive : rien n'est restauré."
import sys, zipfile, stat
z = zipfile.ZipFile(sys.argv[1])
import pathlib
bad = []
for i in z.infolist():
    p = pathlib.PurePosixPath(i.filename)
    mode = i.external_attr >> 16
    if (p.is_absolute() or '..' in p.parts or not p.parts
            or p.parts[0] not in ('config', 'zomboid') or '\\' in i.filename
            or stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
        bad.append(i.filename)
if bad:
    print("symlinks refuses: %s" % ", ".join(bad))
    sys.exit(1)
PYEOF
    else
        die "python3 indisponible : vérification symlinks impossible, restauration refusée."
    fi
}

# Les métadonnées systemd précèdent le routage dans pz.slice, jamais les
# données/config de l'archive. L'absence doit être prouvée sur un bus joignable.
restore_service_load_state() {
    local runtime="$1" output key value probe
    local -A fields=()
    output="$(as_manager env XDG_RUNTIME_DIR="$runtime" systemctl --user show \
        "${PZ_SERVICE_NAME:-zomboid.service}" -p LoadState,ActiveState,SubState,MainPID,ControlPID)" \
        || die "Serveur non prouvé arrêté : lecture du bus refusée."
    [[ -n "$output" ]] || die "Serveur non prouvé arrêté : bus indisponible."
    while IFS='=' read -r key value; do
        case "$key" in LoadState|ActiveState|SubState|MainPID|ControlPID) ;; *) die "Serveur non prouvé arrêté : état systemd incomplet." ;; esac
        [[ ! -v "fields[$key]" ]] || die "Serveur non prouvé arrêté : état systemd ambigu."
        fields[$key]="$value"
    done <<< "$output"
    [[ "${fields[ActiveState]:-}" == inactive && "${fields[SubState]:-}" == dead \
        && "${fields[MainPID]:-}" == 0 && "${fields[ControlPID]:-}" == 0 ]] \
        || die "Serveur non prouvé arrêté : restauration refusée (état ${fields[ActiveState]:-inconnu})."
    case "${fields[LoadState]:-}" in
        loaded) ;;
        not-found)
            probe="$(as_manager env XDG_RUNTIME_DIR="$runtime" systemctl --user show -p Version)" \
                || die "Bus utilisateur indisponible : restauration refusée."
            [[ "$probe" == Version=?* && "$probe" != *$'\n'* ]] \
                || die "Bus utilisateur non prouvé joignable : restauration refusée."
            ;;
        *) die "Unité serveur non vérifiable : restauration refusée." ;;
    esac
    printf '%s\n' "${fields[LoadState]}"
}

prepare_restore_units() {
    local runtime load slice_load templates="${SCRIPT_DIR}/../../setupTemplates"
    local destination="$PZ_HOME/.config/systemd/user"
    runtime="$(ensure_runtime_dir)"
    load="$(restore_service_load_state "$runtime")" || return 1
    slice_load="$(as_manager env XDG_RUNTIME_DIR="$runtime" systemctl --user show pz.slice -p LoadState --value)" \
        || die "Lecture pz.slice refusée."
    case "$slice_load" in
        loaded|not-found) ;;
        *) die "État pz.slice ambigu : restauration refusée." ;;
    esac
    if [[ "$load" == not-found || "$slice_load" == not-found ]]; then
        as_manager mkdir -p "$destination" || die "Création du répertoire des unités impossible."
        if [[ "$load" == not-found ]]; then
            # Ne pas installer/activer la socket, le logger ou les timers ici.
            as_manager cp "$templates/zomboid.service" "$destination/zomboid.service" || die "Préparation unité serveur impossible."
        fi
        if [[ "$slice_load" == not-found ]]; then
            as_manager cp "$templates/pz.slice" "$destination/pz.slice" || die "Préparation pz.slice impossible."
        fi
        as_manager env XDG_RUNTIME_DIR="$runtime" systemctl --user daemon-reload \
            || die "Rechargement des unités de restauration impossible."
        [[ "$(restore_service_load_state "$runtime")" == loaded ]] \
            || die "Unité serveur non chargée après préparation : restauration refusée."
    fi
}

prepare_restore_game_source() {
    # $1 = racine de config du backup ; $2 (optionnel) = dossier des données de jeu
    # déjà extraites (nouveau format ZIP : zomboid/ = Saves/db/Server/Lua). Si $2 est
    # vide, on retombe sur l'ancien format (zip interne Zomboid_Latest_Full.zip).
    local cfg_root="$1" game_root="${2:-}"
    local src=""

    if [[ -n "$game_root" && -d "$game_root" ]]; then
        src="$game_root"
    else
        local zip_file="$cfg_root$PZ_HOME/Zomboid_Latest_Full.zip"
        [[ -f "$zip_file" ]] || return 0
        # L'ancien ZIP est lui aussi extrait uniquement en staging privé.
        src="$(mktemp -d "$cfg_root/.legacy-world-XXXXXXXX")" || die "Staging de l'ancien ZIP impossible."
        python3 - "$zip_file" "$src" <<'PYZIP' || die "Ancienne archive invalide."
import pathlib, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for entry in archive.infolist():
        path = pathlib.PurePosixPath(entry.filename)
        mode = entry.external_attr >> 16
        if (path.is_absolute() or '..' in path.parts or '\\' in entry.filename
                or not path.parts or path.parts[0] != 'latest'
                or stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
            raise ValueError('Chemin ancien ZIP refusé: ' + entry.filename)
    archive.extractall(sys.argv[2])
PYZIP
        src="$src/latest"
    fi

    [[ -n "$src" && -d "$src" ]] || return 0
    printf '%s\n' "$src"
}

restore_zomboid_data() {
    local src="${2:-}"
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

    echo "Restauration transactionnelle des données Zomboid..."
    # Figer le code AVANT restore_scripts. Seul le manager exécute cette copie ;
    # le .env est un snapshot déclaratif, jamais le shell archivé.
    local runtime_root key
    runtime_root="$(mktemp -d /tmp/pzmanager-restore-runtime-XXXXXXXX)" || die "Staging du métier impossible."
    mkdir -m 0700 "$runtime_root/data" || die "Répertoire du métier impossible."
    cp -a "${SCRIPT_DIR}/.." "$runtime_root/data/scripts" || die "Copie du métier impossible."
    : > "$runtime_root/.env"
    for key in PZ_USER PZ_HOME PZ_MANAGER_DIR PZ_DATA_DIR PZ_SOURCE_DIR PZ_INSTALL_DIR \
        PZ_SERVER_NAME PZ_SERVICE_NAME PZ_DB_PATH PZ_INI_PATH PZ_GAME_USER PZ_MANAGER_USER PZ_GAME_HOME PZ_MANAGER_HOME; do
        [[ -v "$key" ]] || continue
        printf 'export %s=%q\n' "$key" "${!key}" >> "$runtime_root/.env"
    done
    cp -a -- "$src" "$runtime_root/source" || die "Copie de la source impossible."
    src="$runtime_root/source"
    chown -R "$PZ_USER:$PZ_USER" "$runtime_root" || die "Identité du staging impossible."
    chmod -R u+rwX,go-rwx "$runtime_root" || die "Protection du staging impossible."
    local status=0
    # Un cwd root privé (/root, par exemple) empêche find de revenir à son
    # répertoire initial après le changement d'UID.
    (cd / && as_manager env XDG_RUNTIME_DIR="$(ensure_runtime_dir)" \
        bash "$runtime_root/data/scripts/backup/restoreZomboidData.sh" "$src") || status=$?
    rm -rf -- "$runtime_root"
    (( status == 0 )) || die "Restauration transactionnelle refusée (code $status)."
}

restore_backup() {
    [[ "${PZ_GAME_USER:-$PZ_USER}" == "${PZ_MANAGER_USER:-$PZ_USER}" ]] \
        || die "Budget PZ partagé : split multi-UID non pris en charge, aucun fichier modifié."
    # Flags dans tout ordre : restore PATH [--force] [--restore-ssh].
    local backup_path="" arg
    for arg in "$@"; do
        case "$arg" in
            --restore-ssh) RESTORE_SSH=true ;;
            --force) FORCE_MODE=true ;;
            *) [[ -z "$backup_path" ]] && backup_path="$arg" ;;
        esac
    done
    local cfg_root game_root="" tmp_extract=""

    if [[ -f "$backup_path" && "$backup_path" == *.zip ]]; then
        # Nouveau format : UN seul ZIP (config/ + zomboid/). Validé AVANT
        # extraction (C16), extrait vers un staging tmp (jamais vers /, /home,
        # /etc directement), puis install contrôlée (voir validate ci-dessus).
        validate_restore_archive "$backup_path"
        tmp_extract="$(mktemp -d /tmp/pzmanager-restore-XXXXXXXX)" || die "Staging de restauration impossible."
        trap 'rm -rf -- "${tmp_extract:-}" 2>/dev/null || true' RETURN EXIT
        echo "Extraction de l'archive : $backup_path ..."
        unzip -o -q "$backup_path" -d "$tmp_extract" || die "Extraction de restauration impossible."
        cfg_root="$tmp_extract/config"
        [[ -d "$tmp_extract/zomboid" ]] && game_root="$tmp_extract/zomboid"
    elif [[ -d "$backup_path" ]]; then
        # Ancien format : dossier fullBackups/<ts>/ (config en vrac + zip interne).
        tmp_extract="$(mktemp -d /tmp/pzmanager-restore-XXXXXXXX)" || die "Staging de restauration impossible."
        trap 'rm -rf -- "${tmp_extract:-}" 2>/dev/null || true' RETURN EXIT
        cp -a -- "$backup_path/." "$tmp_extract/" || die "Copie de restauration impossible."
        cfg_root="$tmp_extract"
    else
        echo "Usage: $0 restore ${SYNC_BACKUPS_DIR}/YYYY-MM-DD_HH-MM-SS-<pid>.zip [--force] [--restore-ssh]"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$SYNC_BACKUPS_DIR" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    # Aucun lien ni fichier spécial n'atteint les copies privilégiées.
    if [[ -n "$(find "$cfg_root" ! -type d ! -type f -print -quit 2>/dev/null)" ]]; then
        die "Arbre de restauration non régulier : aucun fichier restauré."
    fi
    echo "=== Restauration : $backup_path ==="

    if [[ "$RESTORE_SSH" == true && -d "$cfg_root$PZ_HOME/.ssh" ]]; then
        validate_ssh_tree "$cfg_root$PZ_HOME/.ssh"
    fi
    game_root="$(prepare_restore_game_source "$cfg_root" "$game_root")" \
        || die "Source de restauration refusée avant préparation des unités."
    prepare_restore_units || die "Préflight restauration refusé avant mutation du monde."
    # Le métier doit réussir avant tout remplacement de code/configuration.
    restore_zomboid_data "$cfg_root" "$game_root"

    # Les copies vers le home se font sans privilège, y compris pour des
    # archives dont les fichiers ont des modes privés.
    chown -R "$PZ_USER:$PZ_USER" "$tmp_extract"
    restore_ssh_opt_in "$cfg_root"

    refuse_systemd_units_from_backup "$cfg_root"
    install_systemd_services
    restore_scripts "$cfg_root$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    refuse_sudoers_from_backup "$cfg_root"
    install_sudoers

    local runtime_dir
    runtime_dir="$(ensure_runtime_dir)"

    echo "Rechargement des services systemd..."
    # Critique (C11) : un rechargement en échec laisse des unités périmées.
    user_systemctl_strict "$runtime_dir" daemon-reload \
        || fail_on_error $? "daemon-reload systemd --user"
    enable_automation_timers "$runtime_dir"

    echo "=== Restauration terminée ==="
    show_summary
}

# === Install Functions ===

install_zomboid_dependencies() {
    echo "Installation des dépendances..."
    # C14 (matrice OS/JDK) : ne jamais supposer que JAVA_VERSION existe dans
    # les depots de l'OS — resolve le triple effectif (avec repli loggue),
    # puis controle le binaire EFFECTIF apres install (die si mismatch).
    source "${SCRIPT_DIR}/../lib/jdk_matrix.sh"
    dpkg --add-architecture i386
    apt-get update -qq
    resolve_java_package
    # steamcmd n'est pas dans les dépôts de base : ne pas modifier les sources
    # APT automatiquement, expliquer le prérequis avant toute installation.
    if ! LC_ALL=C apt-cache policy steamcmd | awk '$1 == "Candidate:" && $2 != "(none)" { found=1 } END { exit !found }'; then
        die "Paquet steamcmd indisponible : activer manuellement non-free sur Debian ou multiverse sur Ubuntu, puis actualiser APT."
    fi

    # Accept Steam license automatically
    echo steam steam/question select "I AGREE" | debconf-set-selections
    echo steam steam/license note '' | debconf-set-selections

    apt-get install -yqq lib32gcc-s1 libsdl2-2.0-0:i386 steamcmd "${JAVA_PACKAGE}"
    if declare -F verify_java_version >/dev/null 2>&1; then
        verify_java_version "${JAVA_VERSION}"
    else
        [[ -d "${JAVA_PATH}" ]] || die "Java non installé"
    fi
}

download_zomboid_server() {
    echo "Téléchargement du serveur via SteamCMD..."
    as_manager mkdir -p "$PZ_INSTALL_DIR"

    # -beta TOUJOURS explicite, y compris "public" : omettre l'option laisse la
    # BetaKey précédente figée dans le manifeste, ce qui avait provoqué la boucle
    # de mises à jour du 05/08/2026. performFullMaintenance.sh le documente et le
    # fait déjà ; l'installation faisait l'inverse et rejouait donc le bug sur une
    # machine neuve. La ligne est interpolée dans le runscript (citée) plutôt
    # qu'en tableau argv : le login n'y est jamais visible via /proc ou ps.
    local branch; branch="$(steam_beta_branch)"
    echo "  → Branche Steam: ${branch}"

    # STEAMCMD_PATH / STEAM_APP_ID viennent du .env comme partout ailleurs, au
    # lieu d'être écrits en dur ici seulement.
    # Login hors argv : runscript 0600 confié à PZ_USER puis exécuté sous son
    # identité (ce script tourne en root, steamcmd sous PZ_USER).
    steamcmd_runscript "${STEAM_LOGIN:-anonymous}" \
        "force_install_dir \"${PZ_INSTALL_DIR}\"" \
        "login \"${STEAM_LOGIN:-anonymous}\"" \
        "app_update \"${STEAM_APP_ID:-380870}\" -beta \"${branch}\" validate"
}

# Un code retour Steam réussi ne garantit pas un téléchargement utilisable.
# Inspection de fichiers seulement : aucune JVM ni lanceur n'est exécuté ici.
validate_zomboid_payload() {
    local file
    [[ -d "$PZ_INSTALL_DIR/jre64" && ! -L "$PZ_INSTALL_DIR/jre64" && \
       -d "$PZ_INSTALL_DIR/jre64/bin" && ! -L "$PZ_INSTALL_DIR/jre64/bin" ]] \
        || die "Payload Steam incomplet ou invalide : JRE stock absent ou symbolique."
    for file in ProjectZomboid64 start-server.sh jre64/bin/java; do
        [[ -f "$PZ_INSTALL_DIR/$file" && ! -L "$PZ_INSTALL_DIR/$file" && -x "$PZ_INSTALL_DIR/$file" ]] \
            || die "Payload Steam incomplet ou invalide : exécutable $file absent ou non régulier."
    done
    python3 - "$PZ_INSTALL_DIR/ProjectZomboid64.json" <<'PAYLOAD'
import json, pathlib, sys
try:
    path = pathlib.Path(sys.argv[1])
    if path.is_symlink() or not path.is_file():
        raise ValueError("JSON absent ou non régulier")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("mainClass"), str) or not data["mainClass"]:
        raise ValueError("mainClass absent ou invalide")
    for key in ("classpath", "vmArgs"):
        if not isinstance(data.get(key), list) or any(not isinstance(value, str) for value in data[key]):
            raise ValueError(key + " doit être une liste de chaînes")
    if not data["classpath"] or any(not entry for entry in data["classpath"]):
        raise ValueError("classpath vide")
except (OSError, ValueError) as error:
    print("Payload Steam incomplet ou invalide : " + str(error), file=sys.stderr)
    raise SystemExit(1)
PAYLOAD
}

configure_zomboid_jvm() {
    # Tuning JVM partagé avec la maintenance (steamcmd validate restaure le
    # JSON vanilla à chaque update, le script est donc réappliqué chaque nuit)
    as_manager "${PZ_MANAGER_DIR}/data/scripts/internal/configureJvm.sh"
}

configure_user_environment() {
    local bashrc="$PZ_HOME/.bashrc"
    as_manager grep -q "XDG_RUNTIME_DIR" "$bashrc" 2>/dev/null && return 0

    echo "Configuration environnement utilisateur..."
    printf '%s\n' 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' \
        | as_manager tee -a -- "$bashrc" >/dev/null
}

install_systemd_services() {
    local systemd_dir="$PZ_HOME/.config/systemd/user"
    local templates_dir="${SCRIPT_DIR}/../../setupTemplates"

    echo "Installation des services systemd..."
    as_manager mkdir -p "$systemd_dir"

    # Un plafond --user ne peut pas agréger deux UID distincts.
    [[ "${PZ_GAME_USER:-$PZ_USER}" == "${PZ_MANAGER_USER:-$PZ_USER}" ]] \
        || die "Budget PZ partagé : mode split multi-UID non pris en charge."
    as_manager cp "$templates_dir/pz.slice" "$systemd_dir/pz.slice"

    # Outside Zomboid so that a full restore cannot move the pending intent.
    # Create under the manager identity, with the same trusted-path checks as
    # maintenance; never repair a public or foreign directory by chmod/chown.
    as_manager python3 "${PZ_MANAGER_DIR}/data/scripts/lib/world_transaction.py" \
        init --world "$PZ_SOURCE_DIR" || die "Journal de récupération indisponible."

    # Server services
    for service_file in zomboid.service zomboid.socket zomboid_logger.service; do
        if [[ -f "$templates_dir/$service_file" ]]; then
            as_manager cp "$templates_dir/$service_file" "$systemd_dir/$service_file"
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
            as_manager cp "$templates_dir/$unit_file" "$systemd_dir/$unit_file"
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
    # Étapes critiques (C11) : le moindre échec MEURT (die, exit != 0), jamais
    # de succès partiel annoncé. Seuls les timers restent best-effort via
    # user_systemctl tolérant (documenté, invariant historique).
    user_systemctl_strict "$runtime_dir" daemon-reload \
        || fail_on_error $? "daemon-reload systemd --user"
    user_systemctl_strict "$runtime_dir" enable zomboid.service \
        || fail_on_error $? "activation zomboid.service"
    enable_automation_timers "$runtime_dir"
}

generate_admin_password() {
    local password_file="$PZ_MANAGER_DIR/.admin_password"

    # Idempotence (C11) : ne jamais écraser un mot de passe existant sauf
    # --force. Une relance d'installation conserve le secret déjà distribué.
    if [[ -s "$password_file" && "$FORCE_MODE" != true ]]; then
        echo "  → Mot de passe admin déjà présent ($password_file), conservé (relance avec --force pour régénérer)."
        return 0
    fi

    # Générer un mot de passe admin pour le premier démarrage
    local password; password="$(generate_password)"
    # Propriétaire = compte du service (PZ_MANAGER_USER, = PZ_USER en
    # mono-user) : créé par root, le fichier serait sinon root-owned et donc
    # illisible pour le service. Créer le fichier DÉJÀ en 600 : un `echo >`
    # suivi d'un chmod le laisse lisible par tous (umask 022) le temps de
    # l'écriture.
    local owner="${PZ_MANAGER_USER:-${PZ_USER:-pzuser}}"
    as_manager install -m 600 /dev/null "$password_file"
    printf '%s\n' "$password" | as_manager tee "$password_file" >/dev/null
    as_manager chmod 600 "$password_file"

    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  Mot de passe admin généré pour le premier démarrage   ║"
    echo "  ║  Mot de passe: $password  ║"
    echo "  ║  NOTEZ-LE, il ne sera plus affiché !                   ║"
    echo "  ║  Fichier: $password_file          ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
}

# Tous les chemins ReadWritePaths stricts doivent exister avant enable.
prepare_server_directories() {
    local directory
    for directory in "$PZ_INSTALL_DIR" "$PZ_SOURCE_DIR" "$PZ_MANAGER_DIR/logs" \
        "$PZ_MANAGER_DIR/logs/zomboid" "$BACKUP_DIR"; do
        as_manager mkdir -p "$directory"
        as_manager chmod 0700 "$directory"
    done
}

install_zomboid_manager() {
    local download_server="$1"
    [[ "$(id -un)" == "$PZ_USER" && "$EUID" != 0 ]] || die "Phase d'installation réservée au manager."
    acquire_world_lock --required || die "Installation : verrou monde indisponible."
    acquire_serverctl_lock_or_die
    prepare_restore_units || die "Installation : arrêt serveur non prouvé."
    if ! python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" inside; then
        exec bash "${SCRIPT_DIR}/../lib/run_in_pz_slice.sh" /bin/bash -c \
            'source "$1" --manager-root "$2"; source_env; install_zomboid_manager "$3"' \
            _ "${SCRIPT_DIR}/configurationInitiale.sh" "$PZ_MANAGER_DIR" "$download_server"
    fi
    python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" check
    [[ "$(restore_service_load_state "$XDG_RUNTIME_DIR")" == loaded ]] || die "Unité serveur non chargée."
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" check --world "$PZ_SOURCE_DIR"

    if [[ "$download_server" == true ]]; then
        # source_env recharge la préférence utilisateur ; recalculer le triple
        # effectif dans ce processus, sans modifier son .env.
        source "${SCRIPT_DIR}/../lib/jdk_matrix.sh"
        resolve_java_package
        # validate ne doit jamais suivre le lien vers un JRE externe.
        "${PZ_MANAGER_DIR}/data/scripts/internal/linkJvm.sh" --stock
        [[ ! -L "${PZ_INSTALL_DIR}/jre64" ]] || die "JRE stock non rétabli : validate interdit."
        unset STEAMCMD_AS_USER
        download_zomboid_server
        validate_zomboid_payload || die "Payload Steam incomplet ou invalide : installation refusée."
        configure_zomboid_jvm
    fi
    prepare_server_directories
    configure_user_environment
    install_systemd_services
    generate_admin_password
    enable_zomboid_service
    echo "=== Installation terminée ==="
}

install_zomboid() {
    [[ "${PZ_GAME_USER:-$PZ_USER}" == "${PZ_MANAGER_USER:-$PZ_USER}" ]] \
        || die "Budget PZ partagé : split multi-UID non pris en charge, aucun fichier modifié."
    local do_server_install=true runtime_dir
    echo "=== Installation serveur Project Zomboid (utilisateur: $PZ_USER) ==="
    if [[ -f "$PZ_INSTALL_DIR/ProjectZomboid64" ]] && ! confirm_action "Réinstaller/mettre à jour le serveur ?"; then
        do_server_install=false
    fi
    # Seuls les prérequis système s'exécutent en root, depuis le code pristine.
    loginctl enable-linger "$PZ_USER"
    runtime_dir="$(ensure_runtime_dir)"
    if [[ "$do_server_install" == true ]]; then
        install_zomboid_dependencies
    fi
    (cd / && as_manager env HOME="$PZ_HOME" TMPDIR=/tmp XDG_RUNTIME_DIR="$runtime_dir" /bin/bash -c \
        'source "$1" --manager-root "$2"; source_env; FORCE_MODE="$3"; install_zomboid_manager "$4"' \
        _ "${SCRIPT_DIR}/configurationInitiale.sh" "$PZ_MANAGER_DIR" "$FORCE_MODE" "$do_server_install")
}

show_help() {
    cat <<HELPEOF
Usage: $0 --manager-root /home/UTILISATEUR/pzmanager <commande> [--force]

Commandes :
  restore PATH [--force] [--restore-ssh]  Restaurer (sudoers régénéré depuis
    le template, .ssh seulement avec --restore-ssh après validation)
  zomboid       Installer le serveur Project Zomboid

Options :
  --force       Ne pas demander de confirmation avant écrasement

Note: PZ_USER et chemins lus depuis .env
Pour configuration système initiale, utilisez: ./setupSystem.sh [nom_utilisateur]
HELPEOF
}

# === Main ===
# Garde de sourçage (C11) : les tests sourcent ce fichier pour exercer
# generate_admin_password / enable_zomboid_service avec des mocks, sans
# exécuter le dispatch principal.
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
[[ $EUID -eq 0 ]] || die "Exécution root requise"
if [[ "${1:-}" == restore || "${1:-}" == zomboid ]]; then
    [[ -n "$INSTALL_MANAGER_ROOT" ]] || die "--manager-root CHEMIN est requis avant la commande."
fi

# Parse --force / --restore-ssh flags
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE_MODE=true
    [[ "$arg" == "--restore-ssh" ]] && RESTORE_SSH=true
done

case "${1:-}" in
    restore)   shift; restore_backup "$@" ;;
    zomboid)   install_zomboid ;;
    setup)     echo "Utilisez maintenant ./setupSystem.sh pour la configuration système" ;;
    *)         show_help ;;
esac
fi
