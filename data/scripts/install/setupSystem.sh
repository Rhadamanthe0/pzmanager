#!/usr/bin/env bash
# setupSystem.sh - Configuration système initiale
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# Helpers et ancêtres doivent appartenir à root, sans écriture pour un tiers.
# Helper root : ne jamais charger le .env (modifiable par
# PZ_USER) par execution shell ; parsing declaratif via lib/env_parse.sh.
# Crée l'utilisateur, installe les paquets requis et configure le pare-feu.
# Usage: sudo ./setupSystem.sh [nom_utilisateur] [chemin_du_.env]
# Par défaut, l'utilisateur est "pzuser" et le .env est cherché dans son home.
# Le 2e argument sert à l'installateur, qui prépare le .env dans un dossier
# temporaire AVANT que le home ne soit peuplé.

set -euo pipefail
trap 'on_error $LINENO' ERR

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# Même frontière que configurationInitiale : aucun code manager-owned en root.
if [[ "${EUID:-0}" -eq 0 ]]; then
    _trusted="$(realpath -e "$SCRIPT_DIR")"
    while [[ "$_trusted" != / ]]; do
        [[ "$(stat -c %u "$_trusted")" == 0 && $(( 8#$(stat -c %a "$_trusted") & 0022 )) == 0 ]] \
            || { echo "[ERROR] Chemin helper root non fiable : $_trusted" >&2; exit 1; }
        _trusted="$(dirname "$_trusted")"
    done
    [[ -z "$(find "$SCRIPT_DIR" "${SCRIPT_DIR}/../lib" "${SCRIPT_DIR}/../../setupTemplates" \( -type l -o ! -uid 0 -o -perm /0022 \) -print -quit)" ]] \
        || { echo "[ERROR] Helpers root modifiables par un tiers." >&2; exit 1; }
    unset _trusted
fi
SETUP_MANAGER_ROOT=""
if [[ "${1:-}" == --manager-root ]]; then
    [[ "${2:-}" == /* && "${2:-}" != *..* && "${2:-}" != *$'\n'* ]] \
        || { echo "[ERROR] Racine manager absolue requise." >&2; exit 1; }
    SETUP_MANAGER_ROOT="$2"
    shift 2
    _manager_uid="$(stat -c %u "$SETUP_MANAGER_ROOT")"
    [[ "$_manager_uid" != 0 ]] || { echo "[ERROR] Installation manager non root requise." >&2; exit 1; }
    _manager_user="$(getent passwd "$_manager_uid" | cut -d: -f1)"
    _manager_home="$(getent passwd "$_manager_uid" | cut -d: -f6)"
else
    _manager_user="${1:-pzuser}"
    _manager_home="/home/${_manager_user}"
fi
readonly PZ_USER="$_manager_user"
[[ "$PZ_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$_manager_home" == /* ]] \
    || { echo "[ERROR] Invalid PZ_USER '${PZ_USER}'" >&2; exit 1; }
readonly PZ_HOME="$_manager_home"
if [[ -n "$SETUP_MANAGER_ROOT" ]]; then
    readonly ENV_FILE="${SETUP_MANAGER_ROOT}/.env"
else
    readonly ENV_FILE="${2:-${PZ_HOME}/pzmanager/.env}"
fi
unset _manager_uid _manager_user _manager_home

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

# Toute écriture du home s'effectue avec les droits du manager : même un
# remplacement concurrent par un lien ne donne aucun droit sur une cible root.
as_manager() {
    if [[ "$(id -un)" == "$PZ_USER" ]]; then "$@"; else sudo -u "$PZ_USER" "$@"; fi
}

harden_manager_secrets() {
    local mgr_home="${PZ_MANAGER_HOME:-$PZ_HOME}" secrets_file="$ENV_FILE"
    local ssh_dir="${mgr_home}/.ssh"
    [[ ! -L "$secrets_file" && ! -L "$ssh_dir" ]] \
        || { echo "[ERROR] Secret manager symbolique refusé." >&2; return 1; }
    [[ ! -d "$mgr_home" ]] || as_manager chmod 0750 "$mgr_home"
    # Le clone privé de l'installateur contient déjà un .env root 0600 avant
    # création du home ; on ne le confie pas au compte nouvellement créé.
    if [[ "$secrets_file" == "$mgr_home/"* || -n "$SETUP_MANAGER_ROOT" ]]; then
        [[ ! -f "$secrets_file" ]] || as_manager chmod 0600 "$secrets_file"
    fi
    if [[ -d "$ssh_dir" ]]; then
        as_manager chmod 0700 "$ssh_dir"
        as_manager bash -c 'for file in "$1"/*; do [[ ! -f "$file" ]] || chmod 0600 "$file" || exit; done' _ "$ssh_dir"
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
    # shellcheck disable=SC1090
    . "$lib1"
    if [[ -n "$SETUP_MANAGER_ROOT" ]]; then
        local declared_user
        declared_user="$(bash -c 'source "$1"; unset PZ_USER; parse_env_declarative "$2"; printf "%s" "${PZ_USER:-}"' _ "$lib1" "$env_file")"
        [[ -z "$declared_user" || "$declared_user" == "$PZ_USER" ]] \
            || { echo "[ERROR] Identité .env incompatible avec le propriétaire manager." >&2; exit 1; }
    fi
    if declare -F parse_env_declarative >/dev/null 2>&1; then
        # L'identité et le home sont les arguments administrateur readonly,
        # jamais des affectations venant du fichier manager.
        parse_env_declarative <(grep -E '^[[:space:]]*(export[[:space:]]+)?(PZ_PORT_GAME|PZ_PORT_GAME2|PZ_PROMETHEUS_PORT|PZ_GAME_USER|PZ_MANAGER_USER)=' "$env_file")
    else
        read_ports_from_env "$env_file"
    fi
}

# Règle ufw déjà présente ? Motif fixe (ex. "16261/udp", "OpenSSH").
# Lecture seule (sonde) : sûre en contexte `if`, jamais de modification.
ufw_has_rule() {
    local status
    status="$(LC_ALL=C LANGUAGE=C ufw status numbered)" || { echo "[ERROR] Lecture UFW impossible." >&2; exit 1; }
    grep -qF "$1" <<< "$status"
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

# Ports SSH observés en priorité ; sinon configuration effective (Include inclus).
# Sans binaire NI configuration, installation locale sans SSH : garde-fou 22.
# Une configuration indéterminée refuse toute mutation du pare-feu.
detect_ssh_port() {
    local sshd_config="${PZ_SSHD_CONFIG:-/etc/ssh/sshd_config}" ports="" effective="" sshd_bin=""
    if command -v ss >/dev/null 2>&1; then
        ports="$(ss -lntp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -nu || true)"
    fi
    if [[ -z "$ports" ]]; then
        sshd_bin="$(command -v sshd || command -v /usr/sbin/sshd || true)"
        if [[ -n "$sshd_bin" && -f "$sshd_config" ]]; then
            effective="$(LC_ALL=C LANGUAGE=C "$sshd_bin" -T -f "$sshd_config")" \
                || { echo "[ERROR] Configuration SSH indéterminée : aucune règle modifiée." >&2; return 1; }
            ports="$(awk 'tolower($1)=="port" {print $2}' <<< "$effective")"
            [[ -n "$ports" ]] \
                || { echo "[ERROR] Aucun port SSH effectif : aucune règle modifiée." >&2; return 1; }
        elif [[ -n "$sshd_bin" || -e "$sshd_config" || -L "$sshd_config" ]]; then
            echo "[ERROR] Configuration ou binaire SSH indisponible : aucune règle modifiée." >&2
            return 1
        else
            echo "[INFO] Aucun serveur SSH installé ; accès local, garde-fou 22." >&2
        fi
    fi
    if [[ -n "$ports" ]]; then
        # sshd accepte les zéros initiaux en décimal : comparer et autoriser
        # toujours le port canonique, sans débordement arithmétique Bash.
        ports="$(awk '/^[0-9]+$/ && $0+0 >= 1 && $0+0 <= 65535 { printf "%d\n", $0+0; next } { exit 1 }' <<< "$ports" | sort -nu)" \
            || { echo "[ERROR] Port SSH invalide : aucune règle modifiée." >&2; return 1; }
    fi
    [[ -n "$ports" ]] || ports="22"
    if ! grep -qx '22' <<< "$ports"; then
        ports="$(printf '%s\n%s' "22" "$ports" | sort -nu)"
    fi
    printf '%s\n' "$ports"
}

# UFW compare les doublons sans tenir compte d'action/log/comment : prepend
# peut sinon ignorer un DENY s'il reste un ALLOW exact au même endpoint.
# Parser la sortie numérotée C, jamais les ACL partielles/interfaces/ranges.
prometheus_rules() {
    python3 -c '
import ipaddress,re,sys
port,mode=sys.argv[1:]
exact=re.compile(re.escape(port)+r"/tcp(?: \(v6\))? (ALLOW|DENY|REJECT|LIMIT) IN Anywhere(?: \(v6\))?(?: \(log(?:-all)?\))?$")
rows=[]
for line in sys.stdin:
    match=re.match(r"^\s*\[\s*(\d+)\]\s*(.*)$",line)
    if not match: continue
    number,body=int(match[1])," ".join(match[2].split("#",1)[0].split())
    family=6 if "(v6)" in body else 4
    for token in body.split():
        try: family=max(family,ipaddress.ip_network(token,strict=False).version)
        except ValueError: pass
    parsed=re.match(r"^.*? (ALLOW|DENY|REJECT|LIMIT) (IN|OUT|FWD) .*",body)
    if not parsed: raise ValueError("État UFW non reconnu : "+body)
    rows.append((number,body,family,parsed[2]))
if mode=="indices":
    print("\n".join(str(n) for n,b,f,d in reversed(rows) if exact.fullmatch(b)))
else:
    first={}
    for n,b,f,d in rows:
        if d=="IN": first.setdefault(f,b)
    if 4 not in first or any(not exact.fullmatch(b) or exact.fullmatch(b)[1]!="DENY" for b in first.values()):
        raise ValueError("Refus Prometheus prioritaire non prouvé")
' "$1" "$2"
}

configure_firewall() {
    require_command ufw
    local prom_port="${PZ_PROMETHEUS_PORT:-9110}" ssh_ports
    [[ "$prom_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$prom_port >= 1 && 10#$prom_port <= 65535 )) \
        || { echo "[ERROR] Port métriques invalide." >&2; return 1; }
    prom_port="$((10#$prom_port))"
    ssh_ports="$(detect_ssh_port)" || return 1
    if grep -qx "$prom_port" <<< "$ssh_ports"; then
        echo "[ERROR] Port métriques $prom_port en conflit avec SSH : aucune règle modifiée." >&2
        return 1
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

    # Delta avant/après (C12) : photographie stricte avant toute modification.
    local ufw_before
    ufw_before="$(LC_ALL=C LANGUAGE=C ufw status numbered)" || { echo "[ERROR] Lecture UFW impossible." >&2; return 1; }
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
        ufw_run default deny incoming || return 1
        ufw_run default allow outgoing || return 1
    fi
    # Ports numériques : le profil OpenSSH peut être absent (installation locale).
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! ufw_has_rule "${p}/tcp"; then
            ufw_run allow "${p}/tcp" || return 1
            added+=("${p}/tcp")
        fi
    done <<< "$ssh_ports"
    # Jeu : uniquement les règles manquantes (jamais de doublon).
    for r in "${rules[@]}"; do
        if ! ufw_has_rule "$r"; then
            ufw_run allow "$r" || return 1
            added+=("$r")
        fi
    done
    echo "[INFO] Ports ouverts: ${rules[*]}"

    # Inactif : les anciennes règles restent enregistrées mais status ne les
    # affiche pas. Activer seulement après préparation de tous les accès SSH.
    # L'état initial inactif exposait déjà le port ; ne jamais annoncer le
    # refus tant que sa priorité n'est pas prouvée après correction.
    if [[ "$ufw_active" != true ]]; then
        ufw_run --force enable || return 1
        echo "[INFO] UFW activé avec règles par défaut"
    else
        echo "[INFO] UFW déjà actif : règles existantes préservées"
    fi
    local snapshot indices index ufw_after
    snapshot="$(LC_ALL=C LANGUAGE=C ufw status numbered)" || return 1
    if [[ "${PZ_UFW_DRY_RUN:-0}" == 1 ]] || ! prometheus_rules "$prom_port" verify <<< "$snapshot" 2>/dev/null; then
        indices="$(prometheus_rules "$prom_port" indices <<< "$snapshot")" || return 1
        while IFS= read -r index; do
            [[ -z "$index" ]] || ufw_run --force delete "$index" || return 1
        done <<< "$indices"
        ufw_run prepend deny in proto tcp from any to any port "$prom_port" || return 1
        added+=("deny ${prom_port}/tcp prioritaire")
    fi
    ufw_after="$(LC_ALL=C LANGUAGE=C ufw status numbered)" || return 1
    if [[ "${PZ_UFW_DRY_RUN:-0}" == 1 ]]; then
        echo "[DRY-RUN] Restriction métriques planifiée, non vérifiée."
    else
        prometheus_rules "$prom_port" verify <<< "$ufw_after" || return 1
        echo "[INFO] Port métriques ${prom_port}/tcp restreint à localhost"
    fi
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

    if as_manager grep -q "PATH.*pzmanager" "$bashrc"; then
        echo "[INFO] PATH déjà configuré pour pzmanager"
        return
    fi

    [[ ! -L "$bashrc" ]] || { echo "[ERROR] .bashrc symbolique refusé." >&2; return 1; }
    printf '\n# pzmanager PATH\nexport PATH="%s/pzmanager:${PATH}"\n' "$PZ_HOME" \
        | as_manager tee -a -- "$bashrc" >/dev/null

    echo "[INFO] PATH configuré pour inclure pzmanager"
}

install_sudoers() {
    # SCRIPT_DIR = data/scripts/install -> les templates sont sous data/setupTemplates
    local templates_dir="${SCRIPT_DIR}/../../setupTemplates"
    local template="${templates_dir}/pzuser-sudoers"
    local dest="/etc/sudoers.d/${PZ_USER}"

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

    [[ "$PZ_GAME_USER" == "$PZ_MANAGER_USER" ]] \
        || { echo "[FATAL] Budget PZ partagé incompatible avec split multi-UID ; aucun compte modifié." >&2; exit 1; }

    create_user
    install_packages
    harden_manager_secrets
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
