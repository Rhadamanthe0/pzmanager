#!/usr/bin/env bash
# world_lock.sh - Verrou global unique pzmanager (C1).
#
# PROTOCOLE UNIQUE pour toutes les opérations qui touchent au monde :
#   start / stop / restart (core/pz.sh), backup (backup/dataBackup.sh),
#   restore (backup/restoreZomboidData.sh), wipe (admin/wipeMapTile.sh),
#   purge (admin/purgeInactivePlayers.sh), reset (admin/resetServer.sh),
#   maintenance (admin/performFullMaintenance.sh).
#
# Pourquoi un verrou de plus (alors que MAINTENANCE/SERVERCTL existent) :
#   - les verrous historiques vivent sous /tmp/pzmanager-*-$(id -un).lock.
#     L'unité zomboid.service tourne avec PrivateTmp=true : son /tmp est
#     PRIVÉ (namespace monté par systemd). Un ExecStartPre (purge) et un
#     appel `pzm ...` (shell user) ne voient donc PAS le même /tmp :
#     un verrou sous /tmp ne peut pas exclure un démarrage systemd d'un
#     wipe manuel. Le verrou monde vit sous ${XDG_RUNTIME_DIR}/pzmanager/
#     (/run/user/<uid>, partagé par tout le user manager, insensible à
#     PrivateTmp), avec repli /tmp/pzmanager-<user>/ uniquement si le
#     runtime est absent (cron sans pam_systemd...).
#   - MAINTENANCE et SERVERCTL sont CONSERVÉS (compat) : pour les opérations
#     destructrices, le verrou monde les ENGLOBE (il se prend AVANT eux).
#     Ordre d'acquisition global, partout : WORLD -> SERVERCTL -> verrou
#     spécifique (maintenance/backup). Jamais l'inverse (pas de deadlock ABBA).
#
# Sémantique flock (rappel, cf. common.sh) : prise atomique non bloquante,
# libération par le NOYAU à la mort du process (kill -9 inclus) -> pas de
# verrou fantôme, pas de nettoyage au mtime.
#
# Réentrance parent/enfant (anti-deadlock) : le fd est HÉRITÉ par les
# sous-scripts (fork+exec, vérifié : pas de CLOEXEC sur les fd `exec {v}>`),
# et PZ_WORLD_LOCK_DEPTH (exporté) compte les acquisitions imbriquées.
# Un enfant qui appelle acquire_world_lock alors que son parent tient déjà
# le verrou ne retente PAS flock (ce serait un refus illégitime, voire un
# deadlock en mode bloquant) : il incrémente le compteur et participe à la
# section critique. Seul le retour à 0 libère réellement (flock -u + close).
#
# API :
#   world_lock_path                  -> imprime le chemin du verrou (crée le
#                                       dossier en 0700). Une seule ligne stdout.
#   acquire_world_lock [--try|--required] (défaut: --required)
#                                    0 = détenu (ou participation), 1 = occupé
#                                    (message sur stderr sauf --try).
#   release_world_lock               décrémente ; no-op si rien à libérer.
#   with_world_lock [--try|--required] CMD...  -> acquire, CMD, release ;
#                                    retourne le code de CMD (ou 1 si occupé).
# Ces fonctions ne font jamais `exit` (codes retour uniquement) : sous
# `set -e`, un appel nu qui échoue fait sortir le script (fail-closed) ;
# en `if ! acquire...` l'appelant gère (skip gracieux exit 0...).
[[ -n "${PZ_WORLD_LOCK_LOADED:-}" ]] && return 0
PZ_WORLD_LOCK_LOADED=1

: "${PZ_WORLD_LOCK_DEPTH:=0}"
: "${PZ_WORLD_LOCK_FD:=}"
export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD

# Imprime le chemin du verrou monde (stdout, une ligne). Crée le dossier
# parent en 0700 (best-effort sur FS sans modes, ex. NTFS).
world_lock_path() {
    local user runtime dir
    user="$(id -un 2>/dev/null || echo unknown)"
    runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}"
    if [[ -n "$runtime" && -d "$runtime" ]] && mkdir -p "${runtime}/pzmanager" 2>/dev/null; then
        chmod 0700 "${runtime}/pzmanager" 2>/dev/null || true
        printf '%s\n' "${runtime}/pzmanager/world.lock"
        return 0
    fi
    # Repli : pas de runtime (service sans session user...). /tmp partagé ici
    # (hors PrivateTmp des unités) : mieux que rien, documenté comme dégradé.
    dir="/tmp/pzmanager-${user}"
    mkdir -p "$dir" 2>/dev/null || true
    chmod 0700 "$dir" 2>/dev/null || true
    printf '%s\n' "${dir}/world.lock"
    return 0
}

# Usage: acquire_world_lock [--try|--required]
acquire_world_lock() {
    local mode="--required" lock_file fd
    if [[ "${1:-}" == "--try" || "${1:-}" == "--required" ]]; then mode="$1"; shift; fi

    # Participation (même arbre, verrou déjà détenu, fd hérité encore ouvert).
    if [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] && [[ -n "${PZ_WORLD_LOCK_FD:-}" ]] \
        && { : >&"${PZ_WORLD_LOCK_FD}" 2>/dev/null; }; then
        PZ_WORLD_LOCK_DEPTH=$(( PZ_WORLD_LOCK_DEPTH + 1 ))
        export PZ_WORLD_LOCK_DEPTH
        return 0
    fi

    lock_file="$(world_lock_path)"
    if ! exec {fd}>"$lock_file"; then
        [[ "$mode" == "--try" ]] || echo "ERREUR: impossible d'ouvrir le verrou monde (${lock_file})" >&2
        return 1
    fi
    if flock -n "$fd" 2>/dev/null; then
        PZ_WORLD_LOCK_FD="$fd"
        PZ_WORLD_LOCK_DEPTH=1
        export PZ_WORLD_LOCK_FD PZ_WORLD_LOCK_DEPTH
        return 0
    fi
    exec {fd}>&- || true
    [[ "$mode" == "--try" ]] || echo "ERREUR: une opération monde est déjà en cours (verrou ${lock_file}). Attends qu'elle se termine." >&2
    return 1
}

# No-op si le verrou n'est pas détenu par cet arbre.
release_world_lock() {
    if [[ "${PZ_WORLD_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]]; then
        PZ_WORLD_LOCK_DEPTH=$(( PZ_WORLD_LOCK_DEPTH - 1 ))
        if (( PZ_WORLD_LOCK_DEPTH <= 0 )); then
            PZ_WORLD_LOCK_DEPTH=0
            if [[ -n "${PZ_WORLD_LOCK_FD:-}" ]]; then
                flock -u "${PZ_WORLD_LOCK_FD}" 2>/dev/null || true
                exec {PZ_WORLD_LOCK_FD}>&- || true
                PZ_WORLD_LOCK_FD=""
            fi
        fi
        export PZ_WORLD_LOCK_DEPTH PZ_WORLD_LOCK_FD
    fi
    return 0
}

# Usage: with_world_lock [--try|--required] CMD [ARGS...]
with_world_lock() {
    local mode="--required" rc=0
    if [[ "${1:-}" == "--try" || "${1:-}" == "--required" ]]; then mode="$1"; shift; fi
    if [[ $# -lt 1 ]]; then
        echo "ERREUR: with_world_lock [--try|--required] COMMANDE [ARGS...]" >&2
        return 2
    fi
    acquire_world_lock "$mode" || return 1
    "$@" || rc=$?
    release_world_lock
    return "$rc"
}
