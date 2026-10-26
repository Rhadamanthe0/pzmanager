#!/usr/bin/env bash
# env_parse.sh - Parsing declaratif du .env pour contexte root (C15).
# Installation attendue : /usr/local/libexec/pzmanager/ root:root 0755.
# Ce fichier est du code versionne ; le .env, lui, est modifiable par PZ_USER
# et ne doit jamais etre execute par un processus root.
# Aucun chargement shell du fichier cible ici : lecture ligne a ligne,
# motif KEY=VALUE uniquement, whitelist stricte, validation avant export.

# Usage: parse_env_declarative <fichier>
# Retour 0 si le fichier a ete parcouru (meme si tout est ignore),
# retour 1 si fichier absent/illisible ou profil metier non resoluble. Exporte uniquement les cles
# whitelisted et validees, sans jamais executer le contenu.
parse_env_declarative() {
    local env_file="${1:-}"
    [[ -n "$env_file" ]] || return 1
    [[ -r "$env_file" ]] || return 1

    local line key raw val first candidate literal
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            case "$key" in
                PZ_USER|PZ_GAME_USER|PZ_MANAGER_USER|PZ_HOME|PZ_MANAGER_DIR|PZ_SOURCE_DIR|PZ_DATA_DIR|PZ_INSTALL_DIR|PZ_SERVICE_NAME|PZ_DB_PATH|PZ_INI_PATH|PZ_PORT_GAME|PZ_PORT_GAME2|PZ_PROMETHEUS_PORT|PZ_SERVER_NAME|JAVA_VERSION|JAVA_PACKAGE|JAVA_PATH|PZ_JDK_SOURCE|STEAMCMD_PATH|STEAM_APP_ID|STEAM_BETA_BRANCH|STEAM_LOGIN)
                    ;;
                *) continue ;;
            esac

            val="$raw"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"

            if [[ -z "$val" ]]; then
                case "$key" in
                    PZ_HOME|PZ_MANAGER_DIR|PZ_SOURCE_DIR|PZ_DATA_DIR|PZ_INSTALL_DIR|PZ_SERVICE_NAME|PZ_SERVER_NAME|PZ_DB_PATH|PZ_INI_PATH)
                        echo "Profil déclaratif vide : $key." >&2; return 1 ;;
                    STEAM_BETA_BRANCH|STEAM_LOGIN|PZ_JDK_SOURCE)
                        export "$key="
                        ;;
                esac
                continue
            fi

            # These fields select the world and the unit whose stop is proved.
            # Never silently replace an unresolvable profile with defaults.
            case "$key" in
                PZ_HOME|PZ_MANAGER_DIR|PZ_SOURCE_DIR|PZ_DATA_DIR|PZ_INSTALL_DIR|PZ_SERVICE_NAME|PZ_SERVER_NAME|PZ_DB_PATH|PZ_INI_PATH)
                    literal=false
                    if [[ "$val" == \"* ]]; then
                        [[ "$val" =~ ^\"([^\"]*)\"([[:space:]]+#.*)?$ ]] || return 1
                        [[ "${BASH_REMATCH[1]}" != *'\'* ]] || return 1
                        val="${BASH_REMATCH[1]}"
                    elif [[ "$val" == \'* ]]; then
                        [[ "$val" =~ ^\'([^\']*)\'([[:space:]]+#.*)?$ ]] || return 1
                        val="${BASH_REMATCH[1]}"
                        literal=true
                    else
                        # A # inside the assignment word is literal. Accept
                        # only a single word plus an optional separated comment;
                        # quoting/escaping concatenations need an explicit refusal.
                        [[ "$val" =~ ^([^[:space:]]+)([[:space:]]+#.*)?$ ]] || return 1
                        val="${BASH_REMATCH[1]}"
                        case "$val" in
                            *'\'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'~'*) return 1 ;;
                        esac
                    fi
                    local ref replacement token
                    while [[ "$literal" == false && "$val" =~ \$\{([A-Z_]+)\} ]]; do
                        token="${BASH_REMATCH[0]}"; ref="${BASH_REMATCH[1]}"
                        [[ "$ref" != "$key" ]] || { echo "Profil déclaratif auto-référent : $key." >&2; return 1; }
                        case "$ref" in
                            PZ_USER) replacement="${PZ_USER:-pzuser}" ;;
                            PZ_MANAGER_ROOT) replacement="${PZ_MANAGER_ROOT:-}" ;;
                            PZ_HOME) replacement="${PZ_HOME:-/home/${PZ_USER:-pzuser}}" ;;
                            PZ_MANAGER_DIR) replacement="${PZ_MANAGER_DIR:-${INSTALL_MANAGER_ROOT:-${PZ_MANAGER_ROOT:-}}}" ;;
                            PZ_DATA_DIR) replacement="${PZ_DATA_DIR:-${PZ_MANAGER_DIR:-${INSTALL_MANAGER_ROOT:-${PZ_MANAGER_ROOT:-}}}/data}" ;;
                            PZ_SOURCE_DIR) replacement="${PZ_SOURCE_DIR:-${PZ_MANAGER_DIR:-${INSTALL_MANAGER_ROOT:-${PZ_MANAGER_ROOT:-}}}/Zomboid}" ;;
                            PZ_SERVER_NAME) replacement="${PZ_SERVER_NAME:-servertest}" ;;
                            *) echo "Profil déclaratif non résolu : $key ($ref)." >&2; return 1 ;;
                        esac
                        [[ -n "$replacement" && "$replacement" != *'$'* ]] || return 1
                        val="${val//"$token"/"$replacement"}"
                    done
                    if [[ "$key" == PZ_SERVICE_NAME ]]; then
                        [[ "$val" =~ ^[A-Za-z0-9_.@:-]+\.service$ && "$val" != -* ]] || {
                            echo "Unité déclarative invalide : $key." >&2; return 1;
                        }
                    elif [[ "$key" == PZ_SERVER_NAME ]]; then
                        [[ "$val" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || {
                            echo "Nom de monde déclaratif invalide : $key." >&2; return 1;
                        }
                    else
                        [[ "$val" == /* && "$val" != *'..'* && "$val" != *'$'* && "$val" != *'`'* && "$val" != *';'* && "$val" != *$'\n'* && "$val" != *'"'* && "$val" != *"'"* ]] || {
                            echo "Chemin déclaratif invalide : $key." >&2; return 1;
                        }
                    fi
                    if [[ "$key" == PZ_MANAGER_DIR && -n "${INSTALL_MANAGER_ROOT:-}" ]]; then
                        [[ "$(realpath -e -- "$val")" == "$(realpath -e -- "$INSTALL_MANAGER_ROOT")" ]] || {
                            echo "Alias PZ_MANAGER_DIR contradictoire avec la racine explicite." >&2; return 1;
                        }
                        # Same installation: resolve subsequent path references
                        # from its physical root, without a mutable alias ancestor.
                        val="$(realpath -e -- "$INSTALL_MANAGER_ROOT")"
                    fi
                    export "$key=$val"
                    continue
                    ;;
            esac

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
                    elif [[ "$key" == PZ_USER ]]; then
                        echo "Identité déclarative non résolue : PZ_USER." >&2; return 1
                    fi
                    ;;
                JAVA_PATH|STEAMCMD_PATH)
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
