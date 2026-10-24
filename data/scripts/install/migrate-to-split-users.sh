#!/usr/bin/env bash
# Compatibilité : mono-user = aucun changement ; split multi-UID refusé car
# le budget PZ partagé exige un UID unique. Aucun compte ni fichier modifié.
# Usage: sudo ./migrate-to-split-users.sh [chemin_du_.env]
# PZ_MIGRATE_ALLOW_NONROOT=1 : exécution des tests de contrat sans privilège.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ENV_FILE="${1:-/home/pzuser/pzmanager/.env}"

die() { echo "[FATAL] $*" >&2; exit 1; }

if [[ "${PZ_MIGRATE_ALLOW_NONROOT:-0}" != "1" ]] && [[ "${EUID:-0}" -ne 0 ]]; then
    die "Ce script doit être exécuté en root"
fi

# Parsing déclaratif du .env (jamais exécuté), comme setupSystem.sh.
# shellcheck source=../lib/env_parse.sh
source "${SCRIPT_DIR}/../lib/env_parse.sh"
[[ -f "$ENV_FILE" ]] || die "Fichier .env introuvable : $ENV_FILE"
if declare -F parse_env_declarative >/dev/null 2>&1; then
    parse_env_declarative "$ENV_FILE" || true
fi

# Défauts compatibles mono-user : sans ces clés, rien à migrer.
: "${PZ_USER:=pzuser}"
: "${PZ_GAME_USER:=${PZ_USER}}"
: "${PZ_MANAGER_USER:=${PZ_USER}}"

if [[ "$PZ_GAME_USER" == "$PZ_MANAGER_USER" ]]; then
    echo "Mode mono-user (${PZ_MANAGER_USER}) : rien à migrer."
    exit 0
fi

die "Migration split refusée : le plafond PZ partagé exige un UID unique ; données et comptes conservés."
