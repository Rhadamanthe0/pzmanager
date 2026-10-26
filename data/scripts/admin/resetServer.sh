#!/bin/bash
# ------------------------------------------------------------------------------
# resetServer.sh - Reset complet du serveur Zomboid
# ------------------------------------------------------------------------------
# Usage: ./resetServer.sh [OPTIONS]
#
# Options:
#   --keep-whitelist    Restaure whitelist depuis backup
#   --keep-config       Restaure <monde>.ini, SandboxVars, spawnpoints,
#                       spawnregions AVANT la génération du monde (les mods
#                       seront téléchargés au premier lancement)
#
# Les deux options sont combinables.
#
# ATTENTION: Supprime toutes les données du serveur actuel !
# L'ancien Zomboid est gardé le temps du reset (rollback), puis supprimé une
# fois le nouveau monde en place. Les vrais backups restent dans dataBackups/.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

OPT_KEEP_WHITELIST=false
OPT_KEEP_CONFIG=false

# Une transition systemd ne prouve pas l'absence de JVM, même sans monde live.
require_reset_stopped() {
    python3 - "${SCRIPT_DIR}/../lib" "$PZ_SERVICE_NAME" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from snapshot_consistency import probe, stopped
if not stopped(probe(sys.argv[2])):
    raise SystemExit(1)
PY
}

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

# Copie temporaire du live, réservée à côté du monde avant la transaction
# et supprimée seulement après vérification de la nouvelle image.
PREVIOUS_DIR=""
TRANSACTION_TOKEN=""

# Fichiers de config à restaurer avec --keep-config. PZ les nomme tous d'après
# le nom du monde (PZ_SERVER_NAME).
readonly CONFIG_FILES=(
    "${PZ_SERVER_NAME}.ini"
    "${PZ_SERVER_NAME}_SandboxVars.lua"
    "${PZ_SERVER_NAME}_spawnpoints.lua"
    "${PZ_SERVER_NAME}_spawnregions.lua"
)

# Numérotation des étapes. Elle était écrite en dur dans chaque en-tête, avec un
# if/else dans generate_world pour choisir « 3. » ou « 4. » selon --keep-config —
# et restore_whitelist annonçait « 5. » même quand elle était la 4e (sans
# --keep-config). Un compteur rend le numéro dérivé de l'ordre réel d'exécution.
STEP=0
step() {
    STEP=$(( STEP + 1 ))
    echo ""
    echo "=== ${STEP}. $* ==="
}

# C8 : staging (monde en cours de génération) + générateur suivi par PID exact.
# Globaux car posés par une étape et relus par une autre (génération, swap,
# rollback, nettoyage sur interruption).
STAGING_DIR=""
GENERATOR_PID=""
STAGING_CACHEDIR=""
GENERATOR_METADATA=""

# L'identité du leader stable et l'absence de tout écrivain sont prouvées par
# le helper ; aucune suppression du staging si cette preuve échoue.
kill_generator_exact() {
    [[ -n "${GENERATOR_PID:-}" ]] || return 0
    python3 "${SCRIPT_DIR}/../lib/reset_generator.py" stop \
        --metadata "$GENERATOR_METADATA" -cachedir="$STAGING_CACHEDIR" --pid "$GENERATOR_PID" \
        || return 1
    wait "$GENERATOR_PID" 2>/dev/null || true
    GENERATOR_PID=""
    rm -f -- "$GENERATOR_METADATA"
    GENERATOR_METADATA=""
}

# À la sortie : arrêter le générateur, vérifier le rollback si nécessaire,
# puis nettoyer le staging jetable.
cleanup_reset_staging() {
    if ! kill_generator_exact; then
        echo "Générateur non prouvé arrêté — staging et journal conservés : ${STAGING_DIR}" >&2
        return 0
    fi
    # A prepared intent always survives an unverified rollback. Preserve both
    # images if verification or restoration fails, so start remains blocked.
    if [[ -n "${TRANSACTION_TOKEN:-}" ]]; then
        rollback_live || return 0
    fi
    if [[ -n "${STAGING_DIR:-}" && "${STAGING_DIR}" == "${PZ_HOME}"/Zomboid.new.* && -d "${STAGING_DIR}" ]]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    fi
}

