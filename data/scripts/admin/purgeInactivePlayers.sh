#!/bin/bash
# ------------------------------------------------------------------------------
# purgeInactivePlayers.sh - Purge AUTOMATIQUE des accès inactifs
# ------------------------------------------------------------------------------
# Pour chaque compte inactif depuis >= WHITELIST_PURGE_DAYS jours, retire SES
# ACCÈS au serveur :
#   - l'autorisation SteamID (servertest.db: allowedsteamid) -- seulement si
#     aucun autre compte encore présent ne partage ce SteamID ;
#   - le compte de la liste blanche (servertest.db: whitelist).
#
# Le PERSONNAGE est CONSERVÉ (players.db / networkPlayers n'est PAS touché) :
# si le joueur revient et qu'on ré-autorise son SteamID, il retrouve son perso.
#
# Le compte interne 'admin' est TOUJOURS préservé (sinon perte d'administration).
#
# Écrit directement dans <monde>.db -> DOIT tourner MONDE FERMÉ. Une sauvegarde
# de la base est faite avant toute suppression.
#
# Déclenchée depuis ExecStartPre de zomboid.service, donc juste avant que la JVM
# ne démarre : c'est le seul instant garanti fermé quel que soit le chemin de
# démarrage (boot, pzm server start/restart, socket-activation). Elle n'est plus
# appelée par la maintenance nocturne, qui redémarrait le serveur juste après et
# la rejouait donc pour rien. En ExecStartPre l'unité est "activating" : le
# garde-fou ci-dessous passe de lui-même, sans --force.
#
# Usage: ./purgeInactivePlayers.sh [--force] [--dry-run] [--days N]
#   --force    Ne pas refuser même si le service zomboid est actif
#   --dry-run  Affiche le plan (dont le sort de chaque SteamID) sans rien modifier
#   --days N   Seuil d'inactivité en jours ; prime sur WHITELIST_PURGE_DAYS (.env)
#
# Voir le plan sans rien toucher, serveur allumé :
#   ./purgeInactivePlayers.sh --force --dry-run --days 60
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly DB_PATH="${PZ_DB_PATH}"

FORCE=false
DRY_RUN=false
DAYS_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --days)    DAYS_OVERRIDE="${2:-}"; shift ;;
        --days=*)  DAYS_OVERRIDE="${1#--days=}" ;;
        *) ;;
    esac
    shift
done

if [[ -n "$DAYS_OVERRIDE" ]]; then
    [[ "$DAYS_OVERRIDE" =~ ^[0-9]+$ ]] || die "--days attend un nombre de jours (reçu: '${DAYS_OVERRIDE}')"
fi

require_sqlite
[[ -f "$DB_PATH" ]] || { log "Base introuvable: $DB_PATH (purge ignorée)"; exit 0; }

# C4 (fail-closed) : toute lecture qui décide d'une suppression passe par ici.
# Une erreur SQLite (table absente, base verrouillée, disque...) MEURT au lieu
# de se lire comme « vide » — l'ancien `2>/dev/null || echo 0/1` transformait
# exactement ces erreurs en décision (aucune victime / SteamID orphelin à tort).
# La stderr de sqlite3 n'est jamais masquée (diagnostic visible dans le journal)
# et la mort survient AVANT toute écriture : aucun DELETE n'a encore eu lieu.
# Écrit le résultat (stdout) dans la variable nommée $1 — pas de substitution
# de commande chez l'appelant, donc le die ci-dessous sort du VRAI shell même
# en contexte de condition (où `set -e` est inopérant).
# Usage: sql_or_die VAR [--sep $'\x1f'] "SELECT ..."
sql_or_die() {
    local __var="$1"; shift
    local sep='|' sql out rc
    if [[ "${1:-}" == "--sep" ]]; then sep="${2:-|}"; sql="${3:-}"; else sql="${1:-}"; fi
    [[ -n "${__var:-}" && -n "${sql:-}" ]] || die "sql_or_die : usage interne invalide (erreur de code)"
    out=""; rc=0
    out="$(sqlite3 -separator "$sep" "$DB_PATH" "$sql")" || rc=$?
    if (( rc != 0 )); then
        die "Lecture SQLite impossible (sqlite exit=${rc}) — purge annulée, aucune suppression (fail-closed)."
    fi
    printf -v "$__var" '%s' "$out"
}

