#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, git pull, reboot)
# Usage: ./performFullMaintenance.sh [délai] [options]
# Options: --reason TEXT (raison de maintenance), --automatic (flag si auto), --silent
# Lock partagé avec pz.sh/triggerMaintenanceOnModUpdate.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/.silent_next_start"

# C9 : machine à états récupérable (minimum de changements, inline).
# Fichier d'état : ${XDG_RUNTIME_DIR}/pzmanager/maintenance.state si le runtime
# existe (partagé, insensible à PrivateTmp comme le verrou monde), sinon repli
# ${PZ_MANAGER_DIR}/.maintenance.state. PZ_MAINT_STATE_FILE permet aux tests de
# rediriger l'état vers un sandbox.
# États : INIT→STOPPED→SYSTEM→STEAM→MODS→BACKUP→SELF→DONE/FAILED. L'état est
# écrit AVANT chaque phase ; la reprise est armée AVANT le stop (fichier
# ${STATE}.recovery_armed + trap EXIT déjà posé) et n'est désarmée qu'après la
# validation finale (service actif + JVM + ready). Une relance qui trouve un
# état non terminal + reprise armée = crash mid-maintenance -> rollback minimal
# (redémarrage serveur + message) puis reprise du parcours.
maint_state_file() {
    local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}"
    if [[ -n "$runtime" && -d "$runtime" ]] && mkdir -p "${runtime}/pzmanager" 2>/dev/null; then
        printf '%s\n' "${runtime}/pzmanager/maintenance.state"
    else
        printf '%s\n' "${PZ_MANAGER_DIR}/.maintenance.state"
    fi
}
readonly MAINT_STATE_FILE="${PZ_MAINT_STATE_FILE:-$(maint_state_file)}"
readonly MAINT_RECOVERY_FILE="${MAINT_STATE_FILE}.recovery_armed"
maint_set_state() {
    printf '%s\n' "$1" > "${MAINT_STATE_FILE}" 2>/dev/null || true
    log "État maintenance: $1"
}
maint_arm_recovery() {
    : > "${MAINT_RECOVERY_FILE}" 2>/dev/null || true
}
maint_disarm_recovery() {
    rm -f "${MAINT_RECOVERY_FILE}" 2>/dev/null || true
}
# Si crash mid-maintenance : état non terminal + reprise armée. Rollback minimal
# (redémarre le serveur + message) puis la main() en cours reprend à INIT.
maint_detect_interrupted() {
    local prev=""
    [[ -f "${MAINT_STATE_FILE}" ]] && prev="$(cat "${MAINT_STATE_FILE}" 2>/dev/null || true)"
    case "$prev" in
        INIT|STOPPED|SYSTEM|STEAM|MODS|BACKUP|SELF)
            if [[ -f "${MAINT_RECOVERY_FILE}" ]]; then
                log "Reprise après interruption (état précédent: ${prev}) — redémarrage de sécurité."
                "${SCRIPT_DIR}/../core/pz.sh" start now --reason "Reprise après interruption de maintenance (${prev})" --automatic 2>&1 || \
                    log "WARNING: redémarrage de reprise en échec (non bloquant)" || true
                notify "Maintenance précédente interrompue (${prev}) — serveur redémarré, reprise en cours." || true
            fi
            ;;
    esac
}
validate_final_start() {
    # Différencie 4 niveaux : start DEMANDÉ (pz.sh start a rendu 0, vérifié par
    # l'appelant) vs ACTIF (systemd) vs JVM (processus) vs READY (boucle de jeu).
    if ! server_is_active; then
        log "ERREUR: validation finale — start demandé mais service non actif."
        return 1
    fi
    if ! pgrep -f 'ProjectZomboid64' >/dev/null 2>&1; then
        log "ERREUR: validation finale — service actif mais JVM ProjectZomboid64 absente."
        return 1
    fi
    # wait_for_server_ready ne consomme PAS le délai joueurs (warn_players) : il
    # attend le boot COURANT (boucle f:1, repli marqueur Lua), borné ici à 120 s.
    # Gardé tel quel : un boot long post-validate retombe en FAILED explicite
    # plutôt qu'en DONE aveugle.
    if ! wait_for_server_ready 120; then
        log "ERREUR: validation finale — JVM présente mais boot jamais prêt (timeout 120 s)."
        return 1
    fi
    return 0
}

