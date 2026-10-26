#!/bin/bash
# ------------------------------------------------------------------------------
# purgeInactivePlayers.sh - Purge AUTOMATIQUE des accès inactifs
# ------------------------------------------------------------------------------
# Seuil strict WHITELIST_PURGE_DAYS : retire les ACCÈS des comptes sélectionnés :
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
# courtier prouve l’identité de notre start-pre et transmet le FD WORLD.
#
# Usage: ./purgeInactivePlayers.sh [--force] [--dry-run] [--days N]
#   --force    Permet seulement l’aperçu --dry-run quand le service est actif
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
readonly ACCOUNT_HELPER="${SCRIPT_DIR}/../lib/account_safety.py"

ORIGINAL_ARGS=("$@")
ADMITTED_WORKER=false
FORCE=false
DRY_RUN=false
DAYS_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --admitted-worker) ADMITTED_WORKER=true ;;
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
python3 "$ACCOUNT_HELPER" validate-db --db "$DB_PATH" --missing-ok || exit 1
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
    if [[ "$DRY_RUN" == true ]]; then
        out="$(python3 "$ACCOUNT_HELPER" read-sql --db "$DB_PATH" --sql "$sql" -- -separator "$sep")" || rc=$?
    else
        out="$(sqlite3 -separator "$sep" "$DB_PATH" "$sql")" || rc=$?
    fi
    if (( rc != 0 )); then
        die "Lecture SQLite impossible (sqlite exit=${rc}) — purge annulée, aucune suppression (fail-closed)."
    fi
    printf -v "$__var" '%s' "$out"
}

# Toute mutation passe par le courtier existant. Un drapeau worker n'est
# jamais une preuve : le worker revérifie lui-même FD, état et journal.
readonly ADMISSION_HELPER="${SCRIPT_DIR}/../internal/writing_start_admission.py"
if [[ "$DRY_RUN" != true && "$ADMITTED_WORKER" != true ]]; then
    _purge_lock="$(python3 "$ADMISSION_HELPER" path)" || exit 1
    exec python3 "$ADMISSION_HELPER" run --lock-path "$_purge_lock" --unit "$PZ_SERVICE_NAME" -- \
        bash "$0" --admitted-worker "${ORIGINAL_ARGS[@]}"
fi
if [[ "$ADMITTED_WORKER" == true ]]; then
    python3 "$ACCOUNT_HELPER" verify-worker || exit 1
elif [[ "$FORCE" != true ]]; then
    require_server_stopped "Aperçu purge (utiliser --force --dry-run si actif)"
fi

# C4 : sorties anticipées (die, liste vide, dry-run) et interruption (INT/TERM) :
# le fichier SQL tmp est retiré ; seul notre FD est fermé à la sortie.
# La transaction SQLite elle-même est atomique : tuée avant COMMIT, la connexion
# meurt sans valider et SQLite annule tout — aucun état partiel n'est un succès.
SQL_TMP=""
purge_cleanup() {
    if [[ -n "${SQL_TMP:-}" ]]; then rm -f -- "$SQL_TMP" 2>/dev/null || true; fi
    # Le FD admis partage l’OFD du courtier : jamais de flock -u.
    # La sortie du processus ferme seulement sa copie du descripteur.
}
trap purge_cleanup EXIT
trap 'purge_cleanup; exit 143' INT TERM

# Mettre le registre des dates de création à jour AVANT de décider quoi que ce
# soit : un compte restauré après un wipe, ou créé depuis le dernier passage du
# timer de minuit, doit y figurer sinon il serait jugé sur une ancienneté qu'on
# ne connaît pas. Non bloquant : sans registre, les comptes jamais connectés sont
# simplement épargnés.
if [[ "$DRY_RUN" != true ]]; then
    "${SCRIPT_DIR}/creationDateInit.sh" || log "AVERTISSEMENT: registre des dates non mis à jour."
fi

# --days l'emporte sur .env : sans ça, le seuil n'est testable qu'en éditant .env.
readonly DAYS="${DAYS_OVERRIDE:-${WHITELIST_PURGE_DAYS:-90}}"

# Comptes inactifs (prédicat partagé avec la purge interactive — cf. common.sh).
WHERE="$(inactive_where_clause "$DAYS")"

log "=== Purge des accès inactifs (seuil : ${DAYS} jours) ==="

# Récupérer les victimes : id|username|steamid
# Séparateur : caractère de contrôle US (0x1f), jamais un | .
# Un joueur s'appelle littéralement « MabEira | Hannibal » (constaté le
# 19/08/2026) : avec -separator '|' ses champs débordaient les uns sur les
# autres, ce qui a produit une ligne de registre corrompue (pseudo tronqué à
# « MabEira », steamid « Hannibal », date = un SteamID). Les gardes ci-dessous
# rejettent les lignes dont le cadrage reste ambigu.
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

# Garde-fou précoce (constat de sécurité, 10/2026) : les id alimentent des
# IN (...) SQL dès le plan (steamid_becomes_orphan) puis la transaction. Le
# garde du plan venait trop tard pour les lignes précédentes, et un saut de
# ligne ou un 0x1f dans un pseudo forgeait des lignes
# (VICTIM_IDS="5,0); DELETE FROM whitelist;--"). Tout identifiant non entier,
# toute ligne mal cadrée ou tout écart de cardinalité annule la purge AVANT
# toute requête (fail-closed).
sql_or_die _pz_expected "SELECT COUNT(*) FROM whitelist WHERE $WHERE"
(( ${#VICTIMS[@]} == _pz_expected )) \
    || die "Registre incohérent (${#VICTIMS[@]} lignes pour ${_pz_expected} victimes) : purge annulée (fail-closed)."
for _pz_row in "${VICTIMS[@]}"; do
    _pz_vid="${_pz_row%%$'\x1f'*}"
    _pz_sep="${_pz_row//[^$'\x1f']/}"
    if [[ ! "$_pz_vid" =~ ^[0-9]+$ || "${#_pz_sep}" -ne 2 ]]; then
        die "Ligne inattendue en base (id='${_pz_vid}') : purge annulée (fail-closed)."
    fi
done
unset _pz_expected _pz_row _pz_vid _pz_sep

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

# SQLite.backup inclut les pages WAL et publie une image privée vérifiée,
# fsync fichier + parent, avant tout DELETE. Aucun skip snapshot n'est accepté.
_PZ_PURGE_FB="$(python3 "$ACCOUNT_HELPER" backup --db "$DB_PATH")" \
    || die "Sauvegarde SQLite impossible — purge annulée avant suppression."
log "Filet local durable : $_PZ_PURGE_FB"

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
        printf "SELECT 'PURGE_STEAMIDS=' || changes();\n"
    else
        printf "SELECT 'PURGE_STEAMIDS=0';\n"
    fi
    printf 'COMMIT;\n'
} > "$SQL_TMP"

# Couture de test C4 : PZ_PURGE_TEST_SLEEP retarde l'écriture (défaut 0,
# production inchangée) pour laisser un test SIGTERM frapper avant tout DELETE.
if [[ "${PZ_PURGE_TEST_SLEEP:-0}" =~ ^[0-9]+$ ]] && (( ${PZ_PURGE_TEST_SLEEP:-0} > 0 )); then
    sleep "$PZ_PURGE_TEST_SLEEP"
fi

python3 "$ACCOUNT_HELPER" verify-worker || exit 1
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

# Le courtier conserve son verrou ; la sortie ferme seulement notre FD hérité.
