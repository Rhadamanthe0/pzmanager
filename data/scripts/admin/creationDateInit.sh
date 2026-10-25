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
    python3 "${SCRIPT_DIR}/../lib/account_safety.py" validate-db --db "$DB_PATH" --missing-ok || exit 1
    [[ -f "$DB_PATH" ]] || { log "Base de données introuvable: $DB_PATH (registre inchangé)"; exit 0; }

    # Capture le statut du lecteur lui-même avant toute création/écriture.
    # Les champs SQLite sont lus typés ; seules des lignes CSV représentables
    # sont émises (LF, CR, NUL et points-virgules sont refusés dans les champs).
    local records now
    now="$(date '+%F %T')"
    if ! records="$(python3 "${SCRIPT_DIR}/../lib/account_safety.py" ledger-rows --db "$DB_PATH" --now "$now")"; then
        log "Base illisible pour l'instant (verrou ?) — registre inchangé."
        exit 1
    fi

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

    local added=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        user="${line%%;*}"
        [[ -n "${known[$user]:-}" ]] && continue
        printf '%s\n' "$line" >> "$LEDGER"
        known["$user"]=1
        added=$(( added + 1 ))
    done <<< "$records"

    if (( added > 0 )); then
        log "Registre des dates de création : ${added} compte(s) ajouté(s) (total suivi : $(( ${#known[@]} )))."
    fi
}

main "$@"
