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
readonly STALL_SAMPLES="${STALL_WATCH_SAMPLES:-2}"   # relevés identiques avant capture
readonly JCMD="${PZ_GRAALVM_HOME:-}/bin/jcmd"

server_is_active || { rm -f "$STATE_FILE"; exit 0; }
[[ -n "$PORT" ]] || exit 0

pid="$(pgrep -f 'ProjectZomboid64' | head -1 || true)"
[[ -n "$pid" ]] || exit 0

metrics="$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null || true)"
[[ -n "$metrics" ]] || exit 0   # exporteur muet (boot en cours) -> on ne conclut rien

# Somme des octets envoyés (avance à chaque tick tant que la main loop tourne)
# et nombre de clients connectés (labels client="..." non vides).
sent="$(awk -F' ' '/^packet_send_bytes_count/ {s+=$2} END {printf "%.0f", s+0}' <<< "$metrics")"
clients="$(grep -oP '(?<=^packet_send_bytes_count\{client=")[^"]+' <<< "$metrics" | sort -u | grep -cv '^$' || true)"

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
        if [[ -x "$JCMD" ]]; then
            timeout 60 "$JCMD" "$pid" Thread.print -l 2>&1 || echo "(jcmd a échoué)"
        else
            echo "(jcmd introuvable : ${JCMD})"
        fi
        echo
    } >> "$out"
    (( i < 3 )) && sleep 10
done

# --- Tri vrai gel / faux positif ---------------------------------------------
# Un compteur figé ne suffit PAS à conclure : un client connecté mais encore en
# écran de chargement (ou déconnecté sans que le serveur l'ait purgé) n'engendre
# aucun envoi alors que la boucle principale tourne très bien — c'est ce qui a
# produit 4 fausses alertes les 11/08 (04h35, 06h33, 09h02, 09h10).
# Le juge de paix est dans le dump : en vrai gel, "main" est RUNNABLE et son
# compteur `cpu=` grimpe d'une seconde par seconde (un cœur à 100 %) ; au repos
# il dort dans `Thread.sleep` à GameServer.main.
main_state="$(awk '/^"main" /{getline; print; exit}' "$out")"
if ! grep -q 'State: RUNNABLE' <<< "$main_state"; then
    log "stallwatch: faux positif (main au repos : ${main_state//[[:space:]]/ }) — capture supprimée."
    rm -f "$out"
    exit 0
fi

# --- Notifications ------------------------------------------------------------
# Canal public (annonces joueurs) : une seule ligne, lisible, sans jargon — les
# joueurs ont juste besoin de savoir pourquoi ça coupe et que ça repart seul.
"${SCRIPT_DIR}/sendDiscord.sh" \
    "🧊 Gel du serveur détecté — redémarrage automatique en cours." || true

# Détail technique (chemin du dump) : réservé à l'admin. Sur
# DISCORD_ADMIN_WEBHOOK si défini dans .env, sinon journal seul — jamais sur le
# canal public.
if [[ -n "${DISCORD_ADMIN_WEBHOOK:-}" ]]; then
    jq -n --arg content "🧊 Gel confirmé (main RUNNABLE, ${clients} joueur(s), compteur figé ~$(( STALL_SAMPLES + 1 )) min). Thread dump : \`logs/zomboid/stall_${ts}.txt\`" '{content: $content}' \
        | curl -s --connect-timeout 5 --max-time 10 \
               -H "Content-Type: application/json" -d @- "${DISCORD_ADMIN_WEBHOOK}" \
               > /dev/null 2>&1 || true
fi

# --- Redémarrage automatique --------------------------------------------------
# Le serveur est mort pour les joueurs : attendre une intervention humaine ne
# gagne rien (le 11/08 il est resté figé ~10 min). `now` car tout préavis serait
# absurde — plus rien ne tourne — et `--silent` parce que l'annonce ci-dessus a
# déjà prévenu les joueurs (notifyServerReady annoncera le retour en ligne).
# Le `quit` propre ne passera pas (traité par le thread bloqué) : systemd
# SIGKILL à TimeoutStopSec, c'est attendu.
# Débrayable : STALL_AUTO_RESTART=0 dans .env.
if [[ "${STALL_AUTO_RESTART:-1}" != "1" ]]; then
    log "stallwatch: STALL_AUTO_RESTART=0 — redémarrage laissé à l'admin."
    exit 0
fi

log "stallwatch: redémarrage automatique du serveur."
"${PZ_MANAGER_ROOT}/pzm" server restart now --silent --reason "Gel du thread principal (redémarrage automatique)" \
    || log "stallwatch: le redémarrage automatique a échoué — intervention manuelle nécessaire."
