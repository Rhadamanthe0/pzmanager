#!/bin/bash
# enforceClosedServer.sh - Garantit Open=false dans le .ini avant démarrage.
#
# Modèle B42 : l'admission passe par allowedsteamid (whitelist SteamID), et
# Open=false est LA barrière (cf. manageWhitelist.sh, resetServer.sh). Or aucun
# code n'écrivait jamais Open= : une installation existante restait Open=true
# après mise à jour, et une fraîche dépendait du défaut du jeu (constat de
# sécurité, 10/2026 : serveur ouvert malgré la doc whitelist).
# Appelé en ExecStartPre BLOQUANT de zomboid.service (sans "-" : un serveur qui
# ne peut pas être fermé ne démarre pas), donc sur TOUS les chemins de
# démarrage (boot, pzm server start/restart, socket-activation). La whitelist
# (allowedsteamid, comptes) n'est jamais touchée : seul le mode d'admission
# est verrouillé — le flux « whitelist dès la première connexion » est inchangé.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

# Join the same authenticated WORLD admission as Writing/purge. The worker
# proves the inherited OFD and clean journal before even creating the INI dir.
if [[ "${1:-}" != --admitted-worker ]]; then
    lock_path="$(python3 "${SCRIPT_DIR}/writing_start_admission.py" path)" || exit 1
    exec python3 "${SCRIPT_DIR}/writing_start_admission.py" run \
        --lock-path "$lock_path" --unit "$PZ_SERVICE_NAME" -- bash "$0" --admitted-worker
fi
# The editor independently re-proves the inherited FD and clean journal.
exec python3 "${SCRIPT_DIR}/enforceClosedServer.py"
