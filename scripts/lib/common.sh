#!/usr/bin/env bash
# Library commune pour tous les scripts pzmanager

# Charge .env avec création automatique depuis .env.example
source_env() {
    local script_dir="$1"
    local env_file="${script_dir}/.env"
    local env_example="${script_dir}/../data/setupTemplates/.env.example"

    if [[ ! -f "$env_file" ]] && [[ -f "$env_example" ]]; then
        cp "$env_example" "$env_file"
        echo "Fichier .env créé depuis .env.example. Éditez-le pour configurer votre installation."
    fi

    [[ -f "$env_file" ]] || {
        echo "ERREUR: Fichier .env introuvable: $env_file" >&2
        exit 1
    }

    source "$env_file"
}

# Arrêt avec message d'erreur
die() {
    echo "ERREUR: $*" >&2
    exit 1
}

# Logging avec timestamp
log() {
    echo "[$(date +'%H:%M:%S')] $*"
}

# Validation de répertoire
validate_directory() {
    local dir="$1"
    local description="$2"
    [[ -d "$dir" ]] || die "$description introuvable: $dir"
}

# Création de répertoire si inexistant
ensure_directory() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir" || die "Impossible de créer le répertoire: $dir"
}

# Acquire maintenance lock (non-blocking, shared between pz.sh/modcheck/maintenance)
# Usage: try_acquire_maintenance_lock [lock_file] [max_age_seconds]
# Returns: 0 if acquired, 1 if already held
readonly MAINTENANCE_LOCK_FILE="/tmp/pzmanager-maintenance-$(id -un).lock"
readonly LOCK_MAX_AGE=3600

try_acquire_maintenance_lock() {
    local lock_file="${1:-$MAINTENANCE_LOCK_FILE}"
    local max_age="${2:-$LOCK_MAX_AGE}"

    # Clean stale lock (>max_age old)
    if [[ -f "$lock_file" ]]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$lock_file" 2>/dev/null || echo 0) ))
        (( age > max_age )) && rm -f "$lock_file"
    fi

    exec 200>"$lock_file"
    flock -n 200
}