# C1 : verrou monde autour de toute la section critique (plan -> snapshot ->
# suppressions), sans le relâcher au milieu. Cas particulier ExecStartPre de
# zomboid.service : le démarreur (`pzm server start`...) tient déjà le verrou
# (processus systemd séparé, pas d'héritage) et l'unité est en « activating » —
# on procède alors SOUS SA COUVERTURE, sans le prendre (sinon la purge ne
# tournerait plus jamais au démarrage). Hors activation, verrou occupé =
# vraie concurrence -> refus.
# C4 : vérifié dans lib/world_lock.sh — son `exec {fd}>…` ne porte aucun
# `2>/dev/null` (seul le `flock -n` sonde est masqué) : la prise du verrou ne
# redirige jamais la stderr de ce shell, aucune sauvegarde de fd n'est requise
# et les erreurs fail-closed ci-dessous restent visibles au journal.
# _PZ_PURGE_HOLDS_LOCK : vrai si CETTE purge détient le verrou monde (snapshot
# --required + release en fin) ; faux sous couverture du démarreur (ExecStartPre
# : le verrou est tenu par un autre processus, --required y est impossible).
_PZ_PURGE_HOLDS_LOCK=false
if acquire_world_lock --try; then
    _PZ_PURGE_HOLDS_LOCK=true
else
    _PZ_PURGE_STATE="unknown"
    # Lib d'état absente = on reste sur « unknown », refusé hors activation.
    if declare -F server_state >/dev/null 2>&1; then
        _PZ_PURGE_STATE="$(server_state)"
    fi
    if [[ "$_PZ_PURGE_STATE" == "activating" || "$_PZ_PURGE_STATE" == "deactivating" ]]; then
        log "Verrou monde tenu par le démarreur (état ${_PZ_PURGE_STATE}) : purge sous sa couverture."
    else
        die "Une opération monde est déjà en cours (état '${_PZ_PURGE_STATE}') : purge annulée."
    fi
    unset _PZ_PURGE_STATE
fi

# C1 (fail-closed) : bus systemd injoignable != serveur arrêté. Sauf --force
# (qui assume l'incertitude explicitement), un état indéterminé refuse la purge.
if [[ "$FORCE" != true ]] && declare -F server_state >/dev/null 2>&1; then
    _PZ_PURGE_STATE="$(server_state)"
    case "$_PZ_PURGE_STATE" in
        inactive|activating|deactivating|failed) ;;
        *) die "État serveur indéterminé ('${_PZ_PURGE_STATE}') : purge refusée sans preuve d'arrêt (fail-closed)." ;;
    esac
    unset _PZ_PURGE_STATE
fi

# Refuser si le serveur tourne (écriture DB live dangereuse), sauf --force.
# (sql_escape et server_is_active viennent de lib/common.sh)
if [[ "$FORCE" != true ]] && server_is_active; then
    die "Le serveur est actif : la purge écrit dans la base du monde et doit se faire serveur arrêté.
Elle tourne d'elle-même au prochain démarrage (ExecStartPre de zomboid.service).
Pour la voir sans rien modifier : $0 --force --dry-run"
fi

# C4 : sorties anticipées (die, liste vide, dry-run) et interruption (INT/TERM) :
# le verrou monde est toujours relâché et le fichier SQL tmp toujours retiré.
# La transaction SQLite elle-même est atomique : tuée avant COMMIT, la connexion
# meurt sans valider et SQLite annule tout — aucun état partiel n'est un succès.
SQL_TMP=""
purge_cleanup() {
    if [[ -n "${SQL_TMP:-}" ]]; then rm -f -- "$SQL_TMP" 2>/dev/null || true; fi
    release_world_lock 2>/dev/null || true
}
trap purge_cleanup EXIT
trap 'purge_cleanup; exit 143' INT TERM

