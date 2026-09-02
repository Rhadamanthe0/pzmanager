#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# checkDocsDuplication.sh - Détecte la redite entre CLAUDE.md et docs/
# ------------------------------------------------------------------------------
# Pourquoi : CLAUDE.md et docs/ ont dérivé jusqu'à expliquer les mêmes choses
# deux fois, en des termes différents. Deux copies d'un même fait finissent
# toujours par se contredire, et rien n'indique laquelle est périmée.
#
# Règle du dépôt : docs/ est la SOURCE UNIQUE. CLAUDE.md ne porte que des
# consignes destinées à l'agent et des liens vers docs/.
#
# Deux contrôles, parce qu'ils attrapent deux choses différentes :
#
#  1. RECOUVREMENT LITTÉRAL — empreintes de N mots consécutifs (normalisées :
#     minuscules, ponctuation et blocs de code écartés) comparées entre chaque
#     paire de fichiers. Attrape le copier-coller.
#
#  2. TAILLE DE CLAUDE.md — le vrai motif observé ici n'était PAS du
#     copier-coller (0,7% de recouvrement littéral seulement) mais de la
#     PARAPHRASE : CLAUDE.md avait grossi jusqu'à 49 Ko en réexpliquant, avec
#     d'autres mots, ce que docs/ disait déjà. Aucune comparaison de texte ne
#     détecte ça de façon fiable. Le signal utilisable est structurel : un
#     CLAUDE.md qui grossit est un CLAUDE.md qui redevient un second manuel.
#     On borne donc sa taille et on exige qu'il reste dense en liens.
#
# Usage: ./checkDocsDuplication.sh [--threshold N] [--shingle N] [--show]
#   --threshold N  % de recouvrement à partir duquel on échoue (défaut 3)
#   --shingle N    longueur des empreintes en mots (défaut 12)
#   --max-bytes N  taille max de CLAUDE.md (défaut 12000)
#   --show         affiche les passages communs (diagnostic)
#
# Code de retour : 0 = rien à signaler, 1 = redite détectée.
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

THRESHOLD=3
SHINGLE=12
MAX_BYTES=12000
SHOW=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) [[ $# -ge 2 ]] || die "--threshold attend un nombre"; THRESHOLD="$2"; shift 2 ;;
        --shingle)   [[ $# -ge 2 ]] || die "--shingle attend un nombre";   SHINGLE="$2";   shift 2 ;;
        --max-bytes) [[ $# -ge 2 ]] || die "--max-bytes attend un nombre"; MAX_BYTES="$2"; shift 2 ;;
        --show)      SHOW=1; shift ;;
        -h|--help)   sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "Option inconnue: $1" ;;
    esac
done

cd "${PZ_MANAGER_ROOT}"

python3 - "$THRESHOLD" "$SHINGLE" "$SHOW" "$MAX_BYTES" <<'PYEOF'
import itertools, pathlib, re, sys

threshold, n, show = float(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "1"
max_bytes = int(sys.argv[4])

def shingles(path):
    t = path.read_text(encoding="utf-8")
    t = re.sub(r"```.*?```", " ", t, flags=re.S)   # blocs de code
    t = re.sub(r"`[^`]*`", " ", t)                 # code inline
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t) # liens -> libellé
    t = re.sub(r"[^0-9a-zà-öø-ÿ]+", " ", t.lower())
    w = t.split()
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}

files = sorted(pathlib.Path("docs").glob("*.md"))
for extra in ("CLAUDE.md", "README.md"):
    p = pathlib.Path(extra)
    if p.is_file():
        files.append(p)

sh = {f: shingles(f) for f in files}
sh = {f: s for f, s in sh.items() if s}

problems = []
for a, b in itertools.combinations(sh, 2):
    inter = sh[a] & sh[b]
    if not inter:
        continue
    pct = 100 * len(inter) / min(len(sh[a]), len(sh[b]))
    if pct >= threshold:
        problems.append((pct, a, b, inter))

problems.sort(reverse=True, key=lambda x: x[0])
for pct, a, b, inter in problems:
    print(f"  {pct:5.1f}%  {a}  <->  {b}   ({len(inter)} passages de {n} mots)")
    if show:
        for frag in sorted(inter)[:5]:
            print(f"           « {frag} »")

if problems:
    print()
    print(f"{len(problems)} paire(s) au-dessus de {threshold}% de recouvrement.")
    print("docs/ est la source unique : garder UNE seule explication et remplacer")
    print("l'autre par un lien. Voir docs/README.md pour savoir quel doc possède quel sujet.")
    sys.exit(1)

# --- Contrôle structurel de CLAUDE.md ---------------------------------------
claude = pathlib.Path("CLAUDE.md")
if claude.is_file():
    size = len(claude.read_bytes())
    links = len(re.findall(r"\]\(docs/", claude.read_text(encoding="utf-8")))
    if size > max_bytes:
        print(f"CLAUDE.md fait {size} o (max {max_bytes}).")
        print("Il a recommencé à porter de la doc au lieu d'y renvoyer.")
        print("Déplacer le contenu dans le doc qui possède le sujet (voir docs/README.md)")
        print("et ne laisser ici qu'une consigne + un lien.")
        sys.exit(1)
    if links < 5:
        print(f"CLAUDE.md ne contient que {links} lien(s) vers docs/ — il devrait être un index.")
        sys.exit(1)
    print(f"CLAUDE.md : {size} o (max {max_bytes}), {links} liens vers docs/ — OK.")

print(f"OK — aucune paire au-dessus de {threshold}% de recouvrement "
      f"({len(sh)} fichiers, empreintes de {n} mots).")
PYEOF
