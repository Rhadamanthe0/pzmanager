#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# wipeMapTile.sh - Efface (regenere) une zone de la carte par coordonnees X/Y
# ------------------------------------------------------------------------------
# Cas d'usage : un mod de carte (ex: un chateau custom en tiles) a ete mis a
# jour, mais la zone a deja ete exploree -> PZ a mis en cache les chunks et
# affiche l'ancienne version. On supprime les fichiers de sauvegarde de cette
# zone : au prochain passage d'un joueur, le jeu les regenere depuis le mod.
#
# Usage:
#   wipeMapTile.sh <x> <y> [options]                # une seule tuile (son chunk)
#   wipeMapTile.sh <x1> <y1> <x2> <y2> [options]    # rectangle de tuiles
#
# Options:
#   --no-cell      NE PAS toucher au niveau cellule (300x300). Par defaut le wipe
#                  efface AUSSI chunkdata + metagrid (definitions de pieces) +
#                  zpop (zombies) + apop (animaux), car un mod qui change des
#                  batiments/pieces laisse sinon les pieces desynchro. --no-cell
#                  limite au terrain (chunks 10x10) pour un simple retouche sol.
#                  (--cell reste accepte pour compat, c'est deja le defaut.)
#   --save <nom>   Nom de la sauvegarde MP (defaut: auto-detection)
#   -h|--help
#
# NB: le niveau cellule porte sur toute la cellule 300x300, pas seulement la
#     zone de tuiles demandee.
#
# Format de sauvegarde Build 42 (verifie sur ce serveur) :
#   map/<cx>/<cy>.bin                      terrain,   par CHUNK  (10 tuiles)
#   isoregiondata/datachunk_<cx>_<cy>.bin  isoregion, par CHUNK  (10 tuiles)
#   chunkdata/chunkdata_<Cx>_<Cy>.bin      metadata,  par CELLULE (300 tuiles)
#   zpop/zpop_<Cx>_<Cy>.bin                pop zombie, par CELLULE
#   apop/apop_<Cx>_<Cy>.bin                pop animale, par CELLULE
#   metagrid/metacell_<Cx>_<Cy>.bin        metagrid,  par CELLULE
#   ou  cx = tuileX / 10   et   Cx = tuileX / 300
#
# Suppression IMMEDIATE (pas de dry-run). Securite : refuse de tourner si le
# serveur est actif ; snapshot de chaque fichier supprime dans
# ${BACKUP_DIR}/tile-wipe-snapshots/ avant suppression.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

readonly CHUNK_SIZE=10
readonly CELL_SIZE=300

usage() {
    # Imprime le bandeau d'en-tete : tout ce qui est entre le shebang et le
    # 3e separateur "# ---" (1er = ouverture, 2e = sous le titre, 3e = fin),
    # separateurs eux-memes exclus.
    awk 'NR==1{next} /^# ---/{c++; if(c==3) exit; next} {sub(/^# ?/,""); print}' "$0"
    exit "${1:-0}"
}

# --- Parse des arguments -----------------------------------------------------
WIPE_CELL=true        # niveau cellule efface par defaut (voir en-tete)
SAVE_NAME=""
COORDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cell) WIPE_CELL=false; shift ;;
        --cell)   WIPE_CELL=true; shift ;;   # defaut, garde pour compat
        --save)   SAVE_NAME="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*)       die "Option inconnue: $1" ;;
        *)        COORDS+=("$1"); shift ;;
    esac
done

# Coordonnees : 2 (point) ou 4 (rectangle)
case "${#COORDS[@]}" in
    2) X1="${COORDS[0]}"; Y1="${COORDS[1]}"; X2="$X1"; Y2="$Y1" ;;
    4) X1="${COORDS[0]}"; Y1="${COORDS[1]}"; X2="${COORDS[2]}"; Y2="${COORDS[3]}" ;;
    *) echo "Erreur: coordonnees attendues : <x> <y>  ou  <x1> <y1> <x2> <y2>" >&2; usage 1 ;;
esac

for v in "$X1" "$Y1" "$X2" "$Y2"; do
    [[ "$v" =~ ^[0-9]+$ ]] || die "Coordonnee invalide (entier positif attendu): $v"
done

# Ordonne le rectangle
(( X1 <= X2 )) || { t=$X1; X1=$X2; X2=$t; }
(( Y1 <= Y2 )) || { t=$Y1; Y1=$Y2; Y2=$t; }

# --- Serveur doit etre arrete ------------------------------------------------
if server_is_active; then
    die "Le serveur est actif. Arretez-le d'abord: pzm server stop"
fi

