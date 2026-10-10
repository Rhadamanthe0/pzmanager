#!/usr/bin/env bash
# Library commune pour tous les scripts pzmanager

# Racine de l'installation (pzmanager/), déduite de l'emplacement de ce fichier
# — data/scripts/lib/common.sh, donc trois niveaux au-dessus. Le .env vit à cette
# racine (et non plus dans scripts/) : l'ancrer ici une fois pour toutes évite que
# chaque script recompte ses "..", et rend le prochain déplacement d'arborescence
# indolore (seule cette ligne dépend de la profondeur).
PZ_MANAGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# C1 (verrou global + état serveur) : protocole unique partagé par toutes les
# opérations qui touchent au monde (world_lock.sh) et état prouvé fail-closed
# (server_state.sh). Sourcing OPTIONNEL : si les libs sont absentes, les
# gardes ci-dessous dégradent vers l'inspection directe de systemctl (toujours
# fail-closed sur erreur). Les verrous MAINTENANCE/SERVERCTL historiques sont
# CONSERVÉS : pour les opérations destructrices, le verrou monde les ENGLOBE
# (ordre d'acquisition global : WORLD -> SERVERCTL -> verrou spécifique).
_PZ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forme `if` explicite : lib absente = on saute (sourcing optionnel, les
# gardes ci-dessous dégradent vers l'inspection directe de systemctl, toujours
# fail-closed). En revanche une lib PRÉSENTE mais en erreur de lecture fait
# sortir le script aussitôt (fail-closed : pas de garde silencieuse).
if [[ -f "${_PZ_LIB_DIR}/world_lock.sh" ]]; then source "${_PZ_LIB_DIR}/world_lock.sh"; fi
if [[ -f "${_PZ_LIB_DIR}/server_state.sh" ]]; then source "${_PZ_LIB_DIR}/server_state.sh"; fi
unset _PZ_LIB_DIR

# Charge .env avec création automatique depuis .env.example
# Usage: source_env [racine]   (défaut : PZ_MANAGER_ROOT)
source_env() {
    local root="${1:-$PZ_MANAGER_ROOT}"
    local env_file="${root}/.env"
    local env_example="${root}/data/setupTemplates/.env.example"

    if [[ ! -f "$env_file" ]] && [[ -f "$env_example" ]]; then
        # install -m 600 et non `cp` : le .env porte le webhook Discord, le token
        # du bot et la clé privée du compte de service Google (base64). Un `cp`
        # applique l'umask (022 par défaut) et publiait donc ces trois secrets en
        # lecture à tout le monde sur la machine dès la première exécution.
        install -m 600 "$env_example" "$env_file"
        echo "Fichier .env créé depuis .env.example. Éditez-le pour configurer votre installation."
    fi

    [[ -f "$env_file" ]] || {
        echo "ERREUR: Fichier .env introuvable: $env_file" >&2
        exit 1
    }

    # Rattrapage pour les installations créées avant le install -m 600 ci-dessus :
    # on resserre un .env trop ouvert au lieu de se contenter de le signaler.
    # Silencieux si on n'en est pas propriétaire (rien à rattraper de toute façon).
    if [[ -O "$env_file" && "$(stat -c %a "$env_file" 2>/dev/null || echo 600)" != "600" ]]; then
        chmod 600 "$env_file" 2>/dev/null || true
    fi

    source "$env_file"
    apply_env_defaults
}

# Valeurs par défaut de TOUTE la configuration.
#
# source_env ne copie .env.example que si .env est ABSENT : il ne fusionne jamais
# les nouvelles clés dans un .env existant. Sans défaut, toute clé ajoutée par une
# mise à jour casse les installations antérieures sur « variable sans liaison »
# (set -u) — et pas au même endroit pour tout le monde : WHITELIST_PURGE_DAYS,
# par exemple, avait un `:-90` dans purgeInactivePlayers.sh mais pas dans
# manageWhitelist.sh, où `pzm whitelist help` mourait sur un message bash brut.
#
# On couvre donc ici la totalité des clés de .env.example, dérivées de la racine
# déduite (PZ_MANAGER_ROOT) exactement comme le fait le gabarit. Conséquence utile :
# .env redevient un fichier de SURCHARGE — `:=` n'écrase jamais une valeur définie.
apply_env_defaults() {
    # --- Utilisateur et chemins de base ---
    : "${PZ_USER:=$(id -un)}"
    # C17 (split-users) : la JVM tourne sous PZ_GAME_USER, l'admin sous
    # PZ_MANAGER_USER. Défaut = PZ_USER pour les deux : une install existante
    # mono-user (ou un .env sans ces clés) fonctionne exactement comme avant.
    : "${PZ_GAME_USER:=${PZ_USER}}"
    : "${PZ_MANAGER_USER:=${PZ_USER}}"
    : "${PZ_GAME_HOME:=/home/${PZ_GAME_USER}}"
    : "${PZ_MANAGER_HOME:=/home/${PZ_MANAGER_USER}}"
    # PZ_MANAGER_DIR est un ALIAS de la racine déduite, pas une seconde source de
    # vérité : la moitié des scripts l'utilisaient (checkHeapAndRestart, fullBackup,
    # notifyServerReady...) et l'autre PZ_MANAGER_ROOT. Un .env recopié depuis une
    # autre machine faisait alors pointer les deux moitiés sur des arbres différents,
    # et l'écart ne se voyait que dans les chemins de redémarrage automatique.
    : "${PZ_MANAGER_DIR:=${PZ_MANAGER_ROOT}}"
    : "${PZ_HOME:=$(dirname "${PZ_MANAGER_DIR}")}"
    : "${PZ_DATA_DIR:=${PZ_MANAGER_DIR}/data}"
    : "${PZ_SCRIPTS_DIR:=${PZ_DATA_DIR}/scripts}"

    # --- Serveur Project Zomboid ---
    : "${PZ_INSTALL_DIR:=${PZ_DATA_DIR}/pzserver}"
    : "${PZ_CONTROL_PIPE:=${PZ_INSTALL_DIR}/zomboid.control}"
    : "${PZ_SERVICE_NAME:=zomboid.service}"
    : "${PZ_SOURCE_DIR:=${PZ_MANAGER_DIR}/Zomboid}"
    # Nom du monde PZ ; "servertest" est le défaut du jeu. Voir .env.example.
    : "${PZ_SERVER_NAME:=servertest}"
    : "${PZ_DB_PATH:=${PZ_SOURCE_DIR}/db/${PZ_SERVER_NAME}.db}"
    : "${PZ_INI_PATH:=${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}.ini}"

    # --- SteamCMD ---
    : "${STEAMCMD_PATH:=/usr/games/steamcmd}"
    : "${STEAM_APP_ID:=380870}"
    # Vide = branche publique (stable). Voir steam_beta_branch() plus bas : le nom
    # interne Valve de cette branche est "public", et il doit être passé
    # EXPLICITEMENT à steamcmd.
    : "${STEAM_BETA_BRANCH:=}"
    : "${STEAM_LOGIN:=}"

    # --- Java ---
    : "${JAVA_VERSION:=25}"
    : "${JAVA_PACKAGE:=openjdk-${JAVA_VERSION}-jre-headless}"
    : "${JAVA_PATH:=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64}"
    # Source des paquets JDK : "debian" (depots de la distribution, defaut sur)
    # ou "temurin" (Adoptium, nommage temurin-<v>-jre). Lu par
    # lib/jdk_matrix.sh (resolve_java_package) a l'installation.
    : "${PZ_JDK_SOURCE:=debian}"

    # --- Sauvegardes ---
    : "${BACKUP_DIR:=${PZ_DATA_DIR}/dataBackups}"
    : "${BACKUP_LATEST_LINK:=${BACKUP_DIR}/latest}"
    : "${SYNC_BACKUPS_DIR:=${PZ_DATA_DIR}/fullBackups}"

    # --- Journaux ---
    : "${LOG_BASE_DIR:=${PZ_MANAGER_DIR}/logs}"
    : "${LOG_ZOMBOID_DIR:=${LOG_BASE_DIR}/zomboid}"
    : "${LOG_MAINTENANCE_DIR:=${LOG_BASE_DIR}/maintenance}"
    : "${LOG_RETENTION_DAYS:=30}"

    # --- Liste blanche ---
    : "${WHITELIST_PURGE_DAYS:=90}"
    # Registre des dates de création des comptes. Vit DANS data/ et non dans
    # Zomboid/ : c'est justement ce qui lui permet de survivre à `pzm admin reset`
    # (qui ne déplace que Zomboid/) et donc de garder l'ancienneté des comptes au
    # travers d'un wipe, sans toucher au schéma de la base du monde.
    : "${WHITELIST_LEDGER:=${PZ_DATA_DIR}/whitelistLedger.csv}"

    export PZ_USER PZ_GAME_USER PZ_MANAGER_USER PZ_GAME_HOME PZ_MANAGER_HOME PZ_HOME PZ_MANAGER_DIR PZ_DATA_DIR PZ_SCRIPTS_DIR \
           PZ_INSTALL_DIR PZ_CONTROL_PIPE PZ_SERVICE_NAME PZ_SOURCE_DIR \
           PZ_SERVER_NAME PZ_DB_PATH PZ_INI_PATH \
           STEAMCMD_PATH STEAM_APP_ID STEAM_BETA_BRANCH STEAM_LOGIN \
            JAVA_VERSION JAVA_PACKAGE JAVA_PATH PZ_JDK_SOURCE \
           BACKUP_DIR BACKUP_LATEST_LINK SYNC_BACKUPS_DIR \
           LOG_BASE_DIR LOG_ZOMBOID_DIR LOG_MAINTENANCE_DIR LOG_RETENTION_DAYS \
           WHITELIST_PURGE_DAYS WHITELIST_LEDGER
}

# Nom de branche Steam à passer à `steamcmd -beta`. STEAM_BETA_BRANCH vide = la
# branche par défaut, dont le nom interne Valve est "public".
#
# Il FAUT passer -beta EXPLICITEMENT : ne rien passer n'efface PAS une beta déjà
# gravée dans le manifeste (UserConfig/MountedConfig "BetaKey"), donc app_update
# revalide l'ancienne beta au lieu de basculer sur public. C'est ce qui a causé la
# boucle « Mise à jour serveur disponible » -> maintenance -> reboot toutes les
# ~10 min au passage 42.19 -> stable le 05/08/2026. `-beta ""` reste proscrit :
# steamcmd avalerait le token suivant comme nom de branche.
#
# Les trois appelants (maintenance, modcheck, installation) recopiaient la même
# expression `${STEAM_BETA_BRANCH:-public}` avec le même paragraphe d'explication.
steam_beta_branch() { echo "${STEAM_BETA_BRANCH:-public}"; }

# SteamCMD sans exposer le login dans argv (lisible via /proc et ps) : le
# `login` transite par un runscript temporaire (mktemp = 0600, nom aléatoire),
# exécuté via `+runscript` puis effacé — l'argv ne montre que le chemin du
# fichier, jamais le compte. Chaque argument = une ligne du script (`quit`
# ajouté d'office). Le login est refusé s'il contient un saut de ligne ou un
# guillemet (injection de commande du runscript) ; les chemins/IDs sont cités
# par l'appelant. STEAMCMD_AS_USER (optionnel) : exécute sous cet utilisateur
# (installation root via sudo) après lui avoir confié le fichier.
# Usage: steamcmd_runscript <login> <ligne>...
steamcmd_runscript() {
    local login="$1"; shift
    [[ "$login" != *$'\n'* && "$login" != *\"* ]] \
        || die "STEAM_LOGIN invalide (saut de ligne ou guillemet) : login steamcmd refusé."
    local script
    script="$(mktemp "${TMPDIR:-/tmp}/pz-steamcmd-XXXXXX")" || die "Impossible de créer le runscript steamcmd."
    printf '%s\n' "$@" 'quit' > "$script"
    local rc=0
    if [[ -n "${STEAMCMD_AS_USER:-}" ]]; then
        chown -- "${STEAMCMD_AS_USER}:${STEAMCMD_AS_USER}" "$script" || { rm -f -- "$script"; die "Impossible de confier le runscript steamcmd à ${STEAMCMD_AS_USER}."; }
        sudo -u "${STEAMCMD_AS_USER}" "${STEAMCMD_PATH}" +runscript "$script" || rc=$?
    else
        "${STEAMCMD_PATH}" +runscript "$script" || rc=$?
    fi
    rm -f -- "$script"
    return "$rc"
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
# Conservé pour compat (lecture seule : status, délais...) : sur erreur
# systemd il répond FAUX comme avant — ne jamais s'en servir comme garde
# d'écriture, utiliser require_server_stopped / server_is_active_strict.
server_is_active() {
    systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" 2>/dev/null
}

# C1 : comme server_is_active, mais fail-closed. Meurt au lieu de répondre
# « arrêté » quand l'état est indéterminé (bus user injoignable, unité
# inconnue...). `failed` y meurt aussi : un crash ne prouve pas un arrêt
# propre — les opérations destructrices exigent `inactive` (voir
# assert_server_stopped_proven dans lib/server_state.sh).
# `activating`/`deactivating` valent « actif » (démarrage/arrêt en cours).
server_is_active_strict() {
    if declare -F server_state >/dev/null 2>&1; then
        local st
        st="$(server_state)"
        case "$st" in
            active|activating|deactivating) return 0 ;;
            inactive) return 1 ;;
            *) die "État serveur indéterminé ('${st}') : refus par sécurité (fail-closed).
Vérifie l'unité ${PZ_SERVICE_NAME} (bus user : systemctl --user) puis réessaie." ;;
        esac
    else
        local rc=0
        systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" 2>/dev/null || rc=$?
        if (( rc == 0 )); then return 0; fi
        if (( rc == 3 || rc == 4 )); then return 1; fi
        die "État serveur indéterminé (systemctl is-active exit=${rc}) : refus par sécurité (fail-closed)."
    fi
}

# Refuse d'aller plus loin si le serveur tourne. Toute écriture directe dans le
# monde (<world>.db, players.db, fichiers de save) DOIT passer par ici : le jeu
# garde ces fichiers ouverts et réécrit son état depuis sa mémoire, donc une
# modification faite à chaud est au mieux perdue, au pire corrompue.
# C1 (fail-closed) : une erreur systemd (bus injoignable...) MEURT au lieu de
# passer comme « arrêté » — `server_is_active` répondait faux sur erreur.
# Acceptation inchangée par ailleurs : `activating`/`deactivating` passent
# (la purge tourne en ExecStartPre, où l'unité est « activating ») et `failed`
# passe (post-crash, process mort). Les opérations destructrices qui exigent
# un arrêt PROUVÉ utilisent assert_server_stopped_proven (inactive seule).
# Usage: require_server_stopped [contexte affiché dans le --reason suggéré]
# Pour une commande qui a un --dry-run, ne PAS appeler ceci : basculer en aperçu,
# afficher le plan, puis terminer par die_server_active — un refus nu oblige
# sinon à couper le serveur juste pour savoir ce que la commande aurait fait.
require_server_stopped() {
    local context="${1:-Maintenance}"
    if declare -F server_state >/dev/null 2>&1; then
        local st
        st="$(server_state)"
        case "$st" in
            inactive|activating|deactivating|failed)
                return 0
                ;;
            active)
                die "Le serveur est actif : cette opération écrit dans le monde et doit se faire SERVEUR ARRÊTÉ.
