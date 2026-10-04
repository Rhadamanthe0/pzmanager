#!/usr/bin/env bash
# server_state.sh - État serveur prouvé, fail-closed (C1).
#
# Le bug : `server_is_active` (common.sh, `systemctl --user is-active --quiet`)
# vaut FAUX dès que systemctl échoue — bus user injoignable, unité absente...
# Une erreur systemd était donc traitée comme « serveur arrêté », et les
# gardes require_server_stopped laissaient passer des écritures monde
# potentiellement À CHAUD. De même, un `exit 0` silencieux sur verrou occupé
# (backup) se lisait comme un succès.
#
# Ici : `server_state` ne répond JAMAIS « inactive » sur une erreur — il
# répond `error`, et les gardes meurent (fail-closed) sur error/unknown.
#
# API (stdout = exactement un mot, exit toujours 0 : l'état est une DONNÉE) :
#   server_state  -> active|inactive|activating|deactivating|failed|unknown|error
#                    via `systemctl --user show -p ActiveState,SubState,Result`.
#                    systemctl en échec (bus indisponible...) -> `error`.
#                    ActiveState inattendu ou illisible -> `unknown`.
#   require_server_state ETAT...       -> 0 si l'état courant est attendu,
#                    sinon `exit 1` (message fail-closed sur stderr).
#   assert_server_stopped_proven [CONTEXTE] -> 0 si et seulement si `inactive` ;
#                    `active` -> exit 1 (message « serveur actif », comme
#                    require_server_stopped) ; failed|unknown|error (+ activating
#                    /deactivating, qui ne prouvent pas l'arrêt) -> exit 1
#                    fail-closed. C'est la garde des opérations destructrices
#                    (wipe, restore...). La garde historique require_server_stopped
#                    (common.sh) reste, rendue fail-closed sur error/unknown, et
#                    accepte activating/deactivating/failed pour compat
#                    (purge en ExecStartPre : l'unité y est « activating » ;
#                    post-crash : « failed »).
[[ -n "${PZ_SERVER_STATE_LOADED:-}" ]] && return 0
PZ_SERVER_STATE_LOADED=1

_pz_state_die() {
    echo "ERREUR: $*" >&2
    exit 1
}

server_state() {
    local svc="${PZ_SERVICE_NAME:-zomboid.service}" out active
    if ! out="$(systemctl --user show "$svc" -p ActiveState,SubState,Result 2>/dev/null)"; then
        printf 'error\n'
        return 0
    fi
    active="$(printf '%s\n' "$out" | awk -F= '$1 == "ActiveState" { print $2; exit }')"
    case "$active" in
        active|inactive|activating|deactivating|failed)
            printf '%s\n' "$active"
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
    return 0
}

# Usage: require_server_state ETAT [ETAT...]
require_server_state() {
    if [[ $# -lt 1 ]]; then
        echo "ERREUR: require_server_state attend au moins un état attendu" >&2
        return 2
    fi
    local st expected
    st="$(server_state)"
    for expected in "$@"; do
        if [[ "$st" == "$expected" ]]; then
            return 0
        fi
    done
    _pz_state_die "état serveur '${st}' (attendu : $*) — refus par sécurité (fail-closed)."
}

# Usage: assert_server_stopped_proven [CONTEXTE]
assert_server_stopped_proven() {
    local context="${1:-Opération sur le monde}"
    local st
    st="$(server_state)"
    if [[ "$st" == "inactive" ]]; then
        return 0
    fi
    if [[ "$st" == "active" ]]; then
        _pz_state_die "Le serveur est actif : ${context} écrit dans le monde et doit se faire SERVEUR ARRÊTÉ (état : '${st}').
Arrête-le d'abord :  pzm server stop 2m --reason \"${context}\""
    fi
    _pz_state_die "${context} : état serveur non prouvé arrêté ('${st}') — refus par sécurité (fail-closed).
Vérifie l'unité ${PZ_SERVICE_NAME:-zomboid.service} (bus user : systemctl --user) puis réessaie."
}
