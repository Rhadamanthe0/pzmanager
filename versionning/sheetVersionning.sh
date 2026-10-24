#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# sheetVersionning.sh - Gère les onglets de version du Google Sheet "Versionning des mods"
# ------------------------------------------------------------------------------
# Crée un nouvel onglet V{N} (cloné du dernier) et masque les anciens, via l'API
# Google Sheets, authentifié par le COMPTE DE SERVICE dont la clé JSON est stockée
# en base64 dans le .env de la racine (GOOGLE_SERVICE_ACCOUNT_JSON_B64) — plus
# aucun fichier de clé permanent sur le disque. 100% bash : openssl (JWT RS256) +
# curl + jq. Aucune dépendance pip.
#
# Usage:
#   ./sheetVersionning.sh list            # liste les onglets V* (visibles/masqués)
#   ./sheetVersionning.sh new [N]         # crée V{N} (N = max+1 si omis), masque les autres
#   ./sheetVersionning.sh hide-old        # masque tous les V* sauf le plus récent
#   ./sheetVersionning.sh show <tab> [range]        # affiche des cellules
#   ./sheetVersionning.sh setcell <tab> <cell> <txt> # écrit une cellule
#   ./sheetVersionning.sh load <tab> <fichier.tsv>   # peuple l'onglet depuis un TSV
#
# `new` ne fait que CLONER l'onglet précédent : sans un `load` derrière, le
# nouvel onglet reste figé sur l'ancien contenu.
# ------------------------------------------------------------------------------
set -euo pipefail

# --- Config -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="https://www.googleapis.com/auth/spreadsheets"
VPAT='^V[0-9]+$'   # ce qui compte comme onglet de version (V1, V2, …)

die() { echo "Erreur: $*" >&2; exit 1; }
for c in openssl curl jq base64; do command -v "$c" &>/dev/null || die "$c non installé."; done

# Config et secret viennent du .env de la racine (versionning/ est à la racine de
# pzmanager/, donc ../.env). Ce script est versionné : ni l'ID du classeur ni la
# clé ne doivent vivre dans son code.
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] || die "Fichier .env introuvable: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

SPREADSHEET_ID="${SHEET_VERSIONNING_ID:-}"
[[ -n "$SPREADSHEET_ID" ]] || die "SHEET_VERSIONNING_ID non renseigné dans $ENV_FILE."
[[ -n "${GOOGLE_SERVICE_ACCOUNT_JSON_B64:-}" ]] \
    || die "GOOGLE_SERVICE_ACCOUNT_JSON_B64 non renseigné dans $ENV_FILE."

# Allouer dans le parent avant TOKEN=$(...) : ses traps doivent connaître
# tous les secrets, même si la signature échoue dans la substitution.
umask 077
SECRET_DIR=""
cleanup_secrets() {
    [[ -z "$SECRET_DIR" ]] || rm -rf -- "$SECRET_DIR"
}
trap cleanup_secrets EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SECRET_DIR="$(mktemp -d)" || die "Répertoire temporaire privé indisponible."
KEY_FILE="${SECRET_DIR}/account.json"
KEY_PEM="${SECRET_DIR}/private.pem"
printf '%s' "$GOOGLE_SERVICE_ACCOUNT_JSON_B64" | base64 -d > "$KEY_FILE" \
    || die "GOOGLE_SERVICE_ACCOUNT_JSON_B64 n'est pas du base64 valide."
jq -e '.client_email and .private_key' "$KEY_FILE" >/dev/null 2>&1 \
    || die "La clé décodée n'est pas un JSON de compte de service valide."
jq -r '.private_key' "$KEY_FILE" > "$KEY_PEM" \
    || die "Préparation de la clé de signature impossible."

# --- Auth : compte de service -> access token (JWT RS256) --------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

