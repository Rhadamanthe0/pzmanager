#!/bin/bash
# enforceClosedServer.sh - Garantit Open=false dans le .ini avant démarrage.
#
# Modèle B42 : l'admission passe par allowedsteamid (whitelist SteamID), et
# Open=false est LA barrière (cf. manageWhitelist.sh, resetServer.sh). Or aucun
# code n'écrivait jamais Open= : une installation existante restait Open=true
# après mise à jour, et une fraîche dépendait du défaut du jeu (constat Codex
# Security, 10/2026 : serveur ouvert malgré la doc whitelist).
# Appelé en ExecStartPre BLOQUANT de zomboid.service (sans "-" : un serveur qui
# ne peut pas être fermé ne démarre pas), donc sur TOUS les chemins de
# démarrage (boot, pzm server start/restart, socket-activation). La whitelist
# (allowedsteamid, comptes) n'est jamais touchée : seul le mode d'admission
# est verrouillé — le flux « whitelist dès la première connexion » est inchangé.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

: "${PZ_INI_PATH:=${PZ_SOURCE_DIR}/Server/${PZ_SERVER_NAME}.ini}"
ini_dir="$(dirname "$PZ_INI_PATH")"
mkdir -p "$ini_dir" || die "Dossier ini inaccessible (${ini_dir}) : serveur non démarré (fail-closed)."
if [[ ! -f "$PZ_INI_PATH" ]]; then
    # Primo-démarrage : le jeu complète les clés manquantes, il ne touche pas
    # celles déjà posées — pré-ensemencer Open=false est sûr.
    printf 'Open=false\n' > "$PZ_INI_PATH" \
        || die "ini inaccessible (${PZ_INI_PATH}) : serveur non démarré (fail-closed)."
    log "Open=false pré-ensemencé (${PZ_INI_PATH})."
elif grep -q '^Open=false$' "$PZ_INI_PATH"; then
    : # déjà fermé
elif grep -qE '^[[:space:]]*Open[[:space:]]*=' "$PZ_INI_PATH"; then
    sed -i -E 's/^[[:space:]]*Open[[:space:]]*=.*/Open=false/' "$PZ_INI_PATH" \
        || die "ini non réinscriptible (${PZ_INI_PATH}) : serveur non démarré (fail-closed)."
    log "Open=false réparé (${PZ_INI_PATH}) — le serveur était ouvert."
else
    printf 'Open=false\n' >> "$PZ_INI_PATH" \
        || die "ini non réinscriptible (${PZ_INI_PATH}) : serveur non démarré (fail-closed)."
    log "Open=false ajouté (${PZ_INI_PATH})."
fi
grep -q '^Open=false$' "$PZ_INI_PATH" \
    || die "Vérification Open=false impossible (${PZ_INI_PATH}) : serveur non démarré (fail-closed)."
