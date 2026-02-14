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
# Un backup est créé dans $PZ_HOME/OLD/ avant suppression.
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

    mkdir -p "${PZ_SOURCE_DIR}"

    # Générer un mot de passe admin aléatoire
    local password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)

    echo "Démarrage du serveur pour génération du monde..."

    # Lancer le serveur directement avec -adminpassword pour éviter le prompt interactif
    "${PZ_INSTALL_DIR}/start-server.sh" \
        -cachedir="${PZ_SOURCE_DIR}" \
        -adminpassword "$password" &
    local server_pid=$!

    # Attendre que le serveur soit prêt (SERVER STARTED dans les logs)
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        # Vérifier que le processus tourne encore
        if ! kill -0 "$server_pid" 2>/dev/null; then
            die "Le serveur s'est arrêté de manière inattendue"
        fi
        # Vérifier si le serveur est prêt
        if [[ -f "${PZ_SOURCE_DIR}/db/servertest.db" ]]; then
            sleep 5  # Laisser le temps au serveur de finir l'init
            break
        fi
        sleep 2
        waited=$((waited + 2))
        echo -ne "\r  Attente génération monde... ${waited}s/${max_wait}s"
    done
    echo ""

    if [[ $waited -ge $max_wait ]]; then
        kill "$server_pid" 2>/dev/null
        die "Timeout: la base de données n'a pas été créée après ${max_wait}s"
    fi

    # Arrêter le serveur proprement
    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
    echo "✓ Monde généré"

    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  Utilisateur admin créé                                ║"
    echo "  ║  Mot de passe: $password  ║"
    echo "  ║  NOTEZ-LE, il ne sera plus affiché !                   ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
}

restore_whitelist() {
    echo ""
    echo "=== 4. Restauration whitelist et configurations ==="

    local old_db="$OLD_DIR/db/servertest.db"
    local new_db="${PZ_SOURCE_DIR}/db/servertest.db"

    [[ -f "$old_db" ]] || die "Base de données backup introuvable: $old_db"
    [[ -f "$new_db" ]] || die "Base de données nouveau serveur introuvable: $new_db"

    # Détecter le schéma de la nouvelle DB
    local new_columns
    new_columns=$(sqlite3 "$new_db" "PRAGMA table_info(whitelist)" 2>/dev/null)
    local has_role=false has_accesslevel=false
    echo "$new_columns" | grep -q '|role|' && has_role=true
    echo "$new_columns" | grep -q '|accesslevel|' && has_accesslevel=true

    echo "Restauration whitelist..."
    if [[ "$has_role" == true ]]; then
        # B42: colonnes world, username, password, steamid, role, displayName
        # role=2 (user), role=7 (admin) — role=1 est "banned" !
        # Restauration depuis une ancienne B42 (même schéma)
        local old_has_role=false
        sqlite3 "$old_db" "PRAGMA table_info(whitelist)" 2>/dev/null | grep -q '|role|' && old_has_role=true

        if [[ "$old_has_role" == true ]]; then
            # B42 → B42: copie directe
            sqlite3 "$new_db" \
                "ATTACH '$old_db' AS old_db;
                 INSERT OR IGNORE INTO main.whitelist (world, username, password, steamid, role, displayName)
                 SELECT world, username, password, steamid, role, displayName
                 FROM old_db.whitelist WHERE username != 'admin';"
        else
            # B41 → B42: mapper accesslevel vers role
            sqlite3 "$new_db" \
                "ATTACH '$old_db' AS old_db;
                 INSERT OR IGNORE INTO main.whitelist (world, username, password, steamid, role, displayName)
                 SELECT 'servertest', username, password, steamid,
                     CASE WHEN accesslevel = 'admin' THEN 7
                          WHEN accesslevel = 'moderator' THEN 6
                          WHEN accesslevel = 'gm' THEN 5
                          WHEN accesslevel = 'observer' THEN 4
                          ELSE 2 END,
                     displayName
                 FROM old_db.whitelist WHERE username != 'admin';"
        fi
    else
        # B41: colonnes username, password, encryptedPwd, pwdEncryptType, steamid, accesslevel, transactionID, displayName
        sqlite3 "$new_db" \
            "ATTACH '$old_db' AS old_db;
             INSERT OR IGNORE INTO main.whitelist (username, password, encryptedPwd, pwdEncryptType, steamid, accesslevel, transactionID, displayName)
             SELECT username, password, encryptedPwd, pwdEncryptType, steamid, accesslevel, transactionID, displayName
             FROM old_db.whitelist WHERE username != 'admin';"
    fi

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
    echo "Status: pzm server status"
}

show_help() {
    cat <<HELPEOF
Reset complet du serveur Project Zomboid

Usage: $0 [--keep-whitelist]

Options:
  --keep-whitelist    Restaurer whitelist et configs depuis backup

ATTENTION: Supprime toutes les données ! Backup créé dans ${PZ_HOME}/OLD/

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