get_access_token() {
    local email now exp header claim signing_input sig jwt resp tok
    email="$(jq -r '.client_email' "$KEY_FILE")"
    now="$(date +%s)"; exp="$((now + 3600))"
    header='{"alg":"RS256","typ":"JWT"}'
    claim="$(jq -nc --arg iss "$email" --arg scope "$SCOPE" --argjson iat "$now" --argjson exp "$exp" \
        '{iss:$iss,scope:$scope,aud:"https://oauth2.googleapis.com/token",iat:$iat,exp:$exp}')"
    signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$claim" | b64url)"
    sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY_PEM" -binary | b64url)" \
        || return $?
    jwt="${signing_input}.${sig}"

    resp="$(api_request '(.access_token | text) and .token_type == "Bearer" and (.expires_in | type == "number" and . > 0)' \
        -X POST https://oauth2.googleapis.com/token \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "assertion=${jwt}")" || die "Échec auth Google."
    tok="$(printf '%s' "$resp" | jq -r '.access_token')"
    printf '%s' "$tok"
}

# --- Helpers API ------------------------------------------------------------
# Chaque frontière exige HTTP réussi et un unique objet JSON conforme. Ne pas
# imprimer les corps d'erreur : l'authentification peut y exposer des secrets.
check_err() {  # $1 = réponse, $2 = contrat jq interne (défaut : objet sans erreur)
    local schema="${2:-true}"
    jq -se --arg id "$SPREADSHEET_ID" '
        def text: type == "string" and length > 0;
        def count: type == "number" and . >= 0 and floor == .;
        length == 1 and (.[0] | type == "object" and (has("error") | not) and ('"$schema"'))
    ' <<< "$1" >/dev/null 2>&1 || die "Réponse Google vide, en erreur ou non conforme."
}
api_request() {  # $1 = contrat jq, suite = arguments curl
    local schema="$1" response
    shift
    response="$(curl --fail --silent --show-error "$@")" \
        || die "Requête Google refusée (HTTP ou transport)."
    check_err "$response" "$schema"
    printf '%s' "$response"
}
api_get() {  # $1 = querystring (ex: ?fields=...)
    api_request '(.sheets | type == "array") and all(.sheets[]; .properties | (.sheetId | count) and (.title | text) and (.index | count) and ((has("hidden") | not) or (.hidden | type == "boolean")))' \
        -H "Authorization: Bearer ${TOKEN}" \
        "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}${1:-}"
}
api_batch() {  # $1 = JSON {requests:[...]}
    local count
    count="$(jq '.requests | length' <<< "$1")"
    printf '%s' "$1" | api_request '.spreadsheetId == $id and (.replies | type == "array" and length == '"$count"')' \
        -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}:batchUpdate" \
        --data-binary @-
}

# Lecture de valeurs : une plage vide valide omet le champ values.
api_values_get() {
    api_request '(.range | text) and ((has("values") | not) or (.values | type == "array" and all(.[]; type == "array")))' \
        -H "Authorization: Bearer ${TOKEN}" \
        "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/$(jq -rn --arg v "$1" '$v|@uri')"
}
# Écriture d'une valeur brute : $1 = range A1 (une cellule), $2 = texte
api_values_put() {
    api_request '.spreadsheetId == $id and (.updatedRange | text) and (.updatedCells | count)' \
        -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        "https://sheets.googleapis.com/v4/spreadsheets/${SPREADSHEET_ID}/values/$(jq -rn --arg v "$1" '$v|@uri')?valueInputOption=RAW" \
        -d "$(jq -nc --arg v "$2" '{values:[[$v]]}')"
}
# Effacement et remplacement atomiques : aucune fenêtre avec l'onglet vide.
# Seules les valeurs sont touchées, sur A1:Z200 borné à la grille puis la matrice entière ; les
# formats et les cellules hors de cette union sont conservés.
api_values_matrix() {
    local body="$2" tab="${1%%!*}" meta sheet batch
    meta="$(fetch_sheets)" || return 1
    sheet="$(jq -ec --arg tab "$tab" '
        def dimension: type == "number" and . > 0 and floor == .;
        [.sheets[].properties | select(.title == $tab)]
        | if length == 1 then .[0] else error("Onglet absent ou ambigu") end
        | if (.gridProperties.rowCount | dimension) and
             (.gridProperties.columnCount | dimension) then .
          else error("Dimensions de grille invalides") end
    ' <<< "$meta")" || die "Onglet absent, ambigu ou dimensions invalides : chargement refusé."
    batch="$(jq -c --argjson sheet "$sheet" '
        {requests:[
            {updateCells:{range:{sheetId:$sheet.sheetId,startRowIndex:0,
                endRowIndex:([200,$sheet.gridProperties.rowCount] | min),startColumnIndex:0,
                endColumnIndex:([26,$sheet.gridProperties.columnCount] | min)},rows:[],fields:"userEnteredValue"}},
            {updateCells:{start:{sheetId:$sheet.sheetId,rowIndex:0,columnIndex:0},
                rows:(.values | map({values:map({userEnteredValue:{stringValue:.}})})),
                fields:"userEnteredValue"}}
        ]}
    ' <<< "$body")" || return 1
    api_batch "$batch"
}

