#!/usr/bin/env bash
# Configuration RAM serveur Project Zomboid
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../.env"

readonly JSON_FILE="${PZ_INSTALL_DIR}/ProjectZomboid64.json"

show_usage() {
    cat << 'EOF'
Usage: ./scripts/pzm config ram <valeur>

Exemples:
  ./scripts/pzm config ram 4g    # 4GB RAM
  ./scripts/pzm config ram 8g    # 8GB RAM
  ./scripts/pzm config ram 16g   # 16GB RAM

Valeurs acceptées: 2g, 4g, 6g, 8g, 12g, 16g, 20g, 24g, 32g
EOF
}

validate_ram() {
    local ram="$1"
    if [[ ! "$ram" =~ ^(2|4|6|8|12|16|20|24|32)g$ ]]; then
        echo "Erreur: Valeur RAM invalide: $ram" >&2
        echo "" >&2
        show_usage
        exit 1
    fi
}

get_current_ram() {
    grep -oP '"-Xmx\K[0-9]+g' "$JSON_FILE" 2>/dev/null || echo "unknown"
}

set_ram() {
    local ram="$1"
    local current=$(get_current_ram)

    if [[ "$current" == "$ram" ]]; then
        echo "✓ RAM déjà configurée à $ram"
        return 0
    fi

    # Backup
    cp "$JSON_FILE" "${JSON_FILE}.bak"

    # Modifier -Xmx
    sed -i "s/\"-Xmx[0-9]\+g\"/\"-Xmx${ram}\"/" "$JSON_FILE"

    echo "✓ RAM modifiée: $current → $ram"
    echo "⚠️  Redémarrer le serveur pour appliquer: ./scripts/pzm server restart"
}

main() {
    if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    local ram="$1"

    [[ -f "$JSON_FILE" ]] || {
        echo "Erreur: Fichier ProjectZomboid64.json introuvable" >&2
        echo "Chemin: $JSON_FILE" >&2
        exit 1
    }

    validate_ram "$ram"
    set_ram "$ram"
}

main "$@"
