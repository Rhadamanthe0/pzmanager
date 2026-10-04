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
# Un backup est créé dans $PZ_HOME/OLD/ avant suppression.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

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

# C8 : vrai si /proc/<pid>/cmdline contient le cachedir staging EXACT. Un
# processus homonyme (même nom, autre cachedir) ne correspond jamais : il
# n'est jamais tué.
generator_cmdline_matches() {
    local pid="$1" cachedir="$2" cmdline
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$cachedir" ]] || return 1
    [[ -r "/proc/${pid}/cmdline" ]] || return 1
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ -n "$cmdline" ]] || return 1
    grep -F -q -- "-cachedir=${cachedir}" <<< "$cmdline"
}

# C8 : arrête le générateur par PID exact ($!), puis son groupe. Ne passe
# jamais par un kill large au nom (pattern) : seul le PID dont la cmdline
# porte le cachedir staging exact est signalé.
kill_generator_exact() {
    local pid="${GENERATOR_PID:-}"
    [[ -n "$pid" ]] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        GENERATOR_PID=""
        return 0
    fi
    local cachedir="${STAGING_CACHEDIR:-${STAGING_DIR:-}}"
    if ! generator_cmdline_matches "$pid" "$cachedir"; then
        echo "  (générateur PID ${pid} : cmdline sans cachedir staging exact — aucun kill)" >&2
        GENERATOR_PID=""
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    # Groupe : seulement si le PID est chef de son groupe (évite de signaler
    # le groupe du testeur quand le générateur partage son PGID, sans
    # job-control où le bg n'a pas son propre PGID).
    local pgid=""
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$pgid" == "$pid" ]]; then
        kill -- "-${pid}" 2>/dev/null || true
    fi
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        if [[ "$pgid" == "$pid" ]]; then
            kill -9 -- "-${pid}" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    GENERATOR_PID=""
}

# C8 : sur sortie/interruption, on ne nettoie que le jetable (générateur +
# staging). Le live et OLD ne sont jamais supprimés ici.
cleanup_reset_staging() {
    kill_generator_exact || true
    if [[ -n "${STAGING_DIR:-}" && "${STAGING_DIR}" == "${PZ_HOME}"/Zomboid.new.* && -d "${STAGING_DIR}" ]]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    fi
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
        mkdir -p "${PZ_HOME}/OLD"
        mv "${PZ_SOURCE_DIR}" "$OLD_DIR"
        echo "✓ Backup créé: $OLD_DIR"
    else
        echo "  (aucune donnée Zomboid à sauvegarder)"
    fi
}

restore_configs() {
    step "Restauration configs avant génération"

    # C8 : les configs sont restaurées dans le STAGING, jamais dans le live
    # (le live est déjà déplacé vers OLD, ou absent sur une install neuve).
    mkdir -p "${STAGING_DIR}/Server" "${STAGING_DIR}/mods"

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
        cp "$OLD_DIR/Server/$f" "${STAGING_DIR}/Server/"
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
    # C8 : PID exact ($!) + kill ciblé, jamais de kill large au nom.
    "${PZ_INSTALL_DIR}/start-server.sh" \
        -cachedir="${cachedir}" \
        -servername "${PZ_SERVER_NAME}" \
        -adminpassword "$password" <<< "$password" > /dev/null 2>&1 &
    GENERATOR_PID=$!

    local waited=0

    # Phase 1: attendre que la DB soit créée (dans le staging)
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "${staging_db}" ]]; then
            break
        fi
        if (( waited > early_grace )) && ! kill -0 "$GENERATOR_PID" 2>/dev/null; then
            GENERATOR_PID=""
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

    kill_generator_exact

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

