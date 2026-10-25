#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, git pull, reboot)
# Usage: ./performFullMaintenance.sh [délai] [options]
# Options: --reason TEXT (raison de maintenance), --automatic (flag si auto), --silent
# Lock partagé avec pz.sh/triggerMaintenanceOnModUpdate.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# Même emplacement persistant et inscriptible que notifyServerReady.sh :
# la racine pzmanager n'est pas modifiable depuis zomboid.service durci.
readonly SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/logs/.silent_next_start"
readonly LEGACY_SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/.silent_next_start"

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
# Une reprise interrompue doit aboutir avant de recommencer la maintenance.
maint_detect_interrupted() {
    local prev=""
    [[ -f "${MAINT_STATE_FILE}" ]] && prev="$(cat "${MAINT_STATE_FILE}" 2>/dev/null || true)"
    case "$prev" in
        INIT|STOPPED|SYSTEM|STEAM|MODS|BACKUP|SELF|FAILED)
            if [[ -f "${MAINT_RECOVERY_FILE}" ]]; then
                log "Reprise après interruption (état précédent: ${prev}) — redémarrage de sécurité."
                if maint_restart_recovery "Reprise après interruption de maintenance (${prev})" \
                    "Maintenance précédente interrompue (${prev})" false; then
                    return 0
                fi
                maint_set_state "FAILED"
                return 1
            fi
            ;;
    esac
}

# Réutiliser les observations et le prédicat d'arrêt du backup : un échec de
# pz stop peut survenir après l'arrêt, pendant son snapshot. Le drapeau mémoire
# seul ne distingue pas ce cas d'un arrêt refusé pendant le chargement.
maint_recovery_allowed() {
    python3 - "${SCRIPT_DIR}/../lib" "$PZ_SERVICE_NAME" "$PZ_SOURCE_DIR" "$1" <<'PYRECOVERY'
import sys
sys.path.insert(0, sys.argv[1])
from snapshot_consistency import probe, stopped
from world_transaction import check_clean
try:
    check_clean(sys.argv[3], legacy=True)
    state = probe(sys.argv[2])
    active = (state.get('ok') and state.get('LoadState') == 'loaded'
              and state.get('ActiveState') == 'active'
              and str(state.get('MainPID', '')).isdigit()
              and int(state['MainPID']) > 0 and state.get('ControlPID') == '0')
    if not stopped(state) and (sys.argv[4] == 'true' or not active):
        raise ValueError('état serveur non prouvé arrêté ou actif sans transition')
except (OSError, ValueError) as error:
    print('Reprise maintenance refusée : ' + str(error), file=sys.stderr)
    raise SystemExit(1)
PYRECOVERY
}

maint_restart_recovery() {
    local reason="$1" context="$2" require_offline="$3"
    if ! maint_recovery_allowed "$require_offline"; then
        log "ERREUR: reprise refusée — état non prouvé ou récupération du monde nécessaire." || true
        notify "$context — reprise refusée, intervention manuelle requise." || true
        return 1
    fi
    if "${SCRIPT_DIR}/../core/pz.sh" start now --reason "$reason" --automatic; then
        if validate_final_start; then
            notify "$context — serveur prêt (disponibilité vérifiée)." || true
            return 0
        fi
        log "ERREUR: démarrage de reprise demandé, disponibilité non vérifiée." || true
        notify "$context — démarrage demandé, disponibilité non vérifiée ; intervention manuelle requise." || true
    else
        log "ERREUR: redémarrage de reprise en échec — intervention manuelle requise." || true
        notify "$context — redémarrage en échec, intervention manuelle requise." || true
    fi
    return 1
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
    local invocation current_invocation
    invocation="$(server_readiness_invocation)" || {
        log "ERREUR: validation finale — invocation active illisible."
        return 1
    }
    # Attente du boot courant (frame native ou réponse players), bornée à 120 s.
    # Son retour 0 signifie aussi « service arrêté » pour le parcours stop :
    # la maintenance exige ensuite une preuve positive de la même invocation.
    if ! wait_for_server_ready 120; then
        log "ERREUR: validation finale — JVM présente mais boot jamais prêt (timeout 120 s)."
        return 1
    fi
    if ! pgrep -f 'ProjectZomboid64' >/dev/null 2>&1; then
        log "ERREUR: validation finale — JVM ProjectZomboid64 disparue après l'attente."
        return 1
    fi
    if ! current_invocation="$(server_readiness_invocation)" || [[ "$current_invocation" != "$invocation" ]]; then
        log "ERREUR: validation finale — invocation inactive, remplacée ou illisible après l'attente."
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
    # NB délai : le wait_for_server_ready de pz.sh attend le boot COURANT (frame
    # native ou réponse players) AVANT préavis/comptage/arrêt et rend la main aussitôt prêt —
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
    # Résoudre la préférence .env avec les candidats fraîchement actualisés.
    source "${SCRIPT_DIR}/../lib/jdk_matrix.sh"
    resolve_java_package
    sudo /usr/bin/apt-get upgrade -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get install -y -qq "${apt_lock[@]}" "${JAVA_PACKAGE}"
    sudo /usr/bin/apt-get autoremove -y -qq "${apt_lock[@]}"
    sudo /usr/bin/apt-get autoclean -qq "${apt_lock[@]}"
    [[ -d "${JAVA_PATH}" ]] || die "Java non installé"
}

