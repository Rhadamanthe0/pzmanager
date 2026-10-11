#!/usr/bin/env bash
# migrate-to-split-users.sh - Bascule idempotente mono-user -> split (C17).
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# Helper root : ne jamais charger le .env (modifiable par le manager) par
# exécution shell ; parsing déclaratif via lib/env_parse.sh.
# Détecte une install mono-user et, si PZ_GAME_USER != PZ_MANAGER_USER :
# crée le compte jeu + groupe pzgame, déplace le monde (Zomboid) et le serveur
# (pzserver) vers le compte jeu (rsync -a + chown, original conservé sous
# <chemin>.pre-split-bak, chemin historique -> lien symbolique), resserre les
# secrets du manager (.env 0600, .ssh 0700, home 0750), affiche un résumé.
# Idempotent : rejouer sur une install déjà migrée ne fait rien (code 0).
# Usage: sudo ./migrate-to-split-users.sh [chemin_du_.env]
#   PZ_MIGRATE_ALLOW_NONROOT=1 : sandbox de test uniquement (saute le contrôle
#   root ; les appels système sont alors neutralisés par des stubs sur PATH).

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ENV_FILE="${1:-/home/pzuser/pzmanager/.env}"

die() { echo "[FATAL] $*" >&2; exit 1; }

if [[ "${PZ_MIGRATE_ALLOW_NONROOT:-0}" != "1" ]] && [[ "${EUID:-0}" -ne 0 ]]; then
    die "Ce script doit être exécuté en root"
fi

# Parsing déclaratif du .env (jamais exécuté), comme setupSystem.sh.
lib1="${SCRIPT_DIR}/../lib/env_parse.sh"
lib2="/usr/local/libexec/pzmanager/env_parse.sh"
if [[ -f "$lib1" ]]; then
    # shellcheck disable=SC1090
    . "$lib1"
elif [[ -f "$lib2" ]]; then
    # shellcheck disable=SC1090
    . "$lib2"
fi
[[ -f "$ENV_FILE" ]] || die "Fichier .env introuvable : $ENV_FILE"
if declare -F parse_env_declarative >/dev/null 2>&1; then
    parse_env_declarative "$ENV_FILE" || true
fi

# Défauts compatibles mono-user : sans ces clés, rien à migrer.
: "${PZ_USER:=pzuser}"
: "${PZ_HOME:=/home/${PZ_USER}}"
: "${PZ_MANAGER_DIR:=${PZ_HOME}/pzmanager}"
: "${PZ_GAME_USER:=${PZ_USER}}"
: "${PZ_MANAGER_USER:=${PZ_USER}}"
: "${PZ_MANAGER_HOME:=${PZ_HOME}}"
# Dérivé du dirname du home manager (== /home/<jeu> en prod) plutôt que codé
# en dur : une sandbox de test peut ainsi relocaliser les deux homes via PZ_HOME.
: "${PZ_GAME_HOME:=$(dirname "${PZ_MANAGER_HOME}")/${PZ_GAME_USER}}"

readonly SRC_WORLD="${PZ_MANAGER_DIR}/Zomboid"
readonly SRC_SERVER="${PZ_MANAGER_DIR}/data/pzserver"
readonly DST_WORLD="${PZ_GAME_HOME}/pzmanager/Zomboid"
readonly DST_SERVER="${PZ_GAME_HOME}/pzmanager/data/pzserver"

if [[ "$PZ_GAME_USER" == "$PZ_MANAGER_USER" ]]; then
    echo "Mode mono-user (${PZ_MANAGER_USER}) : rien à migrer."
    exit 0
fi

ensure_user() {
    local name="$1"
    if id -u "$name" >/dev/null 2>&1; then
        echo "[INFO] L'utilisateur $name existe déjà"
        return 0
    fi
    useradd -m -s /bin/bash "$name"
    echo "[INFO] Utilisateur $name créé"
}

ensure_user "$PZ_MANAGER_USER"
ensure_user "$PZ_GAME_USER"
if ! getent group pzgame >/dev/null 2>&1; then
    groupadd pzgame
    echo "[INFO] Groupe pzgame créé"
fi
if ! id -nG "$PZ_MANAGER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx pzgame; then
    usermod -aG pzgame "$PZ_MANAGER_USER"
    echo "[INFO] $PZ_MANAGER_USER ajouté au groupe pzgame"
fi

# Copie idempotente d'un arbre vers le compte jeu (rsync -a + chown), puis
# bascule le chemin historique vers un lien symbolique. Ne supprime JAMAIS le
# monde : l'original est conservé sous <chemin>.pre-split-bak.
migrate_item() {
    local src="$1" dst="$2" owner="$3"
    [[ -e "$src" || -L "$src" ]] || { echo "[INFO] Absent, rien à migrer : $src"; return 0; }
    if [[ -L "$src" ]]; then
        echo "[INFO] Déjà migré : $src"
        return 0
    fi
    if [[ ! -d "$dst" ]] || [[ -z "$(ls -A "$dst" 2>/dev/null)" ]]; then
        mkdir -p "$dst"
        rsync -a "$src/" "$dst/" || die "Copie $src -> $dst impossible"
    else
        echo "[INFO] Destination déjà peuplée, copie sautée : $dst"
    fi
    chown -R "${owner}:${owner}" "$dst" || die "chown $dst impossible"
    local bak="${src}.pre-split-bak"
    if [[ -e "$bak" || -L "$bak" ]]; then
        echo "[WARN] Sauvegarde $bak déjà présente, $src laissé en place" >&2
        return 0
    fi
    mv "$src" "$bak"
    # Si le lien échoue, on restaure l'original avant de mourir : les chemins
    # historiques doivent rester valides quoi qu'il arrive.
    if ! ln -s "$dst" "$src"; then
        mv "$bak" "$src" || true
        die "lien symbolique $src -> $dst impossible (original restauré)"
    fi
    echo "[INFO] Migré vers le compte jeu : $src -> $dst (original conservé : $bak)"
}

migrate_item "$SRC_WORLD" "$DST_WORLD" "$PZ_GAME_USER"
migrate_item "$SRC_SERVER" "$DST_SERVER" "$PZ_GAME_USER"

# Secrets du manager : resserrer uniquement, jamais exposer au compte jeu.
if [[ -d "$PZ_MANAGER_HOME" ]]; then
    chmod 0750 "$PZ_MANAGER_HOME"
fi
if [[ -f "$ENV_FILE" ]]; then
    chmod 0600 "$ENV_FILE"
fi
if [[ -d "${PZ_MANAGER_HOME}/.ssh" ]]; then
    chmod 0700 "${PZ_MANAGER_HOME}/.ssh"
    chmod 0600 "${PZ_MANAGER_HOME}/.ssh"/* 2>/dev/null || true
fi

echo "=== Migration split-users terminée ==="
echo "  Compte jeu (JVM) : $PZ_GAME_USER ($PZ_GAME_HOME)"
echo "  Compte admin     : $PZ_MANAGER_USER ($PZ_MANAGER_HOME)"
echo "  Monde            : $SRC_WORLD -> $DST_WORLD"
echo "  Serveur          : $SRC_SERVER -> $DST_SERVER"
echo "  Secrets          : $ENV_FILE (0600), ${PZ_MANAGER_HOME}/.ssh (0700)"