Arrête-le d'abord :  pzm server stop 2m --reason \"${context}\""
                ;;
            *)
                die "État serveur indéterminé ('${st}') : ${context} refuse de s'exécuter sans preuve d'arrêt (fail-closed).
Vérifie l'unité ${PZ_SERVICE_NAME} (bus user : systemctl --user) puis réessaie."
                ;;
        esac
    else
        # Dégradation sans lib/server_state.sh : distingue l'erreur (exit autre
        # que 0/3/4 = bus ou systemctl en panne) de l'arrêt (3/4).
        local rc=0
        systemctl --user is-active --quiet "${PZ_SERVICE_NAME}" 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            die "Le serveur est actif : cette opération écrit dans le monde et doit se faire SERVEUR ARRÊTÉ.
Arrête-le d'abord :  pzm server stop 2m --reason \"${context}\""
        fi
        if (( rc == 3 || rc == 4 )); then
            return 0
        fi
        die "État serveur indéterminé (systemctl is-active exit=${rc}) : ${context} refuse de s'exécuter sans preuve d'arrêt (fail-closed)."
    fi
}

# Refus « serveur actif », à émettre APRÈS avoir affiché l'aperçu.
die_server_active() {
    local context="${1:-Maintenance}"
    die "Rien n'a été modifié : le serveur est actif et cette opération écrit dans le monde.
Arrête-le puis relance la commande :  pzm server stop 2m --reason \"${context}\""
}