# Mettre le registre des dates de création à jour AVANT de décider quoi que ce
# soit : un compte restauré après un wipe, ou créé depuis le dernier passage du
# timer de minuit, doit y figurer sinon il serait jugé sur une ancienneté qu'on
# ne connaît pas. Non bloquant : sans registre, les comptes jamais connectés sont
# simplement épargnés.
"${SCRIPT_DIR}/creationDateInit.sh" || log "AVERTISSEMENT: registre des dates non mis à jour."

# --days l'emporte sur .env : sans ça, le seuil n'est testable qu'en éditant .env.
readonly DAYS="${DAYS_OVERRIDE:-${WHITELIST_PURGE_DAYS:-90}}"

# Comptes inactifs (prédicat partagé avec la purge interactive — cf. common.sh).
WHERE="$(inactive_where_clause "$DAYS")"

log "=== Purge des accès inactifs (>= ${DAYS} jours) ==="

# Récupérer les victimes : id|username|steamid
# Séparateur : caractère de contrôle US (0x1f), jamais un | .
# Un joueur s'appelle littéralement « MabEira | Hannibal » (constaté le
# 19/08/2026) : avec -separator '|' ses champs débordaient les uns sur les
# autres, ce qui a produit une ligne de registre corrompue (pseudo tronqué à
# « MabEira », steamid « Hannibal », date = un SteamID). Un pseudo ne peut pas
# contenir 0x1f.
# C4 : erreur SELECT -> die (fail-closed), jamais « vide ». Liste complète des
# victimes calculée AVANT toute écriture (aucun DELETE n'a encore eu lieu).
sql_or_die VICTIMS_RAW --sep $'\x1f' \
    "SELECT id, username, COALESCE(steamid,'') FROM whitelist WHERE $WHERE ORDER BY lastConnection"
VICTIMS=()
if [[ -n "$VICTIMS_RAW" ]]; then
    mapfile -t VICTIMS <<< "$VICTIMS_RAW"
fi
unset VICTIMS_RAW

if [[ "${#VICTIMS[@]}" -eq 0 ]]; then
    log "Aucun compte inactif à purger."
    exit 0
fi

# Le SteamID n'est désautorisé que s'il ne reste AUCUN compte gardé qui le
# porte. On l'annonce dès le plan : c'est la question qu'on se pose devant une
# purge (« est-ce que je coupe l'accès du copain qui partage le SteamID ? »), et
# le dry-run doit pouvoir y répondre sans rien supprimer.
# cut sur 0x1f, comme le -separator de la requête ci-dessus. Le `-d'|'` d'origine
# est un reste d'avant le changement de séparateur : sur des lignes sans « | » il
# renvoyait la LIGNE ENTIÈRE, donc un `id NOT IN (...)` invalide -> sqlite en
# erreur -> `|| echo 1` -> aucun SteamID n'était jamais annoncé comme désautorisé
# dans le plan/dry-run (toujours « CONSERVÉ, encore utilisé »).
VICTIM_IDS="$(printf '%s\n' "${VICTIMS[@]}" | cut -d$'\x1f' -f1 | paste -sd,)"

steamid_becomes_orphan() {
    local sid="$1" esc kept
    [[ -n "$sid" ]] || return 1
    esc="$(sql_escape "$sid")"
    # C4 : erreur SELECT -> die (fail-closed), jamais « conservé » par défaut.
    sql_or_die kept \
        "SELECT COUNT(*) FROM whitelist WHERE steamid = '${esc}' AND id NOT IN (${VICTIM_IDS})"
    [[ "$kept" -eq 0 ]]
}

