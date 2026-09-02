#!/bin/bash
# Attend que le RCON soit prêt et envoie une notification Discord
# Silencieux si fichier .silent_next_start existe (créé par maintenance)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# Même chemin que celui qu'écrit performFullMaintenance.sh : on lit PZ_MANAGER_DIR
# (.env) au lieu de recompter les ".." depuis SCRIPT_DIR, qui divergeaient dès que
# l'arborescence bouge.
readonly SILENT_FLAG="${PZ_MANAGER_DIR}/.silent_next_start"
readonly NOTIFY_LOCK="/tmp/pzmanager-notify-ready-$(id -un).lock"
readonly TIMEOUT=300
# Check and consume silent flag
if [[ -f "$SILENT_FLAG" ]]; then
    rm -f "$SILENT_FLAG"
    exit 0
fi

# Prevent duplicate notifications (lock for 5 minutes)
if (( $(marker_age_seconds "$NOTIFY_LOCK") < 300 )); then
    exit 0
fi
touch "$NOTIFY_LOCK"

start_time=$(date +%s)

# Lecture EN FLUX du journal (-f) plutôt qu'un re-scan toutes les 5 s.
#
# Deux raisons. (1) Correction : `journalctl | grep -qF` sortait à la 1re
# occurrence, tuant journalctl en SIGPIPE (141) ; sous `set -o pipefail` le test
# devenait faux ALORS QUE le marqueur était là, et la notification « serveur en
# ligne » pouvait n'être jamais envoyée (common.sh documente exactement ce piège
# et l'évite avec grep -cF). (2) Coût : l'ancienne boucle relisait tout le journal
# depuis le début du boot à chaque tour, une fenêtre qui atteint ~11 000 lignes /
# 1,6 Mo en fin de chargement — des dizaines de rescans pendant que la JVM charge
# la map, au pire moment pour la machine. En flux, le coût est constant.
#
# La forme compte : on CAPTURE la sortie de grep et on ignore le statut du
# pipeline. Vérifié le 18/08 sur le journal réel — mettre `grep -qFm1` en bout de
# pipeline ne suffit PAS : journalctl -f meurt quand même en SIGPIPE, pipefail
# remonte 141 et le test reste faux alors que le marqueur a bien été vu.
hits="$( { timeout "$TIMEOUT" journalctl --user -u "${PZ_SERVICE_NAME}" \
            --since "@${start_time}" --no-pager -f 2>/dev/null || true; } \
          | grep -cFm1 "$SERVER_READY_MARKER" || true )"

if (( hits > 0 )); then
    notify "Le serveur Project Zomboid est en ligne !"
fi

exit 0