transaction() {
    python3 "${SCRIPT_DIR}/../lib/world_transaction.py" "$@" --world "${PZ_SOURCE_DIR}"
}

# Bannière d'annonce. PAS de confirmation interactive : le reset est exécutable
# directement (y compris via le bot Discord, dont le stdin est fermé). La seule
# barrière restante est l'accès à `pzm` / au salon+rôle admin du bot.
announce_reset() {
    echo "⚠️  RESET SERVEUR - SUPPRESSION COMPLÈTE DES DONNÉES ⚠️"
    echo ""
    echo "Actions: Arrêt → Backup → Suppression → Nouveau monde"
    $OPT_KEEP_CONFIG && echo "       → Restauration configs (${PZ_SERVER_NAME}.ini, SandboxVars, spawns)"
    $OPT_KEEP_WHITELIST && echo "       → Restauration whitelist"
    echo ""
}

stop_server() {
    step "Arrêt du serveur"

    if server_is_active; then
        # Passer par pz.sh et non `systemctl stop` : le stop direct sautait le
        # verrou serverctl, le préavis joueurs, la notification Discord ET
        # surtout wait_for_server_ready. Or un `quit` envoyé pendant que B42
        # charge encore la map plante le boot (NPE IsoMetaGrid.save) en
        # crash-loop — la commande la plus destructive du produit était la seule
        # à ne pas avoir ce garde-fou.
        "${SCRIPT_DIR}/../core/pz.sh" stop --reason "Reset du monde"
        echo "✓ Serveur arrêté"
    else
        echo "✓ Serveur déjà arrêté"
    fi
}

backup_current() {
    step "Backup des données actuelles"
    if [[ -d "${PZ_SOURCE_DIR}" ]]; then
        "${SCRIPT_DIR}/../backup/dataBackup.sh" --snapshot-only --required --consistent \
            || die "Snapshot de sécurité échoué — reset annulé, live intact."
        echo "✓ Sauvegarde durable publiée ; ancien monde conservé pendant la génération"
    else
        echo "  (aucune donnée Zomboid à sauvegarder)"
    fi
}

restore_configs() {
    step "Restauration configs avant génération"

    # Les configs sont copiées dans le staging depuis le live conservé intact.
    mkdir -p "${STAGING_DIR}/Server" "${STAGING_DIR}/mods"

    if [[ ! -d "${PZ_SOURCE_DIR}/Server" ]]; then
        rollback_live || true
        die "Pas de répertoire Server dans l'ancien monde — live restauré, rien n'est réinitialisé."
    fi

    # Vérifier que les fichiers critiques existent AVANT de copier
    local missing=()
    for f in "${CONFIG_FILES[@]}"; do
        if [[ ! -f "${PZ_SOURCE_DIR}/Server/$f" ]]; then
            missing+=("$f")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "⚠ Fichiers manquants dans Server/ :"
        for f in "${missing[@]}"; do
            echo "  ✗ $f"
        done
        echo ""
        echo "Copiez-les depuis un backup (${BACKUP_DIR}/latest/Server/) puis relancez."
        rollback_live || true
        die "Annulé — live restauré, rien n'est réinitialisé."
    fi

    for f in "${CONFIG_FILES[@]}"; do
        cp "${PZ_SOURCE_DIR}/Server/$f" "${STAGING_DIR}/Server/"
        echo "  ✓ $f"
    done
    echo "✓ ${#CONFIG_FILES[@]} fichier(s) restauré(s)"
}