# Acquire lock
# C1 : verrou monde D'ABORD (ordre WORLD -> MAINTENANCE, réentrant pour les
# enfants pz.sh/dataBackup.sh qui participent au lieu de se bloquer). Tenu
# pendant TOUTE la maintenance : start/stop, backup --required, wipe, restore
# ou reset concurrents sont exclus. Sémantique de skip conservée (exit 0).
if ! acquire_world_lock --try; then
    echo "[$(date +'%H:%M:%S')] Opération monde déjà en cours, maintenance ignorée."
    exit 0
fi
if ! try_acquire_maintenance_lock; then
    echo "[$(date +'%H:%M:%S')] Maintenance already running, skipping."
    release_world_lock
    exit 0
fi

# Parse arguments
DELAY="30m"
SILENT_MODE=false
AUTOMATIC_MODE=false
NO_REBOOT=false
MAINTENANCE_REASON="Maintenance"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --automatic)
            AUTOMATIC_MODE=true
            shift
            ;;
        --no-reboot)
            # Force le redémarrage du SERVICE seul, jamais la machine, quel que
            # soit REBOOT_ON_MAINTENANCE. Utilisé par le déclenchement sur MAJ de
            # build PZ (triggerMaintenanceOnModUpdate.sh) : une MAJ de build ne
            # justifie pas un reboot machine (contrairement à l'apt/noyau nocturne).
            NO_REBOOT=true
            shift
            ;;
        --reason)
            # Garde explicite : sans elle, un « --reason » final sans texte sortait
            # sur « $2 : variable sans liaison » (set -u) au lieu d'un message utile.
            [[ $# -ge 2 ]] || die "--reason attend un texte (ex: --reason \"Montée de RAM\")"
            MAINTENANCE_REASON="$2"
            shift 2
            ;;
        --reason=*)
            MAINTENANCE_REASON="${1#--reason=}"
            shift
            ;;
        30m|15m|5m|2m|30s|now|auto)
            DELAY="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

cd "${PZ_HOME}"

readonly MAINT_LOG="${LOG_MAINTENANCE_DIR}/maintenance_$(date +'%Y-%m-%d_%Hh%Mm%S').log"
ensure_directory "${LOG_MAINTENANCE_DIR}"
# Journal créé d'emblée en 600 (même idiome que generate_admin_password) : un
# `tee` appliquerait l'umask (644) alors que le log mentionne le compte Steam.
install -m 600 /dev/null "${MAINT_LOG}"
exec > >(tee -a "${MAINT_LOG}") 2>&1

stop_server() {
    # NB délai : le wait_for_server_ready de pz.sh attend le boot COURANT (f:1 /
    # marqueur Lua) AVANT préavis/comptage/arrêt et rend la main aussitôt prêt —
    # il ne consomme le délai joueurs ($DELAY, warn_players) qu'en cas de boot
    # bloqué (timeout). Gardé tel quel.
    # Tableau et non chaînes non quotées : même raison que dans main() plus bas —
    # `$automatic_opt $silent_opt` reposait sur le word-splitting de variables
    # vides, et les quoter (le réflexe naturel) aurait passé des arguments vides
    # à pz.sh. Les deux appels à pz.sh du fichier utilisent désormais la même forme.
    local -a opts=()
    [[ "$AUTOMATIC_MODE" == true ]] && opts+=(--automatic)
    [[ "$SILENT_MODE" == true ]] && opts+=(--silent)
    log "Arrêt du serveur ($DELAY) pour maintenance..."
    "${SCRIPT_DIR}/../core/pz.sh" stop "$DELAY" --maintenance --reason "$MAINTENANCE_REASON" "${opts[@]}"
}

# NB : la rotation des backups locaux n'est plus faite ici. Elle est gérée par la
# rétention GFS de dataBackup.sh (prune_gfs), rejouée à chaque backup horaire — y
# compris celui de :14 qui suit cette maintenance. Roter ici avec un simple
# -mtime +N supprimerait à tort la tranche journalière longue conservée par le GFS.

update_system() {
    log "Mise à jour système..."
    # Deux arguments distincts, pas une chaîne unique : la forme doit rester
    # alignée sur les règles de data/setupTemplates/pzuser-sudoers.
    local -a apt_lock=(-o DPkg::Lock::Timeout=300)
    sudo /usr/bin/apt-get update -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get upgrade -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get install -y -qq "${apt_lock[@]}" "${JAVA_PACKAGE}"
    sudo /usr/bin/apt-get autoremove -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get autoclean -qq "${apt_lock[@]}"
    [[ -d "${JAVA_PATH}" ]] || die "Java non installé"
}

