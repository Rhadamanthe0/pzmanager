#!/bin/bash
# listOutdatedMods.sh - Affiche le nom des mods Workshop dont la copie Steam est
# plus récente que celle installée localement (un nom par ligne).
#
# La commande console "checkModsNeedUpdate" du serveur PZ ne répond que par un
# statut global ("Mods need update") : elle ne nomme jamais le mod concerné.
# On retrouve donc l'information en comparant, pour chaque ID de WorkshopItems=,
# le "timeupdated" du cache local avec le "time_updated" publié par Steam.
# L'API renvoie aussi le titre lisible du mod, qui est ce qu'on veut afficher.
#
# Sortie vide = aucun mod en retard, ou information indisponible (API injoignable,
# cache absent). L'appelant doit traiter une sortie vide comme "je ne sais pas"
# et retomber sur un message générique.

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

# 108600 = jeu Project Zomboid (propriétaire des items Workshop).
# À ne pas confondre avec STEAM_APP_ID=380870 = outil serveur dédié.
readonly WORKSHOP_APP_ID=108600
readonly SERVER_INI="${PZ_SOURCE_DIR}/Server/servertest.ini"
readonly WORKSHOP_ACF="${PZ_INSTALL_DIR}/steamapps/workshop/appworkshop_${WORKSHOP_APP_ID}.acf"
readonly STEAM_API="https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
readonly API_TIMEOUT=30

# Les IDs déclarés dans servertest.ini. Le .acf contient aussi de vieux items
# désinstallés (versions précédentes) : on ignore tout ce qui n'est plus listé.
declared_workshop_ids() {
    grep -E '^WorkshopItems=' "${SERVER_INI}" 2>/dev/null \
        | sed 's/^WorkshopItems=//' \
        | tr ';' '\n' \
        | grep -E '^[0-9]+$'
}

# "<id> <timeupdated>" pour chaque item du cache local.
# Seule la section WorkshopItemsInstalled fait foi : WorkshopItemDetails répète
# les mêmes IDs et fausserait la lecture.
local_update_times() {
    awk '
        /"WorkshopItemsInstalled"/ { in_installed = 1 }
        /"WorkshopItemDetails"/    { in_installed = 0 }
        in_installed && /^\t\t"[0-9]+"$/  { gsub(/[^0-9]/, ""); id = $0 }
        in_installed && /"timeupdated"/   {
            gsub(/[^0-9]/, "")
            if (id != "") print id, $0
            id = ""
        }
    ' "${WORKSHOP_ACF}" 2>/dev/null
}

# "<id>\t<time_updated>\t<titre>" pour chaque item, tel que publié par Steam.
# result==1 écarte les items supprimés/privés, dont les champs sont absents.
remote_details() {
    local ids=("$@")
    local args=(-d "itemcount=${#ids[@]}")
    local i=0 id

    for id in "${ids[@]}"; do
        args+=(-d "publishedfileids[${i}]=${id}")
        ((i++))
    done

    curl -s --max-time "${API_TIMEOUT}" -X POST "${STEAM_API}" "${args[@]}" 2>/dev/null \
        | jq -r '.response.publishedfiledetails[]? | select(.result == 1)
                 | [.publishedfileid, (.time_updated | tostring), .title] | @tsv' 2>/dev/null
}

main() {
    [[ -f "${SERVER_INI}" && -f "${WORKSHOP_ACF}" ]] || exit 0
    command -v curl >/dev/null && command -v jq >/dev/null || exit 0

    local ids
    mapfile -t ids < <(declared_workshop_ids)
    [[ ${#ids[@]} -gt 0 ]] || exit 0

    declare -A installed_at
    local id ts
    while read -r id ts; do
        installed_at["${id}"]="${ts}"
    done < <(local_update_times)
    [[ ${#installed_at[@]} -gt 0 ]] || exit 0

    local remote title local_ts
    while IFS=$'\t' read -r id remote title; do
        local_ts="${installed_at[${id}]:-}"
        # Item jamais téléchargé : ce n'est pas une mise à jour, on ne le nomme pas.
        [[ -n "${local_ts}" ]] || continue
        [[ "${remote}" =~ ^[0-9]+$ && "${local_ts}" =~ ^[0-9]+$ ]] || continue
        (( remote > local_ts )) && echo "${title}"
    done < <(remote_details "${ids[@]}")

    exit 0
}

main
