#!/usr/bin/env bash
# setupSystem.sh - Configuration système initiale
# Crée l'utilisateur, installe les paquets requis et configure le pare-feu.
# Usage: sudo ./setupSystem.sh [nom_utilisateur] [chemin_du_.env]
# Par défaut, l'utilisateur est "pzuser" et le .env est cherché dans son home.
# Le 2e argument sert à l'installateur, qui prépare le .env dans un dossier
# temporaire AVANT que le home ne soit peuplé.

set -euo pipefail
trap 'on_error $LINENO' ERR

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PZ_USER="${1:-pzuser}"
readonly PZ_HOME="/home/${PZ_USER}"
readonly ENV_FILE="${2:-${PZ_HOME}/pzmanager/.env}"

on_error() {
    local lineno=${1:-?}
    echo "[ERROR] Échec lors de l'exécution (ligne: ${lineno})" >&2
    exit 1
}

require_command() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] la commande '$cmd' est requise mais introuvable" >&2; exit 1; }
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
    for r in "${rules[@]}"; do
        ufw allow "$r"
    done
    echo "[INFO] Ports ouverts: ${rules[*]}"

    # Exporteur de métriques interne de PZ (Prometheus, cf. PZ_PROMETHEUS_PORT) :
    # le serveur le binde sur 0.0.0.0 et il expose des données sensibles (positions
    # joueurs) ; le bot le scrape en localhost. On refuse explicitement l'accès
    # externe — redondant avec le « deny incoming » par défaut mais explicite et
    # maintenu ; UFW laisse toujours passer la loopback, donc le bot n'est pas gêné.
    local prom_port="${PZ_PROMETHEUS_PORT:-9110}"
    ufw deny "${prom_port}/tcp"
    echo "[INFO] Port métriques ${prom_port}/tcp restreint à localhost"
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

    # Charger les ports depuis .env si disponible. Le filtre couvre AUSSI
    # PZ_PROMETHEUS_PORT : il ne matchait que « PZ_PORT_ », si bien que
    # configure_firewall retombait toujours sur son défaut codé en dur (9110) et
    # posait la règle `deny` sur un port qui n'était pas celui du serveur dès que
    # .env en définissait un autre.
    if [[ -f "$ENV_FILE" ]]; then
        read_ports_from_env "$ENV_FILE"
        echo "[INFO] Ports chargés depuis $ENV_FILE"
    fi

    create_user
    install_packages
    configure_firewall
    configure_path
    install_sudoers

    echo "=== Configuration système terminée pour $PZ_USER ==="
}

main
