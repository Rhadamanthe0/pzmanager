#!/bin/bash
# ------------------------------------------------------------------------------
# creationDateInit.sh - Tient à jour le registre des dates de création de comptes
# ------------------------------------------------------------------------------
# Écrit un CSV (WHITELIST_LEDGER, par défaut data/whitelistLedger.csv) qui garde
# l'ancienneté de chaque compte whitelist EN DEHORS de la base du monde.
#
# Pourquoi : la base est recréée à chaque wipe, donc toute date stockée dedans
# disparaît. Historiquement ce script remplissait une colonne `created_at` de la
# table whitelist — colonne qu'AUCUN code ne crée et qui n'a donc jamais existé :
# le script sortait sans rien faire à chaque exécution depuis son installation.
# Le CSV vit dans data/, que `pzm admin reset` ne déplace pas : l'ancienneté
# traverse les wipes.
#
# Règles (voulues par l'admin) :
#   - created_at n'est écrit qu'à la PREMIÈRE apparition d'un compte ;
#   - il n'est JAMAIS modifié ensuite ;
#   - aucune ligne n'est jamais supprimée, même après purge : si le joueur
#     revient, il retrouve son ancienneté réelle.
#
# lastConnection n'est PAS dupliqué ici : resetServer.sh le réinjecte déjà dans
# la nouvelle base lors d'un wipe (vérifié le 19/08/2026).
#
# Lecture seule sur la base : peut donc tourner serveur ALLUMÉ (le timer tire à
# minuit, en pleine partie).
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly DB_PATH="${PZ_DB_PATH}"
readonly LEDGER="${WHITELIST_LEDGER}"

main() {
    require_sqlite
    [[ -f "$DB_PATH" ]] || { log "Base de données introuvable: $DB_PATH (registre inchangé)"; exit 0; }

    ensure_directory "$(dirname "$LEDGER")"
    if [[ ! -f "$LEDGER" ]]; then
        printf '# username;steamid;created_at (ne jamais modifier une ligne existante)\n' > "$LEDGER"
        chmod 600 "$LEDGER"
        log "Registre créé: $LEDGER"
    fi

    # Comptes déjà connus (1re colonne), pour n'ajouter que les nouveaux.
    local -A known=()
    local line user
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        user="${line%%;*}"
        known["$user"]=1
    done < "$LEDGER"

    # Lecture seule : sur une base tenue ouverte par le jeu, un SQLITE_BUSY est
    # possible — on abandonne proprement, le prochain passage rattrapera.
    local -a rows=()
# Séparateur : caractère de contrôle US (0x1f), jamais un | .
# Un joueur s'appelle littéralement « MabEira | Hannibal » (constaté le
# 19/08/2026) : avec -separator '|' ses champs débordaient les uns sur les
# autres, ce qui a produit une ligne de registre corrompue (pseudo tronqué à
# « MabEira », steamid « Hannibal », date = un SteamID). Un pseudo ne peut pas
# contenir 0x1f.
    if ! mapfile -t rows < <(sqlite3 -separator $'\x1f' "$DB_PATH" \
        "SELECT username, COALESCE(steamid,''), COALESCE(lastConnection,'') FROM whitelist;" 2>/dev/null); then
        log "Base illisible pour l'instant (verrou ?) — registre inchangé."
        exit 0
    fi

    local added=0 uname sid lastconn created now
    now="$(date '+%F %T')"
    for line in "${rows[@]}"; do
        IFS=$'\x1f' read -r uname sid lastconn <<< "$line"
        [[ -n "$uname" ]] || continue
        [[ -n "${known[$uname]:-}" ]] && continue

        # Un pseudo contenant le séparateur casserait le registre : on le refuse
        # plutôt que d'écrire une ligne qu'on relira de travers.
        if [[ "$uname" == *";"* ]]; then
            log "AVERTISSEMENT: pseudo contenant ';' ignoré au registre: $uname"
            continue
        fi

        # Date de création inconnue : on prend la dernière connexion quand elle
        # existe (le compte existait forcément à ce moment-là), sinon l'instant
        # présent. Les deux sous-estiment l'ancienneté réelle, donc retardent une
        # éventuelle purge — l'erreur va dans le sens sûr.
        created="${lastconn:-$now}"
        printf '%s;%s;%s\n' "$uname" "$sid" "$created" >> "$LEDGER"
        known["$uname"]=1
        added=$(( added + 1 ))
    done

    if (( added > 0 )); then
        log "Registre des dates de création : ${added} compte(s) ajouté(s) (total suivi : $(( ${#known[@]} )))."
    fi
}

main "$@"
