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

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

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
log "Installation de discord.py..."
"${VENV_DIR}/bin/pip" install --quiet -r "${DISCORD_DIR}/requirements.txt"

log "Installation de l'unité systemd..."
ensure_directory "${SYSTEMD_DIR}"
[[ -f "${TEMPLATE}" ]] || die "Template introuvable: ${TEMPLATE}"
cp "${TEMPLATE}" "${SYSTEMD_DIR}/${UNIT}"

log "Activation du service..."
systemctl --user daemon-reload
systemctl --user enable --now "${UNIT}"

echo ""
if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
    echo "⚠️  DISCORD_BOT_TOKEN est vide dans scripts/.env : le service ne démarrera"
    echo "    pas tant qu'il n'est pas renseigné. Édite scripts/.env puis :"
    echo "      systemctl --user restart ${UNIT}"
else
    log "Bot Discord installé et démarré."
fi
echo "Statut : systemctl --user status ${UNIT}"
echo "Logs   : journalctl --user -u ${UNIT} -f"
