#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# run-bot.sh - Launcher du bot Discord pzmanager (lancé par pz-discord-bot.service)
# ------------------------------------------------------------------------------
# Source .env (via common.sh) puis exec le bot Python du venv.
# Le .env utilise `export`/`${...}` -> non chargeable en EnvironmentFile systemd,
# d'où ce launcher qui reproduit le pattern "chaque script source l'env".
# ------------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

[[ -n "${DISCORD_BOT_TOKEN:-}" ]] || die "DISCORD_BOT_TOKEN non configuré dans scripts/.env"
[[ -x "${SCRIPT_DIR}/.venv/bin/python" ]] || die "venv absent — lancer: pzm install discord"

exec "${SCRIPT_DIR}/.venv/bin/python" "${SCRIPT_DIR}/bot.py"