# Marqueur journald de fin d'initialisation Lua. B42 n'imprime plus
# "*** SERVER STARTED ****" (disparu vers la 42.x de juin 2026).
#
# ⚠️ Il est émis à `f:0`, donc AVANT le premier tour de boucle : il ne prouve pas
# à lui seul qu'un `quit` est sûr. Il était présent dès 13:32:13 le 02/09/2026
# dans la session de 13:31 dont la boucle n'a jamais démarré, 3 joueurs connectés
# et 0 frame en 15 min — c'est exactement la fenêtre où le `quit` fait planter
# B42. Ne pas s'en servir seul : utiliser game_loop_started() ci-dessous.
#
readonly SERVER_READY_MARKER="LuaNet: Initialization [DONE]"

# Preuve que la boucle de jeu du boot COURANT tourne : le compteur de frames que
# le jeu préfixe à chaque ligne de log. Il reste à `f:0` pendant tout le
# chargement et ne passe à `f:1` qu'au premier tour de boucle. C'est le seul
# signal qui distingue « chargé » de « en train de charger ».
#
# `-n` lit le journal à l'envers : le coût ne dépend pas de l'uptime, ce qui
# permet de supprimer l'ancien raccourci « actif depuis > 240 s donc forcément
# booté ». Cette inférence était fausse — le 02/09 l'arrêt est parti après 829 s
# sur un serveur qui n'avait jamais démarré sa boucle — et elle l'est d'autant
# plus que les boots sains vont ici de 79 s à 44 min (les longs suivent une mise
# à jour SteamCMD).
#
# Retour : 0 = boucle démarrée, 1 = encore en boot, 2 = indéterminé (aucune ligne
# horodatée `f:` dans la fenêtre — l'appelant retombe sur le marqueur Lua).
# grep -c plutôt que grep -q : -q sort à la 1re occurrence et peut SIGPIPE
# journalctl, ce qui sous `set -o pipefail` fausserait le test.
game_loop_started() {
    local since_epoch="$1" lines
    lines="$(journalctl --user -u "${PZ_SERVICE_NAME}" --since "@${since_epoch}" \
        -n 400 --no-pager 2>/dev/null | grep -oE 'f:[0-9]+ st:' || true)"
    [[ -n "$lines" ]] || return 2
    grep -qE 'f:[1-9][0-9]* st:' <<< "$lines"
}

