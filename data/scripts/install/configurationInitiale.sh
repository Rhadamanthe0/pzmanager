#!/bin/bash
# ------------------------------------------------------------------------------
# configurationInitiale.sh - Installation et restauration serveur PZ
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# (Lance depuis le clone en dev : avertissement non bloquant ci-dessous.)
# Helper root : ne jamais charger le .env modifiable par PZ_USER par execution
# shell en root ; parsing declaratif via lib/env_parse.sh + defauts surs. Les
# sous-commandes en sudo -u PZ_USER peuvent ensuite charger le .env normalement.
# ------------------------------------------------------------------------------
# Usage: ./configurationInitiale.sh <restore|zomboid> [--force] [--restore-ssh]
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

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# C15 : garde AVANT tout sourcing. common.sh vit dans le même arbre que ce
# script : après le chown PZ_USER de l'install, root sourcerait du code
# modifiable par PZ_USER. En root, exige des helpers owned root (posés par le
# stage install.sh vers /usr/local/libexec/pzmanager/) ; sinon die
# (fail-closed). Sans die() ici (common.sh pas encore chargé) : echo + exit.
# Les bits group/other sur DrvFs/NTFS (777 d'affichage) ne sont pas probants :
# seul l'owner est discriminant (un owner non-root réécrit à volonté).
if [[ "${EUID:-0}" -eq 0 ]]; then
    _c15_owner="$(stat -c %U "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || echo unknown)"
    _c15_self="$(stat -c %U "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo unknown)"
    if [[ "${_c15_owner}" != "root" || "${_c15_self}" != "root" ]]; then
        echo "ERREUR: helper root non owned root (common.sh owner=${_c15_owner}, self owner=${_c15_self}) ; attendu /usr/local/libexec/pzmanager/ root:root." >&2
        exit 1
    fi
    unset _c15_owner _c15_self
fi
source "${SCRIPT_DIR}/../lib/common.sh"

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
    if [[ -f "$env_file" ]]; then
        if grep -qE '\$\(|`|;' "$env_file" 2>/dev/null; then
            echo "[WARN] $env_file contient '\$()' / backtick / ';' : contenu non execute, valeurs validees uniquement." >&2
        fi
    fi
    local lib1="${SCRIPT_DIR}/../lib/env_parse.sh"
    local lib2="/usr/local/libexec/pzmanager/env_parse.sh"
    if [[ -f "$lib1" ]]; then
        # shellcheck disable=SC1090
        . "$lib1"
    elif [[ -f "$lib2" ]]; then
        # shellcheck disable=SC1090
        . "$lib2"
    fi
    if declare -F parse_env_declarative >/dev/null 2>&1; then
        [[ -f "$env_file" ]] && parse_env_declarative "$env_file" || true
    fi
    : "${PZ_USER:=pzuser}"
    : "${PZ_HOME:=/home/${PZ_USER}}"
    # C17 (split-users) : défaut = PZ_USER pour les deux (mono-user inchangé).
    : "${PZ_GAME_USER:=${PZ_USER}}"
    : "${PZ_MANAGER_USER:=${PZ_USER}}"
    : "${PZ_GAME_HOME:=/home/${PZ_GAME_USER}}"
    : "${PZ_MANAGER_HOME:=/home/${PZ_MANAGER_USER}}"
    : "${PZ_MANAGER_DIR:=${PZ_HOME}/pzmanager}"
    : "${PZ_DATA_DIR:=${PZ_MANAGER_DIR}/data}"
    : "${PZ_INSTALL_DIR:=${PZ_DATA_DIR}/pzserver}"
    : "${PZ_SOURCE_DIR:=${PZ_MANAGER_DIR}/Zomboid}"
    : "${PZ_SERVER_NAME:=servertest}"
    : "${PZ_DB_PATH:=${PZ_SOURCE_DIR}/db/${PZ_SERVER_NAME}.db}"
    : "${PZ_INI_PATH:=${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}.ini}"
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
        PZ_SERVER_NAME PZ_DB_PATH PZ_INI_PATH \
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
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@" || true
}

