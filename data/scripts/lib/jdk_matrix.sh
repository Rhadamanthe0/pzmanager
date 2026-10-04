#!/usr/bin/env bash
# jdk_matrix.sh - Matrice OS/JDK coherente (C14).
# Sourcable sans effet de bord : aucune execution au sourcing, aucune lecture
# du .env (contexte root-safe, comme lib/env_parse.sh). Les seuls appels
# externes sont `apt-cache policy` (disponibilite paquet) et `<bin> -version`
# (controle du binaire effectif) — mockables via PATH pour les tests.
# Surcharge test : PZ_OS_RELEASE (defaut /etc/os-release).
#
# Plafond connu : heuristique simple « demande puis LTS decroissants »
# (25 -> 21 -> 17), pas de resolution SAT de dependances ; a etendre si les
# distributions ajoutent un JDK superieur.

# Replis si sourcé seul (tests) : n'ecrasent jamais log()/die() de common.sh.
if ! declare -F log >/dev/null 2>&1; then
    log() { echo "[$(date +'%H:%M:%S')] $*"; }
fi
if ! declare -F die >/dev/null 2>&1; then
    die() { echo "ERREUR: $*" >&2; exit 1; }
fi

# Identifiant OS "id:version" (ex: debian:12, ubuntu:24.04).
# Parse, ne source PAS le fichier (fichier systeme, mais la regle root-safe
# reste : on n'execute jamais un fichier qu'on ne fait que lire).
jdk_os_id() {
    local f="${PZ_OS_RELEASE:-/etc/os-release}" id="" ver=""
    [[ -r "$f" ]] || { printf 'unknown:unknown\n'; return 0; }
    id="$(sed -n -E 's/^ID="?([^"[:space:]]+)"?/\1/p' "$f" | tail -1)"
    ver="$(sed -n -E 's/^VERSION_ID="?([^"[:space:]]+)"?/\1/p' "$f" | tail -1)"
    [[ -n "$id" ]] || id="unknown"
    [[ -n "$ver" ]] || ver="unknown"
    printf '%s:%s\n' "$id" "$ver"
}

# Vrai (0) si apt propose un candidat installable pour $1.
# `apt-cache policy` imprime « Candidate: (none) » quand le paquet est inconnu
# ou non fourni par les depots configures : c'est exactement le cas
# « JAVA_VERSION en dur que l'OS ne fournit pas ».
apt_package_available() {
    local pkg="${1:-}" out=""
    [[ -n "$pkg" ]] || return 1
    command -v apt-cache >/dev/null 2>&1 || return 1
    out="$(apt-cache policy "$pkg" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    grep -q 'Candidate:' <<<"$out" || return 1
    ! grep -qE 'Candidate:[[:space:]]+\(none\)' <<<"$out"
}

# Resout le triple effectif JAVA_VERSION/JAVA_PACKAGE/JAVA_PATH et l'exporte.
# Ordre : version demandee (JAVA_VERSION, defaut 25) puis LTS decroissants
# (21, 17), dedupliques ; premier paquet avec un candidat apt gagne.
# PZ_JDK_SOURCE=temurin : nommage Adoptium, disponibilite verifiee aussi.
resolve_java_package() {
    local desired="${JAVA_VERSION:-25}" os=""
    os="$(jdk_os_id)"
    if [[ "${PZ_JDK_SOURCE:-debian}" == "temurin" ]]; then
        JAVA_VERSION="$desired"
        JAVA_PACKAGE="temurin-${desired}-jre"
        JAVA_PATH="/usr/lib/jvm/temurin-${desired}-jre-amd64"
        export JAVA_VERSION JAVA_PACKAGE JAVA_PATH
        log "JDK source=temurin : ${JAVA_PACKAGE} (${JAVA_PATH}) sur ${os}."
        return 0
    fi
    local -a cands=()
    local v seen=" " pkg=""
    for v in "$desired" 21 17; do
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        if [[ "$seen" != *" $v "* ]]; then
            cands+=("$v")
            seen+=" $v "
        fi
    done
    for v in "${cands[@]}"; do
        pkg="openjdk-${v}-jre-headless"
        if apt_package_available "$pkg"; then
            JAVA_VERSION="$v"
            JAVA_PACKAGE="$pkg"
            JAVA_PATH="/usr/lib/jvm/java-${v}-openjdk-amd64"
            export JAVA_VERSION JAVA_PACKAGE JAVA_PATH
            if [[ "$v" != "$desired" ]]; then
                log "JDK ${desired} indisponible sur ${os} : repli documente vers ${v} (${pkg})."
            else
                log "JDK ${v} selectionne (${pkg}) sur ${os}."
            fi
            return 0
        fi
    done
    die "Aucun JRE compatible (candidats: ${cands[*]:-aucun}) sur ${os}."
}

# Majeure depuis la sortie de `<bin> -version` (stderr) : "25.0.1" -> 25,
# "21.0.5" -> 21, "1.8.0_xxx" -> 8. Imprime sur stdout, exit 1 si illisible.
java_major_of() {
    local bin="${1:-java}" out="" ver="" major=""
    out="$("$bin" -version 2>&1 || true)"
    ver="$(grep -oE '"[0-9][0-9._-]*"' <<<"$out" | head -1 | tr -d '"')"
    [[ -n "$ver" ]] || return 1
    if [[ "$ver" =~ ^1\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
    else
        major="${ver%%.*}"
    fi
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$major"
}

# Controle le binaire EFFECTIVEMENT utilise par le service : JAVA_PATH/bin/java
# s'il est executable, sinon `java` du PATH. Meurt si sa majeure != attendue.
verify_java_version() {
    local expected="${1:?version attendue requise}" bin=""
    if (( $# >= 2 )); then
        bin="$2"
    elif [[ -n "${JAVA_PATH:-}" && -x "${JAVA_PATH}/bin/java" ]]; then
        bin="${JAVA_PATH}/bin/java"
    else
        bin="java"
    fi
    local major=""
    major="$(java_major_of "$bin" || true)"
    [[ -n "$major" ]] || die "Version illisible depuis ${bin} (attendu ${expected})."
    [[ "$major" == "$expected" ]] || die "JDK incoherent : ${bin} annonce ${major}, attendu ${expected} (JAVA_PATH=${JAVA_PATH:-?})."
    log "JDK verifie : ${bin} -> ${major} (attendu ${expected})."
}
