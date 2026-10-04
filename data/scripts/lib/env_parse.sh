#!/usr/bin/env bash
# env_parse.sh - Parsing declaratif du .env pour contexte root (C15).
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# Ce fichier est du code versionne ; le .env, lui, est modifiable par PZ_USER
# et ne doit jamais etre execute par un processus root.
# Aucun chargement shell du fichier cible ici : lecture ligne a ligne,
# motif KEY=VALUE uniquement, whitelist stricte, validation avant export.

# Usage: parse_env_declarative <fichier>
# Retour 0 si le fichier a ete parcouru (meme si tout est ignore),
# retour 1 si fichier absent/illisible. Exporte uniquement les cles
# whitelisted et validees, sans jamais executer le contenu.
parse_env_declarative() {
    local env_file="${1:-}"
    [[ -n "$env_file" ]] || return 1
    [[ -r "$env_file" ]] || return 1

    local line key raw val first candidate
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            case "$key" in
                PZ_USER|PZ_GAME_USER|PZ_MANAGER_USER|PZ_HOME|PZ_MANAGER_DIR|PZ_PORT_GAME|PZ_PORT_GAME2|PZ_PROMETHEUS_PORT|PZ_SERVER_NAME|JAVA_VERSION|JAVA_PACKAGE|JAVA_PATH|PZ_JDK_SOURCE|STEAMCMD_PATH|STEAM_APP_ID|STEAM_BETA_BRANCH|STEAM_LOGIN)
                    ;;
                *) continue ;;
            esac

            val="$raw"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"

            if [[ -z "$val" ]]; then
                case "$key" in
                    STEAM_BETA_BRANCH|STEAM_LOGIN|PZ_JDK_SOURCE)
                        export "$key="
                        ;;
                esac
                continue
            fi

            first="${val:0:1}"
            if [[ "$first" == "'" ]]; then
                val="${val#\'}"
                val="${val%%\'*}"
            elif [[ "$first" == '"' ]]; then
                val="${val#\"}"
                val="${val%%\"*}"
            else
                val="${val%%\#*}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
            fi

            case "$key" in
                PZ_USER|PZ_GAME_USER|PZ_MANAGER_USER)
                    if [[ "$val" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                        export "$key=$val"
                    fi
                    ;;
                PZ_HOME|PZ_MANAGER_DIR|JAVA_PATH|STEAMCMD_PATH)
                    if [[ "$val" == /* ]] \
                        && [[ "$val" != *".."* ]] \
                        && [[ "$val" != *";"* ]] \
                        && [[ "$val" != *"|"* ]] \
                        && [[ "$val" != *"&"* ]] \
                        && [[ "$val" != *\$* ]] \
                        && [[ "$val" != *"("* ]] \
                        && [[ "$val" != *")"* ]] \
                        && [[ "$val" != *'`'* ]] \
                        && [[ "$val" != *"'"* ]] \
                        && [[ "$val" != *'"'* ]] \
                        && [[ "$val" != *"#"* ]] \
                        && [[ "$val" != *" "* ]] \
                        && [[ "$val" != *$'\t'* ]]; then
                        export "$key=$val"
                    fi
                    ;;
                PZ_PORT_GAME|PZ_PORT_GAME2|PZ_PROMETHEUS_PORT)
                    candidate=""
                    if [[ "$val" =~ ^([0-9]+) ]]; then
                        candidate="${BASH_REMATCH[1]}"
                    fi
                    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( 10#$candidate >= 1 && 10#$candidate <= 65535 )); then
                        # Normaliser (retirer zeros de tete via base 10)
                        candidate="$((10#$candidate))"
                        export "$key=$candidate"
                    fi
                    ;;
                JAVA_VERSION)
                    if [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val >= 17 && 10#$val <= 25 )); then
                        export "JAVA_VERSION=$((10#$val))"
                    fi
                    ;;
                STEAM_APP_ID)
                    if [[ "$val" =~ ^[0-9]{1,10}$ ]]; then
                        export "STEAM_APP_ID=$val"
                    fi
                    ;;
                PZ_SERVER_NAME)
                    if [[ "$val" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
                        export "PZ_SERVER_NAME=$val"
                    fi
                    ;;
                JAVA_PACKAGE)
                    if [[ "$val" =~ ^[a-z0-9][a-z0-9+._-]{0,127}$ ]]; then
                        export "JAVA_PACKAGE=$val"
                    fi
                    ;;
                PZ_JDK_SOURCE)
                    if [[ "$val" =~ ^(debian|temurin)$ ]]; then
                        export "PZ_JDK_SOURCE=$val"
                    fi
                    ;;
                STEAM_BETA_BRANCH|STEAM_LOGIN)
                    if [[ -z "$val" ]]; then
                        export "$key="
                    elif [[ "$val" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
                        export "$key=$val"
                    fi
                    ;;
            esac
        fi
    done < "$env_file"
    return 0
}
