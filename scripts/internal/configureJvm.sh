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

# Heap Java : PAS de -Xms (retiré) — avec AlwaysPreTouch il était trompeur (le
# vrai poste résident est le Xmx pré-touché, pas Xms) et le give-back ZGC ne se
# déclenche jamais sur ce workload (le heap ne fait que croître de cellules
# vivantes). Sans -Xms, l'init part du défaut ergonomique et croît à la demande.
# Xmx = moitié de la RAM physique par défaut (garde-fou laissant la place au natif
# PZ + l'OS), override via .env (PZ_XMX_GB, en Go).
# On ne pose AUCUN plafond cgroup (MemoryMax/MemoryHigh) : il throttle/OOM
# PZ dès qu'il est atteint. Voir aussi data/setupTemplates/zomboid.service.
# ATTENTION PZ_XMX_GB: dépasser la moitié de la RAM est RISQUÉ — avec AlwaysPreTouch
# tout le Xmx est résident dès le boot ; Xmx + ~5 Go de natif PZ peut dépasser la
# RAM totale → OOM-killer OS (SIGKILL brutal). Ne relever qu'en connaissance de cause.
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
default_xmx_gb=$(( mem_kb / 1024 / 1024 / 2 ))
xmx_gb="${PZ_XMX_GB:-$default_xmx_gb}"
(( xmx_gb < 2 )) && xmx_gb=2  # plancher de sécurité

if [[ -n "${PZ_XMX_GB:-}" ]]; then
    echo "Optimisation JVM (Xmx ${xmx_gb}g = override PZ_XMX_GB ; moitié RAM = ${default_xmx_gb}g ; pas de Xms)..."
else
    echo "Optimisation JVM (Xmx ${xmx_gb}g = moitié RAM ; pas de Xms)..."
fi
cp "$json_file" "${json_file}.bak"

python3 - "$json_file" "$xmx_gb" "$LOG_ZOMBOID_DIR" << 'PYEOF'
import json, sys

f = sys.argv[1]
xmx_gb = sys.argv[2]
log_dir = sys.argv[3]
with open(f) as fp:
    data = json.load(fp)

# Repartir des args sans aucun réglage mémoire/GC/réseau/diag qu'on (re)pose nous-mêmes.
# '-Xms' reste dans la liste retirée -> on NE le repose PAS (défaut JVM = init à la demande).
drop = ('znetlog', '-Xms', '-Xmx', 'UseZGC', 'AlwaysPreTouch',
        'ZCollectionInterval', 'MaxRAMPercentage', 'preferIPv4Stack',
        'UseStringDeduplication',
        'HeapDumpOnOutOfMemoryError', 'HeapDumpPath', 'Xlog:gc')
args = [a for a in data['vmArgs'] if not any(d in a for d in drop)]

# Heap : plafond Xmx uniquement (pas de -Xms -> init ergonomique, croît à la demande)
args.append(f'-Xmx{xmx_gb}g')

# ZGC (générationnel par défaut en JDK 25) + pré-touche + cycle périodique.
# ZCollectionInterval force une collecte MAJEURE (young + old) à cet intervalle.
# À 5s, la passe old (~4,5s, ne libère quasi rien sur ce heap majoritairement
# vivant) tournait en quasi-continu -> CPU de fond + chauffe. À 60s, les collectes
# young restent fréquentes/bon marché (pilotées par l'allocation) et les majeures
# deviennent rares. Le moniteur heap (pz-heapcheck, ~3 min) lit la dernière ligne
# "Major Collection" de gc.log : une majeure/min suffit largement (le heap met
# ~15 h à se remplir). Remonter si gc.log devient trop clairsemé.
args.append('-XX:+UseZGC')
args.append('-XX:+AlwaysPreTouch')
args.append('-XX:ZCollectionInterval=60')

# Déduplication des String : le heap est plein de cellules de map aux chaînes
# répétées (noms de sprites/tiles) -> la dédup réduit la part String du live set
# et retarde marginalement l'OOM. Coût = un thread de fond, négligeable.
args.append('-XX:+UseStringDeduplication')

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
