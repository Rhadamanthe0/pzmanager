#!/usr/bin/env bash
# setupSystem.sh - Configuration système initiale
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# (Lance depuis le clone par install.sh en dev : l'avertissement ci-dessous est
# donc non bloquant.) Helper root : ne jamais charger le .env (modifiable par
# PZ_USER) par execution shell ; parsing declaratif via lib/env_parse.sh.
# Crée l'utilisateur, installe les paquets requis et configure le pare-feu.
# Usage: sudo ./setupSystem.sh [nom_utilisateur] [chemin_du_.env]
# Par défaut, l'utilisateur est "pzuser" et le .env est cherché dans son home.
# Le 2e argument sert à l'installateur, qui prépare le .env dans un dossier
# temporaire AVANT que le home ne soit peuplé.

set -euo pipefail
trap 'on_error $LINENO' ERR

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly PZ_USER="${1:-pzuser}"
# PZ_USER alimente useradd et un sed/sudoers sans échappement (cf. install_sudoers)
# : refuse toute valeur hors regex avant usage, comme install.sh.
[[ "$PZ_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "[ERROR] Invalid PZ_USER '${PZ_USER}' (attendu ^[a-z_][a-z0-9_-]{0,31}$)" >&2; exit 1; }
readonly PZ_HOME="/home/${PZ_USER}"
readonly ENV_FILE="${2:-${PZ_HOME}/pzmanager/.env}"

on_error() {
    local lineno=${1:-?}
    echo "[ERROR] Échec lors de l'exécution (ligne: ${lineno})" >&2
    exit 1
}

# Non bloquant : avertit si ce helper root n'est pas owned root (install dev
# depuis clone), sans casser l'installation.
warn_if_not_root_owned() {
    local target="${1:-$0}" owner=""
    owner="$(stat -c %U "$target" 2>/dev/null || echo unknown)"
    if [[ "$owner" != "root" ]]; then
        echo "[WARN] Helper root $target non owned root (owner=$owner) ; attendu /usr/local/libexec/pzmanager/ root:root 0755." >&2
    fi
    return 0
}

require_command() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] la commande '$cmd' est requise mais introuvable" >&2; exit 1; }
}

# C17 : paramétrique pour créer le compte jeu ET le compte admin quand ils
# diffèrent. Appel sans argument = comportement historique (crée PZ_USER).
create_user() {
    local target_user="${1:-$PZ_USER}"
    require_command id
    require_command useradd
    if id -u "$target_user" >/dev/null 2>&1; then
        echo "[INFO] L'utilisateur $target_user existe déjà"
        return
    fi
    useradd -m -s /bin/bash "$target_user"
    echo "[INFO] Utilisateur $target_user créé"
}

# C17 (split-users) : crée le compte jeu (JVM seule) quand il diffère du
# compte admin, plus le groupe "pzgame" dont le manager est membre pour une
# FIFO/socket de contrôle restreinte. No-op en mono-user (compat totale).
# Idempotent : chaque étape vérifie avant d'agir.
ensure_split_users() {
    if [[ "${PZ_GAME_USER:-$PZ_USER}" == "${PZ_MANAGER_USER:-$PZ_USER}" ]]; then
        echo "[INFO] Mode mono-user (${PZ_MANAGER_USER:-$PZ_USER}) : pas de séparation des comptes"
        return 0
    fi
    create_user "$PZ_MANAGER_USER"
    create_user "$PZ_GAME_USER"
    if ! getent group pzgame >/dev/null 2>&1; then
        groupadd pzgame
        echo "[INFO] Groupe pzgame créé"
    fi
    if ! id -nG "$PZ_MANAGER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx pzgame; then
        usermod -aG pzgame "$PZ_MANAGER_USER"
        echo "[INFO] $PZ_MANAGER_USER ajouté au groupe pzgame"
    fi
}

# C17 : resserre les secrets du manager (home 0750, .env 0600, .ssh 0700).
# Ne fait QUE resserrer : aucun secret n'est donné en lecture au compte jeu.
harden_manager_secrets() {
    local mgr_home="${PZ_MANAGER_HOME:-$PZ_HOME}"
    local secrets_file="${ENV_FILE}"
    local ssh_dir="${mgr_home}/.ssh"
    if [[ -d "$mgr_home" ]]; then
        chmod 0750 "$mgr_home"
    fi
    if [[ -f "$secrets_file" ]]; then
        chmod 0600 "$secrets_file"
    fi
    if [[ -d "$ssh_dir" ]]; then
        chmod 0700 "$ssh_dir"
        chmod 0600 "$ssh_dir"/* 2>/dev/null || true
    fi
}

install_packages() {
    require_command apt-get
    local -a needed=(sudo rsync unzip zip ufw curl sqlite3 python3-venv)
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

# Lit les numéros de port du .env SANS l'exécuter.
#
# Ce script tourne en ROOT, alors que le .env appartient à l'utilisateur du
# serveur (non privilégié) et est écrit par lui. L'ancienne forme
# `eval "$(grep ... "$env_file")"` donnait donc à quiconque peut écrire dans ce
# fichier une exécution de code arbitraire en root — il suffisait d'y glisser
# `export PZ_PORT_GAME=1; <commande>` et d'attendre le prochain
# `pzm install system`. On extrait maintenant la valeur par une expression
# régulière et on n'accepte QUE des entiers : un contenu inattendu est ignoré et
# le défaut s'applique, plutôt que d'être exécuté.
read_ports_from_env() {
    local env_file="$1" key value
    for key in PZ_PORT_GAME PZ_PORT_GAME2 PZ_PROMETHEUS_PORT; do
        value="$(sed -n -E "s/^[[:space:]]*export[[:space:]]+${key}=[\"']?([0-9]+)[\"']?.*/\\1/p" \
                 "$env_file" | tail -1)"
        # Port TCP/UDP valide uniquement ; sinon on garde le défaut du script.
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 && value < 65536 )); then
            printf -v "$key" '%s' "$value"
        fi
    done
}