update_game_server() {
    log "Mise à jour SteamCMD..."

    # Nettoyer un éventuel état SteamCMD corrompu (manifest, staging)
    local steamapps="${PZ_INSTALL_DIR}/steamapps"
    rm -rf "${steamapps}/downloading" "${steamapps}/temp"
    local manifest="${steamapps}/appmanifest_${STEAM_APP_ID}.acf"
    if [[ -f "$manifest" ]]; then
        local state
        state=$(grep -oP '"StateFlags"\s*"\K[0-9]+' "$manifest" 2>/dev/null || echo "0")
        if [[ "$state" != "4" ]]; then
            log "Manifest corrompu (StateFlags=$state), réinitialisation..."
            rm -f "$manifest"
        fi
    fi

    # Rétablir le vrai jre64 bundlé AVANT le validate : si jre64 est un lien vers
    # GraalVM (cf. linkJvm.sh), steamcmd écrirait à travers le lien et corromprait
    # l'install GraalVM externe. Le lien est ré-appliqué au prochain démarrage
    # (ExecStartPre linkJvm.sh --auto). No-op si on n'utilise pas GraalVM.
    "${SCRIPT_DIR}/../internal/linkJvm.sh" --stock || true

    # STEAM_BETA_BRANCH vide = branche publique (stable). Il FAUT passer -beta
    # public EXPLICITEMENT : ne rien passer n'efface PAS une beta déjà gravée dans
    # le manifeste (UserConfig/MountedConfig "BetaKey"), donc app_update revalide
    # l'ancienne beta au lieu de basculer sur public. C'est ce qui a causé la boucle
    # "Mise à jour serveur disponible" -> maintenance -> reboot toutes les ~10 min
    # au passage 42.19 -> stable le 2026-08-05 (install figé sur buildid 24438606
    # alors que public était 24574884). "public" est le nom interne Valve de la
    # branche par défaut ; -beta "" reste proscrit (steamcmd avalerait le token
    # suivant comme nom de branche).
    local beta_branch; beta_branch="$(steam_beta_branch)"
    # Login hors argv (/proc, ps) : via runscript 0600, jamais en argument visible.
    steamcmd_runscript "${STEAM_LOGIN:-anonymous}" \
        "force_install_dir \"${PZ_INSTALL_DIR}\"" \
        "login \"${STEAM_LOGIN:-anonymous}\"" \
        "app_update \"${STEAM_APP_ID}\" -beta \"${beta_branch}\" validate"

    # Le validate restaure le ProjectZomboid64.json vanilla : réappliquer le tuning
    "${SCRIPT_DIR}/../internal/configureJvm.sh"
}

# App ID du JEU (108600) pour les mods Workshop — distinct du serveur dédié (380870)
readonly STEAM_WORKSHOP_APP_ID=108600

download_workshop_mods() {
    # Pré-télécharge les mods Workshop listés dans servertest.ini avec le compte
    # STEAM_LOGIN. Depuis 2026 Steam a retiré PZ des DL Workshop anonymes : le
    # serveur ne peut plus télécharger lui-même un mod NEUF ou MIS À JOUR au boot
    # (onItemNotDownloaded result=3 -> NPE -> crash-loop). En les pré-tirant ici
    # (serveur arrêté -> écriture du dossier workshop sûre) avec un compte possédant
    # PZ, le serveur les retrouve "Installed/Ready" au démarrage. Non bloquant.
    local login="${STEAM_LOGIN:-anonymous}"
    if [[ "$login" == "anonymous" ]]; then
        log "STEAM_LOGIN non défini : pré-DL des mods ignoré (DL anonyme cassé pour les items neufs/mis à jour)."
        return 0
    fi
    local ini="${PZ_INI_PATH}"
    if [[ ! -f "$ini" ]]; then
        log "WARNING: $ini introuvable, pré-DL des mods ignoré"
        return 0
    fi
    local items
    # `|| true` : clé WorkshopItems ABSENTE -> grep sort 1, et sous `set -euo
    # pipefail` la substitution sortait (maintenance annulée pour un serveur
    # sans mods). Le test vide ci-dessous fait le reste (return 0).
    items=$(grep -oP '^WorkshopItems=\K.*' "$ini" 2>/dev/null | tr ';' ' ' || true)
    if [[ -z "${items// }" ]]; then
        log "Aucun WorkshopItems à pré-télécharger."
        return 0
    fi
    log "Pré-téléchargement des mods Workshop (compte configuré)..."
    local lines=("force_install_dir \"${PZ_INSTALL_DIR}\"" "login \"${login}\"")
    local id
    for id in $items; do
        # Garde anti-injection du runscript : les IDs viennent de servertest.ini.
        # Averti + ignoré (non bloquant, comme l'échec pré-DL ci-dessous) : un
        # `die` annulerait toute la maintenance pour une coquille dans l'ini.
        if [[ ! "$id" =~ ^[0-9]+$ ]]; then
            log "WARNING: WorkshopItems invalide ignoré ('${id}') : ID numérique attendu."
            continue
        fi
        lines+=("workshop_download_item \"${STEAM_WORKSHOP_APP_ID}\" \"${id}\"")
    done
    if steamcmd_runscript "$login" "${lines[@]}"; then
        log "Pré-téléchargement des mods Workshop terminé."
    else
        log "WARNING: pré-DL des mods Workshop en échec (non bloquant) — vérifier le compte Steam configuré (jeton steamcmd expiré ?)."
    fi
}

