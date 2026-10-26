#!/bin/bash
# Même configuration que les workers : budget réel avant lancement natif.
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
    '') [[ $# == 0 ]] || exit 2 ;;
    --check) [[ $# == 1 ]] || exit 2 ;;
    *) echo 'Usage interne : startServer.sh [--check]' >&2; exit 2 ;;
esac
source "${SCRIPT_DIR}/../lib/common.sh"
source_env --read-only
if [[ "${1:-}" == --check ]]; then
    # Aucun secret de bootstrap, FIFO, verrou ou réparation de configuration.
    exec python3 "${SCRIPT_DIR}/../lib/jvm_memory_budget.py" check \
        "${PZ_INSTALL_DIR}/ProjectZomboid64.json"
fi
python3 "${SCRIPT_DIR}/../lib/jvm_memory_budget.py" check \
    "${PZ_INSTALL_DIR}/ProjectZomboid64.json"
[[ -p "$PZ_CONTROL_PIPE" && ! -L "$PZ_CONTROL_PIPE" && -O "$PZ_CONTROL_PIPE" ]] \
    || die "FIFO de contrôle absente ou non sûre : ${PZ_CONTROL_PIPE}. Vérifier ListenFIFO et les chemins de l'unité installée."
# Écarter un ancien quit avant de connecter le jeu à cette même FIFO.
dd if="$PZ_CONTROL_PIPE" iflag=nonblock of=/dev/null 2>/dev/null || true
args=("-cachedir=${PZ_SOURCE_DIR}" -servername "$PZ_SERVER_NAME")
password_file="${PZ_MANAGER_DIR}/.admin_password"
if [[ -e "$password_file" || -L "$password_file" ]]; then
    [[ -f "$password_file" && ! -L "$password_file" && -O "$password_file" && \
       "$(stat -c '%a:%h' -- "$password_file")" == 600:1 ]] \
        || die 'Fichier de mot de passe administrateur non sûr : démarrage refusé.'
    if [[ -s "$password_file" ]]; then
        admin_password="$(cat -- "$password_file")" || exit 1
        : > "$password_file" || exit 1
        args+=(-adminpassword "$admin_password")
    fi
fi
# Le wrapper fournisseur calcule son répertoire avec un dirname non quoté.
# Même s'il échoue sur un chemin avec espaces, son pwd doit désigner ce jeu.
cd -- "$PZ_INSTALL_DIR"
exec ./start-server.sh "${args[@]}" <> "$PZ_CONTROL_PIPE"
