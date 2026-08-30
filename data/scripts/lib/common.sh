#!/usr/bin/env bash
# Library commune pour tous les scripts pzmanager

# Racine de l'installation (pzmanager/), déduite de l'emplacement de ce fichier
# — data/scripts/lib/common.sh, donc trois niveaux au-dessus. Le .env vit à cette
# racine (et non plus dans scripts/) : l'ancrer ici une fois pour toutes évite que
# chaque script recompte ses "..", et rend le prochain déplacement d'arborescence
# indolore (seule cette ligne dépend de la profondeur).
PZ_MANAGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Charge .env avec création automatique depuis .env.example
# Usage: source_env [racine]   (défaut : PZ_MANAGER_ROOT)
source_env() {
    local root="${1:-$PZ_MANAGER_ROOT}"
    local env_file="${root}/.env"
    local env_example="${root}/data/setupTemplates/.env.example"

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
    # PZ_MANAGER_DIR est un ALIAS de la racine déduite, pas une seconde source de
    # vérité : la moitié des scripts l'utilisaient (checkHeapAndRestart, fullBackup,
    # notifyServerReady...) et l'autre PZ_MANAGER_ROOT. Un .env recopié depuis une
    # autre machine faisait alors pointer les deux moitiés sur des arbres différents,
    # et l'écart ne se voyait que dans les chemins de redémarrage automatique.
    : "${PZ_MANAGER_DIR:=${PZ_MANAGER_ROOT}}"
    # Registre des dates de création des comptes. Vit DANS data/ et non dans
    # Zomboid/ : c'est justement ce qui lui permet de survivre à `pzm admin reset`
    # (qui ne déplace que Zomboid/) et donc de garder l'ancienneté des comptes au
    # travers d'un wipe, sans toucher au schéma de la base du monde.
    : "${WHITELIST_LEDGER:=${PZ_DATA_DIR}/whitelistLedger.csv}"
    export PZ_SERVER_NAME PZ_DB_PATH PZ_INI_PATH PZ_MANAGER_DIR WHITELIST_LEDGER
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

# Toute opération qui lit ou écrit la base du monde passe par ici : le message
# d'installation était recopié à l'identique dans quatre scripts.
require_sqlite() {
    command -v sqlite3 &>/dev/null || die "sqlite3 non installé. Installer avec: sudo apt install sqlite3"
}

# Mot de passe admin aléatoire (premier démarrage / nouveau monde). La même
# ligne vivait dans configurationInitiale.sh et resetServer.sh.
generate_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24
}

# Chemin du players.db (personnages multijoueur) sous une racine Zomboid donnée
# — le monde live (PZ_SOURCE_DIR) comme un dossier de backup, d'où le paramètre.
# -maxdepth 2 : le fichier est toujours à Saves/Multiplayer/<monde>/players.db,
# alors qu'un find non borné parcourt ~578 000 entrées de l'arbre de sauvegarde.
find_players_db() {
    find "${1}/Saves/Multiplayer" -maxdepth 2 -name 'players.db' 2>/dev/null | head -1
}

# Âge en secondes d'un fichier-marqueur (verrou de notification, cooldown,
# horodatage de dernier passage). Un marqueur ABSENT vaut « très vieux » (epoch 0)
# : c'est ce que veulent les quatre appelants, qui traitent tous l'absence comme
# « le délai est écoulé, vas-y ».
marker_age_seconds() {
    echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
}

# Vrai (code 0) si l'argument est un SteamID64 (17 chiffres commençant par 7656119).
is_steamid64() { [[ "$1" =~ ^7656119[0-9]{10}$ ]]; }