# Métadonnées des onglets : sheetId, title, index, hidden
fetch_sheets() {
    api_get "?fields=sheets(properties(sheetId,title,index,hidden,gridProperties(rowCount,columnCount)))"
}

# Properties de l'onglet de version le plus récent (ou "null"). $1 = métadonnées.
latest_version() {
    jq -c --arg pat "$VPAT" \
        '[.sheets[].properties | select(.title|test($pat))] | sort_by(.title|ltrimstr("V")|tonumber) | last' \
        <<<"$1"
}

# --- Commandes --------------------------------------------------------------
cmd_list() {
    fetch_sheets | jq -r --arg pat "$VPAT" '
        .sheets[].properties
        | select(.title | test($pat))
        | "\(.title)\t\(if .hidden then "masqué" else "VISIBLE" end)"' \
        | sort -V
}

cmd_new() {
    local meta latest max src_id n new_title create_req hide_reqs
    meta="$(fetch_sheets)"

    # Une seule passe : la version la plus récente donne à la fois max et la source à cloner
    latest="$(latest_version "$meta")"
    if [[ "$latest" == "null" ]]; then
        max=0; src_id=""
    else
        max="$(jq -r '.title|ltrimstr("V")' <<<"$latest")"
        src_id="$(jq -r '.sheetId' <<<"$latest")"
    fi

    n="${1:-$((max + 1))}"; n="${n#V}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "Numéro de version invalide: $n"
    new_title="V${n}"
    jq -e --arg t "$new_title" 'any(.sheets[].properties.title; . == $t)' <<<"$meta" >/dev/null \
        && die "L'onglet ${new_title} existe déjà."

    # Requête de création : clone de la version la plus récente, sinon onglet vierge
    if [[ -n "$src_id" ]]; then
        create_req="$(jq -nc --argjson sid "$src_id" --arg name "$new_title" \
            '{duplicateSheet:{sourceSheetId:$sid,insertSheetIndex:0,newSheetName:$name}}')"
        echo "→ Clone de l'onglet le plus récent vers ${new_title}"
    else
        create_req="$(jq -nc --arg name "$new_title" \
            '{addSheet:{properties:{title:$name,index:0}}}')"
        echo "→ Création d'un onglet vierge ${new_title}"
    fi

    # Masque toutes les versions existantes (le nouvel onglet reste visible). Tout
    # en UN seul batchUpdate : on connaît déjà leurs sheetId via $meta -> pas de
    # second aller-retour réseau.
    hide_reqs="$(jq -c --arg pat "$VPAT" '
        [ .sheets[].properties | select(.title|test($pat))
          | {updateSheetProperties:{properties:{sheetId:.sheetId, hidden:true}, fields:"hidden"}} ]' <<<"$meta")"

    check_err "$(api_batch "$(jq -nc --argjson c "$create_req" --argjson h "$hide_reqs" \
        '{requests:([$c] + $h)}')")"
    echo "✓ ${new_title} créé, placé en tête, anciennes versions masquées."
    cmd_list
}

