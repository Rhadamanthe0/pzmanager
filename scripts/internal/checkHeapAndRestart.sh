#!/bin/bash
# Moniteur mémoire adaptatif : déclenche un redémarrage anticipé quand le heap
# Java atteint HEAP_RESTART_PERCENT % du -Xmx. Remplace le redémarrage périodique
# fixe (11h/17h/23h) : on redémarre quand c'est NÉCESSAIRE, pas à heure fixe.
#
# Pourquoi : le heap se remplit de cellules de map VIVANTES (IsoGridSquare/chunks)
# que rien ne libère — ni le GC (elles sont référencées par ServerMap), ni aucune
# commande console. Un restart est le seul reclaim (cf. gotcha OOM dans CLAUDE.md).
# Le crash Java-heap-OOM survient vers ~15 h d'uptime.
#
# Signal lu : l'occupation heap APRÈS un GC majeur (Major Collection) dans
# gc.log. C'est le vrai indicateur d'OOM imminent : si même après un GC complet
# on reste ≥ seuil, plus rien n'est récupérable sans redémarrer.
#
# Lancé par pz-heapcheck.timer (~toutes les 3 min). Sans effet si le serveur est
# arrêté, si gc.log est absent, ou si un restart a déjà été déclenché récemment.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly GC_LOG="${LOG_ZOMBOID_DIR}/gc.log"
readonly COOLDOWN_MARKER="/tmp/pzmanager-heapcheck-$(id -un).trigger"
readonly PCT_THRESHOLD="${HEAP_RESTART_PERCENT:-95}"
readonly RESTART_DELAY="${HEAP_RESTART_DELAY:-5m}"
# Ne pas re-déclencher tant que le restart précédent (préavis + arrêt + reboot
# éventuel) n'est pas passé et que le heap n'est pas retombé.
readonly COOLDOWN_SECONDS=1800

# Serveur arrêté -> rien à surveiller.
server_is_active || exit 0

# Pas encore de gc.log (aucun GC émis) -> rien à faire.
[[ -f "$GC_LOG" ]] || exit 0

# Dernière synthèse de GC MAJEUR :
#   "... Major Collection (Timer) AAAAM(BB%)->CCCCM(DD%) X,Ys"
# On extrait DD = occupation du heap après le GC (données vivantes / Xmx).
last_line="$(grep -aE 'Major Collection .*->[0-9]+M\([0-9]+%\)' "$GC_LOG" 2>/dev/null | tail -1)"
[[ -n "$last_line" ]] || exit 0
pct="$(sed -E 's/.*->[0-9]+M\(([0-9]+)%\).*/\1/' <<< "$last_line")"
[[ "$pct" =~ ^[0-9]+$ ]] || exit 0

log "heapcheck: heap post-GC ${pct}% (seuil ${PCT_THRESHOLD}%)"
(( pct >= PCT_THRESHOLD )) || exit 0

# Anti-empilement : un restart vient-il d'être déclenché ?
if [[ -f "$COOLDOWN_MARKER" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$COOLDOWN_MARKER" 2>/dev/null || echo 0) ))
    if (( age < COOLDOWN_SECONDS )); then
        log "heapcheck: restart déjà déclenché il y a ${age}s (<${COOLDOWN_SECONDS}s) — on attend."
        exit 0
    fi
fi
: > "$COOLDOWN_MARKER"

log "heapcheck: seuil atteint (${pct}%) -> redémarrage préventif dans ${RESTART_DELAY}."
# Foreground obligatoire (un restart avec délai lancé en arrière-plan est un no-op).
# La commande bloque le temps du préavis : pz-heapcheck.service a un TimeoutStartSec large.
exec "${PZ_MANAGER_DIR}/pzm" server restart "$RESTART_DELAY" --automatic \
    --reason "Mémoire serveur à ${pct}% du max — redémarrage préventif (évite le crash mémoire)"