# Le marqueur de fin d'init Lua est-il présent depuis l'instant donné (epoch) ?
# Filtrage par journald (--grep), pas par un `-n N | grep` : le marqueur tombe au
# DÉBUT du boot et sortait donc du tampon des N dernières lignes dès que le
# serveur avait un peu écrit. `--grep` est une regex -> on cherche la partie sans
# crochets ([DONE] serait une classe de caractères) puis on confirme en littéral.
marker_seen_since() {
    local since_epoch="$1" hits
    hits="$(journalctl --user -u "${PZ_SERVICE_NAME}" --since "@${since_epoch}" \
        --grep 'LuaNet: Initialization' -n 1 --no-pager 2>/dev/null \
        | grep -cF "$SERVER_READY_MARKER" || true)"
    (( hits > 0 ))
}

# Attend que le serveur ait FINI de booter (map chargée) avant de rendre la main.
# CRUCIAL : un `quit`/stop envoyé pendant le chargement de la map fait planter
# B42 (NullPointerException zombie.iso.IsoMetaGrid.save, grid=null) -> crash-loop
# (incident du 2026-07-20 : un 2e restart lancé pendant le boot du 1er). Tant que
# la boucle de jeu n'a pas démarré, il ne faut jamais arrêter le serveur.
# Retour 0 dès que le boot courant est terminé (ou si le serveur n'est pas actif :
# rien à attendre). Retour 1 sur timeout (actif mais fin de boot jamais signalée)
# -> pz.sh refuse l'arrêt : un timeout ne prouve pas qu'un SIGKILL est sûr.
# On ne scanne QUE le boot courant (depuis
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
        # Signal primaire : la boucle de jeu tourne-t-elle ? Coût indépendant de
        # l'uptime, donc utilisable aussi bien sur un serveur qui vient de démarrer
        # que sur un qui tourne depuis des jours.
        local probe=0
        game_loop_started "$since_epoch" || probe=$?
        if (( probe == 0 )); then
            $announced && echo "Boucle de jeu démarrée — poursuite de l'opération."
            return 0
        fi

        # probe == 2 : aucune ligne `f:` dans la fenêtre (log inhabituellement
        # muet). On retombe alors sur le marqueur Lua, prématuré mais meilleur que
        # rien. Sur probe == 1 (f:0 vu), le marqueur ne prouve pas que la boucle a
        # démarré. Le nombre instantané de joueurs ne change pas cette conclusion :
        # un boot bloqué peut être vide ou le devenir après une déconnexion.
        if (( probe == 2 )); then
            # marker_seen_since : filtrage par journald. L'ancienne forme
            # `--since @boot -n 2000 | grep` ne trouvait plus rien dès que le
            # serveur avait écrit plus de 2000 lignes depuis le marqueur — celui-ci
            # tombe au DÉBUT du boot et `-n` garde les DERNIÈRES lignes (constaté
            # ici après 4 h à f:0 et 8 819 lignes : le repli ne s'armait jamais).
            if marker_seen_since "$since_epoch"; then
                $announced && echo "Boot du serveur terminé — poursuite de l'opération."
                return 0
            fi
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