# --- Localise la sauvegarde MP -----------------------------------------------
readonly MP_DIR="${PZ_SOURCE_DIR}/Saves/Multiplayer"
[[ -d "$MP_DIR" ]] || die "Dossier de sauvegardes introuvable: $MP_DIR"

if [[ -z "$SAVE_NAME" ]]; then
    # Auto-detection : une seule sauvegarde MP attendue
    mapfile -t saves < <(find "$MP_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n')
    case "${#saves[@]}" in
        0) die "Aucune sauvegarde MP dans $MP_DIR" ;;
        1) SAVE_NAME="${saves[0]}" ;;
        *) die "Plusieurs sauvegardes MP trouvees, precisez --save <nom>: ${saves[*]}" ;;
    esac
fi
readonly SAVE_DIR="${MP_DIR}/${SAVE_NAME}"
[[ -d "$SAVE_DIR" ]] || die "Sauvegarde introuvable: $SAVE_DIR"

# --- Calcul des chunks / cellules --------------------------------------------
readonly CX1=$(( X1 / CHUNK_SIZE )) CX2=$(( X2 / CHUNK_SIZE ))
readonly CY1=$(( Y1 / CHUNK_SIZE )) CY2=$(( Y2 / CHUNK_SIZE ))
readonly CELL_X1=$(( X1 / CELL_SIZE )) CELL_X2=$(( X2 / CELL_SIZE ))
readonly CELL_Y1=$(( Y1 / CELL_SIZE )) CELL_Y2=$(( Y2 / CELL_SIZE ))

# Rassemble la liste des fichiers cibles EXISTANTS
targets=()
for (( cx=CX1; cx<=CX2; cx++ )); do
    for (( cy=CY1; cy<=CY2; cy++ )); do
        [[ -f "${SAVE_DIR}/map/${cx}/${cy}.bin" ]]               && targets+=("map/${cx}/${cy}.bin")
        [[ -f "${SAVE_DIR}/isoregiondata/datachunk_${cx}_${cy}.bin" ]] && targets+=("isoregiondata/datachunk_${cx}_${cy}.bin")
    done
done
if $WIPE_CELL; then
    for (( cx=CELL_X1; cx<=CELL_X2; cx++ )); do
        for (( cy=CELL_Y1; cy<=CELL_Y2; cy++ )); do
            for f in "chunkdata/chunkdata_${cx}_${cy}.bin" \
                     "zpop/zpop_${cx}_${cy}.bin" \
                     "apop/apop_${cx}_${cy}.bin" \
                     "metagrid/metacell_${cx}_${cy}.bin"; do
                [[ -f "${SAVE_DIR}/${f}" ]] && targets+=("$f")
            done
        done
    done
fi

# --- Rapport -----------------------------------------------------------------
n_chunks=$(( (CX2 - CX1 + 1) * (CY2 - CY1 + 1) ))
echo "=== Wipe de zone carte ==="
echo "Sauvegarde   : $SAVE_NAME"
echo "Tuiles       : ($X1,$Y1) -> ($X2,$Y2)"
echo "Chunks       : X ${CX1}..${CX2}, Y ${CY1}..${CY2}  (${n_chunks} chunk(s) 10x10)"
if $WIPE_CELL; then
    echo "Cellules     : X ${CELL_X1}..${CELL_X2}, Y ${CELL_Y1}..${CELL_Y2}  (niveau 300x300, chunkdata/metagrid/zpop/apop)"
else
    echo "Cellules     : ignorees (--no-cell : terrain seul)"
fi
echo "Fichiers existants a supprimer : ${#targets[@]}"
printf '  %s\n' "${targets[@]:0:20}"
(( ${#targets[@]} > 20 )) && echo "  ... (+$(( ${#targets[@]} - 20 )) autres)"

if (( ${#targets[@]} == 0 )); then
    echo "Rien a supprimer (zone non encore generee sur la sauvegarde -> la maj du mod s'appliquera d'elle-meme)."
    exit 0
fi

# --- Snapshot + suppression --------------------------------------------------
readonly STAMP="$(date +%Y-%m-%d_%Hh%Mm%Ss)"
readonly SNAP_DIR="${BACKUP_DIR}/tile-wipe-snapshots/wipe_${STAMP}"
ensure_directory "$SNAP_DIR"
echo
log "Snapshot vers: $SNAP_DIR"

deleted=0
for rel in "${targets[@]}"; do
    src="${SAVE_DIR}/${rel}"
    dst="${SNAP_DIR}/${rel}"
    ensure_directory "$(dirname "$dst")"
    cp -p "$src" "$dst"
    rm -f "$src"
    (( deleted++ )) || true
done

log "Supprime: ${deleted} fichier(s). Snapshot conserve dans $SNAP_DIR"
echo "Terminez par: pzm server start  (la zone se regenerera au prochain passage d'un joueur)."