# --- Registre des dates de création (CSV hors base du monde) ------------------
# Format : username;steamid;created_at   (created_at = "YYYY-MM-DD HH:MM:SS")
#
# Pourquoi un fichier plutôt qu'une colonne : la base du monde est RECRÉÉE à
# chaque wipe. Une colonne created_at y disparaîtrait à chaque fois (et le code
# qui prétendait la remplir ne l'a jamais créée — elle n'a jamais existé). Le CSV
# vit dans data/, que le reset ne touche pas, donc l'ancienneté des comptes
# traverse les wipes. lastConnection, lui, n'est PAS dupliqué ici : resetServer.sh
# le réinjecte déjà dans la nouvelle base (vérifié le 19/08/2026 — la plus
# ancienne date en base, 2026-06-19, précède la recréation du monde du 05/08).
#
# Règles (voulues par l'admin) : created_at n'est écrit qu'à la PREMIÈRE
# apparition d'un compte et n'est jamais modifié ensuite ; aucune ligne n'est
# jamais supprimée, y compris après une purge — si le joueur revient, il retrouve
# son ancienneté réelle.

# Pseudos des comptes JAMAIS CONNECTÉS dont le registre dit qu'ils datent de plus
# de <days> jours. Comparaison lexicographique : le format ISO se trie comme une
# date, donc pas d'arithmétique d'époques.
ledger_stale_usernames() {
    local days="$1" cutoff
    cutoff="$(date -d "-${days} days" '+%F %T')"
    [[ -f "${WHITELIST_LEDGER}" ]] || return 0
    awk -F';' -v cutoff="$cutoff" '
        /^#/ { next }
        NF >= 3 && $3 != "" && $3 < cutoff { print $1 }
    ' "${WHITELIST_LEDGER}"
}

