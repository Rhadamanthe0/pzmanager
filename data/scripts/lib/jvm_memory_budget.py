"""Contrat PZ : heap16 Gio, plafond partagé20 Gio (jeu et gestion)."""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shared_memory_budget import check_process

GIB = 1024 ** 3
SERVICE_BUDGET = 20 * GIB
OUTSIDE_HEAP_RESERVE = 4 * GIB
MAX_HEAP_GIB = 16


def choose_heap_gib(override, memory_kib):
    if override:
        if not re.fullmatch(r"(?:[2-9]|1[0-6])", override):
            raise ValueError("PZ_XMX_GB doit être un entier de 2 à 16 : budget total 20 Gio, marge hors heap 4 Gio.")
        return int(override)
    if memory_kib <= 0:
        raise ValueError("RAM physique indisponible : définir PZ_XMX_GB explicitement.")
    # Sur MINIPC (30,6 Gio utilisables), la moitié arrondie vaut 16 Gio.
    return min(MAX_HEAP_GIB, max(2, (memory_kib + 2 * 1024 ** 2 - 1) // (2 * 1024 ** 2)))


def size_bytes(value):
    match = re.fullmatch(r"([1-9][0-9]{0,18})([kKmMgGtT]?)", value)
    if not match:
        raise ValueError("Taille mémoire invalide.")
    return int(match[1]) * 1024 ** ("kmgt".find(match[2].lower()) + 1 if match[2] else 0)


def validate_config(config, memory_max):
    if not isinstance(config, dict):
        raise ValueError("Le JSON JVM doit être un objet.")
    args = config.get("vmArgs")
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError("vmArgs doit être une liste de chaînes.")
    heap_args = [arg[4:] for arg in args if arg.startswith("-Xmx")]
    if len(heap_args) != 1:
        raise ValueError("Le JSON doit contenir exactement un -Xmx explicite.")
    if any(arg.startswith(("-XX:MaxHeapSize=", "-XX:MaxRAM=", "-XX:MaxRAMPercentage=")) for arg in args):
        raise ValueError("Réglage de heap alternatif ambigu : réappliquer configureJvm.sh.")
    heap = size_bytes(heap_args[0])
    if not isinstance(memory_max, int) or memory_max <= 0 or memory_max > SERVICE_BUDGET:
        raise ValueError("MemoryMax effectif doit être fini et au plus 20 Gio ; vérifier les overrides de l'unité.")
    if heap < 2 * GIB or heap + OUTSIDE_HEAP_RESERVE > memory_max:
        raise ValueError("Heap incompatible avec MemoryMax : prévoir au moins 4 Gio hors heap (16 Gio maximum pour un budget de 20 Gio).")
    for arg in args:
        if arg.startswith("-Xms") and size_bytes(arg[4:]) > heap:
            raise ValueError("Xms dépasse Xmx : réappliquer configureJvm.sh.")
    return heap


def cgroup_memory_max(proc_cgroup=Path("/proc/self/cgroup"), cgroup_root=Path("/sys/fs/cgroup")):
    groups = [line[3:] for line in proc_cgroup.read_text().splitlines() if line.startswith("0::")]
    if len(groups) != 1 or not groups[0].startswith("/") or ".." in groups[0].split("/"):
        raise ValueError("Cgroup v2 du processus indisponible.")
    group = cgroup_root / groups[0].lstrip("/")
    limits = []
    # Un processus de contrôle peut être dans un sous-cgroup illimité, soumis
    # au plafond fini du service parent. Parcourir toutes les limites effectives.
    while True:
        parent_limit = group / "memory.max"
        if not (group == cgroup_root and not parent_limit.exists()):
            value = parent_limit.read_text().strip()
            if value != "max":
                if not value.isdigit():
                    raise ValueError("Limite mémoire d'un cgroup invalide.")
                limits.append(int(value))
        if group == cgroup_root:
            break
        group = group.parent
    if not limits:
        raise ValueError("MemoryMax effectif absent ou illimité ; réinstaller l'unité avec MemoryMax=20G.")
    return min(limits)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    choose = commands.add_parser("choose-heap", help="valide l'override ou calcule le défaut plafonné à 16 Gio")
    choose.add_argument("--override", default="")
    choose.add_argument("--memory-kib", type=int, required=True)
    check = commands.add_parser("check", help="contrôle le JSON et le MemoryMax effectif du cgroup courant")
    check.add_argument("json_file", type=Path)
    check.add_argument("--planned-limit", help="validation hors service d'une limite prévue, sans preuve de son application")
    args = parser.parse_args(argv)
    try:
        if args.command == "choose-heap":
            print(choose_heap_gib(args.override, args.memory_kib))
        else:
            if not args.planned_limit:
                check_process()
            limit = size_bytes(args.planned_limit) if args.planned_limit else cgroup_memory_max()
            heap = validate_config(json.loads(args.json_file.read_text()), limit)
            print(f"Budget PZ valide : heap {heap / GIB:g} Gio, MemoryMax {limit / GIB:g} Gio, marge hors heap au moins 4 Gio.")
    except (OSError, ValueError, TypeError) as error:
        print(f"Budget PZ refusé : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
