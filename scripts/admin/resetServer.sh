#!/bin/bash
# ------------------------------------------------------------------------------
# resetServer.sh - Reset complet du serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./resetServer.sh [OPTIONS]
#
# Options:
#   --keep-whitelist    Restaure whitelist depuis backup
#   --keep-config       Restaure servertest.ini, SandboxVars, spawnpoints,
#                       spawnregions AVANT la génération du monde (les mods
#                       seront téléchargés au premier lancement)
#
# Les deux options sont combinables.
#
# ATTENTION: Supprime toutes les données du serveur actuel !
# Un backup est créé dans $PZ_HOME/OLD/ avant suppression.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

OPT_KEEP_WHITELIST=false
OPT_KEEP_CONFIG=false

# Parsé depuis main() : show_help n'est définie que plus bas dans le fichier.
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --keep-whitelist) OPT_KEEP_WHITELIST=true ;;
            --keep-config)    OPT_KEEP_CONFIG=true ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Option invalide: $arg"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done
}

readonly TIMESTAMP=$(date +"%Y-%m-%d_%Hh%Mm%Ss")
readonly OLD_DIR="${PZ_HOME}/OLD/Zomboid_OLD_${TIMESTAMP}"

# Fichiers de config à restaurer avec --keep-config
readonly CONFIG_FILES=(
    "servertest.ini"
    "servertest_SandboxVars.lua"
    "servertest_spawnpoints.lua"
    "servertest_spawnregions.lua"
)

# Bannière d'annonce. PAS de confirmation interactive : le reset est exécutable
# directement (y compris via le bot Discord, dont le stdin est fermé). La seule
# barrière restante est l'accès à `pzm` / au salon+rôle admin du bot.
announce_reset() {
    echo "⚠️  RESET SERVEUR - SUPPRESSION COMPLÈTE DES DONNÉES ⚠️"
    echo ""
    echo "Actions: Arrêt → Backup → Suppression → Nouveau monde"
    $OPT_KEEP_CONFIG && echo "       → Restauration configs (servertest.ini, SandboxVars, spawns)"
    $OPT_KEEP_WHITELIST && echo "       → Restauration whitelist"
    echo ""
}

stop_server() {
    echo ""
    echo "=== 1. Arrêt du serveur ==="

    if server_is_active; then
        systemctl --user stop "${PZ_SERVICE_NAME}"
        echo "✓ Serveur arrêté"
    else
        echo "✓ Serveur déjà arrêté"
    fi
}

backup_current() {
    echo ""
    echo "=== 2. Backup des données actuelles ==="

    if [[ -d "${PZ_SOURCE_DIR}" ]]; then
        mkdir -p "${PZ_HOME}/OLD"
        mv "${PZ_SOURCE_DIR}" "$OLD_DIR"
        echo "✓ Backup créé: $OLD_DIR"
    else
        echo "  (aucune donnée Zomboid à sauvegarder)"
    fi
}

