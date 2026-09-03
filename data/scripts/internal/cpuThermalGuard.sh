#!/bin/bash
# cpuThermalGuard.sh - Plafond de fréquence CPU asservi à la température.
#
# CE QUE CE SCRIPT NE FAIT PAS : piloter la fréquence. amd-pstate/CPPC ajuste
# déjà la fréquence de chaque cœur à l'échelle de la milliseconde, en matériel,
# bien mieux qu'une boucle bash. Y toucher créerait précisément les allers-retours
# qu'on veut éviter.
#
# CE QU'IL FAIT : déplacer LENTEMENT un PLAFOND (scaling_max_freq), et seulement
# quand la température le justifie. Le matériel garde toute liberté sous ce
# plafond : il monte quand le serveur est demandé, il redescend à 400 MHz au
# repos (c'est le rôle de l'EPP, réglé par l'unité systemd).
#
# Anti-oscillation, trois mécanismes cumulés :
#   1. Bande d'hystérésis large : on descend à >= TEMP_HIGH, on ne remonte qu'à
#      <= TEMP_LOW. L'écart entre les deux interdit le va-et-vient autour d'un
#      seuil unique.
#   2. Asymétrie : descendre demande DOWN_SAMPLES relevés (~20 s), remonter en
#      demande UP_SAMPLES (~5 min). Prompt à protéger, lent à relâcher.
#   3. Temps de garde (DWELL) après chaque changement : aucun nouveau mouvement
#      pendant ce délai, le temps que la température reflète le palier.
#
# Réglages via l'environnement (voir pz-cpu-guard.service).

set -uo pipefail

readonly LADDER_KHZ="${CPU_GUARD_LADDER:-4400000 4100000 3801000}"
readonly TEMP_HIGH="${CPU_GUARD_TEMP_HIGH:-82}"     # °C : au-dessus, on descend
readonly TEMP_LOW="${CPU_GUARD_TEMP_LOW:-68}"       # °C : en dessous, on remonte
readonly INTERVAL="${CPU_GUARD_INTERVAL:-10}"       # s entre deux relevés
readonly DOWN_SAMPLES="${CPU_GUARD_DOWN_SAMPLES:-2}"
readonly UP_SAMPLES="${CPU_GUARD_UP_SAMPLES:-30}"
readonly DWELL="${CPU_GUARD_DWELL:-120}"            # s de garde après un changement

log() { printf '%s\n' "$*"; }

# Le numéro de hwmon change d'un boot à l'autre : on résout k10temp par son nom.
# acpitz renvoie 0 °C sur cette carte, il ne faut surtout pas s'en servir.
find_temp_input() {
    local h
    for h in /sys/class/hwmon/hwmon*; do
        [[ "$(cat "$h/name" 2>/dev/null)" == "k10temp" ]] || continue
        # Tctl est la température de contrôle, celle que le silicium régule.
        local l
        for l in "$h"/temp*_label; do
            [[ -f "$l" && "$(cat "$l")" == "Tctl" ]] && { echo "${l%_label}_input"; return 0; }
        done
        [[ -f "$h/temp1_input" ]] && { echo "$h/temp1_input"; return 0; }
    done
    return 1
}

read_temp_c() {
    local raw
    raw="$(cat "$TEMP_INPUT" 2>/dev/null)" || return 1
    [[ "$raw" =~ ^-?[0-9]+$ ]] || return 1
    echo $(( raw / 1000 ))
}

# Mode simulation : on peut rejouer une série de températures et vérifier les
# seuils SANS toucher au matériel ni être root. C'est ce qui permet de valider
# l'absence d'oscillation avant d'installer quoi que ce soit.
#   CPU_GUARD_DRYRUN=1                 -> n'écrit pas dans /sys
#   CPU_GUARD_TEMP_SERIE="70 85 85 ..." -> lit ces °C au lieu du capteur, puis sort
readonly DRYRUN="${CPU_GUARD_DRYRUN:-0}"

