#!/bin/bash
# ------------------------------------------------------------------------------
# resetServer.sh - Reset complet du serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./resetServer.sh [--keep-whitelist]
#
# Reset complet du serveur avec nouveau monde.
# Option --keep-whitelist: Restaure whitelist et configs depuis ancien serveur.
#
# ATTENTION: Supprime toutes les données du serveur actuel !
# Un backup est créé dans /home/pzuser/OLD/ avant suppression.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly KEEP_WHITELIST="${1:-}"
readonly TIMESTAMP=$(date +"%Y-%m-%d_%Hh%Mm%Ss")
readonly OLD_DIR="${PZ_HOME}/OLD/Zomboid_OLD_${TIMESTAMP}"

confirm_reset() {
    echo "⚠️  RESET SERVEUR - SUPPRESSION COMPLÈTE DES DONNÉES ⚠️"
    echo ""
    echo "Actions: Arrêt → Backup ($OLD_DIR) → Suppression → Nouveau serveur"
    [[ "$KEEP_WHITELIST" == "--keep-whitelist" ]] && echo "       → Restauration whitelist et configs"
    echo ""
    echo -n "Tapez 'RESET' en majuscules pour confirmer: "
    read -r confirmation
    [[ "$confirmation" == "RESET" ]] || die "Annulé"
}

stop_server() {
    echo ""
    echo "=== 1. Arrêt du serveur ==="

    if systemctl --user is-active --quiet "${PZ_SERVICE_NAME}"; then
        systemctl --user stop "${PZ_SERVICE_NAME}"
        echo "✓ Serveur arrêté"
    else
        echo "✓ Serveur déjà arrêté"
    fi
}

backup_current() {
    echo ""
    echo "=== 2. Backup des données actuelles ==="

    [[ -d "${PZ_SOURCE_DIR}" ]] || die "Répertoire Zomboid introuvable: ${PZ_SOURCE_DIR}"

    mkdir -p "${PZ_HOME}/OLD"
    mv "${PZ_SOURCE_DIR}" "$OLD_DIR"

    echo "✓ Backup créé: $OLD_DIR"
}

initial_setup() {
    echo ""
    echo "=== 3. Configuration initiale du nouveau serveur ==="
    echo ""
    echo "INSTRUCTIONS:"
    echo "  1. Le serveur va démarrer en mode configuration"
    echo "  2. Entrez le mot de passe admin DEUX FOIS quand demandé"
    echo "  3. Quand vous voyez 'If the server hangs here, set UPnP=false':"
    echo "     → Appuyez sur Ctrl+C pour arrêter"
    echo ""
    echo -n "Appuyez sur ENTRÉE pour continuer..."
    read -r

    mkdir -p "${PZ_SOURCE_DIR}"

    echo ""
    echo "Démarrage configuration initiale..."
    echo "──────────────────────────────────────────────────────────────"

    "${PZ_INSTALL_DIR}/start-server.sh" || true

    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo "✓ Configuration initiale terminée"
}

restore_whitelist() {
    echo ""
    echo "=== 4. Restauration whitelist et configurations ==="

    local old_db="$OLD_DIR/db/servertest.db"
    local new_db="${PZ_SOURCE_DIR}/db/servertest.db"

    [[ -f "$old_db" ]] || die "Base de données backup introuvable: $old_db"
    [[ -f "$new_db" ]] || die "Base de données nouveau serveur introuvable: $new_db"

    # Restaurer whitelist
    echo "Restauration whitelist..."
    sqlite3 "$new_db" \
        "ATTACH '$old_db' AS old_db;
         INSERT OR IGNORE INTO main.whitelist (username, password, encryptedPwd, pwdEncryptType, steamid, accesslevel, transactionID, displayName)
         SELECT username, password, encryptedPwd, pwdEncryptType, steamid, accesslevel, transactionID, displayName
         FROM old_db.whitelist WHERE username != 'admin';"

    local count=$(sqlite3 "$new_db" "SELECT COUNT(*) FROM whitelist WHERE username != 'admin'")
    echo "✓ $count utilisateur(s) restauré(s)"

    # Copier fichiers de configuration
    echo "Copie configurations..."
    cp "$OLD_DIR/Server/"*.ini "${PZ_SOURCE_DIR}/Server/" 2>/dev/null || true
    cp "$OLD_DIR/Server/"*.lua "${PZ_SOURCE_DIR}/Server/" 2>/dev/null || true
    echo "✓ Fichiers de configuration copiés"
}

finalize() {
    echo ""
    echo "=== 5. Finalisation ==="

    if [[ "$KEEP_WHITELIST" == "--keep-whitelist" ]]; then
        echo "Vérifiez configs dans ${PZ_SOURCE_DIR}/Server/ (servertest.ini, .lua)"
        echo -n "Appuyez sur ENTRÉE pour démarrer..."
        read -r
    fi

    systemctl --user start "${PZ_SERVICE_NAME}"

    echo ""
    echo "✓ RESET TERMINÉ"
    echo "Backup: $OLD_DIR"
    echo "Status: ./scripts/pz.sh status"
}

show_help() {
    cat <<HELPEOF
Reset complet du serveur Project Zomboid

Usage: $0 [--keep-whitelist]

Options:
  --keep-whitelist    Restaurer whitelist et configs depuis backup

ATTENTION: Supprime toutes les données ! Backup créé dans /home/pzuser/OLD/

Exemples:
  $0                  # Reset complet, serveur vierge
  $0 --keep-whitelist # Reset + restauration whitelist/configs

Restauré avec --keep-whitelist: Whitelist (sauf admin), servertest.ini, .lua
HELPEOF
}

main() {
    if [[ "${KEEP_WHITELIST}" == "--help" ]] || [[ "${KEEP_WHITELIST}" == "-h" ]]; then
        show_help
        exit 0
    fi

    if [[ -n "$KEEP_WHITELIST" ]] && [[ "$KEEP_WHITELIST" != "--keep-whitelist" ]]; then
        echo "Option invalide: $KEEP_WHITELIST"
        echo ""
        show_help
        exit 1
    fi

    confirm_reset
    stop_server
    backup_current
    initial_setup

    if [[ "$KEEP_WHITELIST" == "--keep-whitelist" ]]; then
        restore_whitelist
    fi

    finalize
}

main