# Charge les ports depuis le .env SANS jamais l'executer : parsing declaratif
# via lib/env_parse.sh. Fallback sur read_ports_from_env si le helper est
# absent (compat ascendante).
load_ports_from_env() {
    local env_file="$1"
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
        parse_env_declarative "$env_file" || true
    else
        read_ports_from_env "$env_file"
    fi
}

# Règle ufw déjà présente ? Motif fixe (ex. "16261/udp", "OpenSSH").
# Lecture seule (sonde) : sûre en contexte `if`, jamais de modification.
ufw_has_rule() {
    ufw status numbered 2>/dev/null | grep -qF "$1"
}

# Exécute ufw, sauf en DRY-RUN (PZ_UFW_DRY_RUN=1, tests) où la commande est
# seulement journalisée sans toucher au pare-feu. Les lectures (status) ne
# passent jamais par ici.
ufw_run() {
    if [[ "${PZ_UFW_DRY_RUN:-0}" == "1" ]]; then
        echo "[DRY-RUN] ufw $*"
        return 0
    fi
    ufw "$@"
}

# Port(s) SSH réel(s) (C12) : écoute sshd observée d'abord
# (`ss -lntp | grep sshd`, mockable via PATH), sinon directive Port de
# ${PZ_SSHD_CONFIG:-/etc/ssh/sshd_config} (surchargeable pour les tests),
# sinon 22. Imprime un port par ligne, 22 toujours inclus (garde-fou admin :
# on ne se lock-out jamais en oubliant le port standard).
detect_ssh_port() {
    local sshd_config="${PZ_SSHD_CONFIG:-/etc/ssh/sshd_config}" ports=""
    if command -v ss >/dev/null 2>&1; then
        # Sonde lecture seule : le `|| true` absorbe le grep sans match.
        ports="$(ss -lntp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -nu || true)"
    fi
    if [[ -z "$ports" && -f "$sshd_config" ]]; then
        # Sonde lecture seule : idem ci-dessus.
        ports="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_config" | grep -oE '[0-9]+' | sort -nu || true)"
    fi
    [[ -n "$ports" ]] || ports="22"
    if ! grep -qx '22' <<< "$ports"; then
        ports="$(printf '%s\n%s' "22" "$ports" | sort -nu)"
    fi
    printf '%s\n' "$ports"
}

