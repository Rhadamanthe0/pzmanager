#!/usr/bin/env bash
# Configuration RAM serveur Project Zomboid
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../.env"

readonly JSON_FILE="${PZ_INSTALL_DIR}/ProjectZomboid64.json"

show_usage() {
    cat << 'EOF'
Usage: ./scripts/pzm config ram <valeur>

Configure le heap Java (Xms=Xmx), le cgroup MemoryMax/SwapMax, et les flags GC.

Exemples:
  ./scripts/pzm config ram 4g    # Heap 4GB, MemoryMax 10G (heap + 6G shmem buffer)
  ./scripts/pzm config ram 6g    # Heap 6GB, MemoryMax 12G
  ./scripts/pzm config ram 8g    # Heap 8GB, MemoryMax 14G

Valeurs acceptées: 2g, 4g, 6g, 8g, 12g, 16g, 20g, 24g, 32g

Note: PZ B42 modded utilise ~6-9 GB de native/shmem en plus du heap Java.
La formule MemoryMax = Xmx + 6G couvre ce besoin. Swap=2G en filet OOM.
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

# PZ B42 modded peut utiliser 6-9 GB de native/shmem (hors heap Java).
# Formule: MemoryMax = Xmx + SHMEM_BUFFER_GB pour couvrir heap + shmem.
# Swap=2G en filet de sécurité (déborder en swap plutôt que OOM-kill).
readonly SHMEM_BUFFER_GB=6
readonly MEMORY_SWAP_MAX="2G"

update_service_memory_max() {
    local ram="$1"
    local ram_num="${ram%g}"
    local memory_max_mb=$(( (ram_num + SHMEM_BUFFER_GB) * 1024 ))

    local service_file="${PZ_HOME}/.config/systemd/user/${PZ_SERVICE_NAME}"
    local template_file="${PZ_MANAGER_DIR}/data/setupTemplates/${PZ_SERVICE_NAME}"

    for f in "$service_file" "$template_file"; do
        [[ -f "$f" ]] || continue

        # MemoryMax
        if grep -q "^MemoryMax=" "$f"; then
            sed -i "s/^MemoryMax=.*/MemoryMax=${memory_max_mb}M/" "$f"
        else
            sed -i "/^\[Service\]/a MemoryMax=${memory_max_mb}M" "$f"
        fi

        # MemorySwapMax (filet OOM)
        if grep -q "^MemorySwapMax=" "$f"; then
            sed -i "s/^MemorySwapMax=.*/MemorySwapMax=${MEMORY_SWAP_MAX}/" "$f"
        else
            sed -i "/^MemoryMax=/i MemorySwapMax=${MEMORY_SWAP_MAX}" "$f"
        fi
    done

    if [[ "$(id -un)" == "${PZ_USER}" ]]; then
        systemctl --user daemon-reload
    fi

    echo "MemoryMax service: ${memory_max_mb}M (Xmx ${ram} + ${SHMEM_BUFFER_GB}G shmem buffer)"
    echo "MemorySwapMax    : ${MEMORY_SWAP_MAX} (filet OOM)"
}

# Configure les flags GC dans ProjectZomboid64.json (idempotent).
# PZ utilise -XX:+UseZGC par défaut (pauses < 10ms, supérieur à G1GC).
# Si ZGC absent (futur changement PZ ?), fallback sur G1GC + pauses courtes.
update_jvm_gc_flags() {
    local ram="$1"

    if grep -q '"-XX:+UseZGC"' "$JSON_FILE"; then
        # Nettoyer d'éventuels flags G1GC qui conflicteraient avec ZGC
        # (présents si versions antérieures de ce script les ont ajoutés)
        local cleaned=false
        if grep -q '"-XX:+UseG1GC"' "$JSON_FILE"; then
            sed -i '/"-XX:+UseG1GC",/d' "$JSON_FILE"
            cleaned=true
        fi
        if grep -q "MaxGCPauseMillis" "$JSON_FILE"; then
            sed -i '/"-XX:MaxGCPauseMillis=[0-9]*",/d' "$JSON_FILE"
            cleaned=true
        fi
        if [[ "$cleaned" == true ]]; then
            echo "GC: nettoyage flags G1GC (conflit avec ZGC déjà actif)"
        else
            echo "GC: ZGC déjà configuré (PZ default) - rien à faire"
        fi
        return 0
    fi

    # Pas de ZGC : ajouter G1GC + pauses courtes comme fallback
    if ! grep -q '"-XX:+UseG1GC"' "$JSON_FILE"; then
        sed -i "/\"-Xmx${ram}\"/a\\\\t\\t\"-XX:+UseG1GC\"," "$JSON_FILE"
        echo "GC flag ajouté : -XX:+UseG1GC"
    fi
    if ! grep -q "MaxGCPauseMillis" "$JSON_FILE"; then
        sed -i "/\"-XX:+UseG1GC\"/a\\\\t\\t\"-XX:MaxGCPauseMillis=50\"," "$JSON_FILE"
        echo "GC flag ajouté : -XX:MaxGCPauseMillis=50"
    fi
}

set_ram() {
    local ram="$1"
    local current=$(get_current_ram)

    if [[ "$current" != "$ram" ]]; then
        # Backup
        cp "$JSON_FILE" "${JSON_FILE}.bak"

        # Modifier -Xmx (max heap)
        sed -i "s/\"-Xmx[0-9]\+g\"/\"-Xmx${ram}\"/" "$JSON_FILE"

        # Ajouter ou modifier -Xms (min heap) = même valeur
        if grep -q '"-Xms' "$JSON_FILE"; then
            sed -i "s/\"-Xms[0-9]\+g\"/\"-Xms${ram}\"/" "$JSON_FILE"
        else
            sed -i "/\"-Xmx${ram}\"/a\\\\t\\t\"-Xms${ram}\"," "$JSON_FILE"
        fi

        echo "RAM modifiee: $current -> $ram (-Xms${ram} / -Xmx${ram})"
    else
        echo "RAM deja configuree a $ram"
    fi

    update_service_memory_max "$ram"
    update_jvm_gc_flags "$ram"
    echo "Redemarrer le serveur pour appliquer: pzm server restart 2m"
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