# C8 : rollback — la génération/validation/swap a échoué, on restaure le live
# depuis OLD (OLD est conservé : copie, pas déplacement inverse).
rollback_live() {
    local old_backup="${OLD_DIR}"
    [[ -n "$old_backup" && -d "$old_backup" ]] || return 0
    echo "Échec — rollback depuis $old_backup ..."
    rm -rf -- "${PZ_SOURCE_DIR}" 2>/dev/null || true
    mkdir -p "${PZ_SOURCE_DIR}"
    cp -a "${old_backup}/." "${PZ_SOURCE_DIR}/" \
        || die "Échec du rollback — restaure manuellement : $old_backup → ${PZ_SOURCE_DIR}."
    echo "✓ Rollback terminé: $old_backup → ${PZ_SOURCE_DIR} (OLD conservé)"
}

# C8 : bascule staging → live (le live a été déplacé vers OLD par
# backup_current). Valide d'abord, ne bascule que si valide, sinon rollback.
# OLD est conservé jusqu'à finalize OK (jamais supprimé ici).
swap_staging_to_live() {
    validate_staging_world "$STAGING_DIR" \
        || { rollback_live || true; die "Monde invalide — live restauré depuis $OLD_DIR, OLD conservé."; }
    mkdir -p "$(dirname "${PZ_SOURCE_DIR}")"
    if mv -T "${STAGING_DIR}" "${PZ_SOURCE_DIR}" 2>/dev/null; then
        STAGING_DIR=""
        STAGING_CACHEDIR=""
        return 0
    fi
    # Repli cross-FS : copie puis validation finale.
    mkdir -p "${PZ_SOURCE_DIR}"
    cp -a "${STAGING_DIR}/." "${PZ_SOURCE_DIR}/" \
        || { rollback_live || true; die "Échec de la bascule — live restauré depuis $OLD_DIR, OLD conservé."; }
    validate_staging_world "${PZ_SOURCE_DIR}" \
        || { rollback_live || true; die "Bascule incomplète — live restauré depuis $OLD_DIR, OLD conservé."; }
    rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
    STAGING_DIR=""
    STAGING_CACHEDIR=""
}

restore_whitelist() {
    step "Restauration whitelist"

    local old_db="${OLD_DIR}/db/${PZ_SERVER_NAME}.db"
    local new_db="${PZ_DB_PATH}"

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
    step "Démarrage du serveur"

    "${SCRIPT_DIR}/../core/pz.sh" start now --reason "Nouveau monde après reset"

    echo "✓ Serveur démarré"
    echo ""
    echo "Backup: $OLD_DIR"
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

ATTENTION: Supprime toutes les données ! Backup créé dans \$PZ_HOME/OLD/

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
    require_server_stopped "Reset du monde"
    backup_current

    # C8 : génération en staging sous PZ_HOME (le live reste déplacé vers OLD,
    # conservé jusqu'à finalize OK). Traps : toute interruption tue le
    # générateur (PID exact) et nettoie le staging, jamais le live ni OLD.
    STAGING_DIR="$(mktemp -d "${PZ_HOME}/Zomboid.new.XXXXXX")" \
        || die "Impossible de créer le staging sous ${PZ_HOME}."
    STAGING_CACHEDIR="${STAGING_DIR}"
    trap cleanup_reset_staging EXIT
    trap 'cleanup_reset_staging; exit 143' INT TERM

    if $OPT_KEEP_CONFIG; then
        restore_configs
    fi

    generate_world

    # C8 : validation complète AVANT bascule (DB + admin + .ini/Server), puis
    # swap staging → live. Échec = die + live restauré depuis OLD (rollback
    # auto), staging nettoyé par le trap EXIT.
    swap_staging_to_live

    if $OPT_KEEP_WHITELIST; then
        restore_whitelist
    fi

    # C8 : staging basculé (mv : le répertoire n'existe plus ; le trap EXIT
    # devient no-op). OLD conservé jusqu'ici et au-delà (jamais supprimé).
    trap - INT TERM EXIT
    cleanup_reset_staging || true

    finalize
    # C1 : fin de section critique.
    release_world_lock
}

main "$@"
