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

python3 - "$json_file" "$xms_gb" "$xmx_gb" "$LOG_ZOMBOID_DIR" << 'PYEOF'
import json, sys

f = sys.argv[1]
xms_gb = sys.argv[2]
xmx_gb = sys.argv[3]
log_dir = sys.argv[4]
with open(f) as fp:
    data = json.load(fp)

# Repartir des args sans aucun réglage mémoire/GC/réseau/diag qu'on (re)pose nous-mêmes
drop = ('znetlog', '-Xms', '-Xmx', 'UseZGC', 'AlwaysPreTouch',
        'ZCollectionInterval', 'MaxRAMPercentage', 'preferIPv4Stack',
        'HeapDumpOnOutOfMemoryError', 'HeapDumpPath', 'Xlog:gc')
args = [a for a in data['vmArgs'] if not any(d in a for d in drop)]

# Heap : plancher fixe Xms, plafond = moitié de la RAM (give-back ZGC entre les deux)
args.append(f'-Xms{xms_gb}g')
args.append(f'-Xmx{xmx_gb}g')

# ZGC + pré-touche du heap initial + cycle périodique 5s
args.append('-XX:+UseZGC')
args.append('-XX:+AlwaysPreTouch')
args.append('-XX:ZCollectionInterval=5')

# Stabilité réseau : forcer la pile IPv4 (évite le fallback IPv6 de RakNet/UdpEngine)
args.append('-Djava.net.preferIPv4Stack=true')

# Diagnostic mémoire : dump heap auto sur OutOfMemoryError (post-mortem de fuite,
# ~Xmx Go sur disque, 362 Go libres) + log GC rotatif (croissance heap-after-GC
# = fuite vs simplement sous-dimensionné). Analysable ensuite avec Eclipse MAT.
args.append('-XX:+HeapDumpOnOutOfMemoryError')
args.append(f'-XX:HeapDumpPath={log_dir}')
args.append(f'-Xlog:gc*:file={log_dir}/gc.log:time,uptime,level,tags:filecount=5,filesize=20M')

data['vmArgs'] = args
with open(f, 'w') as fp:
    json.dump(data, fp, indent='\t')
    fp.write('\n')

for a in data['vmArgs']:
    print(f'  {a}')
PYEOF
