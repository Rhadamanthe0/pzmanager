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

# Marqueur journald émis à la toute fin du boot PZ (map chargée, serveur prêt).
# Dernière étape d'init, 1 seule fois par boot ; source unique partagée avec
# notifyServerReady.sh et wait_for_server_ready. B42 n'imprime plus
# "*** SERVER STARTED ****" (disparu vers la 42.x de juin 2026).
readonly SERVER_READY_MARKER="LuaNet: Initialization [DONE]"

# Attend que le serveur ait FINI de booter (map chargée) avant de rendre la main.
# CRUCIAL : un `quit`/stop envoyé pendant le chargement de la map fait planter
# B42 (NullPointerException zombie.iso.IsoMetaGrid.save, grid=null) -> crash-loop
# (incident du 2026-07-20 : un 2e restart lancé pendant le boot du 1er). Tant que
# le marqueur de fin de boot n'est pas vu, il ne faut jamais arrêter le serveur.
# Retour 0 dès que le boot courant est terminé (ou si le serveur n'est pas actif :
# rien à attendre). Retour 1 sur timeout (actif mais fin de boot jamais signalée)
# -> l'appelant décide (pz.sh arrête quand même : systemd récupère un boot bloqué
# via ExecStop/SIGKILL). On ne scanne QUE le boot courant (depuis
# ActiveEnterTimestamp) pour ne pas confondre avec le marqueur d'un boot antérieur.
# Usage: wait_for_server_ready [timeout_seconds]
wait_for_server_ready() {
    local timeout="${1:-300}"
    server_is_active || return 0

    local since_ts since_epoch
    since_ts="$(systemctl --user show "${PZ_SERVICE_NAME}" -p ActiveEnterTimestamp --value 2>/dev/null)"
    since_epoch="$(date -d "$since_ts" +%s 2>/dev/null || echo 0)"
    # Si l'horodatage de boot est illisible, on ne peut pas cibler le boot courant
    # sans risquer de matcher un marqueur ancien -> on dégrade au comportement
    # historique (pas d'attente) plutôt que de bloquer ou de fausser la détection.
    (( since_epoch > 0 )) || return 0

    local start elapsed=0
    start="$(date +%s)"
    while (( elapsed < timeout )); do
        server_is_active || return 0
        if journalctl --user -u "${PZ_SERVICE_NAME}" --since "@${since_epoch}" \
            --no-pager 2>/dev/null | grep -qF "$SERVER_READY_MARKER"; then
            return 0
        fi
        sleep 3
        elapsed=$(( $(date +%s) - start ))
    done
    return 1
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
