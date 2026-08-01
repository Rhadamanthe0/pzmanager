#!/bin/bash
# linkJvm.sh [--auto|--graal|--stock]
#
# Bascule le JRE qu'utilise le serveur PZ entre :
#   - le jre64 BUNDLÉ par PZ (Azul Zulu, "stock") — livré et restauré par SteamCMD ;
#   - GraalVM (compilo Graal JIT actif) pointé par PZ_GRAALVM_HOME dans .env.
#
# Mécanisme : start-server.sh code en dur "${INSTDIR}/jre64/bin/java" et le lanceur
# natif ProjectZomboid64 charge le libjvm.so du java trouvé via ce PATH. On remplace
# donc jre64 par un LIEN SYMBOLIQUE vers GraalVM (le vrai dossier est mis de côté
# dans jre64.stock). Comme `steamcmd ... validate` restaure le vrai jre64 à chaque
# maintenance, on ré-applique le lien à CHAQUE démarrage via l'ExecStartPre de
# zomboid.service (--auto).
#
# Sécurité vis-à-vis de validate : la maintenance appelle --stock AVANT le validate
# pour restaurer le vrai dossier jre64, afin que steamcmd n'écrive JAMAIS à travers
# le lien symbolique (ce qui corromprait l'install GraalVM externe).
#
# --auto  : lie vers GraalVM si PZ_GRAALVM_HOME est valide, sinon garde/rétablit stock.
# --graal : force le lien vers GraalVM (no-op si PZ_GRAALVM_HOME invalide).
# --stock : rétablit le jre64 bundlé (retire le lien, remet jre64.stock).
#
# Réversible : vider PZ_GRAALVM_HOME dans .env -> au prochain démarrage --auto
# rétablit le jre64 stock automatiquement.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source_env

readonly JRE="${PZ_INSTALL_DIR}/jre64"
readonly STOCK="${PZ_INSTALL_DIR}/jre64.stock"
readonly GRAAL="${PZ_GRAALVM_HOME:-}"

mode="${1:---auto}"

graal_ok() { [[ -n "$GRAAL" && -x "${GRAAL}/bin/java" ]]; }

link_graal() {
    if ! graal_ok; then
        log "linkJvm: PZ_GRAALVM_HOME invalide ou absent ('${GRAAL}') — on garde le jre64 bundlé."
        return 0
    fi
    # Sauvegarde unique du vrai jre64 (dossier) avant de le remplacer par un lien.
    # validate le restaure en vrai dossier -> à chaque appel on rafraîchit jre64.stock.
    if [[ -d "$JRE" && ! -L "$JRE" ]]; then
        rm -rf "$STOCK"
        mv "$JRE" "$STOCK"
    fi
    ln -sfn "$GRAAL" "$JRE"
    # Compat libjsig : start-server.sh précharge libjsig.so via LD_LIBRARY_PATH
    # .../jre64/lib/amd64 (chemin JDK legacy, absent des JDK modernes/GraalVM où les
    # libs sont dans lib/). Sans ça : warning "libjsig.so cannot be preloaded" et pas
    # de chaînage de signaux JVM<->natif. On expose lib/amd64 -> lib dans GraalVM.
    if [[ -d "${GRAAL}/lib" && ! -e "${GRAAL}/lib/amd64" ]]; then
        ln -sfn . "${GRAAL}/lib/amd64" 2>/dev/null || true
    fi
    log "linkJvm: jre64 -> GraalVM (${GRAAL})"
}

link_stock() {
    # Ne retirer le lien QUE si on a un vrai dossier à remettre (jamais laisser
    # jre64 absent : le serveur ne démarrerait pas).
    if [[ -L "$JRE" ]]; then
        if [[ -d "$STOCK" ]]; then
            rm -f "$JRE"
            mv "$STOCK" "$JRE"
            log "linkJvm: jre64 rétabli (Zulu bundlé)."
        else
            log "linkJvm: lien jre64 présent mais pas de jre64.stock — on ne touche pas (validate le restaurera)."
        fi
    fi
}

case "$mode" in
    --auto)  graal_ok && link_graal || link_stock ;;
    --graal) link_graal ;;
    --stock) link_stock ;;
    *) die "usage: linkJvm.sh [--auto|--graal|--stock]" ;;
esac
