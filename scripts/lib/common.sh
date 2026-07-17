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
    apply_env_defaults
}

# Valeurs par défaut des variables introduites après la création du .env.
#
# source_env ne copie .env.example que si .env est ABSENT : il ne fusionne jamais
# les nouvelles clés dans un .env existant. Sans ces défauts, toute installation
# antérieure casserait sur "variable sans liaison" (set -u) après une mise à jour
# qui ajoute une variable. `:=` n'écrase rien : un .env qui définit la clé gagne.
apply_env_defaults() {
    # Nom du monde PZ ; "servertest" est le défaut du jeu. Voir .env.example.
    : "${PZ_SERVER_NAME:=servertest}"
    : "${PZ_DB_PATH:=${PZ_SOURCE_DIR}/db/${PZ_SERVER_NAME}.db}"
    : "${PZ_INI_PATH:=${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}.ini}"
    export PZ_SERVER_NAME PZ_DB_PATH PZ_INI_PATH
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

# Échappe une chaîne pour une string SQL sqlite3 (double les apostrophes)
sql_escape() { printf "%s" "${1//\'/\'\'}"; }

# Vrai (code 0) si l'argument est un SteamID64 (17 chiffres commençant par 7656119).
is_steamid64() { [[ "$1" =~ ^7656119[0-9]{10}$ ]]; }

# Clause SQL WHERE identifiant les comptes `whitelist` inactifs depuis >= <days>
# jours (jamais connectés & créés il y a plus de <days> jours, OU dernière
# connexion antérieure à <days> jours), le compte interne 'admin' toujours exclu.
# <has_created_at> ("true"/"false") = présence de la colonne created_at (ajoutée
# par creationDateInit.sh). Partagée par la purge auto (purgeInactivePlayers.sh)
# et la purge interactive (manageWhitelist.sh) pour qu'elles ciblent EXACTEMENT
# les mêmes comptes — ce prédicat ne doit exister qu'à un seul endroit.
inactive_where_clause() {
    local days="$1" has_created_at="$2"
    if [[ "$has_created_at" == true ]]; then
        echo "(((lastConnection IS NULL OR lastConnection = '') AND (created_at IS NULL OR created_at < date('now', '-${days} days'))) OR (lastConnection < date('now', '-${days} days') AND lastConnection <> '')) AND username <> 'admin'"
    else
        echo "((lastConnection IS NULL OR lastConnection = '' OR (lastConnection < date('now', '-${days} days') AND lastConnection <> '')) AND username <> 'admin')"
    fi
}

# Vrai (code 0) si le service serveur Zomboid tourne actuellement.
# Requiert que source_env ait été appelé (PZ_SERVICE_NAME).
server_is_active() {
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" 2>/dev/null
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
