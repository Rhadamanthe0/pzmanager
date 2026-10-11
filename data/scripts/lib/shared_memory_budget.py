"""Plafond commun PZ : vérifier le vrai parent cgroup, jamais une variable ENV."""
import argparse
from pathlib import Path
import re
import pwd
import os
import sys

GIB = 1024 ** 3
SLICE_NAME = "pz.slice"
BUDGET = 20 * GIB


def process_group(proc_cgroup=Path("/proc/self/cgroup")):
    groups = [line[3:] for line in proc_cgroup.read_text().splitlines() if line.startswith("0::")]
    if len(groups) != 1 or not groups[0].startswith("/") or ".." in groups[0].split("/"):
        raise ValueError("Cgroup v2 indisponible ou invalide.")
    return groups[0]


def slice_group(control_group):
    parts = control_group.split("/")
    if not control_group.startswith("/") or ".." in parts or parts.count(SLICE_NAME) != 1:
        raise ValueError("Processus hors de pz.slice : lancer pzm ou réinstaller les unités.")
    index = parts.index(SLICE_NAME)
    # Le parent appartient au gestionnaire utilisateur, pas à une session SSH.
    if index == 0 or not re.fullmatch(r"user@[0-9]+\.service", parts[index - 1]):
        raise ValueError("pz.slice doit appartenir au gestionnaire systemd utilisateur.")
    return "/".join(parts[:index + 1])


def validate_slice(control_group, cgroup_root=Path("/sys/fs/cgroup")):
    group = cgroup_root / slice_group(control_group).lstrip("/")
    if (group / "memory.max").read_text().strip() != str(BUDGET):
        raise ValueError("Le plafond partagé pz.slice doit être exactement 20 Gio.")
    if (group / "memory.swap.max").read_text().strip() != "0":
        raise ValueError("Le swap de pz.slice doit être interdit.")
    # Existence de ces fichiers = contrôleur mémoire effectivement disponible.
    if not (group / "memory.current").read_text().strip().isdigit():
        raise ValueError("Comptabilité mémoire de pz.slice indisponible.")
    return group


def check_process(proc_cgroup=Path("/proc/self/cgroup"), cgroup_root=Path("/sys/fs/cgroup")):
    return validate_slice(process_group(proc_cgroup), cgroup_root)


def check_identity(env_file, user=None):
    """Lire seulement les identités déclaratives, sans exécuter le .env."""
    current = user or pwd.getpwuid(os.getuid()).pw_name
    values = {"PZ_USER": current}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            match = re.fullmatch(r"\s*(?:export\s+)?(PZ_USER|PZ_GAME_USER|PZ_MANAGER_USER)=(.*?)\s*", line)
            if not match:
                continue
            key, value = match.groups()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if value in ["${PZ_USER}", "$PZ_USER"]:
                value = values["PZ_USER"]
            elif key == "PZ_USER" and value == "$(id -un)":
                value = current  # Valeur connue, aucune commande exécutée.
            if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", value):
                raise ValueError("Identité PZ non déclarative : refus avant installation.")
            values[key] = value
    if values.get("PZ_GAME_USER", values["PZ_USER"]) != values.get("PZ_MANAGER_USER", values["PZ_USER"]):
        raise ValueError("Budget partagé incompatible avec split multi-UID : aucune donnée modifiée.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "inside", "identity"])
    parser.add_argument("env_file", nargs="?", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "identity":
            if args.env_file is None:
                raise ValueError("Fichier .env requis pour contrôler les identités.")
            check_identity(args.env_file)
            return 0
        group = process_group()
        if args.command == "inside":
            # La présence seule sert au routage ; le lancement puis la lecture
            # bloquante check confirment ensuite le plafond et les contrôleurs.
            slice_group(group)
        else:
            validate_slice(group)
    except (OSError, ValueError) as error:
        if args.command != "inside":
            print(f"Budget partagé PZ refusé : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