generate_world() {
    step "Génération nouveau monde"
    # C8 : génération en STAGING, jamais dans le live. Sans --keep-config,
    # restore_configs n'a pas tourné : c'est ici que l'arborescence minimale
    # du staging doit être créée.
    $OPT_KEEP_CONFIG || mkdir -p "${STAGING_DIR}/Server" "${STAGING_DIR}/mods"

    local password
    password="$(generate_password)"
    local cachedir="${STAGING_DIR}"
    STAGING_CACHEDIR="${STAGING_DIR}"
    local staging_db="${STAGING_DIR}/db/${PZ_SERVER_NAME}.db"
    # Bornes pilotables pour les tests (défauts = comportement prod).
    local max_wait="${PZ_RESET_MAX_WAIT:-300}"
    local admin_timeout="${PZ_RESET_ADMIN_WAIT:-60}"
    local poll_interval="${PZ_RESET_POLL_INTERVAL:-5}"
    local early_grace="${PZ_RESET_EARLY_GRACE:-30}"

    echo "Démarrage du serveur pour génération..."

    # -servername comme dans zomboid.service : sans lui PZ génèrerait le monde
    # sous son nom par défaut, et les scripts chercheraient PZ_SERVER_NAME.
    # Aucun job-control ici : le PID $! devient lui-même le leader de session,
    # sans fork implicite de setsid(1). Le wrapper fournisseur reste son enfant.
    set +m
    GENERATOR_METADATA="${STAGING_DIR}/.pzm-generator.json"
    python3 "${SCRIPT_DIR}/../lib/reset_generator.py" launch \
        --metadata "$GENERATOR_METADATA" -cachedir="$cachedir" -- \
        "${PZ_INSTALL_DIR}/start-server.sh" \
        -cachedir="${cachedir}" \
        -servername "${PZ_SERVER_NAME}" \
        -adminpassword "$password" <<< "$password" > /dev/null 2>&1 &
    GENERATOR_PID=$!
    local handshake
    for ((handshake=0; handshake<100; handshake++)); do
        if [[ -s "$GENERATOR_METADATA" ]] && python3 "${SCRIPT_DIR}/../lib/reset_generator.py" ready \
            --metadata "$GENERATOR_METADATA" -cachedir="$cachedir" --pid "$GENERATOR_PID"; then
            break
        fi
        kill -0 "$GENERATOR_PID" 2>/dev/null || die "Session du générateur impossible — staging conservé."
        sleep .02
    done
    (( handshake < 100 )) || die "Identité du générateur non établie — staging conservé."

    local waited=0

    # Phase 1: attendre que la DB soit créée (dans le staging)
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "${staging_db}" ]]; then
            break
        fi
        if (( waited > early_grace )) && ! python3 "${SCRIPT_DIR}/../lib/reset_generator.py" running \
            --metadata "$GENERATOR_METADATA" -cachedir="$cachedir" --pid "$GENERATOR_PID"; then
            rollback_live || true
            die "Le serveur s'est arrêté de manière inattendue"
        fi
        sleep "$poll_interval"
        waited=$((waited + poll_interval))
        echo -ne "\r  Attente génération monde... ${waited}s/${max_wait}s"
    done

    if [[ $waited -ge $max_wait ]]; then
        kill_generator_exact
        rollback_live || true
        die "Timeout: monde non généré après ${max_wait}s"
    fi

    # Phase 2: attendre que l'admin soit créé en DB (sinon le serveur demandera le mdp au prochain start)
    local admin_wait=0
    while [[ $admin_wait -lt $admin_timeout ]]; do
        local admin_count
        admin_count=$(sqlite3 "${staging_db}" "SELECT COUNT(*) FROM whitelist WHERE username = 'admin'" 2>/dev/null || echo "0")
        if [[ "$admin_count" -ge 1 ]]; then
            break
        fi
        sleep 2
        admin_wait=$((admin_wait + 2))
        echo -ne "\r  Attente création admin... ${admin_wait}s/${admin_timeout}s"
    done
    echo ""

    kill_generator_exact || die "Arrêt du générateur non prouvé — live intact, staging conservé."

    if [[ $admin_wait -ge $admin_timeout ]]; then
        echo "⚠ Admin non créé en DB (timeout). Le serveur demandera le mot de passe au démarrage."
    else
        echo "✓ Monde généré"
        echo ""
        printf "  Mot de passe admin: %s\n" "$password"
        echo "  NOTEZ-LE, il ne sera plus affiché !"
        echo ""
    fi
}

