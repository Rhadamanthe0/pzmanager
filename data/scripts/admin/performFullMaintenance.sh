#!/bin/bash
# performFullMaintenance.sh - Maintenance quotidienne (apt, steamcmd, reboot)
# Usage: ./performFullMaintenance.sh [délai] [options]
# Options: --reason TEXT (raison de maintenance), --automatic (flag si auto), --silent
# Lock partagé avec pz.sh/triggerMaintenanceOnModUpdate.sh

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/.silent_next_start"

# Acquire lock
if ! try_acquire_maintenance_lock; then
    echo "[$(date +'%H:%M:%S')] Maintenance already running, skipping."
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
exec > >(tee -a "${MAINT_LOG}") 2>&1

stop_server() {
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
    "${STEAMCMD_PATH}" +force_install_dir "${PZ_INSTALL_DIR}" +login "${STEAM_LOGIN:-anonymous}" \
        +app_update "${STEAM_APP_ID}" -beta "${beta_branch}" validate +quit

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
    items=$(grep -oP '^WorkshopItems=\K.*' "$ini" | tr ';' ' ')
    if [[ -z "${items// }" ]]; then
        log "Aucun WorkshopItems à pré-télécharger."
        return 0
    fi
    log "Pré-téléchargement des mods Workshop (compte ${login})..."
    local args=(+force_install_dir "${PZ_INSTALL_DIR}" +login "${login}")
    local id
    for id in $items; do
        args+=(+workshop_download_item "${STEAM_WORKSHOP_APP_ID}" "${id}")
    done
    args+=(+quit)
    if "${STEAMCMD_PATH}" "${args[@]}"; then
        log "Pré-téléchargement des mods Workshop terminé."
    else
        log "WARNING: pré-DL des mods Workshop en échec (non bloquant) — vérifier le login '${login}' (jeton steamcmd expiré ?)."
    fi
}

sync_external() {
    log "Synchronisation externe..."
    if [[ -x "${SCRIPT_DIR}/../backup/fullBackup.sh" ]]; then
        "${SCRIPT_DIR}/../backup/fullBackup.sh" || log "WARNING: Synchronisation externe échouée (non bloquant)"
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
    log "ÉCHEC de la maintenance (code ${rc}) — redémarrage du serveur pour ne pas le laisser hors ligne."
    "${SCRIPT_DIR}/../core/pz.sh" start now --reason "Reprise après échec de la maintenance" --automatic || \
        log "ERREUR: le redémarrage de secours a lui aussi échoué — intervention manuelle requise."
    notify "Maintenance interrompue par une erreur — le serveur a été redémarré."
    return $rc
}
trap restart_server_on_failure EXIT

main() {
    log "=== MAINTENANCE DEMARREE ==="
    [[ -x "${SCRIPT_DIR}/../core/pz.sh" ]] || die "pz.sh introuvable"

    # La purge des accès inactifs n'est plus déclenchée ici : elle est en
    # ExecStartPre de zomboid.service, donc rejouée à chaque démarrage (dont
    # celui qui suit cette maintenance), toujours monde fermé.
    stop_server
    SERVER_STOPPED_BY_MAINTENANCE=true
    update_system
    update_game_server
    download_workshop_mods
    sync_external

    [[ "$SILENT_MODE" == true ]] && touch "${SILENT_FLAG_FILE}"

    # Passé ce point, la maintenance a réussi : le filet ci-dessus n'a plus lieu
    # d'être (le reboot machine, notamment, n'est pas un échec).
    SERVER_STOPPED_BY_MAINTENANCE=false

    if [[ "$NO_REBOOT" != true && "${REBOOT_ON_MAINTENANCE:-true}" == true ]]; then
        log "Maintenance terminée, redémarrage machine..."
        [[ "$SILENT_MODE" == true ]] || notify "Maintenance terminée - Redémarrage machine"
        sudo /sbin/reboot
    else
        log "Maintenance terminée, redémarrage du service..."
        local -a opts=()
        [[ "$AUTOMATIC_MODE" == true ]] && opts+=(--automatic)
        "${SCRIPT_DIR}/../core/pz.sh" start --reason "$MAINTENANCE_REASON" "${opts[@]}"
    fi
}

main