# Plan complet AVANT toute écriture : victimes + SteamID orphelins (+ libellés).
# La suppression réelle, plus bas, rejoue la garde orphelin DANS la transaction
# (NOT EXISTS après les DELETE whitelist) : même si le plan était périmé, un
# SteamID encore partagé survit.
declare -a ORPHAN_SIDS=()
declare -A ORPHAN_SEEN=()
declare -a SUMMARY=()
log "${#VICTIMS[@]} compte(s) inactif(s) détecté(s) :"
for row in "${VICTIMS[@]}"; do
    IFS=$'\x1f' read -r id uname sid <<< "$row"
    # Garde-fou pré-écriture : les id alimentent un IN (...) SQL — tout
    # identifiant non entier annule la purge au lieu d'être interpolé.
    [[ "$id" =~ ^[0-9]+$ ]] || die "Identifiant inattendu en base (id='${id}') : purge annulée (fail-closed)."
    if [[ -z "$sid" ]]; then
        log "  - ${uname} : compte supprimé (aucun steamid)"
        SUMMARY+=("$uname")
    elif steamid_becomes_orphan "$sid"; then
        log "  - ${uname} : compte supprimé + SteamID ${sid} désautorisé (plus aucun compte)"
        if [[ -z "${ORPHAN_SEEN[$sid]:-}" ]]; then ORPHAN_SEEN["$sid"]=1; ORPHAN_SIDS+=("$sid"); fi
        SUMMARY+=("$uname (accès SteamID retiré)")
    else
        log "  - ${uname} : compte supprimé, SteamID ${sid} CONSERVÉ (encore utilisé)"
        SUMMARY+=("$uname (SteamID conservé, partagé)")
    fi
done
log "Les personnages sont conservés dans tous les cas."

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Aucune modification effectuée."
    exit 0
fi

# Filet de sécurité avant suppression : un snapshot NORMAL (backup_<ts>, visible dans
# `pzm backup list` et purgé par le timer horaire) plutôt qu'un fichier .db à part.
# --snapshot-only => pas de save in-game (serveur arrêté / en cours de boot en
# ExecStartPre) ni de prune.
# C4 (fail-closed, C2 --required) : un snapshot impossible ou sauté ANNULE la purge,
# aucune suppression n'a encore eu lieu. Sous couverture du démarreur (ExecStartPre)
# --required est impossible (verrou tenu par un autre processus) : on exige alors
# un snapshot RÉEL — tout échec ou saut (BACKUP_SKIPPED_LOCK) annule la purge,
# SAUF le saut sous unité « activating » (couverture du démarreur, C1×C2×C4) :
# la purge ne modifie que PZ_DB_PATH, donc une copie du fichier vérifiée
# (taille > 0 + integrity_check) suffit comme filet local, et la purge poursuit.
DATABACKUP_BIN="${PZ_DATABACKUP_BIN:-${SCRIPT_DIR}/../backup/dataBackup.sh}"
if [[ "$_PZ_PURGE_HOLDS_LOCK" == true ]]; then
    if ! "$DATABACKUP_BIN" --snapshot-only --required; then
        die "Snapshot de sécurité impossible — purge annulée, aucune suppression (fail-closed)."
    fi