cmd_hide_old() {  # $1 (optionnel) = titre à garder visible ; défaut = plus récent
    local meta keep batch
    meta="$(fetch_sheets)"
    keep="${1:-$(latest_version "$meta" | jq -r '.title // empty')}"
    [[ -n "$keep" ]] || { echo "Aucun onglet de version trouvé."; return; }

    batch="$(jq -c --arg pat "$VPAT" --arg keep "$keep" '
        {requests:[ .sheets[].properties | select(.title|test($pat))
          | {updateSheetProperties:{properties:{sheetId:.sheetId, hidden:(.title != $keep)}, fields:"hidden"}} ]}' <<<"$meta")"
    [[ "$(jq '.requests|length' <<<"$batch")" -eq 0 ]] && { echo "Rien à masquer."; return; }
    check_err "$(api_batch "$batch")"
    echo "→ Seul ${keep} reste visible."
}

# Affiche un range (défaut : les 6 premières lignes de la 1re colonne d'un onglet).
# $1 = onglet (ex: V28), $2 = range optionnel (ex: A1:C6).
cmd_show() {
    local tab="${1:?Usage: $0 show <onglet> [range]}" range="${2:-A1:A6}"
    api_values_get "${tab}!${range}" | jq -r '.values // [] | .[] | @tsv'
}

# Écrit une cellule. $1 = onglet, $2 = cellule (ex: A1), $3 = texte.
cmd_setcell() {
    local tab="${1:?Usage: $0 setcell <onglet> <cellule> <texte>}" cell="${2:?cellule requise}" text="${3-}"
    api_values_put "${tab}!${cell}" "$text" >/dev/null
    echo "✓ ${tab}!${cell} mis à jour."
}

# Peuple un onglet depuis un TSV (effacement et écriture atomiques). $1 = onglet, $2 = fichier TSV.
# Corrige le vice de fond : `new` clone l'onglet precedent, donc sans re-peuplement le
# contenu reste fige (le Sheet est reste bloque sur V10 pendant que les noms d'onglets
# avancaient). `load` ecrit le VRAI contenu d'un V[N].txt transforme en TSV.
cmd_load() {
    local tab="${1:?Usage: $0 load <onglet> <fichier.tsv>}" file="${2:?fichier TSV requis}"
    [[ -f "$file" ]] || die "Fichier introuvable: $file"
    # TSV -> {values:[[col,col,...],...]}, en préservant les lignes/cellules vides.
    local body
    body="$(jq -Rn --rawfile tsv "$file" '
        {values: ($tsv | rtrimstr("\n") | split("\n") | map(split("\t")))}')"
    api_values_matrix "${tab}!A1" "$body" >/dev/null
    echo "✓ Onglet ${tab} peuplé depuis $(basename "$file")."
}

# --- Dispatch ---------------------------------------------------------------
[[ $# -ge 1 ]] || die "Usage: $0 {list|new [N]|hide-old|show <tab> [range]|setcell <tab> <cell> <texte>|load <tab> <fichier.tsv>}"
action="$1"; shift || true
TOKEN="$(get_access_token)"
case "$action" in
    list)     cmd_list ;;
    new)      cmd_new "${1:-}" ;;
    hide-old) cmd_hide_old "${1:-}" ;;
    show)     cmd_show "${1:-}" "${2:-}" ;;
    setcell)  cmd_setcell "${1:-}" "${2:-}" "${3-}" ;;
    load)     cmd_load "${1:-}" "${2:-}" ;;
    *)        die "Action inconnue: $action (list|new|hide-old|show|setcell|load)" ;;
esac
