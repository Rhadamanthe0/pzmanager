#!/bin/bash
# configureJvm.sh - (Ré)applique le tuning JVM dans ProjectZomboid64.json
# SteamCMD (app_update ... validate) restaure le JSON vanilla à chaque update :
# ce script est appelé à l'installation ET après chaque mise à jour du serveur
# (maintenance quotidienne). Idempotent : repart des args vanilla avant de
# poser les nôtres.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

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

# Exporteur de métriques réseau interne de PZ (voir plus bas). Vide => désactivé.
prom_port="${PZ_PROMETHEUS_PORT:-}"

cp "$json_file" "${json_file}.bak"

python3 - "$json_file" "$xmx_gb" "$LOG_ZOMBOID_DIR" "$prom_port" << 'PYEOF'
import json, sys

f = sys.argv[1]
xmx_gb = sys.argv[2]
log_dir = sys.argv[3]
prom_port = sys.argv[4]
with open(f) as fp:
    data = json.load(fp)

# Repartir des args sans aucun réglage mémoire/GC/réseau/diag qu'on (re)pose nous-mêmes.
# '-Xms' reste dans la liste retirée -> on NE le repose PAS (défaut JVM = init à la demande).
drop = ('znetlog', '-Xms', '-Xmx', 'UseZGC', 'AlwaysPreTouch',
        'ZCollectionInterval', 'MaxRAMPercentage', 'preferIPv4Stack',
        'UseStringDeduplication', 'UseCompactObjectHeaders',
        'HeapDumpOnOutOfMemoryError', 'HeapDumpPath', 'Xlog:gc',
        'prometheusEnabled', 'prometheusPort', 'OmitStackTraceInFastThrow',
        'jdk.graal')
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

# En-têtes d'objets compacts (Projet Lilliput, JEP 519 — product en JDK 25, off par
# défaut). Ramène l'en-tête de CHAQUE objet de ~12 à 8 octets. Le heap PZ est fait
# de MILLIONS de petits objets (IsoGridSquare/IsoObject/chunks) -> cas idéal :
# ~10-20% de live set en moins => moins de RAM résidente ET OOM repoussé (il RÉDUIT
# les données vivantes, là où monter -Xmx ne fait que retarder). Bonus perf : moins
# d'octets à marquer/relocaliser + meilleure localité cache -> pauses GC plutôt plus
# courtes. À surveiller (encore off par défaut côté Oracle) ; retrait = cette ligne.
args.append('-XX:+UseCompactObjectHeaders')

# Stabilité réseau : forcer la pile IPv4 (évite le fallback IPv6 de RakNet/UdpEngine)
args.append('-Djava.net.preferIPv4Stack=true')

# Réglage du compilo Graal JIT. Actif UNIQUEMENT sur GraalVM (voir linkJvm.sh /
# PZ_GRAALVM_HOME) : propriété système lue par le compilo Graal. Sur le jre64 bundlé
# (Zulu/HotSpot, sans compilo Graal) elle est IGNORÉE -> inoffensive.
# IMPORTANT : sur Oracle GraalVM 25, TOUTES les optims perf enterprise (Vectorization,
# VectorIntrinsics, toutes les optims de boucles, PEA/escape analysis, inlining) sont
# déjà ON par défaut -> inutile de les poser (redondant + risque de crash si un nom
# change/disparaît : GraalVM VALIDE les -Djdk.graal.* et plante fatalement sur un nom
# inconnu, contrairement à HotSpot). On ne pose donc QUE ce qui diffère du défaut :
# TuneInlinerExploration (défaut 0.0 -> 1 = explore + d'opportunités d'inlining ;
# temps de compil amorti sur un serveur longue durée). Ciblé sur nos boucles
# d'allocation intensives (instanciation d'IsoGridSquare à la génération de chunks
# = les gels mono-thread diagnostiqués). Vérifié existant sur GraalVM 25.
args.append('-Djdk.graal.TuneInlinerExploration=1')

# Diagnostic : toujours imprimer la stack trace COMPLÈTE des exceptions répétées.
# Par défaut la JVM tronque la trace des exceptions "fast-throw" (NPE, AIOOBE...)
# une fois le point chaud JIT-compilé -> on perd la trace des NPE de désync
# récurrents (HumanVisualPacket getPlayer()-null, IsoMetaGrid.save). Vanilla Linux
# le fournit déjà, mais on le pose explicitement (et on le retire de la liste ci-
# dessus) pour ne pas dépendre du JSON vanilla. Coût négligeable.
args.append('-XX:-OmitStackTraceInFastThrow')

# Diagnostic mémoire : dump heap auto sur OutOfMemoryError (post-mortem de fuite,
# ~Xmx Go sur disque, 362 Go libres) + log GC rotatif (croissance heap-after-GC
# = fuite vs simplement sous-dimensionné). Analysable ensuite avec Eclipse MAT.
args.append('-XX:+HeapDumpOnOutOfMemoryError')
args.append(f'-XX:HeapDumpPath={log_dir}')
args.append(f'-Xlog:gc*:file={log_dir}/gc.log:time,uptime,level,tags:filecount=5,filesize=20M')

# Métriques réseau internes de PZ (client Prometheus embarqué). Avec
# MultiplayerStatisticsPeriod>0 (servertest.ini), StatisticManager collecte
# serverPacketSend/serverPacketReceive : des histogrammes PAR TYPE de paquet dont
# _count = NOMBRE de paquets et _sum = OCTETS. Il ne démarre son exporteur HTTP
# /metrics QUE si ces deux propriétés système sont posées (lues via getProperty).
# Une fois actif -> source EXACTE des paquets/s du SEUL serveur de jeu (bien plus
# propre que la mesure au niveau de la carte réseau, polluée par Docker/Pi-hole/WG),
# scrappée par le bot Discord (monitoring). Vide (PZ_PROMETHEUS_PORT non défini) =
# désactivé. ATTENTION : l'exporteur peut binder 0.0.0.0 et les métriques incluent
# la position des joueurs -> vérifier `ss -tlnp` après boot et garder ce port
# NON redirigé par le routeur.
if prom_port:
    args.append('-DprometheusEnabled=true')
    args.append(f'-DprometheusPort={prom_port}')

data['vmArgs'] = args
with open(f, 'w') as fp:
    json.dump(data, fp, indent='\t')
    fp.write('\n')

for a in data['vmArgs']:
    print(f'  {a}')
PYEOF
