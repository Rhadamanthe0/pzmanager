#!/bin/bash
# configureJvm.sh - (Ré)applique le tuning JVM dans ProjectZomboid64.json
# SteamCMD (app_update ... validate) restaure le JSON vanilla à chaque update :
# ce script est appelé à l'installation ET après chaque mise à jour du serveur
# (maintenance quotidienne). Idempotent : repart des args vanilla avant de
# poser les nôtres.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env "${SCRIPT_DIR}/.."

json_file="${PZ_INSTALL_DIR}/ProjectZomboid64.json"
[[ -f "$json_file" ]] || exit 0

# Heap Java : Xms=2g fixe (plancher, give-back ZGC au-dessus), Xmx=moitié de
# la RAM physique (garde-fou réel laissant la place au natif PZ + l'OS).
# On ne pose AUCUN plafond cgroup (MemoryMax/MemoryHigh) : il throttle/OOM
# PZ dès qu'il est atteint. Voir aussi data/setupTemplates/zomboid.service.
xms_gb=2
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
xmx_gb=$(( mem_kb / 1024 / 1024 / 2 ))
(( xmx_gb < xms_gb )) && xmx_gb=$xms_gb  # Xmx jamais sous le plancher Xms

echo "Optimisation JVM (Xms ${xms_gb}g / Xmx ${xmx_gb}g = moitié RAM)..."
cp "$json_file" "${json_file}.bak"

python3 - "$json_file" "$xms_gb" "$xmx_gb" << 'PYEOF'
import json, sys

f = sys.argv[1]
xms_gb = sys.argv[2]
xmx_gb = sys.argv[3]
with open(f) as fp:
    data = json.load(fp)

# Repartir des args sans aucun réglage mémoire/GC qu'on (re)pose nous-mêmes
drop = ('znetlog', '-Xms', '-Xmx', 'UseZGC', 'AlwaysPreTouch',
        'ZCollectionInterval', 'MaxRAMPercentage')
args = [a for a in data['vmArgs'] if not any(d in a for d in drop)]

# Heap : plancher fixe Xms, plafond = moitié de la RAM (give-back ZGC entre les deux)
args.append(f'-Xms{xms_gb}g')
args.append(f'-Xmx{xmx_gb}g')

# ZGC + pré-touche du heap initial + cycle périodique 5s
args.append('-XX:+UseZGC')
args.append('-XX:+AlwaysPreTouch')
args.append('-XX:ZCollectionInterval=5')

data['vmArgs'] = args
with open(f, 'w') as fp:
    json.dump(data, fp, indent='\t')
    fp.write('\n')

for a in data['vmArgs']:
    print(f'  {a}')
PYEOF