restore_configs() {
    echo ""
    echo "=== 3. Restauration configs avant génération ==="

    mkdir -p "${PZ_SOURCE_DIR}/Server" "${PZ_SOURCE_DIR}/mods"

    if [[ ! -d "$OLD_DIR/Server" ]]; then
        die "Pas de répertoire Server dans le backup: $OLD_DIR/Server"
    fi

    # Vérifier que les fichiers critiques existent AVANT de copier
    local missing=()
    for f in "${CONFIG_FILES[@]}"; do
        if [[ ! -f "$OLD_DIR/Server/$f" ]]; then
            missing+=("$f")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "⚠ Fichiers manquants dans le backup $OLD_DIR/Server/ :"
        for f in "${missing[@]}"; do
            echo "  ✗ $f"
        done
        echo ""
        echo "Le backup semble provenir d'un reset intermédiaire incomplet."
        echo "Backups disponibles avec configs complètes :"
        for d in "${PZ_HOME}"/OLD/Zomboid_OLD_*/Server; do
            [[ -d "$d" ]] || continue
            local count=0
            for f in "${CONFIG_FILES[@]}"; do
                [[ -f "$d/$f" ]] && (( count++ ))
            done
            if [[ $count -eq ${#CONFIG_FILES[@]} ]]; then
                echo "  $(dirname "$d")"
            fi
        done
        die "Annulé. Restaurez manuellement les fichiers manquants ou utilisez un backup complet."
    fi

    for f in "${CONFIG_FILES[@]}"; do
        cp "$OLD_DIR/Server/$f" "${PZ_SOURCE_DIR}/Server/"
        echo "  ✓ $f"
    done
    echo "✓ ${#CONFIG_FILES[@]} fichier(s) restauré(s)"
}

generate_world() {
    echo ""
    if $OPT_KEEP_CONFIG; then
        echo "=== 4. Génération nouveau monde ==="
    else
        echo "=== 3. Génération nouveau monde ==="
        mkdir -p "${PZ_SOURCE_DIR}/Server" "${PZ_SOURCE_DIR}/mods"
    fi

    local password
    password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    local cachedir="${PZ_SOURCE_DIR}"

    echo "Démarrage du serveur pour génération..."

    "${PZ_INSTALL_DIR}/start-server.sh" \
        -cachedir="${cachedir}" \
        -adminpassword "$password" > /dev/null 2>&1 &

    local max_wait=300
    local waited=0

    # Phase 1: attendre que la DB soit créée
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "${cachedir}/db/servertest.db" ]]; then
            break
        fi
        if (( waited > 30 )) && ! pgrep -f "ProjectZomboid64.*-cachedir=${cachedir}" > /dev/null 2>&1; then
            die "Le serveur s'est arrêté de manière inattendue"
        fi
        sleep 5
        waited=$((waited + 5))
        echo -ne "\r  Attente génération monde... ${waited}s/${max_wait}s"
    done

    if [[ $waited -ge $max_wait ]]; then
        pkill -f "ProjectZomboid64.*-cachedir=${cachedir}" 2>/dev/null || true
        sleep 2
        pkill -9 -f "ProjectZomboid64.*-cachedir=${cachedir}" 2>/dev/null || true
        die "Timeout: monde non généré après ${max_wait}s"
    fi

    # Phase 2: attendre que l'admin soit créé en DB (sinon le serveur demandera le mdp au prochain start)
    local admin_wait=0
    while [[ $admin_wait -lt 60 ]]; do
        local admin_count
        admin_count=$(sqlite3 "${cachedir}/db/servertest.db" "SELECT COUNT(*) FROM whitelist WHERE username = 'admin'" 2>/dev/null || echo "0")
        if [[ "$admin_count" -ge 1 ]]; then
            break
        fi
        sleep 2
        admin_wait=$((admin_wait + 2))
        echo -ne "\r  Attente création admin... ${admin_wait}s/60s"
    done
    echo ""

    pkill -f "ProjectZomboid64.*-cachedir=${cachedir}" 2>/dev/null || true
    sleep 2
    pkill -9 -f "ProjectZomboid64.*-cachedir=${cachedir}" 2>/dev/null || true

    if [[ $admin_wait -ge 60 ]]; then
        echo "⚠ Admin non créé en DB (timeout). Le serveur demandera le mot de passe au démarrage."
    else
        echo "✓ Monde généré"
        echo ""
        printf "  Mot de passe admin: %s\n" "$password"
        echo "  NOTEZ-LE, il ne sera plus affiché !"
        echo ""
    fi
}

restore_whitelist() {
    echo ""
    echo "=== 5. Restauration whitelist ==="

    local old_db="$OLD_DIR/db/servertest.db"
    local new_db="${PZ_SOURCE_DIR}/db/servertest.db"

    [[ -f "$old_db" ]] || { echo "⚠ Pas de base backup, skip whitelist"; return 0; }
    [[ -f "$new_db" ]] || { echo "⚠ Pas de base nouveau serveur, skip whitelist"; return 0; }

    # Restaurer TOUS les utilisateurs y compris admin (pour garder le même mot de passe)
    # On supprime d'abord l'admin généré pour éviter les doublons
    sqlite3 "$new_db" "DELETE FROM whitelist WHERE username = 'admin';"

    # On restaure AUSSI lastConnection : sinon les comptes reviennent "jamais
    # connectés" et la purge d'inactifs (purgeInactivePlayers.sh) les retire dès
    # la maintenance suivante, avant même que les joueurs se reconnectent.
    sqlite3 "$new_db" \
        "ATTACH '$old_db' AS old_db;
         INSERT OR IGNORE INTO main.whitelist (world, username, password, steamid, role, displayName, lastConnection)
         SELECT world, username, password, steamid, role, displayName, lastConnection
         FROM old_db.whitelist;"

    # Autorisations d'accès (allowedsteamid) : EN B42 Open=false, c'est LA barrière
    # d'accès. Sans ça, tous les joueurs sont bloqués malgré les comptes restaurés.
    # On NE restaure PAS bannedid : on préfère retirer via `pzm whitelist remove`.
    if ! sqlite3 "$new_db" \
        "ATTACH '$old_db' AS old_db;
         INSERT OR IGNORE INTO main.allowedsteamid SELECT * FROM old_db.allowedsteamid;
         DETACH old_db;" 2>/dev/null; then
        echo "⚠ Échec restauration allowedsteamid — ré-autorise les SteamID à la main (pzm whitelist add)."
    fi

    local count allowed
    count=$(sqlite3 "$new_db" "SELECT COUNT(*) FROM whitelist")
    allowed=$(sqlite3 "$new_db" "SELECT COUNT(*) FROM allowedsteamid" 2>/dev/null || echo "0")
    echo "✓ $count compte(s) + $allowed SteamID autorisé(s) restauré(s) (admin inclus)"
}

finalize() {
    echo ""
    echo "=== Démarrage du serveur ==="

    systemctl --user start "${PZ_SERVICE_NAME}"

    echo "✓ Serveur démarré"
    echo ""
    echo "Backup: $OLD_DIR"
    echo "Status: pzm server status"
}

show_help() {
    cat <<HELPEOF
Reset complet du serveur Project Zomboid

Usage: $0 [OPTIONS]

Options:
  --keep-whitelist    Restaurer whitelist depuis backup
  --keep-config       Restaurer configs depuis backup AVANT génération monde:
                        - servertest.ini (mods, settings réseau)
                        - servertest_SandboxVars.lua (difficulté, loot, zombies)
                        - servertest_spawnpoints.lua (points d'apparition)
                        - servertest_spawnregions.lua (régions de spawn)
                      Les mods Workshop sont téléchargés au premier lancement.

Les options sont combinables.

ATTENTION: Supprime toutes les données ! Backup créé dans \$PZ_HOME/OLD/

Exemples:
  $0                                    # Reset complet, serveur vierge
  $0 --keep-config                      # Reset monde, garde configs/mods
  $0 --keep-config --keep-whitelist     # Reset monde, garde tout
HELPEOF
}

main() {
    parse_args "$@"
    announce_reset
    stop_server
    backup_current

    if $OPT_KEEP_CONFIG; then
        restore_configs
    fi

    generate_world

    if $OPT_KEEP_WHITELIST; then
        restore_whitelist
    fi

    finalize
}

main "$@"