# Variante stricte pour les étapes critiques : ne masque rien, le code retour
# réel est renvoyé à l'appelant qui le vérifie via fail_on_error (C11).
user_systemctl_strict() {
    local runtime_dir="$1"; shift
    sudo -u "$PZ_USER" XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@"
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
    mkdir -p "$dest"
    rsync -a "$src/" "$dest/"
    [[ -n "$owner" ]] && chown -R "$owner:$owner" "$dest"
}

restore_scripts() {
    local src="$1" dest="$2" owner="${3:-}"
    restore_directory "$src" "$dest" "$owner"
    chmod +x "$dest"/*.sh 2>/dev/null || true
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
        echo "[WARN] Template sudoers introuvable: $template"
        return 0
    fi

    # Générer le sudoers avec les bonnes valeurs. mktemp et non un
    # /tmp/<user>-sudoers prévisible : ce fichier est écrit par root, donc un lien
    # symbolique déposé d'avance à ce chemin connu ferait écrire root à la place
    # visée par le lien.
    local staged
    staged="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${staged}'" RETURN
    sed -e "s|__PZ_USER__|${PZ_USER}|g" -e "s|__PZ_HOME__|${PZ_HOME}|g" "$template" > "$staged"

    if visudo -cf "$staged"; then
        install -o root -g root -m 440 "$staged" "$dest"
        echo "[INFO] Sudoers installé: $dest"
    else
        echo "[ERROR] Fichier sudoers invalide, installation annulée" >&2
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
        chmod 700 "$PZ_HOME/.ssh"
        chmod 600 "$PZ_HOME/.ssh"/* 2>/dev/null || true
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
bad = [i.filename for i in z.infolist() if stat.S_ISLNK(i.external_attr >> 16)]
if bad:
    print("symlinks refuses: %s" % ", ".join(bad))
    sys.exit(1)
PYEOF
    else
        die "python3 indisponible : vérification symlinks impossible, restauration refusée."
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
        echo "Usage: $0 restore ${SYNC_BACKUPS_DIR}/YYYY-MM-DD_HH-MM-SS-<pid>.zip [--force] [--restore-ssh]"
        echo -e "\nSauvegardes disponibles :"
        ls -1t "$SYNC_BACKUPS_DIR" 2>/dev/null || echo "Aucune"
        exit 1
    fi

    echo "=== Restauration : $backup_path ==="

    restore_ssh_opt_in "$cfg_root"

    refuse_systemd_units_from_backup "$cfg_root"
    install_systemd_services
    restore_scripts "$cfg_root$PZ_HOME/pzmanager" "$PZ_HOME/pzmanager" "$PZ_USER"
    refuse_sudoers_from_backup "$cfg_root"
    install_sudoers
    restore_zomboid_data "$cfg_root" "$game_root"

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

# C17 : copie idempotente d'un arbre vers le compte jeu (rsync -a + chown),
# puis bascule le chemin historique vers un lien symbolique. Ne supprime JAMAIS
# le monde : l'original est conservé sous <chemin>.pre-split-bak.
# Usage: migrate_item_to_split <chemin> <destination> <propriétaire>.
# Retour 0 = migré ou déjà migré, 1 = migration ignorée (avertissement affiché).
migrate_item_to_split() {
    local src="$1" dst="$2" owner="$3"
    [[ -e "$src" || -L "$src" ]] || return 0
    if [[ -L "$src" ]]; then
        echo "[INFO] Déjà migré : $src"
        return 0
    fi
    if [[ ! -d "$dst" ]] || [[ -z "$(ls -A "$dst" 2>/dev/null)" ]]; then
        mkdir -p "$dst"
        rsync -a "$src/" "$dst/" || { echo "[WARN] Copie $src -> $dst impossible, migration ignorée" >&2; return 1; }
    fi
    chown -R "${owner}:${owner}" "$dst" || { echo "[WARN] chown $dst impossible, migration ignorée" >&2; return 1; }
    local bak="${src}.pre-split-bak"
    if [[ -e "$bak" || -L "$bak" ]]; then
        echo "[WARN] Sauvegarde $bak déjà présente, $src laissé en place" >&2
        return 1
    fi
    mv "$src" "$bak"
    # Si le lien échoue, on restaure l'original : les chemins historiques
    # doivent rester valides pour que l'installation continue sans dommage.
    if ! ln -s "$dst" "$src"; then
        mv "$bak" "$src" || true
        echo "[WARN] Lien $src -> $dst impossible, original restauré" >&2
        return 1
    fi
    echo "[INFO] Migré vers le compte jeu : $src -> $dst (original conservé : $bak)"
}

# C17 (split-users) : migration idempotente mono-user -> split (compte jeu
# pour la JVM, compte admin pour le reste). No-op en mono-user
# (PZ_GAME_USER == PZ_MANAGER_USER) ou si le compte jeu est absent.
# Déplace monde + serveur vers le compte jeu sans rien supprimer, resserre les
# secrets du manager. Les échecs partiels restent des avertissements : les
# chemins historiques restent valides et l'installation continue.
migrate_single_to_split() {
    local game_user="${PZ_GAME_USER:-$PZ_USER}"
    local manager_user="${PZ_MANAGER_USER:-$PZ_USER}"
    [[ "$game_user" == "$manager_user" ]] && return 0
    if ! id -u "$game_user" >/dev/null 2>&1; then
        echo "[WARN] Compte jeu $game_user absent : migration split ignorée (lancez setupSystem.sh d'abord)" >&2
        return 0
    fi
    local game_home="${PZ_GAME_HOME:-/home/${game_user}}"
    local dst_world="${game_home}/pzmanager/Zomboid"
    local dst_server="${game_home}/pzmanager/data/pzserver"
    migrate_item_to_split "$PZ_SOURCE_DIR" "$dst_world" "$game_user" || true
    migrate_item_to_split "$PZ_INSTALL_DIR" "$dst_server" "$game_user" || true
    local manager_dotenv="${PZ_MANAGER_DIR}/.env"
    local manager_ssh="${PZ_MANAGER_HOME:-$PZ_HOME}/.ssh"
    [[ -f "$manager_dotenv" ]] && chmod 0600 "$manager_dotenv" || true
    if [[ -d "$manager_ssh" ]]; then
        chmod 0700 "$manager_ssh"
        chmod 0600 "$manager_ssh"/* 2>/dev/null || true
    fi
    return 0
}

install_zomboid_dependencies() {
    echo "Installation des dépendances..."
    # C14 (matrice OS/JDK) : ne jamais supposer que JAVA_VERSION existe dans
    # les depots de l'OS — resolve le triple effectif (avec repli loggue),
    # puis controle le binaire EFFECTIF apres install (die si mismatch).
    local jdk_lib="${SCRIPT_DIR}/../lib/jdk_matrix.sh"
    if [[ -f "$jdk_lib" ]]; then
        # shellcheck disable=SC1090
        . "$jdk_lib"
    fi
    if declare -F resolve_java_package >/dev/null 2>&1; then
        resolve_java_package
    fi
    dpkg --add-architecture i386
    apt-get update -qq

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
    mkdir -p "$PZ_INSTALL_DIR"
    chown "$PZ_USER:$PZ_USER" "$PZ_INSTALL_DIR"

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
    STEAMCMD_AS_USER="$PZ_USER" steamcmd_runscript "${STEAM_LOGIN:-anonymous}" \
        "force_install_dir \"${PZ_INSTALL_DIR}\"" \
        "login \"${STEAM_LOGIN:-anonymous}\"" \
        "app_update \"${STEAM_APP_ID:-380870}\" -beta \"${branch}\" validate"
}

configure_zomboid_jvm() {
    # Tuning JVM partagé avec la maintenance (steamcmd validate restaure le
    # JSON vanilla à chaque update, le script est donc réappliqué chaque nuit)
    sudo -u "$PZ_USER" "${SCRIPT_DIR}/../internal/configureJvm.sh"
}

configure_user_environment() {
    local bashrc="$PZ_HOME/.bashrc"
    sudo -u "$PZ_USER" grep -q "XDG_RUNTIME_DIR" "$bashrc" 2>/dev/null && return 0

    echo "Configuration environnement utilisateur..."
    printf '%s\n' 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' \
        | sudo -u "$PZ_USER" tee -a -- "$bashrc" >/dev/null
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
    install -m 600 /dev/null "$password_file"
    echo "$password" > "$password_file"
    chown "$owner:$owner" "$password_file"
    chmod 600 "$password_file"

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
        migrate_single_to_split
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
