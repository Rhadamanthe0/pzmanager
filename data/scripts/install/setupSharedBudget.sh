#!/usr/bin/env bash
# Migration de ressources uniquement : aucune mise à jour Steam, aucun start.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "$(id -u)" != 0 ]] || { echo 'Lancer en tant que manager PZ, pas root.' >&2; exit 1; }
python3 "${SCRIPT_DIR}/../lib/shared_memory_budget.py" identity "${SCRIPT_DIR}/../../../.env"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env
[[ "${PZ_GAME_USER}" == "${PZ_MANAGER_USER}" ]] || die 'Budget commun incompatible avec split multi-UID.'
acquire_world_lock --required
acquire_serverctl_lock_or_die
python3 "${SCRIPT_DIR}/../lib/jvm_memory_budget.py" check \
    "${PZ_INSTALL_DIR}/ProjectZomboid64.json" --planned-limit 20G
python3 "${SCRIPT_DIR}/../lib/install_shared_budget.py" \
    "${PZ_DATA_DIR}/setupTemplates" "${HOME}/.config/systemd/user" \
    "${HOME}/.local/state/pzmanager"
systemctl --user daemon-reload
# Un drop-in local plus tardif peut vider ExecStartPre ; ne pas annoncer une
# migration réussie si le garde effectif a disparu. L'archive reste disponible.
for unit in zomboid.service zomboid_logger.service pz-discord-bot.service \
    pz-backup.service pz-maintenance.service pz-modcheck.service \
    pz-heapcheck.service pz-stallwatch.service pz-creation-date-init.service; do
    [[ -f "${HOME}/.config/systemd/user/$unit" ]] || continue
    [[ "$(systemctl --user show "$unit" -p Slice --value)" == pz.slice ]] \
        || die "Placement effectif incorrect : $unit"
    pre="$(systemctl --user show "$unit" -p ExecStartPre --value)"
    if [[ "$pre" != *"shared_memory_budget.py check"* ]] \
        && ! { [[ "$unit" == zomboid.service && "$pre" == *"jvm_memory_budget.py check"* ]]; }; then
        die "Garde effectif absent après reload : $unit (archive conservée)."
    fi
    [[ "$pre" != *"--planned-limit"* ]] || die "Validation hors service interdite dans ExecStartPre : $unit"
done
echo 'Budget partagé installé ; aucun service démarré. Vérifier les cgroups après reprise planifiée.'