# --- Répertoire privé pour marqueurs/verrous (anti-/tmp prévisible) ---------------
# Même motif que world_lock_path (lib/world_lock.sh) pour le verrou monde : le
# marqueur de cooldown heapcheck et les verrous /tmp prévisibles laissaient un
# autre utilisateur local bloquer les restarts (fichier futur) ou les opérations
# serveur/backup (flock adverse, pré-création hostile). Ce helper donne le même
# abri à tous : ${XDG_RUNTIME_DIR}/pzmanager/ (géré par pam_systemd, un par
# utilisateur, insensible à PrivateTmp), avec repli /tmp/pzmanager-<user>/ 0700.
# Fail-closed : un dossier de repli pré-créé par un tiers (non possédé) fait
# échouer l'appel (retour 1) au lieu d'y écrire.
# Usage: private_state_path <nom-fichier>  -> imprime le chemin (crée le dossier 0700)
private_state_path() {
    local name="${1:-}" user runtime dir
    # Nom simple uniquement : pas de chemin (échappée du dossier privé impossible).
    [[ -n "$name" && "$name" != *"/"* ]] || return 1
    user="$(id -un 2>/dev/null || echo unknown)"
    runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}"
    if [[ -n "$runtime" && -d "$runtime" ]]; then
        dir="${runtime}/pzmanager"
    else
        # Repli : pas de runtime (service sans session user...). Partagé, donc
        # la possession exclusive est vérifiée ci-dessous avant tout usage.
        dir="/tmp/pzmanager-${user}"
    fi
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 0700 "$dir" 2>/dev/null || true
    [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
    printf '%s\n' "${dir}/${name}"
}