sync_external() {
    log "Synchronisation externe..."
    if [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]]; then
        "${SCRIPT_DIR}/../backup/fullBackup.sh" || log "WARNING: Synchronisation externe échouée (non bloquant)"
    fi
}

update_self() {
    # PZ_MAINT_SELF_UPDATE=0 : opt-out (le code n'est pas modifié mid-maintenance).
    if [[ "${PZ_MAINT_SELF_UPDATE:-1}" == "0" ]]; then
        log "Mise à jour de pzmanager ignorée (PZ_MAINT_SELF_UPDATE=0)."
        return 0
    fi
    # Tire la dernière version de pzmanager lui-même, juste avant le reboot (ou le
    # redémarrage du service) : le boot qui suit tourne sur les scripts à jour,
    # sans intervention manuelle après la fusion d'une PR. Même séquence qu'à la
    # main (fetch -p puis pull). --ff-only : un dépôt divergé ou modifié
    # localement n'est jamais fusionné ni écrasé, l'échec est seulement journalisé.
    # Non bloquant — un réseau ou GitHub en panne ne doit pas annuler la
    # maintenance : chaque commande git est protégée, sinon `set -e` sortirait,
    # le filet EXIT relancerait le serveur et le reboot n'aurait jamais lieu. Le
    # script en cours n'est pas affecté : git remplace les fichiers (nouvel
    # inode), bash garde l'ancien ouvert.
    log "Mise à jour de pzmanager (git fetch -p + pull)..."
    local -a git_cmd=(git -C "${PZ_MANAGER_DIR}")
    local branch before after
    branch=$("${git_cmd[@]}" symbolic-ref --short -q HEAD) || branch=""
    if [[ "$branch" != "main" ]]; then
        log "WARNING: pzmanager n'est pas sur main (branche '${branch:-HEAD détachée ou dépôt illisible}'), git pull ignoré."
        return 0
    fi
    if ! before=$("${git_cmd[@]}" rev-parse --short HEAD); then
        log "WARNING: HEAD de pzmanager illisible, git pull ignoré."
        return 0
    fi
    # Dépôt sale -> REFUS sans écraser (jamais de stash mid-maintenance : un stash
    # modifierait le code en prod au milieu du parcours). Non bloquant.
    local porcelain
    if ! porcelain=$("${git_cmd[@]}" status --porcelain 2>/dev/null); then
        log "WARNING: état git de pzmanager illisible, git pull ignoré (non bloquant)."
        return 0
    fi
    if [[ -n "$porcelain" ]]; then
        log "WARNING: pzmanager a des modifs locales, git pull refusé sans écraser (non bloquant)."
        return 0
    fi
    if ! GIT_TERMINAL_PROMPT=0 timeout 120 "${git_cmd[@]}" fetch -p -q origin; then
        log "WARNING: git fetch de pzmanager en échec (non bloquant) — réseau ou GitHub ?"
        return 0
    fi
    if ! GIT_TERMINAL_PROMPT=0 timeout 120 "${git_cmd[@]}" pull --ff-only -q origin main; then
        log "WARNING: git pull de pzmanager en échec (non bloquant) — dépôt divergé ou modifs locales ?"
        return 0
    fi
    after=$("${git_cmd[@]}" rev-parse --short HEAD) || after="?"
    if [[ "$before" == "$after" ]]; then
        log "pzmanager déjà à jour (${after})."
    else
        log "pzmanager mis à jour : ${before} -> ${after}"
        "${git_cmd[@]}" log --oneline "${before}..${after}" | sed 's/^/    /' || true
    fi
}

