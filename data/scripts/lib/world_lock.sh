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
# parent en 0700, avec validation du propriétaire, des ancêtres et des liens.
world_lock_path() {
    local user runtime dir parent owner mode lock_file
    user="$(id -un 2>/dev/null || echo unknown)"
    runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}"
    [[ "$runtime" == /* ]] || return 1
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        # Une valeur XDG_RUNTIME_DIR détournée ne doit pas déplacer le verrou
        # global dans une arborescence appartenant à un autre utilisateur.
        [[ -d "$runtime" && ! -L "$runtime" && -O "$runtime" ]] || return 1
        dir="${runtime}/pzmanager"
    else
        # Repli historique pour les processus sans session systemd utilisateur.
        dir="/tmp/pzmanager-${user}"
    fi

    # Contrôler les ancêtres : même un dossier final en 0700 est remplaçable
    # si son parent appartient à un tiers ou est inscriptible sans sticky root.
    parent="$(dirname -- "$dir")"
    while :; do
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        owner="$(stat -c %u -- "$parent" 2>/dev/null)" || return 1
        mode="$(stat -c %a -- "$parent" 2>/dev/null)" || return 1
        [[ "$owner" == 0 || -O "$parent" ]] || return 1
        if (( (8#$mode & 0022) != 0 )); then
            [[ "$owner" == 0 && -k "$parent" ]] || return 1
        fi
        [[ "$parent" == / ]] && break
        parent="$(dirname -- "$parent")"
    done

    # Vérifier AVANT chmod : chmod suit les symlinks, même si le code rejette
    # ensuite la cible. mkdir sans -p ne crée aucun ancêtre non validé.
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
    else
        # Un autre appel peut gagner la création entre le test et mkdir.
        # Revalider son inode avant chmod, sans créer d'ancêtres.
        if ! (umask 077; mkdir -m 0700 -- "$dir" 2>/dev/null); then
            [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
        fi
    fi
    chmod 0700 -- "$dir" || return 1
    [[ -d "$dir" && ! -L "$dir" && -O "$dir" &&
       "$(stat -c %a -- "$dir" 2>/dev/null)" == 700 ]] || return 1

    lock_file="${dir}/world.lock"
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        [[ -f "$lock_file" && ! -L "$lock_file" && -O "$lock_file" ]] || return 1
        [[ "$(stat -c %h -- "$lock_file" 2>/dev/null)" == 1 ]] || return 1
    fi
    printf '%s\n' "$lock_file"
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

    if ! lock_file="$(world_lock_path)"; then
        [[ "$mode" == "--try" ]] || echo "ERREUR: chemin du verrou monde non sûr ou inaccessible." >&2
        return 1
    fi
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