# Le plafond est une propriété par cœur : il faut l'écrire sur les 16 politiques.
apply_cap_khz() {
    local khz="$1" f n=0
    if [[ "$DRYRUN" == "1" ]]; then
        log "cpu-guard: [simulation] plafond -> $(( khz / 1000 )) MHz"
        return 0
    fi
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [[ -w "$f" ]] || continue
        echo "$khz" > "$f" 2>/dev/null && n=$(( n + 1 ))
    done
    (( n > 0 )) || { log "cpu-guard: ERREUR — aucun scaling_max_freq accessible en écriture (root ?)"; return 1; }
    log "cpu-guard: plafond -> $(( khz / 1000 )) MHz (${n} cœurs)"
}

SERIE="${CPU_GUARD_TEMP_SERIE:-}"
if [[ -n "$SERIE" ]]; then
    read -r -a SERIE_ARR <<< "$SERIE"
    SERIE_I=0
    TEMP_INPUT="(série simulée, ${#SERIE_ARR[@]} relevés)"
else
    TEMP_INPUT="$(find_temp_input)" || {
        log "cpu-guard: ERREUR — capteur k10temp introuvable ; arrêt (aucun réglage touché)."
        exit 1
    }
fi

read -r -a LADDER <<< "$LADDER_KHZ"
(( ${#LADDER[@]} >= 2 )) || { log "cpu-guard: ERREUR — il faut au moins 2 paliers."; exit 1; }

# Sanité : la bande d'hystérésis doit exister, sinon le va-et-vient est garanti.
(( TEMP_HIGH > TEMP_LOW )) || { log "cpu-guard: ERREUR — TEMP_HIGH doit être > TEMP_LOW."; exit 1; }

level=0                       # 0 = palier le plus haut
apply_cap_khz "${LADDER[0]}" || exit 1
log "cpu-guard: démarré — capteur $TEMP_INPUT, paliers: ${LADDER_KHZ} kHz,"
log "cpu-guard: descente >= ${TEMP_HIGH}°C x${DOWN_SAMPLES}, remontée <= ${TEMP_LOW}°C x${UP_SAMPLES}, garde ${DWELL}s."

hot=0; cool=0; guard_until=0

while :; do
    if [[ -n "${SERIE:-}" ]]; then
        now=$(( ${now:-0} + INTERVAL ))          # horloge virtuelle
    else
        sleep "$INTERVAL"
        now="$(date +%s)"
    fi

    if [[ -n "${SERIE:-}" ]]; then
        # Consommé ICI et pas dans read_temp_c : celle-ci est appelée en $( ),
        # donc dans un sous-shell où l'avancée de l'index serait perdue.
        (( SERIE_I < ${#SERIE_ARR[@]} )) || {
            log "cpu-guard: [simulation] fin de série — palier final: $(( LADDER[level] / 1000 )) MHz"; exit 0; }
        t="${SERIE_ARR[$SERIE_I]}"; SERIE_I=$(( SERIE_I + 1 ))
    else
        t="$(read_temp_c)" || { log "cpu-guard: relevé illisible, on passe."; continue; }
    fi

    # Temps de garde : on continue de relever (pour ne pas repartir d'un compteur
    # faussé) mais on ne bouge pas.
    if (( now < guard_until )); then
        hot=0; cool=0
        continue
    fi

    if (( t >= TEMP_HIGH )); then
        hot=$(( hot + 1 )); cool=0
    elif (( t <= TEMP_LOW )); then
        cool=$(( cool + 1 )); hot=0
    else
        # Zone neutre : on ne remet PAS les compteurs à zéro sur un relevé isolé,
        # sinon une oscillation autour d'un seuil empêcherait toute décision.
        :
    fi

    if (( hot >= DOWN_SAMPLES && level < ${#LADDER[@]} - 1 )); then
        level=$(( level + 1 ))
        log "cpu-guard: ${t}°C >= ${TEMP_HIGH}°C sur ${hot} relevés — descente d'un palier."
        apply_cap_khz "${LADDER[$level]}"
        hot=0; cool=0; guard_until=$(( now + DWELL ))
    elif (( cool >= UP_SAMPLES && level > 0 )); then
        level=$(( level - 1 ))
        log "cpu-guard: ${t}°C <= ${TEMP_LOW}°C sur ${cool} relevés — remontée d'un palier."
        apply_cap_khz "${LADDER[$level]}"
        hot=0; cool=0; guard_until=$(( now + DWELL ))
    fi
done