# --- Verrous d'exclusion mutuelle ---------------------------------------------
# Tous les verrous du produit passent par flock. Deux propriétés en découlent, et
# c'est tout ce qu'il faut savoir : le verrou est pris atomiquement (pas de fenêtre
# entre « tester » et « créer »), et il est RELÂCHÉ PAR LE NOYAU à la mort du
# process, quelle qu'en soit la cause (kill, timeout systemd, panne). Il ne peut
# donc pas exister de verrou fantôme.
#
# Corollaire, et c'est ce qui a été retiré ici : le nettoyage « si le fichier a
# plus d'une heure, je le supprime » ne servait à rien et CASSAIT la garantie
# ci-dessus. Le mtime du fichier date de sa CRÉATION et n'est jamais rafraîchi ;
# une maintenance légitimement longue (apt + steamcmd validate + backup hors-site)
# se faisait donc supprimer son fichier de verrou sous les pieds, après quoi
# l'exécution suivante en créait un nouveau et démarrait EN PARALLÈLE — exactement
# la collision que le verrou existait pour empêcher.
#
# Le descripteur est alloué dynamiquement (`exec {var}>`) plutôt que codé en dur :
# les numéros 200/201 étaient écrits en clair dans trois fichiers, et un appelant
# qui devinait « 200 » se retrouvait à déverrouiller dans le vide le jour où il
# changeait (la maintenance suivante se croyait alors déjà en cours et s'auto-ignorait).
readonly MAINTENANCE_LOCK_FILE="/tmp/pzmanager-maintenance-$(id -un).lock"
MAINTENANCE_LOCK_FD=""

