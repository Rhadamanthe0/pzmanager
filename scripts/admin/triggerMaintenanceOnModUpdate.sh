#!/bin/bash
# triggerMaintenanceOnModUpdate.sh - Réagit aux mises à jour de mods et du serveur
# Timer systemd toutes les 5 min. Lock partagé avec pz.sh/performFullMaintenance.sh
#
# Mod mis à jour    -> simple redémarrage (le serveur retélécharge l'item au boot)
# Serveur mis à jour -> maintenance complète (apt, app_update, re-tune JVM, reboot)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

export XDG_RUNTIME_DIR="/run/user/$(id -u)"

readonly LOG_DIR="${LOG_BASE_DIR}/mod_checks"
readonly LOG_FILE="${LOG_DIR}/mod_checks_$(date +'%Y-%m-%d').log"
readonly RETENTION_DAYS=7

ensure_directory "${LOG_DIR}"

log_event() { echo "[$(date +'%H:%M:%S')] $*" >> "${LOG_FILE}"; }

cleanup_old_logs() {
    find "${LOG_DIR}" -name "*.log" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
}

check_prerequisites() {
    server_is_active || exit 0
    [[ -p "${PZ_CONTROL_PIPE}" ]] || { log_event "ERROR: Control pipe unavailable"; exit 1; }
    [[ -x "${SCRIPT_DIR}/performFullMaintenance.sh" ]] || { log_event "ERROR: Maintenance script not found"; exit 1; }
}

