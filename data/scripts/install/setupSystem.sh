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
    # network-manager + ethtool : requis par configure_network(). ethtool reste
    # utile seul (lecture de l'état Wake-on-LAN, `ethtool <iface> | grep Wake-on`),
    # NetworkManager ne l'appelant pas pour poser son propre réglage.
    local -a needed=(sudo rsync unzip zip ufw curl sqlite3 python3-venv network-manager ethtool)
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

configure_network() {
    # Pose le profil NetworkManager de l'interface principale.
    #
    # OPT-IN : sans NET_INTERFACE dans .env, la fonction ne touche à rien. Une
    # machine en DHCP ne doit pas se voir imposer une IP statique par un script
    # d'installation ; seule une box dont l'adresse est fixée par convention
    # (réservation DHCP, services LAN pointant dessus) renseigne ces variables.
    local iface="${NET_INTERFACE:-}"
    if [[ -z "$iface" ]]; then
        echo "[INFO] NET_INTERFACE non défini, configuration réseau ignorée"
        return
    fi

    require_command nmcli

    local con_name="${NET_CONNECTION_NAME:-static-${iface}}"
    local address="${NET_ADDRESS_CIDR:-}"
    local gateway="${NET_GATEWAY:-}"
    local dns="${NET_DNS:-}"
    local wol="${NET_WOL:-magic}"

    if [[ -z "$address" || -z "$gateway" ]]; then
        echo "[WARN] NET_ADDRESS_CIDR et NET_GATEWAY sont requis avec NET_INTERFACE ; profil non posé" >&2
        return
    fi

    if nmcli -g connection.id connection show "$con_name" >/dev/null 2>&1; then
        echo "[INFO] Profil réseau $con_name déjà présent, réalignement sur .env"
    else
        nmcli connection add type ethernet con-name "$con_name" ifname "$iface" >/dev/null
        echo "[INFO] Profil réseau $con_name créé"
    fi

    # `nmcli connection modify` écrase les propriétés visées et laisse le reste :
    # rejouer le script réaligne simplement le profil sur .env, d'où l'idempotence.
    #
    # ipv6.method=auto et NON `disabled` : cette box reçoit une IPv6 publique par
    # RA/SLAAC, la désactiver la lui retirerait silencieusement. `ignore-auto-dns`
    # des deux côtés parce que le résolveur est fixé ci-dessous, pas négocié — sans
    # ça un RDNSS annoncé par le routeur s'ajouterait à /etc/resolv.conf, que
    # NetworkManager réécrit dès qu'il gère l'interface.
    #
    # wake-on-lan : le gain de NetworkManager sur ifupdown, qui exigeait un
    # `post-up ethtool -s <iface> wol g`. Le pilote écrit ce masque dans le
    # contrôleur à l'extinction, donc APRÈS le firmware : le poser explicitement
    # écrase un masque large armé par le BIOS (réveil sur tout paquet entrant).
    nmcli connection modify "$con_name" \
        connection.interface-name "$iface" \
        ipv4.method manual \
        ipv4.addresses "$address" \
        ipv4.gateway "$gateway" \
        ipv4.ignore-auto-dns yes \
        ipv6.method auto \
        ipv6.ignore-auto-dns yes \
        802-3-ethernet.wake-on-lan "$wol"

    if [[ -n "$dns" ]]; then
        nmcli connection modify "$con_name" ipv4.dns "$dns"
    fi
    echo "[INFO] Profil $con_name: $address via $gateway, DNS ${dns:-<hérités>}, WoL $wol"

    # On n'ACTIVE PAS le profil ici. `nmcli connection up` coupe la session en
    # cours sur un serveur administré à distance, et tant que l'interface est
    # encore décrite dans /etc/network/interfaces, ifupdown et NetworkManager se
    # disputent la même carte. La bascule reste un geste manuel, fait avec un
    # accès physique ou un filet de sécurité (cf. CLAUDE.md).
    local active
    active="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
    if [[ "$active" == "$con_name" ]]; then
        echo "[INFO] Profil $con_name déjà actif sur $iface"
    else
        echo "[WARN] Profil posé mais NON activé : $iface n'est pas géré par NetworkManager" >&2
        echo "[WARN] Pour basculer (COUPE LE RÉSEAU, prévoir un accès physique) :" >&2
        echo "[WARN]   1. retirer la strophe '$iface' de /etc/network/interfaces" >&2
        echo "[WARN]   2. systemctl reload NetworkManager" >&2
        echo "[WARN]   3. nmcli connection up '$con_name'" >&2
    fi
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

    # Charger les ports et le réseau depuis .env si disponible. Le filtre couvre
    # AUSSI PZ_PROMETHEUS_PORT : il ne matchait que « PZ_PORT_ », si bien que
    # configure_firewall retombait toujours sur son défaut codé en dur (9110) et
    # posait la règle `deny` sur un port qui n'était pas celui du serveur dès que
    # .env en définissait un autre. « NET_ » alimente configure_network, qui reste
    # inerte tant que NET_INTERFACE n'est pas renseigné.
    local env_file="${PZ_HOME}/pzmanager/.env"
    if [[ -f "$env_file" ]]; then
        eval "$(grep -E '^export (PZ_PORT_|PZ_PROMETHEUS_PORT|NET_)' "$env_file")" 2>/dev/null || true
        echo "[INFO] Ports et réseau chargés depuis $env_file"
    fi

    create_user
    install_packages
    configure_network
    configure_firewall
    configure_path
    install_sudoers

    echo "=== Configuration système terminée pour $PZ_USER ==="
}

main