# Verrou de cycle de vie partagé par les commandes `pzm server` et les écritures
# directes dans les bases du monde. Une commande qui exige un serveur arrêté le
# conserve de sa vérification jusqu'à sa dernière écriture : `pzm server start`
# ne peut donc pas s'intercaler entre les deux.
SERVERCTL_LOCK_FILE=""
SERVERCTL_LOCK_FD=""

# Le chemin partagé prévisible permettait à un autre utilisateur de tenir
# un flock adverse. Résoudre seulement à l'acquisition : common.sh sert aussi
# aux lecteurs et à l'ExecStartPre confiné, qui n'ont pas besoin de ce verrou.
serverctl_lock_path() {
    local runtime dir parent owner mode lock_file
    runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    [[ "$runtime" == /* ]] || return 1
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        [[ -d "$runtime" && ! -L "$runtime" && -O "$runtime" ]] || return 1
        dir="${runtime}/pzmanager"
    else
        dir="/tmp/pzmanager-$(id -un)"
    fi
    # Un répertoire privé sous un parent remplaçable ne protège pas son inode.
    # Le parent sticky possédé par root (/tmp) préserve ses enfants possédés.
    parent="$(dirname "$dir")"
    while :; do
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        owner="$(stat -c %u "$parent")" || return 1
        mode="$(stat -c %a "$parent")" || return 1
        [[ "$owner" == 0 || -O "$parent" ]] || return 1
        if (( (8#$mode & 0022) != 0 )); then
            [[ "$owner" == 0 && -k "$parent" ]] || return 1
        fi
        [[ "$parent" == / ]] && break
        parent="$(dirname "$parent")"
    done
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
    else
        (umask 077; mkdir -m 0700 -- "$dir") || return 1
    fi
    # Même sélection que private_state_path, mais résolue une seule fois :
    # l'apparition du runtime ne doit pas déplacer le verrou après validation.
    chmod 0700 -- "$dir" || return 1
    [[ "$(stat -c %a "$dir")" == 700 ]] || return 1
    lock_file="${dir}/serverctl.lock"
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        [[ -f "$lock_file" && ! -L "$lock_file" && -O "$lock_file" ]] || return 1
        [[ "$(stat -c %h "$lock_file")" == 1 ]] || return 1
    fi
    printf '%s\n' "$lock_file"
}

# Prend un verrou flock NON BLOQUANT sur $1 et publie le fd dans la variable
# nommée $2. Retour 0 si acquis, 1 si déjà tenu par quelqu'un d'autre.
# Usage: try_lock /chemin/du.lock NOM_DE_VARIABLE_FD
try_lock() {
    local lock_file="$1" fd_var="$2" fd
    exec {fd}>"$lock_file" || return 1
    if flock -n "$fd"; then
        printf -v "$fd_var" '%s' "$fd"
        return 0
    fi
    exec {fd}>&-
    return 1
}

# Usage: acquire_serverctl_lock_or_die [message si le verrou est occupé]
acquire_serverctl_lock_or_die() {
    local message="${1:-}"
    [[ -n "$message" ]] || message="Une opération serveur ou une écriture dans le monde est déjà en cours. Attends qu'elle se termine."
    SERVERCTL_LOCK_FILE="$(serverctl_lock_path)" \
        || die "Répertoire ou fichier du verrou serverctl non sûr : opération refusée."
    try_lock "$SERVERCTL_LOCK_FILE" SERVERCTL_LOCK_FD || die "$message"
}

# Verrou de maintenance, partagé par pz.sh / modcheck / performFullMaintenance.
# Usage: try_acquire_maintenance_lock [lock_file]
# Returns: 0 si acquis, 1 s'il est déjà tenu.
try_acquire_maintenance_lock() {
    try_lock "${1:-$MAINTENANCE_LOCK_FILE}" MAINTENANCE_LOCK_FD
}

# Libère le verrou pris par try_acquire_maintenance_lock. Passe par ici plutôt que
# par un `flock -u` chez l'appelant : le descripteur est un détail interne.
# No-op si le verrou n'a jamais été pris.
release_maintenance_lock() {
    [[ -n "$MAINTENANCE_LOCK_FD" ]] || return 0
    flock -u "$MAINTENANCE_LOCK_FD" 2>/dev/null || true
    exec {MAINTENANCE_LOCK_FD}>&- 2>/dev/null || true
    MAINTENANCE_LOCK_FD=""
}

# --- Notification Discord ------------------------------------------------------
# Six scripts appelaient sendDiscord.sh par un chemin relatif recompté à la main
# ("${SCRIPT_DIR}/../internal/sendDiscord.sh" ici, "${SCRIPT_DIR}/sendDiscord.sh"
# là) : autant d'occasions de se tromper de nombre de "..", et une notification
# qui disparaît en silence quand on déplace un script d'un niveau.
# Toujours non bloquant : Discord est optionnel, une panne de webhook ne doit
# jamais faire échouer un arrêt de serveur ou une maintenance.
# Usage: notify "message" [--webhook URL]
notify() {
    "${PZ_MANAGER_ROOT}/data/scripts/internal/sendDiscord.sh" "$@" || true
}
