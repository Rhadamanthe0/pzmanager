#!/bin/bash
# Moniteur mémoire adaptatif : restart à PZ_RAM_RESTART_GB (18 Gio par défaut)
# de RAM résidente agrégée de pz.slice (jeu + bot + backups + gestion), OU
# à HEAP_RESTART_PERCENT % du -Xmx après GC majeur. Le cache de fichiers et le
# slab récupérables ne déclenchent pas un restart. pz.slice MemoryMax=20G reste un plafond
# cgroup de secours, où Linux peut récupérer ces caches avant l'OOM-kill.
# Remplace le redémarrage périodique
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
# Lancé par pz-heapcheck.timer (~toutes les 30 s). La RAM reste surveillée même
# sans gc.log. Sans effet si arrêté ou si un restart a déjà été déclenché.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly GC_LOG="${LOG_ZOMBOID_DIR}/gc.log"
# Marqueur de cooldown dans le répertoire privé (cf. private_state_path) : le
# précédent marqueur partagé prévisible sous /tmp laissait un autre utilisateur
# local le pré-créer avec un mtime futur et bloquer ainsi les restarts
# préventifs (âge calculé négatif < cooldown).
COOLDOWN_MARKER="$(private_state_path "heapcheck.trigger")" \
    || die "Répertoire d'état privé indisponible (repli /tmp pré-créé par un tiers ?) : heapcheck annulé (fail-closed)."
readonly COOLDOWN_MARKER
readonly PCT_THRESHOLD="${HEAP_RESTART_PERCENT:-95}"
readonly RAM_THRESHOLD_GB="${PZ_RAM_RESTART_GB:-18}"
readonly RESTART_DELAY="${HEAP_RESTART_DELAY:-5m}"
[[ "$RAM_THRESHOLD_GB" =~ ^([1-9]|1[0-9])$ ]] \
    || die "PZ_RAM_RESTART_GB doit être un entier entre 1 et 19 (plafond strict : 20 Gio)."
[[ "$PCT_THRESHOLD" =~ ^([1-9]|[1-9][0-9]|100)$ ]] \
    || die "HEAP_RESTART_PERCENT doit être un entier entre 1 et 100."
# Ne pas re-déclencher tant que le restart précédent (préavis + arrêt + reboot
# éventuel) n'est pas passé et que le heap n'est pas retombé.
readonly COOLDOWN_SECONDS=1800

# Serveur arrêté -> rien à surveiller.
server_is_active || exit 0

# Un service peut dépasser le budget total avec un heap encore peu rempli.
# Restreindre la lecture /proc aux processus du cgroup serveur et ses enfants.
# Ne jamais interpréter une erreur du bus comme une mesure valide.
reason=""
control_group="$(systemctl --user show pz.slice -p ControlGroup --value 2>/dev/null || true)"
memory_bytes="$(python3 "${SCRIPT_DIR}/../lib/service_memory.py" "$control_group" 2>/dev/null || true)"
if [[ "$memory_bytes" =~ ^[0-9]{1,18}$ ]]; then
    log "heapcheck: RAM PZ partagée ${memory_bytes} octets (seuil ${RAM_THRESHOLD_GB} Gio)"
    if (( 10#$memory_bytes >= RAM_THRESHOLD_GB * 1024 * 1024 * 1024 )); then
        memory_gb="$(awk -v bytes="$memory_bytes" 'BEGIN {printf "%.1f", bytes / 1073741824}')"
        reason="RAM totale PZ (jeu et gestion) à ${memory_gb} Go (seuil ${RAM_THRESHOLD_GB} Go, plafond strict 20 Go)"
    fi
else
    log "heapcheck: RAM PZ partagée indisponible — surveillance heap conservée."
fi

# Dernière synthèse de GC MAJEUR :
#   "... Major Collection (Timer) AAAAM(BB%)->CCCCM(DD%) X,Ys"
# On extrait DD = occupation du heap après le GC (données vivantes / Xmx).
# `|| true` : juste après un restart, gc.log est recréé vierge (aucune ligne
# "Major Collection" encore) -> grep sort en code 1, et sous set -e + pipefail
# l'assignation ferait planter le script (service "failed" -> alerte Discord)
# AVANT d'atteindre le garde-fou ci-dessous. On avale l'échec pour le gérer ici.
if [[ -f "$GC_LOG" ]]; then
    last_line="$(grep -aE 'Major Collection .*->[0-9]+M\([0-9]+%\)' "$GC_LOG" 2>/dev/null | tail -1 || true)"
    if [[ -n "$last_line" ]]; then
        pct="$(sed -E 's/.*->[0-9]+M\(([0-9]+)%\).*/\1/' <<< "$last_line")"
        if [[ "$pct" =~ ^[0-9]{1,3}$ ]]; then
            log "heapcheck: heap post-GC ${pct}% (seuil ${PCT_THRESHOLD}%)"
            if [[ -z "$reason" ]] && (( 10#$pct >= PCT_THRESHOLD )); then
                reason="Heap Java post-GC à ${pct}% du max (seuil ${PCT_THRESHOLD}%)"
            fi
        fi
    fi
fi
[[ -n "$reason" ]] || exit 0

# Anti-empilement : un restart vient-il d'être déclenché ?
# Hygiène du marqueur : on ne fait confiance qu'à un fichier régulier possédé
# par nous (un autre type/propriétaire est retiré, jamais lu). Dans le dossier
# privé 0700 ci-dessus, un tiers ne peut de toute façon rien y déposer.
if [[ -e "$COOLDOWN_MARKER" ]] && { [[ ! -f "$COOLDOWN_MARKER" ]] || [[ ! -O "$COOLDOWN_MARKER" ]]; }; then
    rm -f -- "$COOLDOWN_MARKER" 2>/dev/null || true
fi
age="$(marker_age_seconds "$COOLDOWN_MARKER")"
if (( age < COOLDOWN_SECONDS )); then
    log "heapcheck: restart déjà déclenché il y a ${age}s (<${COOLDOWN_SECONDS}s) — on attend."
    exit 0
fi
: > "$COOLDOWN_MARKER"

log "heapcheck: ${reason} -> redémarrage préventif dans ${RESTART_DELAY}."
# Foreground obligatoire (un restart avec délai lancé en arrière-plan est un no-op).
# La commande bloque le temps du préavis : pz-heapcheck.service a un TimeoutStartSec large.
if "${PZ_MANAGER_DIR}/pzm" server restart "$RESTART_DELAY" --automatic \
    --reason "${reason} — redémarrage préventif"; then
    exit 0
else
    rc=$?
    # Un verrou occupé ou un restart en échec doit être retenté au prochain tick,
    # pas bloquer la surveillance pendant 30 min jusqu'au plafond brutal.
    rm -f -- "$COOLDOWN_MARKER"
    log "heapcheck: redémarrage en échec (exit=${rc}) — nouvelle tentative au prochain contrôle."
    exit "$rc"
fi