update_game_server() {
    log "Mise à jour SteamCMD..."

    # Refuser avant SteamCMD : validate ne doit jamais écrire à travers le
    # lien jre64 vers une JVM externe, même si le helper manque ou échoue.
    "${SCRIPT_DIR}/../internal/linkJvm.sh" --stock \
        || die "Restauration du JRE stock impossible : mise à jour SteamCMD refusée."
    [[ ! -L "${PZ_INSTALL_DIR}/jre64" ]] \
        || die "jre64 est encore un lien symbolique : mise à jour SteamCMD refusée."

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
MAINT_STOP_ATTEMPTED=false
restart_server_on_failure() {
    local rc=$? require_offline=false
    (( rc == 0 )) && return 0
    if [[ "$SERVER_STOPPED_BY_MAINTENANCE" != true && "${MAINT_STOP_ATTEMPTED:-false}" != true ]]; then
        return "$rc"
    fi
    [[ "$SERVER_STOPPED_BY_MAINTENANCE" == true ]] || require_offline=true
    log "ÉCHEC de la maintenance (code ${rc}) — vérification du redémarrage de secours." || true
    maint_set_state "FAILED"
    maint_restart_recovery "Reprise après échec de la maintenance" \
        "Maintenance interrompue par une erreur" "$require_offline" || true
    return "$rc"
}

trap restart_server_on_failure EXIT

main() {
    log "=== MAINTENANCE DEMARREE ==="
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"

    # Crash mid-maintenance précédent ? Rollback minimal (restart + message),
    # puis reprise du parcours ci-dessous depuis INIT.
    maint_detect_interrupted || return 1
    maint_set_state "INIT"

    # La purge des accès inactifs n'est plus déclenchée ici : elle est en
    # ExecStartPre de zomboid.service, donc rejouée à chaque démarrage (dont
    # celui qui suit cette maintenance), toujours monde fermé.
    # Reprise armée AVANT le stop : le fichier existe dès que le serveur est
    # arrêté, même si la phase suivante échoue. Le trap EXIT ci-dessus est déjà
    # posé depuis le chargement du script.
    maint_arm_recovery
    maint_set_state "STOPPED"
    MAINT_STOP_ATTEMPTED=true
    stop_server
    maint_recovery_allowed true || die "Arrêt non prouvé — phases système et Steam refusées."
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

    # Si l'ancien marqueur existe, le retirer ici (hors sandbox du jeu).
    # Une installation déjà migrée n'en crée plus à cet emplacement.
    if [[ -f "$LEGACY_SILENT_FLAG_FILE" ]]; then
        rm -f -- "$LEGACY_SILENT_FLAG_FILE" ||
            log "AVERTISSEMENT : ancien marqueur de maintenance non supprimé."
    fi
    if [[ "$SILENT_MODE" == true ]]; then
        mkdir -p -- "${PZ_MANAGER_DIR}/logs"
        touch "$SILENT_FLAG_FILE"
    fi

    # Le filet reste armé jusqu'à l'acceptation du reboot ou la validation du
    # démarrage du service : un refus final doit encore déclencher la reprise.
    if [[ "$NO_REBOOT" != true && "${REBOOT_ON_MAINTENANCE:-true}" == true ]]; then
        log "Maintenance terminée, redémarrage machine..."
        [[ "$SILENT_MODE" == true ]] || notify "Maintenance terminée - Redémarrage machine" || true
        sudo /sbin/reboot
        SERVER_STOPPED_BY_MAINTENANCE=false
        maint_set_state "DONE"
        maint_disarm_recovery
    else
        log "Maintenance terminée, redémarrage du service..."
        local -a opts=()
        [[ "$AUTOMATIC_MODE" == true ]] && opts+=(--automatic)
        [[ "$SILENT_MODE" == true ]] && opts+=(--silent)
        "${SCRIPT_DIR}/../core/pz.sh" start --reason "$MAINTENANCE_REASON" "${opts[@]}"
        if validate_final_start; then
            SERVER_STOPPED_BY_MAINTENANCE=false
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