# C8 : validation du staging AVANT toute bascule : DB présente + admin créé +
# Server/.ini présents. Retourne 1 (sans mourir) pour laisser l'appelant
# déclencher le rollback.
validate_staging_world() {
    local staging="$1"
    local staging_db="${staging}/db/${PZ_SERVER_NAME}.db"
    [[ -f "$staging_db" ]] \
        || { echo "ERREUR: staging sans DB (${staging_db}) — live intact, rien n'est basculé." >&2; return 1; }
    local admin_count
    admin_count=$(sqlite3 "$staging_db" "SELECT COUNT(*) FROM whitelist WHERE username = 'admin'" 2>/dev/null || echo "0")
    [[ "$admin_count" -ge 1 ]] \
        || { echo "ERREUR: staging sans admin en DB — live intact, rien n'est basculé." >&2; return 1; }
    [[ -d "${staging}/Server" ]] \
        || { echo "ERREUR: staging sans répertoire Server — live intact, rien n'est basculé." >&2; return 1; }
    [[ -f "${staging}/Server/${PZ_SERVER_NAME}.ini" ]] \
        || { echo "ERREUR: staging sans ${PZ_SERVER_NAME}.ini — live intact, rien n'est basculé." >&2; return 1; }
}

# Restauration puis vérification des octets par le journal avant de lever
# le refus de démarrage. Un échec conserve le journal et les images restantes.
rollback_live() {
    [[ -n "${TRANSACTION_TOKEN:-}" ]] || return 0
    if [[ -n "${PREVIOUS_DIR:-}" && -d "$PREVIOUS_DIR" ]]; then
        # The reserved empty directory is removed before begin; its existence
        # now proves that live was moved, even if the shell died after mv.
        rm -rf -- "${PZ_SOURCE_DIR}" || return 1
        mv -T -- "$PREVIOUS_DIR" "${PZ_SOURCE_DIR}" || return 1
    elif [[ "$BEFORE_PRESENT" == false ]]; then
        rm -rf -- "${PZ_SOURCE_DIR}" || return 1
    fi
    transaction finish --token "$TRANSACTION_TOKEN" --state reverted || return 1
    TRANSACTION_TOKEN=""
    PREVIOUS_DIR=""
    echo "✓ Rollback vérifié : ancien monde restauré"
}

swap_staging_to_live() {
    validate_staging_world "$STAGING_DIR" || die "Monde invalide — live intact."
    require_reset_stopped || die "Bascule du reset refusée : serveur non prouvé arrêté."
    local parent
    parent="$(dirname -- "${PZ_SOURCE_DIR}")"
    mkdir -p -- "$parent"
    PREVIOUS_DIR="$(mktemp -d "${parent}/.reset-previous-XXXXXX")" \
        || die "Impossible de réserver la copie temporaire — live intact."
    rmdir -- "$PREVIOUS_DIR"
    BEFORE_PRESENT=false
    [[ ! -e "${PZ_SOURCE_DIR}" ]] || BEFORE_PRESENT=true
    TRANSACTION_TOKEN="$(transaction begin --kind reset --recovery "$PREVIOUS_DIR" --after-tree "$STAGING_DIR")" \
        || die "Journal de reset refusé — live intact."
    if [[ "$BEFORE_PRESENT" == true ]]; then
        mv -T -- "${PZ_SOURCE_DIR}" "$PREVIOUS_DIR"
    fi
    # mv may copy across filesystems; the prepared intent guards that window.
    mv -T -- "${STAGING_DIR}" "${PZ_SOURCE_DIR}"
    transaction finish --token "$TRANSACTION_TOKEN" --state complete
    TRANSACTION_TOKEN=""
    STAGING_DIR=""
    STAGING_CACHEDIR=""
}