# Filet de sécurité : entre stop_server et le redémarrage final, TOUT échec
# (verrou apt encore tenu après les 300 s, conflit dpkg, steamcmd injoignable,
# `die "Java non installé"`) faisait sortir le script sous `set -e` — serveur
# arrêté, aucun message Discord, et personne pour le relancer avant le timer du
# lendemain. On relance donc systématiquement le serveur avant de propager
# l'erreur, et on prévient.
SERVER_STOPPED_BY_MAINTENANCE=false
restart_server_on_failure() {
    local rc=$?
    (( rc == 0 )) && return 0
    [[ "$SERVER_STOPPED_BY_MAINTENANCE" == true ]] || return 0
    log "ÉCHEC de la maintenance (code ${rc}) — redémarrage du serveur pour ne pas le laisser hors ligne." || true
    printf '%s\n' "FAILED" > "${MAINT_STATE_FILE}" 2>/dev/null || true
    "${SCRIPT_DIR}/../core/pz.sh" start now --reason "Reprise après échec de la maintenance" --automatic || \
        log "ERREUR: le redémarrage de secours a lui aussi échoué — intervention manuelle requise." || true
    # notify() est déjà non bloquant (sendDiscord.sh ... || true en interne) ;
    # le `|| true` explicite protège en plus contre `set -e` si le câblage change.
    notify "Maintenance interrompue par une erreur — le serveur a été redémarré." || true
    return $rc
}
trap restart_server_on_failure EXIT

main() {
    log "=== MAINTENANCE DEMARREE ==="
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"

    # Crash mid-maintenance précédent ? Rollback minimal (restart + message),
    # puis reprise du parcours ci-dessous depuis INIT.
    maint_detect_interrupted || true
    maint_set_state "INIT"

    # La purge des accès inactifs n'est plus déclenchée ici : elle est en
    # ExecStartPre de zomboid.service, donc rejouée à chaque démarrage (dont
    # celui qui suit cette maintenance), toujours monde fermé.
    # Reprise armée AVANT le stop : le fichier existe dès que le serveur est
    # arrêté, même si la phase suivante échoue. Le trap EXIT ci-dessus est déjà
    # posé depuis le chargement du script.
    maint_arm_recovery
    maint_set_state "STOPPED"
    stop_server
    SERVER_STOPPED_BY_MAINTENANCE=true
    maint_set_state "SYSTEM"
    update_system
    maint_set_state "STEAM"
    update_game_server
    maint_set_state "MODS"
    download_workshop_mods
    maint_set_state "BACKUP"
    sync_external
    maint_set_state "SELF"
    update_self

    [[ "$SILENT_MODE" == true ]] && touch "${SILENT_FLAG_FILE}"

    # Passé ce point, la maintenance a réussi : le filet ci-dessus n'a plus lieu
    # d'être (le reboot machine, notamment, n'est pas un échec).
    SERVER_STOPPED_BY_MAINTENANCE=false

    if [[ "$NO_REBOOT" != true && "${REBOOT_ON_MAINTENANCE:-true}" == true ]]; then
        log "Maintenance terminée, redémarrage machine..."
        maint_set_state "DONE"
        maint_disarm_recovery
        [[ "$SILENT_MODE" == true ]] || notify "Maintenance terminée - Redémarrage machine" || true
        sudo /sbin/reboot
    else
        log "Maintenance terminée, redémarrage du service..."
        local -a opts=()
        [[ "$AUTOMATIC_MODE" == true ]] && opts+=(--automatic)
        "${SCRIPT_DIR}/../core/pz.sh" start --reason "$MAINTENANCE_REASON" "${opts[@]}"
        if validate_final_start; then
            maint_set_state "DONE"
            maint_disarm_recovery
        else
            maint_set_state "FAILED"
            notify "Maintenance terminée mais validation finale en échec — intervention manuelle requise." || true
            return 1
        fi
    fi
}

main
