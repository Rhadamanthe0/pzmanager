#!/usr/bin/env bash
# Avant systemd 254, --scope transmet déjà les argv littéralement mais ne
# connaît pas --expand-environment. Aucun repli hors de la scope n'est permis.
pz_scope_noexpand_arg() {
    local help
    help="$(LC_ALL=C systemd-run --help)" || {
        echo 'Impossible de vérifier les options de systemd-run.' >&2
        return 1
    }
    [[ "$help" == *--scope* ]] || {
        echo 'Aide systemd-run invalide : support des scopes non prouvé.' >&2
        return 1
    }
    if [[ "$help" == *--expand-environment=* ]]; then
        printf '%s\n' --expand-environment=no
    fi
}