restore_whitelist() {
    step "Restauration whitelist"

    local old_db="${PZ_SOURCE_DIR}/db/${PZ_SERVER_NAME}.db"
    local new_db="${STAGING_DIR}/db/${PZ_SERVER_NAME}.db"

    [[ -f "$old_db" ]] || die "Base source absente — conservation whitelist impossible, live intact."
    [[ -f "$new_db" ]] || die "Base staging absente — conservation whitelist impossible, live intact."

    # Keep the transfer atomic in staging. Escape the attached filename as an
    # SQL string literal; --bail prevents publishing a partial transfer.
    local quoted_old_db="${old_db//\'/\'\'}"
    sqlite3 -bail "$new_db" \
        "ATTACH '$quoted_old_db' AS old_db;
         BEGIN;
         DELETE FROM main.whitelist;
         INSERT INTO main.whitelist (world, username, password, steamid, role, displayName, lastConnection)
         SELECT world, username, password, steamid, role, displayName, lastConnection FROM old_db.whitelist;
         INSERT OR IGNORE INTO main.allowedsteamid SELECT * FROM old_db.allowedsteamid;
         COMMIT;
         DETACH old_db;"

    local count allowed
    count=$(sqlite3 "$new_db" "SELECT COUNT(*) FROM whitelist")
    allowed=$(sqlite3 "$new_db" "SELECT COUNT(*) FROM allowedsteamid" 2>/dev/null || echo "0")
    echo "✓ $count compte(s) + $allowed SteamID autorisé(s) restauré(s) (admin inclus)"
}

finalize() {
    step "Démarrage du serveur"

    "${SCRIPT_DIR}/../core/pz.sh" start now --reason "Nouveau monde après reset"

    echo "✓ Serveur démarré"
    echo ""
    echo "Status: pzm server status"
}

show_help() {
    cat <<HELPEOF
Reset complet du serveur Project Zomboid

Usage: pzm admin reset [OPTIONS]

Options:
  --keep-whitelist    Restaurer whitelist depuis backup
  --keep-config       Restaurer configs depuis backup AVANT génération monde:
                        - ${PZ_SERVER_NAME}.ini (mods, settings réseau)
                        - ${PZ_SERVER_NAME}_SandboxVars.lua (difficulté, loot, zombies)
                        - ${PZ_SERVER_NAME}_spawnpoints.lua (points d'apparition)
                        - ${PZ_SERVER_NAME}_spawnregions.lua (régions de spawn)
                      Les mods Workshop sont téléchargés au premier lancement.

Les options sont combinables.

ATTENTION: Supprime toutes les données ! Les backups (pzm backup list) restent disponibles.

Exemples:
  pzm admin reset                                 # Reset complet, serveur vierge
  pzm admin reset --keep-config                   # Reset monde, garde configs/mods
  pzm admin reset --keep-config --keep-whitelist  # Reset monde, garde tout
HELPEOF
}

main() {
    parse_args "$@"
    announce_reset
    # C1 : verrou monde autour de TOUT le reset (arrêt -> backup -> suppression
    # -> génération -> redémarrage), sans le relâcher au milieu. Les `pz.sh
    # stop/start` enfants participent (réentrance) au lieu de se bloquer.
    acquire_world_lock --required || exit 1
    stop_server
    # L'arrêt a eu lieu (ou le serveur était déjà arrêté) : l'exiger prouvé
    # avant de déplacer le monde (fail-closed sur erreur systemd).
    require_reset_stopped || die "Reset refusé : serveur non prouvé arrêté."
    backup_current

    # La génération conserve le live. Après préparation du journal, les traps
    # restaurent et vérifient le live ou laissent le démarrage bloqué.
    STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")" \
        || die "Impossible de créer le staging sous ${PZ_HOME}."
    STAGING_CACHEDIR="${STAGING_DIR}"
    trap cleanup_reset_staging EXIT
    trap 'cleanup_reset_staging; exit 143' INT TERM

    if $OPT_KEEP_CONFIG; then
        restore_configs
    fi

    generate_world

    # Les options sont finalisées avant de figer les images du journal.
    # La bascule valide le staging, publie l’intention puis vérifie le live.
    if $OPT_KEEP_WHITELIST; then
        restore_whitelist
    fi
    swap_staging_to_live

    # C8 : staging basculé (mv : le répertoire n'existe plus ; le trap EXIT
    # devient no-op).
    trap - INT TERM EXIT
    cleanup_reset_staging || true

    # Nouveau monde en place (et whitelist reprise) : l'ancien n'a plus d'usage.
    if [[ -n "$PREVIOUS_DIR" ]]; then
        rm -rf -- "$PREVIOUS_DIR" \
            || echo "⚠ Copie temporaire non supprimée : $PREVIOUS_DIR"
        PREVIOUS_DIR=""
    fi

    finalize
    # C1 : fin de section critique.
    release_world_lock
}

main "$@"
