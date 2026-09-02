#!/bin/bash
# Détecteur de GEL du thread principal du serveur (main loop bloquée).
#
# Symptôme observé (2026-08-07 puis 2026-08-10) : le serveur reste "actif" pour
# systemd et pour Steam, la JVM répond (l'exporteur Prometheus sert encore ses
# métriques, le thread réseau accepte encore les connexions Steam) MAIS :
#   - le compteur de frames `f:` du log de jeu N'AVANCE PLUS,
#   - game_pps_sent/recv tombent à 0 (monitoring.csv) alors que des joueurs sont
#     connectés,
#   - cpu_proc reste bloqué à ~110 % = UN cœur à 100 % -> boucle infinie
#     mono-thread, ce n'est ni un OOM (heap ~34 %) ni une surcharge machine.
# Conséquences : les joueurs "disparaissent", plus aucun chunk ne charge, et le
# `quit` de l'ExecStop n'est jamais traité (c'est la main loop qui l'exécute) ->
# systemd SIGKILL à TimeoutStopSec -> alerte Discord "Failed with result
# 'timeout'" + monde non sauvegardé.
#
# Rien dans les logs ne nomme le coupable (aucune exception avant le gel) : la
# seule preuve exploitable est un THREAD DUMP pris PENDANT le gel. C'est le rôle
# de ce script — il ne répare rien, il capture.
#
# Détection : somme des compteurs `packet_send_bytes_count` de l'exporteur
# Prometheus interne (incrémentés par la main loop). Inchangée sur STALL_SAMPLES
# relevés consécutifs alors que des clients sont connectés = gel.
# Capture : 3 x `jcmd Thread.print` + `top -H` (pour identifier le thread qui
# brûle le cœur via son TID -> nid hexa dans le dump) dans
# logs/zomboid/stall_<ts>.txt, puis alerte Discord.
#
# Lancé par pz-stallwatch.timer (toutes les minutes). Sans effet serveur arrêté.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly PORT="${PZ_PROMETHEUS_PORT:-}"
readonly STATE_FILE="/tmp/pzmanager-stallwatch-$(id -un).state"
# 1 seul relevé figé suffit à déclencher la CAPTURE : ce n'est pas elle qui
# tranche, c'est le dump (main RUNNABLE ou non). Exiger 2 relevés ne fiabilisait
# rien et coûtait ~1 min 30 de gel supplémentaire.
readonly STALL_SAMPLES="${STALL_WATCH_SAMPLES:-1}"   # relevés identiques avant capture
# jcmd : GraalVM d'abord (cf. PZ_GRAALVM_HOME), sinon celui du PATH, sinon un JDK
# système. La forme précédente ("${PZ_GRAALVM_HOME:-}/bin/jcmd") donnait "/bin/jcmd"
# dès que la variable était vide — c'est-à-dire après le rollback GraalVM documenté,
# ou sur la JRE Steam qui n'embarque pas jcmd. Le dump ne contenait alors aucune
# ligne "main", le calcul de CPU brûlé restait à -1, et TOUT gel réel était classé
# faux positif : le détecteur se taisait définitivement sans le dire.
resolve_jcmd() {
    local c
    for c in "${PZ_GRAALVM_HOME:-}/bin/jcmd" "$(command -v jcmd 2>/dev/null || true)" \
             /usr/lib/jvm/*/bin/jcmd; do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}
JCMD="$(resolve_jcmd || true)"
readonly JCMD
readonly COOLDOWN_FILE="/tmp/pzmanager-stallwatch-$(id -un).cooldown"
# Après un faux positif, on se tait ce temps-là : inutile de re-dumper (30 s de
# jcmd) chaque minute tant que la cause bénigne dure.
readonly FALSE_POSITIVE_COOLDOWN=600

server_is_active || { rm -f "$STATE_FILE" "$COOLDOWN_FILE"; exit 0; }
[[ -n "$PORT" ]] || exit 0

if [[ -f "$COOLDOWN_FILE" ]]; then
    if (( $(date +%s) < $(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0) )); then
        exit 0
    fi
    rm -f "$COOLDOWN_FILE"
fi

pid="$(pgrep -f 'ProjectZomboid64' | head -1 || true)"
[[ -n "$pid" ]] || exit 0

# Somme des octets envoyés (avance à chaque tick tant que la main loop tourne)
# et nombre de clients connectés (labels client="..." non vides), en UN SEUL
# passage awk directement sur le flux curl.
#
# $NF et non $2 : la valeur Prometheus est le DERNIER champ, et les pseudos
# contiennent des espaces (« Allan Faroweit », « Jeff Pessos »), ce qui décalait
# les champs. Ces clients comptaient donc pour 0 dans la somme — 26 % du trafic
# perdu sur un relevé du 18/08. Conséquence : avec uniquement des pseudos à
# espace connectés, le compteur paraissait figé et le détecteur criait au gel
# sur un serveur sain (seul le filtre CPU évitait le SIGKILL).
read -r sent clients < <(
    curl -s --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null |
    awk '/^packet_send_bytes_count/ {
             s += $NF
             if (match($0, /client="[^"]*"/)) {
                 c = substr($0, RSTART + 8, RLENGTH - 9)
                 if (c != "") seen[c] = 1
             }
         }
         END { printf "%.0f %d\n", s + 0, length(seen) }'
) || true   # read renvoie 1 sur une dernière ligne sans \n — ne pas tuer le script
[[ -n "${sent:-}" ]] || exit 0   # exporteur muet (boot en cours) -> on ne conclut rien

# Aucun joueur : la main loop tourne au ralenti, les compteurs peuvent stagner
# légitimement -> on ne peut pas conclure, on repart de zéro.
if (( clients == 0 )); then
    printf '%s %s 0\n' "$pid" "$sent" > "$STATE_FILE"
    exit 0
fi

prev_pid=""; prev_sent=""; strikes=0
if [[ -f "$STATE_FILE" ]]; then
    read -r prev_pid prev_sent strikes < "$STATE_FILE" || true
fi

# Redémarrage entre deux passages -> compteurs remis à zéro, on réinitialise.
if [[ "$prev_pid" != "$pid" ]]; then
    printf '%s %s 0\n' "$pid" "$sent" > "$STATE_FILE"
    exit 0
fi

if [[ "$sent" == "$prev_sent" ]]; then
    strikes=$(( strikes + 1 ))
else
    strikes=0
fi
printf '%s %s %s\n' "$pid" "$sent" "$strikes" > "$STATE_FILE"

(( strikes >= STALL_SAMPLES )) || exit 0

# --- Gel confirmé : capture ---------------------------------------------------
# strikes == STALL_SAMPLES : on capture UNE fois par gel (aux passages suivants
# strikes continue de monter, on ne re-dumpe pas).
if (( strikes > STALL_SAMPLES )); then
    log "stallwatch: gel toujours en cours (${strikes} relevés) — dump déjà pris."
    exit 0
fi

ts="$(date +%Y-%m-%d_%Hh%Mm%Ss)"
out="${LOG_ZOMBOID_DIR}/stall_${ts}.txt"
log "stallwatch: GEL DÉTECTÉ (pid ${pid}, ${clients} client(s), compteur figé à ${sent}) — capture -> ${out}"

{
    echo "=== stallwatch ${ts} — pid ${pid}, clients=${clients}, packet_send_bytes_count figé à ${sent} ==="
    echo
} > "$out"

for i in 1 2 3; do
    {
        echo "########## capture ${i}/3 — $(date '+%H:%M:%S')"
        # top -H : le thread à ~100 % est le fautif ; son TID (décimal) se
        # retrouve dans le dump sous "nid=0x<hexa>".
        echo "--- top -H (TID décimal ; nid = TID en hexa dans le dump) ---"
        top -H -b -n1 -p "$pid" 2>/dev/null | head -25 || true
        echo "--- jcmd Thread.print ---"
        if [[ -n "$JCMD" ]]; then
            timeout 60 "$JCMD" "$pid" Thread.print -l 2>&1 || echo "(jcmd a échoué)"
        else
            echo "(jcmd introuvable — impossible de trancher, voir resolve_jcmd)"
        fi
        echo
    } >> "$out"
    (( i < 3 )) && sleep 10
done

# --- Tri vrai gel / faux positif ---------------------------------------------
# Un compteur figé ne suffit PAS à conclure : une sauvegarde du monde bloque la
# boucle principale plusieurs dizaines de secondes, et un client encore en écran
# de chargement n'engendre aucun envoi — dans les deux cas le compteur stagne
# alors que le serveur va bien.
#
# Le seul critère fiable est le PROFIL CPU du thread "main" sur les 3 captures :
#   - vrai gel  : RUNNABLE aux 3, et `cpu=` grimpe d'~1 s par seconde écoulée
#                 (boucle infinie = un cœur saturé). Mesuré le 11/08 : 84 %.
#   - sauvegarde: RUNNABLE au début puis endormi, et ~5 % de CPU seulement
#                 (c'est de l'I/O). Mesuré le 14/08 : 7 % puis 3 %.
# Se contenter de "RUNNABLE sur la 1re capture" a coûté un SIGKILL sur un
# serveur sain avec 10 joueurs le 14/08 à 12h15 — d'où ce test sur la durée.
readonly BURN_MIN_PCT="${STALL_BURN_MIN_PCT:-60}"

# Les lignes "main" portent cpu= et elapsed= ; la locale FR écrit « 1004719,50ms ».
mapfile -t main_lines < <(grep -E '^"main" ' "$out")
runnable_count="$(grep -cE '^"main" .* runnable' "$out" || true)"

burn_pct=-1
if (( ${#main_lines[@]} >= 2 )); then
    burn_pct="$(printf '%s\n' "${main_lines[0]}" "${main_lines[-1]}" \
        | tr ',' '.' \
        | awk 'BEGIN {n=0}
               match($0,/cpu=[0-9.]+/)   {c[n]=substr($0,RSTART+4,RLENGTH-4)}
               match($0,/elapsed=[0-9.]+/){e[n]=substr($0,RSTART+8,RLENGTH-8); n++}
               END {if (n<2 || e[1]-e[0] <= 0) {print -1; exit}
                    printf "%.0f", 100*(c[1]-c[0])/((e[1]-e[0])*1000)}')"
fi

# Aucune ligne "main" : le dump n'a rien capturé (jcmd absent). On ne peut ni
# confirmer ni infirmer — on le DIT, au lieu de le faire passer pour un faux
# positif, ce qui donnait un détecteur muet et une capture effacée. Sur cette
# machine seul GraalVM fournit jcmd (la JRE Steam et le JDK système, headless,
# n'en ont pas) : un rollback GraalVM rend donc l'arbitrage impossible.
if (( ${#main_lines[@]} == 0 )); then
    log "stallwatch: ARBITRAGE IMPOSSIBLE (aucune ligne \"main\" dans le dump — jcmd absent ?). Capture conservée dans ${out} ; aucun redémarrage déclenché. Vérifier PZ_GRAALVM_HOME."
    printf '%s %s 0\n' "$pid" "$sent" > "$STATE_FILE"
    date -d "+${FALSE_POSITIVE_COOLDOWN} seconds" +%s > "$COOLDOWN_FILE"
    exit 0
fi

if (( runnable_count < ${#main_lines[@]} )) || (( burn_pct < BURN_MIN_PCT )); then
    log "stallwatch: faux positif (main runnable ${runnable_count}/${#main_lines[@]}, CPU brûlé ${burn_pct}% < ${BURN_MIN_PCT}%) — capture supprimée, pause ${FALSE_POSITIVE_COOLDOWN}s."
    rm -f "$out"
    # Réarmer : sans ça, `strikes` continuait de grimper et le script répondait
    # « dump déjà pris » sans plus rien vérifier — 40 min d'aveuglement le 14/08
    # à 04h12. Le cooldown évite de re-dumper chaque minute entre-temps.
    printf '%s %s 0\n' "$pid" "$sent" > "$STATE_FILE"
    date -d "+${FALSE_POSITIVE_COOLDOWN} seconds" +%s > "$COOLDOWN_FILE"
    exit 0
fi
log "stallwatch: gel confirmé (main runnable ${runnable_count}/${#main_lines[@]}, CPU brûlé ${burn_pct}%)."

# --- Notifications ------------------------------------------------------------
# Canal public (annonces joueurs) : une seule ligne, lisible, sans jargon — les
# joueurs ont juste besoin de savoir pourquoi ça coupe et que ça repart seul.
notify "🧊 Gel du serveur détecté — redémarrage automatique en cours."

# Détail technique (chemin du dump) : réservé à l'admin. Sur
# DISCORD_ADMIN_WEBHOOK si défini dans .env, sinon journal seul — jamais sur le
# canal public. Passe par sendDiscord.sh --webhook plutôt que par un jq|curl
# recopié : celui-ci n'avait pas le repli sans jq du script partagé, donc le
# message admin disparaissait en silence sur une machine sans jq.
if [[ -n "${DISCORD_ADMIN_WEBHOOK:-}" ]]; then
    notify "🧊 Gel confirmé (main RUNNABLE, ${clients} joueur(s), compteur figé ~$(( STALL_SAMPLES + 1 )) min). Thread dump : \`logs/zomboid/stall_${ts}.txt\`" \
        --webhook "${DISCORD_ADMIN_WEBHOOK}"
fi

# --- Redémarrage automatique --------------------------------------------------
# Le serveur est mort pour les joueurs : attendre une intervention humaine ne
# gagne rien (le 11/08 il est resté figé ~7 min 30).
# Débrayable : STALL_AUTO_RESTART=0 dans .env.
if [[ "${STALL_AUTO_RESTART:-1}" != "1" ]]; then
    log "stallwatch: STALL_AUTO_RESTART=0 — redémarrage laissé à l'admin."
    exit 0
fi

# SIGKILL immédiat, sans passer par l'arrêt propre. Le `quit` de l'ExecStop est
# exécuté PAR la boucle principale, donc par le thread bloqué : il ne peut
# structurellement pas aboutir, et les 120 s de TimeoutStopSec ne sont que de
# l'attente avant le SIGKILL que systemd finira par envoyer. Aucune perte
# supplémentaire : la boucle empêche déjà toute sauvegarde.
log "stallwatch: SIGKILL immédiat (le quit ne peut pas aboutir sur un thread bloqué)."
systemctl --user kill --signal=SIGKILL --kill-whom=all "${PZ_SERVICE_NAME}" || true

# Laisser systemd constater la mort : tant qu'il voit le service actif, pz.sh
# tenterait l'arrêt propre et on aurait rattrapé les 120 s qu'on vient d'éviter.
for _ in $(seq 30); do
    server_is_active || break
    sleep 1
done

log "stallwatch: redémarrage automatique du serveur."
"${PZ_MANAGER_DIR}/pzm" server restart now --silent --reason "Gel du thread principal (redémarrage automatique)" \
    || log "stallwatch: le redémarrage automatique a échoué — intervention manuelle nécessaire."