configure_firewall() {
    require_command ufw

    # Charger les ports depuis .env si disponible, sinon utiliser les défauts
    local port_game="${PZ_PORT_GAME:-16261}"
    local port_game2="${PZ_PORT_GAME2:-16262}"
    # On n'ouvre QUE les deux ports de jeu. Vérifié le 19/08/2026 sur le serveur en
    # production (ss -lnup/-lntp sur le pid de la JVM) : PZ B42 n'écoute que sur
    # 16261/udp et 16262/udp.
    #   - RCON (27015) : jamais ouvert par le serveur ici, RCONPassword est vide et
    #     le pilotage passe par la FIFO zomboid.control, pas par RCON-sur-TCP.
    #     L'exposer serait une surface d'attaque pour une fonction inutilisée.
    #   - Port Steam (8766) : hérité de B41 ; aucun socket ne l'utilise en B42,
    #     la découverte se fait via le port de jeu.
    # L'ancienne liste ouvrait "${PZ_PORT_RCON}/udp" et "${PZ_PORT_STEAM}/tcp",
    # c'est-à-dire deux ports morts, avec en prime le protocole lié à la POSITION
    # de la variable et non au rôle du port : .env.example intervertissait les deux
    # noms, ce qui compensait l'erreur, et tout .env correct la révélait.
    local -a rules=("${port_game}/udp" "${port_game2}/udp")

    # Delta avant/après (C12) : photographie avant toute modification.
    # Sonde lecture seule : le `|| true` absorbe un status en échec.
    local ufw_before
    ufw_before="$(ufw status numbered 2>/dev/null || true)"
    echo "[INFO] UFW avant :"
    echo "$ufw_before"

    local ufw_active=false
    if grep -q "Status: active" <<< "$ufw_before"; then
        ufw_active=true
    fi

    # JAMAIS de `ufw --force reset` (C12) : destructeur, il effaçait les règles
    # existantes (dont un SSH non standard => lock-out admin). UFW actif : on
    # n'ajoute que les manquants. UFW inactif : défauts + SSH + jeu, puis
    # enable — toujours sans reset.
    local -a added=()
    local p r
    if [[ "$ufw_active" != true ]]; then
        ufw_run default deny incoming
        ufw_run default allow outgoing
    fi
    # Accès admin conservé : OpenSSH + chaque port sshd détecté.
    if ! ufw_has_rule "OpenSSH"; then
        ufw_run allow OpenSSH
        added+=("OpenSSH")
    fi
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! ufw_has_rule "${p}/tcp"; then
            ufw_run allow "${p}/tcp"
            added+=("${p}/tcp")
        fi
    done < <(detect_ssh_port)
    # Jeu : uniquement les règles manquantes (jamais de doublon).
    for r in "${rules[@]}"; do
        if ! ufw_has_rule "$r"; then
            ufw_run allow "$r"
            added+=("$r")
        fi
    done
    echo "[INFO] Ports ouverts: ${rules[*]}"

    # Exporteur de métriques interne de PZ (Prometheus, cf. PZ_PROMETHEUS_PORT) :
    # le serveur le binde sur 0.0.0.0 et il expose des données sensibles (positions
    # joueurs) ; le bot le scrape en localhost. On refuse explicitement l'accès
    # externe — redondant avec le « deny incoming » par défaut mais explicite et
    # maintenu ; UFW laisse toujours passer la loopback, donc le bot n'est pas gêné.
    local prom_port="${PZ_PROMETHEUS_PORT:-9110}"
    if ufw status numbered 2>/dev/null | grep -F "$prom_port" | grep -qi deny; then
        : # refus déjà en place, on le conserve tel quel
    else
        ufw_run deny "${prom_port}/tcp"
        added+=("deny ${prom_port}/tcp")
    fi
    echo "[INFO] Port métriques ${prom_port}/tcp restreint à localhost"

    if [[ "$ufw_active" != true ]]; then
        ufw_run --force enable
        echo "[INFO] UFW activé avec règles par défaut"
    else
        echo "[INFO] UFW déjà actif : règles existantes préservées, seuls les manquants ajoutés"
    fi

    # Sonde lecture seule : le `|| true` absorbe un status en échec.
    local ufw_after
    ufw_after="$(ufw status numbered 2>/dev/null || true)"
    echo "[INFO] UFW après :"
    echo "$ufw_after"
    if (( ${#added[@]} > 0 )); then
        echo "[INFO] Règles ajoutées: ${added[*]}"
    else
        echo "[INFO] Règles ajoutées: aucune (déjà en place)"
    fi
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
    # SCRIPT_DIR = data/scripts/install -> les templates sont sous data/setupTemplates
    local templates_dir="${SCRIPT_DIR}/../../setupTemplates"
    local template="${templates_dir}/pzuser-sudoers"
    local dest="/etc/sudoers.d/${PZ_USER}"

    if [[ ! -f "$template" ]]; then
        echo "[WARN] Template sudoers introuvable: $template"
        return
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

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "[FATAL] Ce script doit être exécuté en root" >&2
        exit 1
    fi

    echo "[INFO] Configuration pour l'utilisateur: $PZ_USER"
    warn_if_not_root_owned || true

    # Charger les ports depuis .env si disponible. Le filtre couvre AUSSI
    # PZ_PROMETHEUS_PORT : il ne matchait que « PZ_PORT_ », si bien que
    # configure_firewall retombait toujours sur son défaut codé en dur (9110) et
    # posait la règle `deny` sur un port qui n'était pas celui du serveur dès que
    # .env en définissait un autre.
    if [[ -f "$ENV_FILE" ]]; then
        load_ports_from_env "$ENV_FILE"
        echo "[INFO] Ports chargés depuis $ENV_FILE"
    fi

    # C17 : comptes jeu (JVM) / admin lus depuis le .env via le parsing
    # déclaratif ci-dessus ; défaut = PZ_USER pour les deux (mono-user inchangé).
    : "${PZ_GAME_USER:=${PZ_USER}}"
    : "${PZ_MANAGER_USER:=${PZ_USER}}"
    : "${PZ_GAME_HOME:=/home/${PZ_GAME_USER}}"
    : "${PZ_MANAGER_HOME:=/home/${PZ_MANAGER_USER}}"

    create_user
    ensure_split_users
    harden_manager_secrets
    install_packages
    configure_firewall
    configure_path
    install_sudoers

    echo "=== Configuration système terminée pour $PZ_USER ==="
}

# Garde de sourçage (C11/C12) : les tests sourcent ce fichier pour exercer
# detect_ssh_port / configure_firewall avec des mocks, sans exécuter main.
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
main
fi
