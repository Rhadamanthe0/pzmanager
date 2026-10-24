#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# setupDiscordBot.sh - Installe/active le bot Discord pzmanager
# ------------------------------------------------------------------------------
# - Crée le venv Python et installe discord.py
# - Installe l'unité systemd --user pz-discord-bot.service
# - Active et démarre le service
# S'exécute en tant que pzuser (pas de sudo requis).
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Bootstrap minimal avant secrets/venv : le parent manque sur une install bot seul.
[[ "$(id -u)" != 0 ]] || { echo 'Installer le bot avec le compte manager.' >&2; exit 1; }
python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" identity "${SCRIPT_DIR}/../../../.env"
mkdir -p "${HOME}/.config/systemd/user"
if [[ ! -e "${HOME}/.config/systemd/user/pz.slice" ]]; then
    install -m 644 "${SCRIPT_DIR}/../../setupTemplates/pz.slice" "${HOME}/.config/systemd/user/pz.slice"
    systemctl --user daemon-reload
fi
if ! python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" inside; then
    exec bash "${SCRIPT_DIR}/../lib/run_in_pz_slice.sh" /bin/bash "$0" "$@"
fi
python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" check
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
[[ "${PZ_GAME_USER}" == "${PZ_MANAGER_USER}" ]] || die "Budget partagé incompatible avec split multi-UID."

# Requis pour systemctl --user (ex. si lancé hors session interactive)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

readonly DISCORD_DIR="${PZ_SCRIPTS_DIR}/discord"
readonly VENV_DIR="${DISCORD_DIR}/.venv"
readonly SYSTEMD_DIR="${HOME}/.config/systemd/user"
readonly UNIT="pz-discord-bot.service"
readonly TEMPLATE="${PZ_DATA_DIR}/setupTemplates/${UNIT}"

command -v python3 >/dev/null 2>&1 || die "python3 introuvable"
python3 -c "import ensurepip" >/dev/null 2>&1 || die \
    "Paquet python3-venv manquant. Installe-le en root :  sudo apt install python3-venv
    (ou relance 'pzm install system' qui l'inclut désormais), puis réessaie."

log "Création du venv Python (${VENV_DIR})..."
python3 -m venv "${VENV_DIR}"
log "Mise à jour de pip dans le venv..."
"${VENV_DIR}/bin/python" -m pip install --quiet --upgrade "pip>=26.2"
log "Installation des dépendances Discord..."
"${VENV_DIR}/bin/python" -m pip install --quiet -r "${DISCORD_DIR}/requirements.txt"

log "Installation de l'unité systemd..."
ensure_directory "${SYSTEMD_DIR}"
[[ -f "${TEMPLATE}" ]] || die "Template introuvable: ${TEMPLATE}"
cp "${TEMPLATE}" "${SYSTEMD_DIR}/${UNIT}"

log "Activation du service..."
systemctl --user daemon-reload
systemctl --user enable --now "${UNIT}"

echo ""
if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
    echo "⚠️  DISCORD_BOT_TOKEN est vide dans .env : le service ne démarrera"
    echo "    pas tant qu'il n'est pas renseigné. Édite .env puis :"
    echo "      systemctl --user restart ${UNIT}"
else
    log "Bot Discord installé et démarré."
fi
echo "Statut : systemctl --user status ${UNIT}"
echo "Logs   : journalctl --user -u ${UNIT} -f"