else
    _PZ_PURGE_SNAP_OUT=""; _PZ_PURGE_SNAP_RC=0
    _PZ_PURGE_SNAP_OUT="$("$DATABACKUP_BIN" --snapshot-only 2>&1)" || _PZ_PURGE_SNAP_RC=$?
    if (( _PZ_PURGE_SNAP_RC != 0 )) || grep -q 'BACKUP_SKIPPED_LOCK' <<< "$_PZ_PURGE_SNAP_OUT"; then
        # C1×C2×C4 : sous couverture du démarreur (ExecStartPre, unité en
        # « activating », verrou monde tenu par `pzm server start` dans un
        # processus distinct non hérité), dataBackup --snapshot-only (sans
        # --required, impossible ici) rend BACKUP_SKIPPED_LOCK exit 0. Mourir
        # là-dessus = ne plus jamais démarrer dès qu'il y a des victimes.
        _PZ_PURGE_STATE="unknown"
        if declare -F server_state >/dev/null 2>&1; then
            _PZ_PURGE_STATE="$(server_state)"
        fi
        if (( _PZ_PURGE_SNAP_RC == 0 )) \
            && grep -q 'BACKUP_SKIPPED_LOCK' <<< "$_PZ_PURGE_SNAP_OUT" \
            && [[ "$_PZ_PURGE_STATE" == "activating" ]]; then
            printf '%s\n' "$_PZ_PURGE_SNAP_OUT"
            _PZ_PURGE_TS="$(date +'%Y-%m-%d_%Hh%Mm%Ss')"
            _PZ_PURGE_FB="${DB_PATH}.pre-purge-${_PZ_PURGE_TS}"
            cp -a -- "$DB_PATH" "$_PZ_PURGE_FB" \
                || die "Filet local impossible (cp) — purge annulée, aucune suppression (fail-closed)."
            [[ -s "$_PZ_PURGE_FB" ]] \
                || { rm -f -- "$_PZ_PURGE_FB" 2>/dev/null || true; die "Filet local vide — purge annulée, aucune suppression (fail-closed)."; }
            _PZ_PURGE_FB_RC=0; _PZ_PURGE_FB_CHECK=""
            _PZ_PURGE_FB_CHECK="$(sqlite3 "$_PZ_PURGE_FB" 'PRAGMA integrity_check;')" || _PZ_PURGE_FB_RC=$?
            if (( _PZ_PURGE_FB_RC != 0 )); then
                rm -f -- "$_PZ_PURGE_FB" 2>/dev/null || true
                die "Filet local illisible (sqlite exit=${_PZ_PURGE_FB_RC}) — purge annulée, aucune suppression (fail-closed)."
            fi
            if [[ "$_PZ_PURGE_FB_CHECK" != "ok" ]]; then
                rm -f -- "$_PZ_PURGE_FB" 2>/dev/null || true
                die "Filet local corrompu (integrity_check='${_PZ_PURGE_FB_CHECK}') — purge annulée, aucune suppression (fail-closed)."
            fi
            log "Snapshot dataBackup sauté (verrou du démarreur, unité activating) : filet local ${_PZ_PURGE_FB} (integrity_check=ok) — la purge poursuit."
            # _PZ_PURGE_FB est CONSERVÉ (pas unset) : log + rotation après COMMIT réussi.
            unset _PZ_PURGE_TS _PZ_PURGE_FB_RC _PZ_PURGE_FB_CHECK
        else
            printf '%s\n' "$_PZ_PURGE_SNAP_OUT"
            die "Snapshot de sécurité impossible ou sauté — purge annulée, aucune suppression (fail-closed)."
        fi
        unset _PZ_PURGE_STATE
    fi
    printf '%s\n' "$_PZ_PURGE_SNAP_OUT"
    unset _PZ_PURGE_SNAP_OUT _PZ_PURGE_SNAP_RC
fi