# Clause SQL WHERE identifiant les comptes `whitelist` inactifs depuis >= <days>
# jours, le compte interne 'admin' toujours exclu. Deux cas réunis :
#   - dernière connexion antérieure à <days> jours ;
#   - JAMAIS connecté ET inscrit au registre depuis plus de <days> jours.
# Partagée par la purge auto (purgeInactivePlayers.sh) et la purge interactive
# (manageWhitelist.sh) pour qu'elles ciblent EXACTEMENT les mêmes comptes — ce
# prédicat ne doit exister qu'à un seul endroit.
#
# Un compte jamais connecté ET absent du registre n'est JAMAIS purgé : on ignore
# son âge, donc on s'abstient. C'est ce qui manquait avant le 18/08/2026, où la
# clause déclarait inactif tout compte sans lastConnection quel que soit son âge —
# un joueur inscrit le jour même perdait son accès au démarrage suivant.
inactive_where_clause() {
    local days="$1"
    local clause="(lastConnection < date('now', '-${days} days') AND lastConnection IS NOT NULL AND lastConnection <> '')"

    local -a stale=()
    local u
    while IFS= read -r u; do
        [[ -n "$u" ]] && stale+=("'$(sql_escape "$u")'")
    done < <(ledger_stale_usernames "$days")

    if (( ${#stale[@]} > 0 )); then
        local list; list="$(IFS=,; echo "${stale[*]}")"
        clause="${clause} OR ((lastConnection IS NULL OR lastConnection = '') AND username IN (${list}))"
    fi
    echo "(( ${clause} ) AND username <> 'admin')"
}

# Vrai (code 0) si le service serveur Zomboid tourne actuellement.
# Requiert que source_env ait été appelé (PZ_SERVICE_NAME).
server_is_active() {
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" 2>/dev/null
}

# Refuse d'aller plus loin si le serveur tourne. Toute écriture directe dans le
# monde (<world>.db, players.db, fichiers de save) DOIT passer par ici : le jeu
# garde ces fichiers ouverts et réécrit son état depuis sa mémoire, donc une
# modification faite à chaud est au mieux perdue, au pire corrompue.
# Usage: require_server_stopped [contexte du --reason suggéré] [commande d'aperçu]
# Le 2e argument, quand la commande a un --dry-run, donne la ligne exacte pour
# voir ce qui serait fait sans arrêter le serveur : le refus seul laissait
# l'appelant sans aucune façon d'inspecter.
require_server_stopped() {
    local context="${1:-Maintenance}" preview="${2:-}"
    if server_is_active; then
        die "Le serveur est actif : cette opération écrit dans le monde et doit se faire SERVEUR ARRÊTÉ.
Arrête-le d'abord :  pzm server stop 2m --reason \"${context}\"${preview:+
Voir ce qui serait fait, sans rien changer :  ${preview}}"
    fi
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

    # Robustesse (bug 2026-07-20 : boucle de 300s sur un serveur POURTANT prêt).
    # Le marqueur ne sert qu'à distinguer un boot EN COURS d'un serveur prêt, ce qui
    # n'a d'intérêt que dans les premières minutes après un démarrage. Si le service
    # est actif depuis plus longtemps qu'un boot (BOOT_GRACE), il est FORCÉMENT
    # booté -> on rend la main sans scanner le journal. Raison : sur un long uptime,
    # scanner tout le journal depuis ActiveEnterTimestamp (des heures, des dizaines de
    # milliers de lignes, ~Go) est lourd et s'est révélé non fiable sous pression
    # mémoire (journalctl renvoyait vide -> marqueur jamais vu -> boucle 300s muette,
    # aucun message envoyé). On ne garde le scan (fenêtre alors petite) que pendant la
    # fenêtre de boot, seul moment où un `quit` prématuré fait planter B42.
    local BOOT_GRACE=240
    (( $(date +%s) - since_epoch > BOOT_GRACE )) && return 0

    # Feedback : le chemin rapide (marqueur déjà présent) reste MUET. On n'affiche
    # quelque chose que si on doit réellement patienter, pour qu'un stop/restart
    # lancé pendant un boot n'ait plus l'air gelé (aucun message n'est envoyé aux
    # joueurs tant que cette attente n'est pas finie -> sinon on croit à un bug).
    local start elapsed=0 announced=false last_notice=0
    start="$(date +%s)"
    while (( elapsed < timeout )); do
        server_is_active || return 0
        # Défensif : on COMPTE (grep -cF) au lieu de `grep -qF`. grep -q sort à la 1re
        # occurrence -> SIGPIPE possible vers journalctl ; sous `set -o pipefail` (actif
        # dans pz.sh) ce 141 pourrait fausser le `if`. grep -cF lit tout le flux (pas de
        # SIGPIPE) ; `|| true` absorbe le retour 1 quand il n'y a aucune occurrence.
        # NB : la VRAIE cause du blocage 300s du 2026-07-20 était le scan géant du
        # journal sur long uptime (corrigé par BOOT_GRACE ci-dessus), pas ce point.
        local hits
        hits="$(journalctl --user -u "${PZ_SERVICE_NAME}" --since "@${since_epoch}" \
            --no-pager 2>/dev/null | grep -cF "$SERVER_READY_MARKER" || true)"
        if (( hits > 0 )); then
            $announced && echo "Boot du serveur terminé — poursuite de l'opération."
            return 0
        fi
        if ! $announced; then
            echo "Le serveur est encore en train de booter (chargement de la map) ;"
            echo "attente de la fin du boot avant d'agir (évite le crash-loop B42, max ${timeout}s)..."
            announced=true
            last_notice=$elapsed
        elif (( elapsed - last_notice >= 15 )); then
            echo "  ... toujours en attente de la fin du boot (${elapsed}s / ${timeout}s)"
            last_notice=$elapsed
        fi
        sleep 3
        elapsed=$(( $(date +%s) - start ))
    done
    echo "AVERTISSEMENT : fin de boot toujours non signalée après ${timeout}s." >&2
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
        (( $(marker_age_seconds "$lock_file") > max_age )) && rm -f "$lock_file"
    fi

    exec 200>"$lock_file"
    flock -n 200
}

# Libère le verrou pris par try_acquire_maintenance_lock. Passe par ici plutôt que
# par un `flock -u 200` chez l'appelant : le numéro de fd est un détail interne, et
# un appelant qui le devine se retrouve à déverrouiller dans le vide le jour où il
# change (la maintenance suivante se croirait alors déjà en cours et s'auto-skipperait).
release_maintenance_lock() {
    flock -u 200 2>/dev/null || true
}