# Returns: 0=updates needed, 1=up to date or error
check_mods() {
    local output exit_code=0
    output=$("${SCRIPT_DIR}/../internal/sendCommand.sh" "checkModsNeedUpdate" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_event "ERROR: RCON failed - ${output}"
        "${SCRIPT_DIR}/../internal/sendDiscord.sh" "ERROR: Mod check failed" || true
        return 1
    fi

    # Extract the status from "CheckModsNeedUpdate: <status>" lines
    # Possible responses: "Mods updated" (up to date) or "Mods need update" (outdated)
    local status
    status=$(echo "${output}" | grep -i "CheckModsNeedUpdate:" | sed 's/.*CheckModsNeedUpdate: *//' || true)

    if echo "${status}" | grep -iq "need.*update\|outdated"; then
        log_event "MOD UPDATES DETECTED (status: ${status})"
        return 0
    fi

    if echo "${status}" | grep -iq "mods updated\|up.*to.*date"; then
        log_event "OK - mods up to date"
        return 1
    fi

    log_event "OK - no updates (response: ${output:0:100})"
    return 1
}

# Returns: 0=server update available, 1=up to date or error
check_server_update() {
    local manifest="${PZ_INSTALL_DIR}/steamapps/appmanifest_${STEAM_APP_ID}.acf"

    if [[ ! -f "$manifest" ]]; then
        log_event "WARNING: App manifest not found, skipping server update check"
        return 1
    fi

    # Get installed build ID from local manifest
    local installed_buildid
    installed_buildid=$(grep -oP '"buildid"\s*"\K[0-9]+' "$manifest" 2>/dev/null || echo "")

    if [[ -z "$installed_buildid" ]]; then
        log_event "WARNING: Could not read installed build ID"
        return 1
    fi

    # Query SteamCMD for the latest build ID on the configured beta branch
    local steam_output
    steam_output=$(timeout 60 "${STEAMCMD_PATH}" +login anonymous \
        +app_info_update 1 \
        +app_info_print "${STEAM_APP_ID}" \
        +quit 2>/dev/null) || {
        log_event "WARNING: SteamCMD query failed"
        return 1
    }

    # Parse the build ID for the configured beta branch (e.g. "unstable")
    # The manifest structure has: "branches" { "<branch>" { "buildid" "<id>" } }
    local remote_buildid
    remote_buildid=$(echo "$steam_output" | awk -v branch="${STEAM_BETA_BRANCH}" '
        /"branches"/ { in_branches=1 }
        in_branches && $0 ~ "\"" branch "\"" { in_branch=1 }
        in_branch && /"buildid"/ {
            gsub(/[^0-9]/, "")
            print
            exit
        }
        in_branch && /^\t*\}/ { in_branch=0 }
    ')

    if [[ -z "$remote_buildid" ]]; then
        log_event "WARNING: Could not read remote build ID for branch ${STEAM_BETA_BRANCH}"
        return 1
    fi

    if [[ "$installed_buildid" != "$remote_buildid" ]]; then
        log_event "SERVER UPDATE AVAILABLE (installed: ${installed_buildid}, remote: ${remote_buildid}, branch: ${STEAM_BETA_BRANCH})"
        return 0
    fi

    log_event "OK - server up to date (buildid: ${installed_buildid}, branch: ${STEAM_BETA_BRANCH})"
    return 1
}

# Motif de maintenance nommant les mods concernés, ex :
#   "Mods mis à jour : Brita's Weapon Pack, Authentic Z"
# checkModsNeedUpdate ne nomme pas les mods : listOutdatedMods.sh les retrouve en
# comparant le cache local à Steam. Sortie vide (API muette, cache absent) =>
# on retombe sur le motif générique plutôt que d'annoncer une liste fausse.
# Le motif part en servermsg et sur Discord : on borne la liste et on retire les
# guillemets, qui casseraient la commande console.
build_mod_update_reason() {
    local -r generic="Mods mis à jour"
    local -r max_names=3
    local -r max_title=40
    local names=()

    mapfile -t names < <("${SCRIPT_DIR}/../internal/listOutdatedMods.sh" 2>/dev/null | tr -d '"\\' | grep -v '^$')
    [[ ${#names[@]} -gt 0 ]] || { echo "${generic}"; return; }

    # Certains titres Workshop dépassent 60 caractères : sans borne, l'avertissement
    # en jeu devient illisible.
    local list="" name
    for name in "${names[@]:0:${max_names}}"; do
        (( ${#name} > max_title )) && name="${name:0:max_title}…"
        list+="${name}, "
    done
    list="${list%, }"

    local hidden=$(( ${#names[@]} - max_names ))
    (( hidden > 0 )) && list+=" et ${hidden} autre$( ((hidden > 1)) && echo s )"

    echo "${generic} : ${list}"
}

# Un mod mis à jour ne demande qu'un redémarrage : le serveur PZ retélécharge
# lui-même l'item Workshop au boot (GetItemState -> NeedsUpdate -> download).
# La maintenance complète (apt upgrade, app_update validate, re-tune JVM et reboot
# de la machine) ne sert qu'à une mise à jour du BUILD serveur ; la déclencher pour
# un mod rebootait la machine plusieurs fois par jour sans rien apporter de plus :
# son pré-DL des mods (download_workshop_mods) sort immédiatement tant que
# STEAM_LOGIN vaut anonymous, ce qui est le cas ici.
trigger_restart() {
    local reason="$1"
    log_event "Triggering restart (5m delay) - reason: ${reason}"
    # Verrou volontairement conservé : pz.sh ne fait que le tenter
    # (try_acquire_maintenance_lock || true), et le garder empêche une maintenance
    # de s'intercaler pendant les 5 min de préavis. À l'inverse de
    # performFullMaintenance.sh, qui l'exige et impose de le relâcher avant l'appel.
    "${SCRIPT_DIR}/../core/pz.sh" restart "5m" --reason "$reason" --automatic
    log_event "Restart completed"
}

trigger_maintenance() {
    local reason="$1"
    log_event "Triggering maintenance (5m delay) - reason: ${reason}"
    flock -u 200
    "${SCRIPT_DIR}/performFullMaintenance.sh" "5m" --reason "$reason" --automatic
    log_event "Maintenance completed"
}

main() {
    cleanup_old_logs
    check_prerequisites

    if ! try_acquire_maintenance_lock; then
        log_event "Maintenance in progress - skipping"
        exit 0
    fi

    if check_mods; then
        trigger_restart "$(build_mod_update_reason)"
        exit 0
    fi

    if check_server_update; then
        trigger_maintenance "Mise à jour serveur disponible"
        exit 0
    fi
}

main