# C4 : UNE SEULE transaction SQLite par base (une seule ici : PZ_DB_PATH, donc
# prévalidation totale par construction — le plan ci-dessus est déjà complet) :
# BEGIN IMMEDIATE prend le verrou d'écriture d'emblée (base tenue par un autre
# écrivain -> échec immédiat, rien n'est modifié) ; -bail stoppe au premier
# échec sans COMMIT (annulation intégrale, aucun partiel) ; COMMIT validé ou
# rien. Le SteamID n'est désautorisé que s'il ne reste AUCUN compte (NOT EXISTS
# évalué APRÈS les DELETE whitelist, dans la même transaction) : un SteamID
# partagé avec un compte conservé survit quoi qu'ait dit le plan.
SQL_TMP="$(mktemp "${TMPDIR:-/tmp}/pz-purge-XXXXXX.sql")" || die "Impossible de créer le fichier SQL temporaire."
{
    printf 'BEGIN IMMEDIATE;\n'
    printf 'DELETE FROM whitelist WHERE id IN (%s);\n' "$VICTIM_IDS"
    printf "SELECT 'PURGE_ACCOUNTS=' || changes();\n"
    if (( ${#ORPHAN_SIDS[@]} > 0 )); then
        _pz_orphan_list=""
        for _pz_sid in "${ORPHAN_SIDS[@]}"; do
            _pz_esc="$(sql_escape "$_pz_sid")"
            if [[ -n "$_pz_orphan_list" ]]; then _pz_orphan_list+=","; fi
            _pz_orphan_list+="'${_pz_esc}'"
        done
        printf 'DELETE FROM allowedsteamid WHERE steamid IN (%s) AND NOT EXISTS (SELECT 1 FROM whitelist w WHERE w.steamid = allowedsteamid.steamid);\n' "$_pz_orphan_list"
        unset _pz_orphan_list _pz_sid _pz_esc
    fi
    printf "SELECT 'PURGE_STEAMIDS=' || changes();\n"
    printf 'COMMIT;\n'
} > "$SQL_TMP"

# Couture de test C4 : PZ_PURGE_TEST_SLEEP retarde l'écriture (défaut 0,
# production inchangée) pour laisser un test SIGTERM frapper avant tout DELETE.
if [[ "${PZ_PURGE_TEST_SLEEP:-0}" =~ ^[0-9]+$ ]] && (( ${PZ_PURGE_TEST_SLEEP:-0} > 0 )); then
    sleep "$PZ_PURGE_TEST_SLEEP"
fi

_TX_OUT=""; _TX_RC=0
_TX_OUT="$(sqlite3 -bail "$DB_PATH" < "$SQL_TMP")" || _TX_RC=$?
if (( _TX_RC != 0 )); then
    die "Écriture SQLite impossible (sqlite exit=${_TX_RC}) — purge annulée : transaction annulée (ROLLBACK), aucune suppression partielle (fail-closed)."
fi
removed_accounts="$(grep '^PURGE_ACCOUNTS=' <<< "$_TX_OUT" || true)"; removed_accounts="${removed_accounts#*=}"
removed_steamids="$(grep '^PURGE_STEAMIDS=' <<< "$_TX_OUT" || true)"; removed_steamids="${removed_steamids#*=}"
if [[ ! "$removed_accounts" =~ ^[0-9]+$ || ! "$removed_steamids" =~ ^[0-9]+$ ]]; then
    die "Sortie de transaction inattendue — purge interrompue par prudence (fail-closed)."
fi
unset _TX_OUT _TX_RC

log "Purge terminée : ${removed_accounts} compte(s) retiré(s), ${removed_steamids} SteamID désautorisé(s). Personnages conservés."

# Filet pre-purge conservé (jamais supprimé ici) + rotation : ne tourne
# qu'après un COMMIT réussi — en cas d'échec on meurt ci-dessus et le dernier
# filet reste intact. Garde les 3 plus récents (`${DB_PATH}.pre-purge-*`, triés
# par nom = ordre chronologique du suffixe %Y-%m-%d_%Hh%Mm%Ss), supprime les
# anciens. Le filet venant d'être créé est le plus récent : jamais effacé.
if [[ -n "${_PZ_PURGE_FB:-}" && -f "${_PZ_PURGE_FB}" ]]; then
    log "filet conservé: ${_PZ_PURGE_FB}"
    _purge_keep=3
    _purge_all=( "${DB_PATH}".pre-purge-* )
    if (( ${#_purge_all[@]} > _purge_keep )); then
        for _purge_old in "${_purge_all[@]:0:${#_purge_all[@]}-_purge_keep}"; do
            [[ "$_purge_old" == "$_PZ_PURGE_FB" ]] || rm -f -- "$_purge_old" 2>/dev/null || true
        done
    fi
    unset _purge_keep _purge_all _purge_old
fi
unset _PZ_PURGE_FB

# PAS de notification Discord (décision admin, 19/08/2026).
# sendDiscord.sh poste sur le canal PUBLIC des annonces joueurs : la purge y
# affichait la liste NOMINATIVE des comptes retirés, ce qui n'a aucun intérêt
# pour les joueurs et expose inutilement des pseudos. Le détail reste dans le
# journal de l'unité (journalctl --user -u zomboid.service), qui est de toute
# façon le seul endroit consulté pour ce genre d'opération.
if [[ "$removed_accounts" -gt 0 ]]; then
    for local_label in "${SUMMARY[@]}"; do
        log "  • ${local_label}"
    done
fi

# C1 : fin de section critique (no-op si on procédait sous couverture du démarreur).
release_world_lock
